import Logger from "../logger.js";
import snippetRepository from "../repositories/snippetRepository.js";
import groupRepository from "../repositories/groupRepository.js";

export class VisibilityError extends Error {
  constructor(message, status = 400) {
    super(message);
    this.status = status;
  }
}

const EDIT_PERMISSIONS = ["owner", "readonly"];
const SHARE_PERMISSIONS = ["view", "edit"];

/**
 * "owner" (default): the owner plus share targets given "edit" may change the content;
 * "readonly": locked for everyone, the owner included, until the owner unlocks it.
 * The legacy "group" value is accepted as "owner" (its meaning now lives on each share).
 */
function resolveEditPermission(snippetData, { existing = null } = {}) {
  let permission = snippetData.edit_permission ?? existing?.edit_permission ?? "owner";
  if (permission === "group") permission = "owner";
  if (!EDIT_PERMISSIONS.includes(permission)) {
    throw new VisibilityError(`Unknown edit permission: ${permission}`);
  }
  return permission;
}

// Whether userId is one of the snippet's share targets with "edit", directly or via a group.
function hasEditShare(snippet, userId) {
  return (snippet.shares || []).some(
    (share) =>
      share.permission === "edit" &&
      (share.type === "user"
        ? share.id === userId
        : groupRepository.isMember(share.id, userId))
  );
}

export function canEditSnippet(snippet, userId) {
  if (!snippet || snippet.edit_permission === "readonly") return false;
  if (snippet.user_id === userId) return true;
  return !snippet.is_public && hasEditShare(snippet, userId);
}

/**
 * Normalizes requested share targets to [{ type, id, permission }]. Users may be given by
 * id or username (not email). Admins can share with any group, others only with groups they belong to
 * (groups the snippet is already shared with stay allowed).
 */
function resolveShareTargets(targets, { userId, isAdmin, existing }) {
  if (!Array.isArray(targets)) {
    throw new VisibilityError("share_with must be a list of { type, id, permission }");
  }
  const existingGroupIds = new Set(
    (existing?.shares || []).filter((share) => share.type === "group").map((share) => share.id)
  );
  const result = new Map();

  for (const target of targets) {
    const permission = target?.permission ?? "view";
    if (!SHARE_PERMISSIONS.includes(permission)) {
      throw new VisibilityError(`Unknown share permission: ${permission}`);
    }

    if (target?.type === "group") {
      const groupId = parseInt(target.id);
      // Groups you are not in look the same as missing ones, so ids can't be probed
      const allowed = isAdmin || existingGroupIds.has(groupId) || groupRepository.isMember(groupId, userId);
      if (!groupId || !allowed || !groupRepository.findById(groupId)) {
        throw new VisibilityError(`Group not found: ${target.id}`);
      }
      result.set(`group:${groupId}`, { type: "group", id: groupId, permission });
    } else if (target?.type === "user") {
      const user = target.id != null
        ? groupRepository.findUserById(parseInt(target.id))
        : groupRepository.findUserByUsername(target.username); // never by email: that would reveal who is registered
      if (!user) {
        throw new VisibilityError(`User not found: ${target.id ?? target.username}`);
      }
      if (user.id === userId) continue; // the owner always has access
      result.set(`user:${user.id}`, { type: "user", id: user.id, permission });
    } else {
      throw new VisibilityError(`Unknown share target type: ${target?.type}`);
    }
  }

  return [...result.values()];
}

/**
 * Works out is_public and the share list from the request body. Clients send `visibility`
 * ("public" | "private" | "protected") with `share_with`, or the legacy `is_public` flag /
 * single `group_id`. When `share_with` is omitted on update, existing shares are kept.
 */
