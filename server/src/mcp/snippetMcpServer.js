import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import snippetService from '../services/snippetService.js';
import Logger from '../logger.js';
import groupRepository from '../repositories/groupRepository.js';

/*
 * Builds an MCP server instance scoped to a single authenticated ByteStash user.
 *
 * Tools apply the same authorization as the REST API: writes only touch snippets owned
 * by `userId` (or snippets shared with them with edit permission), and reads also reach
 * public snippets and snippets shared with the user directly or through a group. An API key never grants access beyond what its owner could
 * already see through the web UI or REST API.
 *
 * A fresh server is created per request (stateless Streamable HTTP transport), so the
 * userId is safely captured in the tool closures with no cross-request leakage.
 */

const fragmentInputSchema = z.object({
  file_name: z.string().optional().describe('File name for this fragment, e.g. "index.js"'),
  code: z.string().describe('The snippet code/content for this fragment'),
  language: z.string().optional().describe('Language id, e.g. "javascript", "python", "plaintext"'),
});

// Favorite/pinned are the owner's personal flags, so recipients don't see them.
function ownerFlags(snippet, viewerId) {
  if (snippet.user_id !== viewerId) return {};
  return { is_favorite: !!snippet.is_favorite, is_pinned: !!snippet.is_pinned };
}

function summarizeSnippet(snippet, viewerId) {
  return {
    id: snippet.id,
    title: snippet.title,
    description: snippet.description,
    categories: snippet.categories,
    visibility: snippet.visibility,
    shared_with: snippet.shares || [],
    owner: snippet.username,
    is_public: !!snippet.is_public,
    ...ownerFlags(snippet, viewerId),
    updated_at: snippet.updated_at,
    files: (snippet.fragments || []).map((f) => ({
      file_name: f.file_name,
      language: f.language,
    })),
  };
}

function fullSnippet(snippet, viewerId) {
  return {
    id: snippet.id,
    title: snippet.title,
    description: snippet.description,
    categories: snippet.categories,
    visibility: snippet.visibility,
    shared_with: snippet.shares || [],
    owner: snippet.username,
    edit_permission: snippet.edit_permission,
    can_edit: snippet.can_edit,
    is_public: !!snippet.is_public,
    ...ownerFlags(snippet, viewerId),
    updated_at: snippet.updated_at,
    fragments: (snippet.fragments || []).map((f) => ({
      id: f.id,
      file_name: f.file_name,
      language: f.language,
      position: f.position,
      code: f.code,
    })),
  };
}

const editPermissionSchema = z
  .enum(['owner', 'readonly'])
  .describe('owner (default): you plus share targets with "edit" permission can edit; readonly: locked for everyone, you included');

const visibilitySchema = z
  .enum(['private', 'public', 'protected'])
  .describe('private: only you; public: anyone; protected: only the groups and people in share_with');

const shareWithSchema = z
  .array(
    z.object({
      type: z.enum(['group', 'user']),
      id: z.coerce.number().int().optional().describe('Group id (see list_groups) or user id'),
      username: z.string().optional().describe('For type "user": username instead of id'),
      permission: z.enum(['view', 'edit']).optional().describe('view (default) or edit'),
    })
  )
  .describe('Who a protected snippet is shared with. On update, replaces the current list.');

// Visibility errors (e.g. publishing to a group you are not in) are safe to show the client.
function errorMessage(error, fallback) {
  return [400, 404, 409].includes(error?.status) ? error.message : fallback;
}

function ok(data) {
  return { content: [{ type: 'text', text: JSON.stringify(data, null, 2) }] };
}

function fail(message) {
  return { content: [{ type: 'text', text: message }], isError: true };
}

