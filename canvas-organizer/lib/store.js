import { readFile, writeFile, mkdir, rename, chmod, unlink } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
// CANVAS_ORGANIZER_DATA_DIR lets you keep several profiles, or point the app at
// a synced folder. Defaults to ./data next to the app.
const DATA_DIR = process.env.CANVAS_ORGANIZER_DATA_DIR
  ? path.resolve(process.env.CANVAS_ORGANIZER_DATA_DIR)
  : path.join(ROOT, 'data');

const CONFIG_FILE = path.join(DATA_DIR, 'config.json');
const CACHE_FILE = path.join(DATA_DIR, 'cache.json');
const STATE_FILE = path.join(DATA_DIR, 'state.json');

const DEFAULT_STATE = { overrides: {}, tasks: [] };

async function readJson(file, fallback) {
  try {
    return JSON.parse(await readFile(file, 'utf8'));
  } catch (err) {
    if (err.code === 'ENOENT') return fallback;
    if (err instanceof SyntaxError) {
      console.warn(`[store] ${path.basename(file)} is corrupt, starting from defaults`);
      return fallback;
    }
    throw err;
  }
}

// Write via a temp file + rename so a crash mid-write can't leave a half-written
// state file behind (that file holds notes the user typed).
async function writeJson(file, value, mode) {
  await mkdir(DATA_DIR, { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  await writeFile(tmp, JSON.stringify(value, null, 2), { mode: mode ?? 0o644 });
  await rename(tmp, file);
  if (mode) await chmod(file, mode);
}

export async function getConfig() {
  return readJson(CONFIG_FILE, null);
}

export async function saveConfig(config) {
  // 0600: the file holds a Canvas access token.
  await writeJson(CONFIG_FILE, config, 0o600);
  return config;
}

export async function clearConfig() {
  for (const file of [CONFIG_FILE, CACHE_FILE]) {
    await unlink(file).catch((err) => {
      if (err.code !== 'ENOENT') throw err;
    });
  }
}

export async function getCache() {
  return readJson(CACHE_FILE, null);
}

export async function saveCache(cache) {
  await writeJson(CACHE_FILE, cache, 0o600);
  return cache;
}

export async function getState() {
  const state = await readJson(STATE_FILE, DEFAULT_STATE);
  return { ...DEFAULT_STATE, ...state };
}

export async function saveState(state) {
  await writeJson(STATE_FILE, state);
  return state;
}

/** Read-modify-write helper. Calls are serialized so concurrent edits don't clobber. */
let queue = Promise.resolve();
export function updateState(mutator) {
  const run = queue.then(async () => {
    const state = await getState();
    const next = (await mutator(state)) ?? state;
    await saveState(next);
    return next;
  });
  // Swallow the rejection on the *chain* only, so one failed update (e.g. a bad
  // status value) doesn't poison every later write. Callers still see the error.
  queue = run.then(
    () => {},
    () => {},
  );
  return run;
}