function resolveVisibility(snippetData, { userId, isAdmin = false, existing = null }) {
  let visibility = snippetData.visibility;
  let targets = snippetData.share_with;

  if (targets === undefined && snippetData.group_id !== undefined && snippetData.group_id !== null) {
    // Legacy single-group payload
    targets = [{
      type: "group",
      id: snippetData.group_id,
      permission: snippetData.edit_permission === "group" ? "edit" : "view",
    }];
  }

  if (!visibility) {
    if (snippetData.is_public) visibility = "public";
    else if (targets?.length) visibility = "protected";
    else if (targets === undefined && snippetData.is_public === undefined && existing) visibility = existing.visibility;
    else visibility = "private";
  }

  if (visibility === "public") return { isPublic: 1, shares: [] };
  if (visibility === "private") return { isPublic: 0, shares: [] };
  if (visibility !== "protected") {
    throw new VisibilityError(`Unknown visibility: ${visibility}`);
  }

  const shares = targets === undefined
    ? (existing?.shares || []).map(({ type, id, permission }) => ({ type, id, permission }))
    : resolveShareTargets(targets, { userId, isAdmin, existing });
  if (shares.length === 0) {
    throw new VisibilityError("Choose at least one group or person to share with");
  }
  return { isPublic: 0, shares };
}

class SnippetService {
  async getAllSnippets(userId) {
    try {
      Logger.debug("Service: Getting all snippets for user:", userId);
      const result = await snippetRepository.findAll(userId);
      Logger.debug(`Service: Retrieved ${result.length} snippets`);
      return result;
    } catch (error) {
      Logger.error("Service Error - getAllSnippets:", error);
      throw error;
    }
  }

  async getAllPublicSnippets() {
    try {
      Logger.debug("Service: Getting all public snippets");
      const result = await snippetRepository.findAllPublic();
      Logger.debug(`Service: Retrieved ${result.length} public snippets`);
      return result;
    } catch (error) {
      Logger.error("Service Error - getAllPublicSnippets:", error);
      throw error;
    }
  }

  async createSnippet(snippetData, userId, { isAdmin = false } = {}) {
    try {
      Logger.debug("Service: Creating new snippet for user:", userId);
      const visibility = resolveVisibility(snippetData, { userId, isAdmin });
      const result = await snippetRepository.create({
        ...snippetData,
        userId,
        ...visibility,
        editPermission: resolveEditPermission(snippetData),
      });
      Logger.debug("Service: Created snippet with ID:", result.id);
      return result;
    } catch (error) {
      Logger.error("Service Error - createSnippet:", error);
      throw error;
    }
  }

  async moveToRecycle(id, userId) {
    try {
      Logger.debug(
        "Service: Moving snippet to recycle bin:",
        id,
        "for user:",
        userId
      );
      const result = await snippetRepository.moveToRecycle(id, userId);
      if (!result) {
        Logger.debug(
          "Service: Snippet not found or already moved to recycle bin"
        );
        return null;
      }
      Logger.debug("Service: Snippet moved to recycle bin successfully");
      return { id: result.id };
    } catch (error) {
      Logger.error("Service Error - moveToRecycle:", error);
      throw error;
    }
  }

  async getRecycledSnippets(userId) {
    try {
      // Ensure expired snippets are deleted before fetching recycled snippets
      this.deleteExpiredSnippets();

      Logger.debug("Service: Getting recycled snippets for user:", userId);
      const result = await snippetRepository.findAllDeleted(userId);
      Logger.debug(`Service: Retrieved ${result.length} recycled snippets`);
      return result;
      // return {};
    } catch (error) {
      Logger.error("Service Error - getRecycledSnippets:", error);
      throw error;
    }
  }

  async deleteExpiredSnippets() {
    try {
      Logger.debug("Service: Deleting expired snippets");
      await snippetRepository.deleteExpired();
      Logger.debug(`Service: Deleted expired snippets`);
    } catch (error) {
      Logger.error("Service Error - deleteExpiredSnippets:", error);
      throw error;
    }
  }

  async deleteSnippet(id, userId) {
    try {
      Logger.debug("Service: Deleting snippet:", id, "for user:", userId);
      const result = await snippetRepository.delete(id, userId);
      Logger.debug(
        "Service: Delete operation result:",
        result ? "Success" : "Not Found"
      );
      return result;
    } catch (error) {
      Logger.error("Service Error - deleteSnippet:", error);
      throw error;
    }
  }

  async restoreSnippet(id, userId) {
    try {
      Logger.debug("Service: Restoring snippet:", id, "for user:", userId);
      await snippetRepository.restore(id, userId);
      Logger.debug("Service: Restore operation result:", "Success");
      return { id };
    } catch (error) {
      Logger.error("Service Error - restoreSnippet:", error);
      throw error;
    }
  }

