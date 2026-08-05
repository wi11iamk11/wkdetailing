import http from 'node:http';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

import { CanvasClient, CanvasError, fetchEverything, normalizeBaseUrl } from './lib/canvas.js';
import * as store from './lib/store.js';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(ROOT, 'public');
const PORT = Number(process.env.PORT ?? 4173);
const HOST = process.env.HOST ?? '127.0.0.1';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

const STATUSES = new Set(['todo', 'doing', 'done', 'skipped']);

function send(res, status, body, headers = {}) {
  const payload = typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    ...headers,
  });
  res.end(payload);
}

async function readBody(req, limit = 1_000_000) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw new HttpError(413, 'Request body too large');
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new HttpError(400, 'Request body must be JSON');
  }
}

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function requireClient() {
  const config = await store.getConfig();
  if (!config) throw new HttpError(409, 'Not connected to Canvas yet.');
  return new CanvasClient(config);
}

/* ---------------------------------------------------------------- routes */

const routes = {
  'GET /api/status': async () => {
    const [config, cache] = await Promise.all([store.getConfig(), store.getCache()]);
    return {
      connected: Boolean(config),
      baseUrl: config?.baseUrl ?? null,
      user: cache?.user ?? null,
      syncedAt: cache?.syncedAt ?? null,
    };
  },

  'POST /api/connect': async (req) => {
    const { baseUrl, token } = await readBody(req);
    const client = new CanvasClient({ baseUrl: normalizeBaseUrl(baseUrl), token });
    const profile = await client.profile(); // fails loudly if the token is bad
    await store.saveConfig({ baseUrl: client.baseUrl, token: client.token });
    return { connected: true, user: { id: profile.id, name: profile.name ?? 'You', baseUrl: client.baseUrl } };
  },

  'POST /api/disconnect': async () => {
    await store.clearConfig();
    return { connected: false };
  },

  'POST /api/sync': async () => {
    const client = await requireClient();
    const data = await fetchEverything(client);
    await store.saveCache(data);
    return buildPayload(data, await store.getState());
  },

  'GET /api/data': async () => {
    const [cache, state] = await Promise.all([store.getCache(), store.getState()]);
    if (!cache) return { empty: true, ...(await routes['GET /api/status']()) };
    return buildPayload(cache, state);
  },

  'PATCH /api/items/:id': async (req, { id }) => {
    const patch = await readBody(req);
    const state = await store.updateState((s) => {
      const current = s.overrides[id] ?? {};
      const next = { ...current };

      if ('status' in patch) {
        if (patch.status === null) delete next.status;
        else if (STATUSES.has(patch.status)) next.status = patch.status;
        else throw new HttpError(400, `Unknown status "${patch.status}"`);
      }
      if ('notes' in patch) {
        const notes = String(patch.notes ?? '').slice(0, 5000);
        if (notes.trim()) next.notes = notes;
        else delete next.notes;
      }
      if ('pinned' in patch) {
        if (patch.pinned) next.pinned = true;
        else delete next.pinned;
      }

      if (Object.keys(next).length === 0) delete s.overrides[id];
      else s.overrides[id] = { ...next, updatedAt: new Date().toISOString() };

      // Custom tasks carry their own fields; let the same endpoint edit them.
      const task = s.tasks.find((t) => t.id === id);
      if (task) {
        if ('name' in patch && String(patch.name ?? '').trim()) task.name = String(patch.name).trim().slice(0, 300);
        if ('dueAt' in patch) task.dueAt = patch.dueAt ? new Date(patch.dueAt).toISOString() : null;
        if ('courseId' in patch) task.courseId = patch.courseId ? Number(patch.courseId) : null;
      }
      return s;
    });
    const cache = await store.getCache();
    return buildPayload(cache ?? { courses: [], items: [] }, state);
  },

  'POST /api/tasks': async (req) => {
    const body = await readBody(req);
    const name = String(body.name ?? '').trim();
    if (!name) throw new HttpError(400, 'A task needs a name');
    const task = {
      id: `t-${randomUUID()}`,
      source: 'local',
      name: name.slice(0, 300),
      courseId: body.courseId ? Number(body.courseId) : null,
      dueAt: body.dueAt ? new Date(body.dueAt).toISOString() : null,
      createdAt: new Date().toISOString(),
    };
    const state = await store.updateState((s) => {
      s.tasks.push(task);
      return s;
    });
    const cache = await store.getCache();
    return buildPayload(cache ?? { courses: [], items: [] }, state);
  },

  'DELETE /api/tasks/:id': async (_req, { id }) => {
    const state = await store.updateState((s) => {
      s.tasks = s.tasks.filter((t) => t.id !== id);
      delete s.overrides[id];
      return s;
    });
    const cache = await store.getCache();
    return buildPayload(cache ?? { courses: [], items: [] }, state);
  },
};

