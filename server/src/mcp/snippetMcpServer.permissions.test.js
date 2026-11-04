/*
 * Permission tests for the MCP tools: every call runs as one API-key user and must only
 * reach what that user could reach in the web UI. Runs against a throwaway database.
 */
import assert from "node:assert/strict";
import { after, before, describe, test } from "node:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const dbDir = fs.mkdtempSync(path.join(os.tmpdir(), "bytestash-mcp-test-"));
process.env.BYTESTASH_DB_DIR = dbDir;

const { initializeDatabase, getDb, shutdownDatabase } = await import("../config/database.js");
const { Client } = await import("@modelcontextprotocol/sdk/client/index.js");
const { InMemoryTransport } = await import("@modelcontextprotocol/sdk/inMemory.js");
const { createMcpServer } = await import("./snippetMcpServer.js");
const groupRepository = (await import("../repositories/groupRepository.js")).default;

const users = {};
const groups = {};
const snippets = {};
const clients = [];

function addUser(username, email = null) {
  const db = getDb();
  const id = db
    .prepare("INSERT INTO users (username, username_normalized, password_hash, email) VALUES (?, ?, 'x', ?)")
    .run(username, username.toLowerCase(), email).lastInsertRowid;
  return Number(id);
}

async function connect(userId, { isAdmin = false } = {}) {
  const server = createMcpServer(userId, { isAdmin });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "test", version: "1.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  clients.push(client, server);

  const call = async (name, args = {}) => {
    const result = await client.callTool({ name, arguments: args });
    const text = result.content[0].text;
    return { error: !!result.isError, text, data: result.isError ? null : JSON.parse(text) };
  };
  return call;
}

const as = {};

before(async () => {
  initializeDatabase();
  users.alice = addUser("alice", "alice@example.com");
  users.bob = addUser("bob", "bob@example.com");
  users.carol = addUser("carol", "carol.secret@example.com");
  users.dave = addUser("dave");

  groups.team = groupRepository.create({ name: "team" }).id;
  groupRepository.addMember(groups.team, users.alice);
  groupRepository.addMember(groups.team, users.bob);
  groups.other = groupRepository.create({ name: "other" }).id;
  groupRepository.addMember(groups.other, users.carol);

  for (const name of Object.keys(users)) as[name] = await connect(users[name]);

  const create = async (title, extra) => {
    const result = await as.alice("create_snippet", {
      title,
      fragments: [{ file_name: "a.js", code: `// ${title} secret-code`, language: "javascript" }],
      ...extra,
    });
    assert.equal(result.error, false, result.text);
    return result.data.id;
  };
  snippets.private = await create("private", { visibility: "private" });
  snippets.public = await create("public", { visibility: "public" });
  snippets.teamView = await create("team view", {
    visibility: "protected",
    share_with: [{ type: "group", id: groups.team, permission: "view" }],
  });
  snippets.carolEdit = await create("carol edit", {
    visibility: "protected",
    share_with: [{ type: "user", id: users.carol, permission: "edit" }],
  });
  snippets.locked = await create("locked", {
    visibility: "protected",
    share_with: [{ type: "user", id: users.bob, permission: "edit" }],
    edit_permission: "readonly",
  });
});

after(async () => {
  for (const c of clients) await c.close();
  shutdownDatabase();
  fs.rmSync(dbDir, { recursive: true, force: true });
});

describe("reading", () => {
  test("outsiders cannot read private or shared snippets", async () => {
    for (const id of [snippets.private, snippets.teamView, snippets.carolEdit, snippets.locked]) {
      const result = await as.dave("get_snippet", { id });
      assert.equal(result.error, true, `dave read snippet ${id}`);
    }
    assert.equal((await as.dave("get_snippet", { id: snippets.public })).error, false);
  });

  test("shared listing and code search only reach public and shared-with-me snippets", async () => {
    const dave = await as.dave("list_snippets", { scope: "shared", search: "secret-code" });
    assert.deepEqual(dave.data.snippets.map((s) => s.id), [snippets.public]);

    const bob = await as.bob("list_snippets", { scope: "shared", search: "secret-code" });
    assert.deepEqual(
      bob.data.snippets.map((s) => s.id).sort(),
      [snippets.public, snippets.teamView, snippets.locked].sort()
    );
  });

  test("own scope and metadata only cover the caller's snippets", async () => {
    const mine = await as.bob("list_snippets", {});
    assert.equal(mine.data.pagination.total, 0);
    const meta = await as.bob("list_metadata");
    assert.equal(meta.data.counts.total, 0);
  });

  test("group members can read, and lose access when removed", async () => {
    assert.equal((await as.bob("get_snippet", { id: snippets.teamView })).error, false);
    groupRepository.removeMember(groups.team, users.bob);
    assert.equal((await as.bob("get_snippet", { id: snippets.teamView })).error, true);
    groupRepository.addMember(groups.team, users.bob);
  });

  test("share recipients do not see the owner's private flags", async () => {
    const result = await as.bob("get_snippet", { id: snippets.teamView });
    assert.equal(result.data.can_edit, false);
    assert.equal(result.data.is_favorite, undefined);
    assert.equal(result.data.is_pinned, undefined);
  });
});

