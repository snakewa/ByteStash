import { getDb } from '../config/database.js';

const normalizeEmail = (email) => (email || '').trim().toLowerCase();

class GroupRepository {
  findAll() {
    return getDb()
      .prepare(`
        SELECT
          g.id,
          g.name,
          g.description,
          g.created_at,
          (SELECT COUNT(*) FROM user_group_members m WHERE m.group_id = g.id) as member_count,
          (SELECT COUNT(*) FROM user_group_invites i WHERE i.group_id = g.id) as invite_count,
          (SELECT COUNT(*) FROM snippet_shares sh WHERE sh.group_id = g.id) as snippet_count
        FROM user_groups g
        ORDER BY g.name COLLATE NOCASE
      `)
      .all();
  }

  findById(id) {
    return getDb().prepare('SELECT id, name, description, created_at FROM user_groups WHERE id = ?').get(id);
  }

  findForUser(userId) {
    return getDb()
      .prepare(`
        SELECT g.id, g.name, g.description
        FROM user_groups g
        INNER JOIN user_group_members m ON m.group_id = g.id
        WHERE m.user_id = ?
        ORDER BY g.name COLLATE NOCASE
      `)
      .all(userId);
  }

  create({ name, description = null }) {
    const result = getDb()
      .prepare('INSERT INTO user_groups (name, description) VALUES (?, ?)')
      .run(name, description);
    return this.findById(result.lastInsertRowid);
  }

  update(id, { name, description = null }) {
    const result = getDb()
      .prepare('UPDATE user_groups SET name = ?, description = ? WHERE id = ?')
      .run(name, description, id);
    return result.changes > 0 ? this.findById(id) : null;
  }

  // Shares with a deleted group go away; a snippet left with no shares is private again.
  delete(id) {
    return getDb().prepare('DELETE FROM user_groups WHERE id = ?').run(id).changes > 0;
  }

  isMember(groupId, userId) {
    return !!getDb()
      .prepare('SELECT 1 FROM user_group_members WHERE group_id = ? AND user_id = ?')
      .get(groupId, userId);
  }

  getMembers(groupId) {
    return getDb()
      .prepare(`
        SELECT u.id, u.username, u.email, u.name, u.oidc_id IS NOT NULL as is_oidc, m.created_at as added_at
        FROM user_group_members m
        INNER JOIN users u ON u.id = m.user_id
        WHERE m.group_id = ?
        ORDER BY u.username COLLATE NOCASE
      `)
      .all(groupId);
  }

  addMember(groupId, userId) {
    getDb()
      .prepare('INSERT OR IGNORE INTO user_group_members (group_id, user_id) VALUES (?, ?)')
      .run(groupId, userId);
  }

  removeMember(groupId, userId) {
    return getDb()
      .prepare('DELETE FROM user_group_members WHERE group_id = ? AND user_id = ?')
      .run(groupId, userId).changes > 0;
  }

  getInvites(groupId) {
    return getDb()
      .prepare('SELECT email, created_at FROM user_group_invites WHERE group_id = ? ORDER BY email')
      .all(groupId);
  }

  addInvite(groupId, email) {
    getDb()
      .prepare('INSERT OR IGNORE INTO user_group_invites (group_id, email) VALUES (?, ?)')
      .run(groupId, normalizeEmail(email));
  }

  removeInvite(groupId, email) {
    return getDb()
      .prepare('DELETE FROM user_group_invites WHERE group_id = ? AND email = ?')
      .run(groupId, normalizeEmail(email)).changes > 0;
  }

  // People a snippet can be shared with: username matches (no emails exposed), excluding the searcher.
  searchUsers(query, excludeUserId, limit = 10) {
    const value = (query || '').trim().toLowerCase();
    if (!value) return [];
    const escaped = value.replace(/[\\%_]/g, (c) => `\\${c}`);
    return getDb()
      .prepare(`
        SELECT id, username FROM users
        WHERE id != 0 AND id != ? AND username_normalized LIKE ? ESCAPE '\\'
        ORDER BY CASE WHEN username_normalized LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END, username COLLATE NOCASE
        LIMIT ?
      `)
      .all(excludeUserId, `%${escaped}%`, `${escaped}%`, limit);
  }

  findUserById(id) {
    return getDb().prepare('SELECT id, username FROM users WHERE id = ? AND id != 0').get(id);
  }

  findUserByUsername(username) {
    const value = (username || '').trim().toLowerCase();
    if (!value) return null;
    return getDb()
      .prepare('SELECT id, username FROM users WHERE id != 0 AND username_normalized = ?')
      .get(value);
  }

  findUserByUsernameOrEmail(identifier) {
    const value = (identifier || '').trim();
    if (!value) return null;
    return getDb()
      .prepare(`
        SELECT id, username, email FROM users
        WHERE id != 0 AND (username_normalized = ? COLLATE NOCASE OR email = ? COLLATE NOCASE)
        ORDER BY CASE WHEN username_normalized = ? COLLATE NOCASE THEN 0 ELSE 1 END
        LIMIT 1
      `)
      .get(value.toLowerCase(), value, value.toLowerCase());
  }

  hasInvite(email) {
    if (!normalizeEmail(email)) return false;
    return !!getDb()
      .prepare('SELECT 1 FROM user_group_invites WHERE email = ?')
      .get(normalizeEmail(email));
  }

  // Turns pending email invites into memberships once that person has an account.
  acceptInvites(userId, email) {
    const normalized = normalizeEmail(email);
    if (!normalized) return 0;
    const db = getDb();
    return db.transaction(() => {
      const invites = db
        .prepare('SELECT group_id FROM user_group_invites WHERE email = ?')
        .all(normalized);
      for (const { group_id } of invites) {
        this.addMember(group_id, userId);
      }
      db.prepare('DELETE FROM user_group_invites WHERE email = ?').run(normalized);
      return invites.length;
    })();
  }
}

export default new GroupRepository();
