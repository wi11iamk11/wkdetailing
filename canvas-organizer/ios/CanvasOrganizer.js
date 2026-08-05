// Variables used by Scriptable.
// These must be at the very top of the file. Do not edit.
// icon-color: blue; icon-glyph: graduation-cap;

/*
 * Canvas Organizer — iOS (Scriptable)
 *
 * Shows everything due across your Canvas courses, grouped by urgency.
 * Run it in the Scriptable app, add it as a home screen widget, or call it
 * from Shortcuts / Siri.
 *
 * First run asks for your Canvas address and an access token; both are stored
 * in the iOS Keychain and never leave your phone.
 */

const KEY_HOST = 'canvasOrganizer.host';
const KEY_TOKEN = 'canvasOrganizer.token';
const CACHE_FILE = 'canvas-organizer-cache.json';
const DAY = 86_400_000;

/* ============================================================ pure logic
 * Everything below this point is plain JavaScript with no iOS dependencies,
 * so it can be unit-tested off-device (see ios/test.js).
 */

// Scriptable's JS engine is JavaScriptCore without WebKit's DOM layer, so
// there is no global `URL` class (or `URLSearchParams`) — only plain
// ECMAScript. Every URL operation below is done with regex and string
// concatenation instead, so it works on-device as well as under Node's tests.
function normalizeHost(input) {
  // A real Canvas address never contains whitespace, but the iOS keyboard
  // (autocorrect, predictive-text taps) loves to insert a stray space mid-typing.
  // Stripping it all, not just the ends, turns that into a non-issue.
  const raw = String(input ?? '').replace(/\s+/g, '');
  if (!raw) throw new Error('Canvas address is required');
  const withScheme = /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
  const match = withScheme.match(/^(https?):\/\/([^/?#]+)/i);
  const host = match?.[2];
  if (!match || !/^[a-z0-9.-]+(:\d+)?$/i.test(host)) {
    throw new Error(`"${raw}" is not a valid Canvas address`);
  }
  return `${match[1].toLowerCase()}://${host.toLowerCase()}`;
}

function parseNextLink(header) {
  if (!header) return null;
  for (const part of String(header).split(',')) {
    const match = part.match(/<([^>]+)>\s*;\s*rel="?next"?/i);
    if (match) return match[1];
  }
  return null;
}

function isSubmitted(submission) {
  if (!submission) return false;
  if (submission.submitted_at) return true;
  return ['graded', 'complete', 'pending_review'].includes(submission.workflow_state);
}

function normalizeAssignment(a, course) {
  const types = a.submission_types ?? [];
  return {
    id: a.id,
    name: a.name ?? 'Untitled assignment',
    courseName: course.name,
    courseCode: course.code || course.name,
    dueAt: a.due_at ?? null,
    points: typeof a.points_possible === 'number' ? a.points_possible : null,
    url: a.html_url ?? course.url,
    isQuiz: types.includes('online_quiz'),
    missing: a.submission?.missing === true,
    submitted: isSubmitted(a.submission),
  };
}

const BUCKETS = [
  { id: 'overdue', title: 'Overdue' },
  { id: 'today', title: 'Due today' },
  { id: 'week', title: 'Next 7 days' },
  { id: 'later', title: 'Later' },
  { id: 'nodue', title: 'No due date' },
];

function startOfDay(ms) {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

function bucketOf(item, now = Date.now()) {
  if (!item.dueAt) return 'nodue';
  const due = new Date(item.dueAt).getTime();
  if (Number.isNaN(due)) return 'nodue';
  if (due < now) return 'overdue';
  const days = Math.round((startOfDay(due) - startOfDay(now)) / DAY);
  if (days <= 0) return 'today';
  if (days <= 7) return 'week';
  return 'later';
}

/** Unfinished work only, grouped by urgency, each group sorted by due date. */
function organize(items, now = Date.now()) {
  const open = items.filter((i) => !i.submitted);
  return BUCKETS.map(({ id, title }) => ({
    id,
    title,
    items: open
      .filter((i) => bucketOf(i, now) === id)
      .sort((a, b) => {
        if (!a.dueAt) return 1;
        if (!b.dueAt) return -1;
        return new Date(a.dueAt) - new Date(b.dueAt);
      }),
  })).filter((group) => group.items.length);
}

function formatDue(item, now = Date.now()) {
  if (!item.dueAt) return 'No due date';
  const due = new Date(item.dueAt);
  if (Number.isNaN(due.getTime())) return 'No due date';
  const time = due.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  const days = Math.round((startOfDay(due.getTime()) - startOfDay(now)) / DAY);

  if (due.getTime() < now) {
    const late = Math.abs(days);
    if (late === 0) return `Was due today, ${time}`;
    if (late === 1) return 'Was due yesterday';
    return `Was due ${late} days ago`;
  }
  if (days === 0) return `Today at ${time}`;
  if (days === 1) return `Tomorrow at ${time}`;
  if (days <= 7) return `${due.toLocaleDateString([], { weekday: 'long' })} at ${time}`;
  return due.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

/** One line of context per assignment: course, when it's due, what it's worth. */
function subtitleFor(item, now = Date.now()) {
  const bits = [item.courseCode, formatDue(item, now)];
  if (item.points) bits.push(`${item.points} pts`);
  if (item.missing) bits.push('MISSING');
  return bits.join(' · ');
}

/**
 * Fetches courses and assignments.
 * `fetchJson(url, token)` must resolve to { body, next } where `next` is the
 * URL from the Link header, so this stays testable without Scriptable.
 */
async function loadEverything(fetchJson, host, token) {
  const getAll = async (path, params = {}) => {
    // Query string built by hand (see the note above normalizeHost). This only
    // runs for page 1 — later pages reuse Canvas's own "next" link as-is.
    const query = [];
    const add = (key, value) => query.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
    add('per_page', '100');
    for (const [key, value] of Object.entries(params)) {
      if (Array.isArray(value)) value.forEach((v) => add(key, v));
      else add(key, value);
    }

    const out = [];
    let target = `${host}${path}?${query.join('&')}`;
    for (let page = 0; page < 5 && target; page++) {
      const { body, next } = await fetchJson(target, token);
      if (!Array.isArray(body)) throw new Error(`Unexpected response from ${path}`);
      out.push(...body);
      target = next;
    }
    return out;
  };

  const rawCourses = await getAll('/api/v1/courses', {
    enrollment_state: 'active',
    'state[]': ['available'],
  });

  const courses = rawCourses
    .filter((c) => c && c.id && !c.access_restricted_by_date)
    .map((c) => ({
      id: c.id,
      name: c.name ?? `Course ${c.id}`,
      code: c.course_code ?? '',
      url: `${host}/courses/${c.id}`,
    }));

  const warnings = [];
  const perCourse = await Promise.all(
    courses.map(async (course) => {
      try {
        const list = await getAll(`/api/v1/courses/${course.id}/assignments`, {
          'include[]': ['submission'],
        });
        return list.filter((a) => a && a.published !== false).map((a) => normalizeAssignment(a, course));
      } catch (err) {
        warnings.push(`${course.name}: ${err.message}`);
        return [];
      }
    }),
  );

  return { items: perCourse.flat(), courseCount: courses.length, warnings, syncedAt: new Date().toISOString() };
}

/* ============================================================ iOS glue */

async function scriptableFetch(url, token) {
  const req = new Request(url);
  req.headers = { Authorization: `Bearer ${token}`, Accept: 'application/json' };
  let body;
  try {
    body = await req.loadJSON();
  } catch (err) {
    const status = req.response?.statusCode;
    if (status === 401) throw new Error('Canvas rejected your token');
    throw new Error(`Could not reach Canvas (${status ?? 'no response'})`);
  }
  const status = req.response?.statusCode ?? 0;
  if (status === 401) throw new Error('Canvas rejected your token. Generate a new one and sign in again.');
  if (status === 403) throw new Error('Canvas denied access (403). The token may not have permission.');
  if (status >= 400) throw new Error(`Canvas returned HTTP ${status}`);

  const headers = req.response?.headers ?? {};
  return { body, next: parseNextLink(headers.Link ?? headers.link) };
}

async function promptForCredentials() {
  const alert = new Alert();
  alert.title = 'Connect to Canvas';
  alert.message =
    'Canvas address, then an access token from Canvas → Account → Settings → New Access Token.';
  alert.addTextField('myschool.instructure.com', '');
  alert.addSecureTextField('Access token', '');
  alert.addAction('Save');
  alert.addCancelAction('Cancel');
  if ((await alert.presentAlert()) === -1) return null;

  const host = normalizeHost(alert.textFieldValue(0));
  const token = alert.textFieldValue(1).trim();
  if (!token) throw new Error('Access token is required');

  Keychain.set(KEY_HOST, host);
  Keychain.set(KEY_TOKEN, token);
  return { host, token };
}

function storedCredentials() {
  if (!Keychain.contains(KEY_HOST) || !Keychain.contains(KEY_TOKEN)) return null;
  return { host: Keychain.get(KEY_HOST), token: Keychain.get(KEY_TOKEN) };
}

function signOut() {
  for (const key of [KEY_HOST, KEY_TOKEN]) if (Keychain.contains(key)) Keychain.remove(key);
}

function cachePath() {
  const fm = FileManager.local();
  return fm.joinPath(fm.documentsDirectory(), CACHE_FILE);
}

function saveCache(data) {
  try {
    FileManager.local().writeString(cachePath(), JSON.stringify(data));
  } catch {
    // A cache write failing is not worth interrupting the run.
  }
}

function loadCache() {
  try {
    const fm = FileManager.local();
    const path = cachePath();
    if (!fm.fileExists(path)) return null;
    return JSON.parse(fm.readString(path));
  } catch {
    return null;
  }
}

// Built lazily: `Color` only exists inside Scriptable, and this file is also
// required by the off-device tests.
const RED = () => new Color('#d1495b');
const AMBER = () => new Color('#c8791a');
const GREY = () => new Color('#8a9099');

function colorForBucket(id) {
  if (id === 'overdue') return RED();
  if (id === 'today') return AMBER();
  return GREY();
}

function buildTable(data, stale) {
  const now = Date.now();
  const groups = organize(data.items, now);
  const table = new UITable();
  table.showSeparators = true;

  const header = new UITableRow();
  header.isHeader = true;
  const openCount = data.items.filter((i) => !i.submitted).length;
  header.addText('Canvas Organizer', `${openCount} open across ${data.courseCount} courses`);
  table.addRow(header);

  if (stale) {
    const row = new UITableRow();
    const cell = row.addText('⚠️ Offline — showing last sync', new Date(data.syncedAt).toLocaleString());
    cell.titleColor = AMBER();
    table.addRow(row);
  }

  for (const warning of data.warnings ?? []) {
    const row = new UITableRow();
    row.addText("⚠️ " + warning).titleColor = AMBER();
    table.addRow(row);
  }

  if (!groups.length) {
    const row = new UITableRow();
    row.addText('🎉 Nothing due', 'Everything Canvas knows about is turned in.');
    table.addRow(row);
  }

  for (const group of groups) {
    const heading = new UITableRow();
    heading.isHeader = true;
    heading.backgroundColor = new Color('#808080', 0.12);
    const headingCell = heading.addText(`${group.title} (${group.items.length})`);
    headingCell.titleColor = colorForBucket(group.id);
    table.addRow(heading);

    for (const item of group.items) {
      const row = new UITableRow();
      row.height = 60;
      row.dismissOnSelect = false;
      const cell = row.addText(`${item.isQuiz ? '📝 ' : ''}${item.name}`, subtitleFor(item, now));
      cell.subtitleColor = colorForBucket(group.id);
      row.onSelect = () => Safari.open(item.url);
      table.addRow(row);
    }
  }

  const out = new UITableRow();
  out.addText('Sign out', 'Forget this Canvas account on this device').titleColor = RED();
  out.onSelect = () => {
    signOut();
    const done = new Alert();
    done.title = 'Signed out';
    done.message = 'Run the script again to reconnect.';
    done.addAction('OK');
    done.presentAlert();
  };
  table.addRow(out);

  return table;
}

function buildWidget(data, stale) {
  const now = Date.now();
  const groups = organize(data.items, now);
  const flat = groups.flatMap((g) => g.items.map((item) => ({ item, bucket: g.id })));

  const widget = new ListWidget();
  widget.setPadding(14, 14, 14, 14);

  const title = widget.addText(stale ? 'Due next (offline)' : 'Due next');
  title.font = Font.semiboldSystemFont(13);
  title.textColor = GREY();
  widget.addSpacer(6);

  if (!flat.length) {
    const none = widget.addText('🎉 Nothing due');
    none.font = Font.mediumSystemFont(15);
    return widget;
  }

  const rows = config.widgetFamily === 'small' ? 3 : 5;
  for (const { item, bucket } of flat.slice(0, rows)) {
    const name = widget.addText(item.name);
    name.font = Font.mediumSystemFont(13);
    name.lineLimit = 1;

    const detail = widget.addText(subtitleFor(item, now));
    detail.font = Font.systemFont(11);
    detail.textColor = colorForBucket(bucket);
    detail.lineLimit = 1;
    widget.addSpacer(6);
  }

  if (flat.length > rows) {
    const more = widget.addText(`+${flat.length - rows} more`);
    more.font = Font.systemFont(11);
    more.textColor = GREY();
  }
  return widget;
}

async function showError(message) {
  if (config.runsInWidget) {
    const widget = new ListWidget();
    widget.addText('Canvas Organizer').font = Font.semiboldSystemFont(13);
    widget.addSpacer(4);
    const text = widget.addText(message);
    text.font = Font.systemFont(11);
    text.textColor = RED();
    Script.setWidget(widget);
    return;
  }
  const alert = new Alert();
  alert.title = 'Canvas Organizer';
  alert.message = message;
  alert.addAction('OK');
  await alert.presentAlert();
}

async function main() {
  let creds = storedCredentials();
  if (!creds) {
    if (config.runsInWidget) return showError('Open the script once to sign in.');
    try {
      creds = await promptForCredentials();
    } catch (err) {
      return showError(err.message);
    }
    if (!creds) return;
  }

  let data;
  let stale = false;
  try {
    data = await loadEverything(scriptableFetch, creds.host, creds.token);
    saveCache(data);
  } catch (err) {
    data = loadCache();
    stale = true;
    if (!data) return showError(err.message);
  }

  if (config.runsInWidget) Script.setWidget(buildWidget(data, stale));
  else await buildTable(data, stale).present();
}

// Scriptable defines `Script`; Node (running the tests) does not.
if (typeof Script !== 'undefined') {
  main()
    .catch((err) => showError(err?.message ?? String(err)))
    .then(() => Script.complete());
} else if (typeof module !== 'undefined') {
  module.exports = {
    normalizeHost,
    parseNextLink,
    isSubmitted,
    normalizeAssignment,
    bucketOf,
    organize,
    formatDue,
    subtitleFor,
    loadEverything,
  };
}