describe("editing", () => {
  test("view-only recipients and outsiders cannot edit", async () => {
    const bob = await as.bob("update_snippet", { id: snippets.teamView, title: "hacked" });
    assert.equal(bob.error, true);
    const dave = await as.dave("update_snippet", { id: snippets.private, title: "hacked" });
    assert.equal(dave.error, true);
    const check = await as.alice("get_snippet", { id: snippets.teamView });
    assert.equal(check.data.title, "team view");
  });

  test("edit recipients can change content", async () => {
    const result = await as.carol("update_snippet", { id: snippets.carolEdit, title: "edited by carol" });
    assert.equal(result.error, false, result.text);
    assert.equal(result.data.title, "edited by carol");
  });

  test("edit recipients cannot change sharing, visibility or the lock", async () => {
    for (const change of [
      { share_with: [{ type: "user", id: users.dave, permission: "edit" }] },
      { visibility: "public" },
      { is_public: true },
      { edit_permission: "readonly" },
    ]) {
      const result = await as.carol("update_snippet", { id: snippets.carolEdit, ...change });
      assert.equal(result.error, true, `carol changed ${JSON.stringify(change)}`);
    }
    const check = await as.alice("get_snippet", { id: snippets.carolEdit });
    assert.equal(check.data.visibility, "protected");
    assert.equal(check.data.edit_permission, "owner");
    assert.deepEqual(check.data.shared_with.map((s) => s.id), [users.carol]);
    assert.equal((await as.dave("get_snippet", { id: snippets.carolEdit })).error, true);
  });

  test("edit recipients cannot delete", async () => {
    assert.equal((await as.carol("delete_snippet", { id: snippets.carolEdit })).error, true);
    assert.equal((await as.carol("delete_snippet", { id: snippets.carolEdit, permanent: true })).error, true);
    assert.equal((await as.alice("get_snippet", { id: snippets.carolEdit })).error, false);
  });

  test("locked snippets reject edits from recipients and the owner", async () => {
    const bob = await as.bob("update_snippet", { id: snippets.locked, title: "x" });
    assert.equal(bob.error, true);
    const alice = await as.alice("update_snippet", { id: snippets.locked, title: "x" });
    assert.equal(alice.error, true);
    assert.match(alice.text, /locked/i);
    const unlock = await as.alice("update_snippet", { id: snippets.locked, edit_permission: "owner" });
    assert.equal(unlock.error, false, unlock.text);
    const bobAgain = await as.bob("update_snippet", { id: snippets.locked, title: "bob edit" });
    assert.equal(bobAgain.error, false, bobAgain.text);
  });
});

describe("sharing", () => {
  const base = { title: "t", fragments: [{ code: "x" }], visibility: "protected" };

  test("non-admins can only share with their own groups", async () => {
    const result = await as.bob("create_snippet", {
      ...base,
      share_with: [{ type: "group", id: groups.other }],
    });
    assert.equal(result.error, true);
  });

  test("an unknown group and someone else's group give the same error", async () => {
    const other = await as.bob("create_snippet", { ...base, share_with: [{ type: "group", id: groups.other }] });
    const missing = await as.bob("create_snippet", { ...base, share_with: [{ type: "group", id: 9999 }] });
    assert.equal(other.text, missing.text.replace("9999", String(groups.other)));
  });

  test("share_with does not resolve email addresses", async () => {
    const result = await as.bob("create_snippet", {
      ...base,
      share_with: [{ type: "user", username: "carol.secret@example.com" }],
    });
    assert.equal(result.error, true);
    assert.doesNotMatch(result.text, /carol"/);
  });

  test("share_with by username works", async () => {
    const result = await as.bob("create_snippet", {
      ...base,
      share_with: [{ type: "user", username: "Carol", permission: "edit" }],
    });
    assert.equal(result.error, false, result.text);
    assert.deepEqual(result.data.shared_with, [{ type: "user", id: users.carol, name: "carol", permission: "edit" }]);
    assert.equal((await as.carol("get_snippet", { id: result.data.id })).data.can_edit, true);
  });

  test("find_users returns only ids and usernames, never emails", async () => {
    const result = await as.bob("find_users", { query: "example" });
    assert.deepEqual(result.data, []);
    const carol = await as.bob("find_users", { query: "car" });
    assert.deepEqual(carol.data, [{ id: users.carol, username: "carol" }]);
  });

  test("list_groups only shows the caller's groups", async () => {
    const result = await as.bob("list_groups");
    assert.deepEqual(result.data.map((g) => g.id), [groups.team]);
  });
});