  async updateSnippet(id, snippetData, userId, { isAdmin = false } = {}) {
    try {
      Logger.debug("Service: Updating snippet:", id, "for user:", userId);
      const existing = snippetRepository.findById(id, userId);
      if (!existing) return null;

      let settings;
      if (existing.user_id === userId) {
        // The owner controls visibility and edit permission, and may unlock a read-only
        // snippet, but not change its content while it stays read-only.
        const visibility = resolveVisibility(snippetData, { userId, isAdmin, existing });
        const editPermission = resolveEditPermission(snippetData, { existing });
        if (existing.edit_permission === "readonly" && editPermission === "readonly") {
          throw new VisibilityError("This snippet is locked. Change its edit permission to edit it.", 409);
        }
        settings = { ...visibility, editPermission };
      } else if (canEditSnippet(existing, userId)) {
        // Share editors change content only; sharing settings stay as the owner set them
        settings = {
          isPublic: existing.is_public,
          shares: undefined,
          editPermission: existing.edit_permission,
        };
      } else {
        // 404 rather than 403: the web client treats 403 as an expired session
        throw new VisibilityError("You do not have permission to edit this snippet", 404);
      }

      const result = await snippetRepository.update(
        id,
        { ...snippetData, ...settings },
        userId
      );
      Logger.debug(
        "Service: Update operation result:",
        result ? "Success" : "Not Found"
      );
      return result;
    } catch (error) {
      Logger.error("Service Error - updateSnippet:", error);
      throw error;
    }
  }

  async findById(id, userId = null) {
    try {
      Logger.debug(
        "Service: Getting snippet:",
        id,
        userId != null ? `for user: ${userId}` : "(public access)"
      );
      const result = await snippetRepository.findById(id, userId);
      Logger.debug(
        "Service: Find by ID result:",
        result ? "Found" : "Not Found"
      );
      if (result && userId != null) {
        result.is_owner = result.user_id === userId;
        result.can_edit = canEditSnippet(result, userId);
      }
      return result;
    } catch (error) {
      Logger.error("Service Error - findById:", error);
      throw error;
    }
  }

  async setPinned(id, value, userId) {
    try {
      Logger.debug(
        "Service: Setting pinned status for snippet:",
        id,
        "to:",
        value,
        "for user:",
        userId
      );
      const result = await snippetRepository.setPinned(id, value, userId);
      Logger.debug(
        "Service: Set pinned operation result:",
        result ? "Success" : "Not Found"
      );
      return result;
    } catch (error) {
      Logger.error("Service Error - setPinned:", error);
      throw error;
    }
  }

  async setFavorite(id, value, userId) {
    try {
      Logger.debug(
        "Service: Setting favorite status for snippet:",
        id,
        "to:",
        value,
        "for user:",
        userId
      );
      const result = await snippetRepository.setFavorite(id, value, userId);
      Logger.debug(
        "Service: Set favorite operation result:",
        result ? "Success" : "Not Found"
      );
      return result;
    } catch (error) {
      Logger.error("Service Error - setFavorite:", error);
      throw error;
    }
  }

  async getSnippetsPaginated({ userId, viewerId = null, sharedViewerId = null, filters, sort, limit, offset }) {
    try {
      Logger.debug(
        "Service: Getting paginated snippets for user:",
        userId,
        "with filters:",
        filters,
        "sort:",
        sort,
        "limit:",
        limit,
        "offset:",
        offset
      );
      const result = await snippetRepository.findAllPaginated({
        userId,
        viewerId,
        sharedViewerId,
        filters,
        sort,
        limit,
        offset
      });
      Logger.debug(
        `Service: Retrieved ${result.snippets.length} snippets, total: ${result.total}`
      );
      return result;
    } catch (error) {
      Logger.error("Service Error - getSnippetsPaginated:", error);
      throw error;
    }
  }

  async getMetadata(userId = null, viewerId = null, sharedViewerId = null) {
    try {
      Logger.debug(
        "Service: Getting metadata for",
        userId !== null ? `user: ${userId}` : "public snippets"
      );
      const result = await snippetRepository.getMetadata(userId, viewerId, sharedViewerId);
      Logger.debug(
        `Service: Retrieved ${result.categories.length} categories, ${result.languages.length} languages`
      );
      return result;
    } catch (error) {
      Logger.error("Service Error - getMetadata:", error);
      throw error;
    }
  }
}

export default new SnippetService();