/**
 * Merges the Canvas snapshot with local edits into what the UI renders.
 * Canvas submission state seeds "done"; a manual status always wins over it.
 */
function buildPayload(cache, state) {
  const courses = cache.courses ?? [];
  const byCourse = new Map(courses.map((c) => [c.id, c]));

  const localTasks = (state.tasks ?? []).map((t) => ({
    ...t,
    description: '',
    pointsPossible: null,
    url: null,
    kind: 'task',
    submitted: false,
    graded: false,
    score: null,
    missing: false,
    late: false,
  }));

  const items = [...(cache.items ?? []), ...localTasks].map((item) => {
    const override = state.overrides?.[item.id] ?? {};
    const course = byCourse.get(item.courseId);
    const derived = item.submitted || item.graded ? 'done' : 'todo';
    return {
      ...item,
      courseName: course?.name ?? (item.source === 'local' ? 'Personal' : 'Unknown course'),
      courseCode: course?.code ?? '',
      courseColor: course?.color ?? '#7a7f87',
      status: override.status ?? derived,
      statusIsManual: Boolean(override.status),
      notes: override.notes ?? '',
      pinned: Boolean(override.pinned),
    };
  });

  return {
    empty: false,
    user: cache.user ?? null,
    syncedAt: cache.syncedAt ?? null,
    warnings: cache.warnings ?? [],
    courses,
    items,
  };
}

/* ---------------------------------------------------------------- static */

async function serveStatic(req, res, pathname) {
  const rel = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  const file = path.join(PUBLIC_DIR, rel);
  // Block traversal out of public/.
  if (!file.startsWith(PUBLIC_DIR + path.sep)) return send(res, 403, { error: 'Forbidden' });
  try {
    const content = await readFile(file);
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(file)] ?? 'application/octet-stream',
      'Cache-Control': 'no-cache',
    });
    res.end(content);
  } catch (err) {
    if (err.code === 'ENOENT' || err.code === 'EISDIR') return send(res, 404, { error: 'Not found' });
    throw err;
  }
}

/* ---------------------------------------------------------------- server */

function matchRoute(method, pathname) {
  const direct = routes[`${method} ${pathname}`];
  if (direct) return { handler: direct, params: {} };
  for (const key of Object.keys(routes)) {
    const [routeMethod, pattern] = key.split(' ');
    if (routeMethod !== method || !pattern.includes(':')) continue;
    const patternParts = pattern.split('/');
    const pathParts = pathname.split('/');
    if (patternParts.length !== pathParts.length) continue;
    const params = {};
    const ok = patternParts.every((part, i) => {
      if (part.startsWith(':')) {
        params[part.slice(1)] = decodeURIComponent(pathParts[i]);
        return true;
      }
      return part === pathParts[i];
    });
    if (ok) return { handler: routes[key], params };
  }
  return null;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host ?? 'localhost'}`);
  try {
    if (!url.pathname.startsWith('/api/')) return await serveStatic(req, res, url.pathname);

    const match = matchRoute(req.method, url.pathname);
    if (!match) return send(res, 404, { error: `No route for ${req.method} ${url.pathname}` });

    const result = await match.handler(req, match.params, url);
    send(res, 200, result ?? {});
  } catch (err) {
    const status = err instanceof CanvasError ? err.status || 502 : err.status ?? 500;
    if (status >= 500) console.error('[error]', err);
    send(res, status, { error: err.message ?? 'Something went wrong' });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`\n  Canvas Organizer running at http://${HOST}:${PORT}\n`);
});