export function createMcpServer(userId, { isAdmin = false } = {}) {
  const server = new McpServer(
    { name: 'bytestash', version: '1.0.0' },
    {
      instructions:
        'ByteStash is a code-snippet manager. Use these tools to search, read, create, ' +
        'update and delete the authenticated user\'s code snippets, and to read snippets shared ' +
        'with them (public, or shared with them directly or through a group). Each snippet has a title, ' +
        'description, categories (tags), and one or more file "fragments" (each with a file name, ' +
        'language and code). Start with list_snippets or list_metadata to discover what exists.',
    }
  );

  server.registerTool(
    'list_snippets',
    {
      title: 'List / search snippets',
      description:
        'List the user\'s code snippets with optional full-text search and filtering. ' +
        'Returns a summary (no code bodies) plus pagination info. Use get_snippet to read the code.',
      inputSchema: {
        scope: z
          .enum(['mine', 'shared'])
          .optional()
          .describe('mine (default): your own snippets; shared: public snippets plus snippets shared with you'),
        search: z.string().optional().describe('Free-text search over title, description and (by default) code'),
        searchCode: z.boolean().optional().describe('Whether search also matches code content (default true)'),
        language: z.string().optional().describe('Only snippets containing a fragment in this language'),
        categories: z.array(z.string()).optional().describe('Only snippets that have ALL of these categories/tags'),
        favorites: z.boolean().optional().describe('Only favorited snippets'),
        pinned: z.boolean().optional().describe('Only pinned snippets'),
        sort: z.enum(['newest', 'oldest', 'alpha-asc', 'alpha-desc']).optional().describe('Sort order (default newest)'),
        limit: z.number().int().min(1).max(100).optional().describe('Max results (1-100, default 50)'),
        offset: z.number().int().min(0).optional().describe('Pagination offset (default 0)'),
      },
    },
    async (args) => {
      try {
        const limit = args.limit ?? 50;
        const offset = args.offset ?? 0;
        const shared = args.scope === 'shared';
        const { snippets, total } = await snippetService.getSnippetsPaginated({
          userId: shared ? null : userId,
          viewerId: shared ? userId : null,
          filters: {
            search: args.search || null,
            searchCode: args.searchCode !== false,
            language: args.language || null,
            categories: args.categories && args.categories.length
              ? args.categories.map((c) => c.trim().toLowerCase())
              : null,
            // Favorite/pinned flags belong to the owner, so they only filter your own snippets
            favorites: !shared && !!args.favorites,
            pinned: !shared && !!args.pinned,
            recycled: false,
          },
          sort: args.sort || 'newest',
          limit,
          offset,
        });

        return ok({
          snippets: snippets.map((snippet) => summarizeSnippet(snippet, userId)),
          pagination: { total, offset, limit, hasMore: offset + limit < total },
        });
      } catch (error) {
        Logger.error('MCP list_snippets failed:', error);
        return fail('Failed to list snippets');
      }
    }
  );

  server.registerTool(
    'get_snippet',
    {
      title: 'Get a snippet',
      description: 'Fetch a single snippet by id, including the full code of every fragment.',
      inputSchema: {
        id: z.coerce.number().int().describe('The snippet id'),
      },
    },
    async (args) => {
      try {
        const snippet = await snippetService.findById(args.id, userId);
        if (!snippet) {
          return fail(`Snippet ${args.id} not found`);
        }
        return ok(fullSnippet(snippet, userId));
      } catch (error) {
        Logger.error('MCP get_snippet failed:', error);
        return fail('Failed to get snippet');
      }
    }
  );

  server.registerTool(
    'create_snippet',
    {
      title: 'Create a snippet',
      description: 'Create a new code snippet with one or more file fragments.',
      inputSchema: {
        title: z.string().min(1).describe('Snippet title'),
        description: z.string().optional().describe('Markdown description'),
        categories: z.array(z.string()).optional().describe('Category/tag names'),
        fragments: z.array(fragmentInputSchema).min(1).describe('One or more code files'),
        is_public: z.boolean().optional().describe('Deprecated, use visibility. Whether the snippet is publicly visible (default false)'),
        visibility: visibilitySchema.optional(),
        share_with: shareWithSchema.optional(),
        edit_permission: editPermissionSchema.optional(),
      },
    },
    async (args) => {
      try {
        const created = await snippetService.createSnippet(
          {
            title: args.title,
            description: args.description || '',
            categories: args.categories || [],
            fragments: args.fragments.map((f, i) => ({
              file_name: f.file_name || `file${i + 1}`,
              code: f.code || '',
              language: f.language || 'plaintext',
              position: i,
            })),
            is_public: args.is_public ? 1 : 0,
            visibility: args.visibility,
            share_with: args.share_with,
            edit_permission: args.edit_permission,
          },
          userId,
          { isAdmin }
        );
        return ok(fullSnippet(created, userId));
      } catch (error) {
        Logger.error('MCP create_snippet failed:', error);
        return fail(errorMessage(error, 'Failed to create snippet'));
      }
    }
  );

  server.registerTool(
    'update_snippet',
    {
      title: 'Update a snippet',
      description:
        'Update an existing snippet. Only the fields you provide are changed; omitted fields keep ' +
        'their current values. Providing "fragments" or "categories" replaces them entirely. ' +
        'People a snippet is shared with using "edit" permission may edit its content; only the ' +
        'owner can change visibility, share_with or edit_permission.',
      inputSchema: {
        id: z.coerce.number().int().describe('The snippet id to update'),
        title: z.string().min(1).optional().describe('New title'),
        description: z.string().optional().describe('New markdown description'),
        categories: z.array(z.string()).optional().describe('Replacement set of category/tag names'),
        fragments: z.array(fragmentInputSchema).min(1).optional().describe('Replacement set of code files'),
        is_public: z.boolean().optional().describe('Deprecated, use visibility. New public visibility'),
        visibility: visibilitySchema.optional(),
        share_with: shareWithSchema.optional(),
        edit_permission: editPermissionSchema.optional(),
      },
    },
    async (args) => {
      try {
        const existing = await snippetService.findById(args.id, userId);
        if (!existing) {
          return fail(`Snippet ${args.id} not found`);
        }
        // Say so instead of silently ignoring sharing changes from someone who isn't the owner
        const settingsArgs = ['visibility', 'is_public', 'share_with', 'edit_permission'];
        if (existing.user_id !== userId && settingsArgs.some((key) => args[key] !== undefined)) {
          return fail('Only the owner can change visibility, share_with or edit_permission');
        }

        let visibility = args.visibility;
        if (!visibility && args.is_public !== undefined) {
          visibility = args.is_public ? 'public' : 'private';
        }
        if (!visibility && args.share_with) visibility = 'protected';

        const fragments = args.fragments
          ? args.fragments.map((f, i) => ({
              file_name: f.file_name || `file${i + 1}`,
              code: f.code || '',
              language: f.language || 'plaintext',
              position: i,
            }))
          : existing.fragments;

        const updated = await snippetService.updateSnippet(
          args.id,
          {
            title: args.title ?? existing.title,
            description: args.description ?? existing.description,
            categories: args.categories ?? existing.categories,
            fragments,
            // Omitted visibility/share_with keep their current values
            visibility,
            share_with: args.share_with,
            edit_permission: args.edit_permission,
          },
          userId,
          { isAdmin }
        );

        if (!updated) {
          return fail(`Snippet ${args.id} not found`);
        }
        return ok(fullSnippet(updated, userId));
      } catch (error) {
        Logger.error('MCP update_snippet failed:', error);
        return fail(errorMessage(error, 'Failed to update snippet'));
      }
    }
  );

  server.registerTool(
    'delete_snippet',
    {
      title: 'Delete a snippet',
      description:
        'Delete a snippet. By default it is moved to the recycle bin (recoverable for 30 days); ' +
        'set permanent=true to delete it irreversibly.',
      inputSchema: {
        id: z.coerce.number().int().describe('The snippet id to delete'),
        permanent: z.boolean().optional().describe('Permanently delete instead of moving to recycle bin (default false)'),
      },
    },
    async (args) => {
      try {
        const result = args.permanent
          ? await snippetService.deleteSnippet(args.id, userId)
          : await snippetService.moveToRecycle(args.id, userId);

        if (!result) {
          return fail(`Snippet ${args.id} not found`);
        }
        return ok({
          id: result.id,
          deleted: !!args.permanent,
          recycled: !args.permanent,
        });
      } catch (error) {
        Logger.error('MCP delete_snippet failed:', error);
        return fail('Failed to delete snippet');
      }
    }
  );

  server.registerTool(
    'list_groups',
    {
      title: 'List groups',
      description: 'List the groups you can share protected snippets with.',
      inputSchema: {},
    },
    async () => {
      try {
        const groups = isAdmin
          ? groupRepository.findAll().map(({ id, name, description }) => ({ id, name, description }))
          : groupRepository.findForUser(userId);
        return ok(groups);
      } catch (error) {
        Logger.error('MCP list_groups failed:', error);
        return fail('Failed to list groups');
      }
    }
  );

  server.registerTool(
    'find_users',
    {
      title: 'Find users',
      description: 'Find people to share a snippet with, by part of their username.',
      inputSchema: {
        query: z.string().min(1).describe('Part of a username'),
      },
    },
    async (args) => {
      try {
        return ok(groupRepository.searchUsers(args.query, userId));
      } catch (error) {
        Logger.error('MCP find_users failed:', error);
        return fail('Failed to find users');
      }
    }
  );

  server.registerTool(
    'list_metadata',
    {
      title: 'List snippet metadata',
      description: 'List all category/tag names and languages used across the user\'s snippets, plus a total count. Useful for building filters.',
      inputSchema: {},
    },
    async () => {
      try {
        const metadata = await snippetService.getMetadata(userId);
        return ok(metadata);
      } catch (error) {
        Logger.error('MCP list_metadata failed:', error);
        return fail('Failed to list metadata');
      }
    }
  );

  return server;
}
