/*
 * Off-device tests for CanvasOrganizer.js.
 *
 * The Scriptable-specific parts (UITable, ListWidget, Keychain) can only be
 * exercised on an iPhone, but everything that decides *what* is shown — paging,
 * grouping, sorting, date wording — is plain JavaScript and tested here.
 *
 *   node ios/test.js
 */

const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert');

const lib = require('./CanvasOrganizer.js');

let passed = 0;
const failures = [];
function test(name, fn) {
  try {
    fn();
    passed++;
  } catch (err) {
    failures.push(`${name}: ${err.message}`);
  }
}
async function testAsync(name, fn) {
  try {
    await fn();
    passed++;
  } catch (err) {
    failures.push(`${name}: ${err.message}`);
  }
}

/* ---------------------------------------------------------- pure logic */

test('normalizeHost accepts a bare domain', () => {
  assert.equal(lib.normalizeHost('myschool.instructure.com'), 'https://myschool.instructure.com');
});
test('normalizeHost strips a pasted course path', () => {
  assert.equal(lib.normalizeHost('https://s.instructure.com/courses/12/assignments'), 'https://s.instructure.com');
});
test('normalizeHost trims whitespace and fixes case', () => {
  assert.equal(lib.normalizeHost('  MySchool.Instructure.COM '), 'https://myschool.instructure.com');
});
test('normalizeHost rejects empty input', () => {
  assert.throws(() => lib.normalizeHost('   '), /required/);
});
test('normalizeHost survives a stray space from iOS autocorrect', () => {
  assert.equal(lib.normalizeHost('sdhc .instructure.com'), 'https://sdhc.instructure.com');
  assert.equal(lib.normalizeHost('sdhc. instructure.com'), 'https://sdhc.instructure.com');
  assert.equal(lib.normalizeHost('sd hc . instructure . com'), 'https://sdhc.instructure.com');
});

/*
 * Scriptable's JS engine (JavaScriptCore without WebKit) has no global `URL`
 * or `URLSearchParams` — code written and tested under Node, which has both,
 * can still throw "Can't find variable: URL" the moment it actually runs on
 * an iPhone. This is exactly what happened: normalizeHost used `new URL()`,
 * passed every Node test, and failed on every single device.
 *
 * These two checks stand in for that gap: one deletes the globals to prove
 * the code doesn't reach for them, the other statically greps the source so
 * the pattern can't quietly come back in a later edit.
 */
test('normalizeHost works with no global URL/URLSearchParams (simulates Scriptable)', () => {
  const savedURL = global.URL;
  const savedParams = global.URLSearchParams;
  delete global.URL;
  delete global.URLSearchParams;
  try {
    assert.equal(lib.normalizeHost('sdhc.instructure.com'), 'https://sdhc.instructure.com');
    assert.equal(
      lib.normalizeHost('https://s.instructure.com/courses/12/assignments'),
      'https://s.instructure.com',
    );
    assert.throws(() => lib.normalizeHost('not a domain!!'), /not a valid Canvas address/);
  } finally {
    global.URL = savedURL;
    global.URLSearchParams = savedParams;
  }
});
test('CanvasOrganizer.js never references URL or URLSearchParams', () => {
  const source = fs.readFileSync(path.join(__dirname, 'CanvasOrganizer.js'), 'utf8');
  assert.doesNotMatch(source, /\bnew\s+URL\s*\(/, 'no global URL() on Scriptable — build strings by hand');
  assert.doesNotMatch(source, /\.searchParams\b/, 'no URLSearchParams on Scriptable — build query strings by hand');
});

test('parseNextLink finds rel=next among several links', () => {
  const header =
    '<https://x/api/v1/courses?page=1>; rel="current", <https://x/api/v1/courses?page=2>; rel="next", <https://x/api/v1/courses?page=9>; rel="last"';
  assert.equal(lib.parseNextLink(header), 'https://x/api/v1/courses?page=2');
});
test('parseNextLink returns null on the last page', () => {
  assert.equal(lib.parseNextLink('<https://x/api/v1/courses?page=9>; rel="last"'), null);
});
test('parseNextLink tolerates a missing header', () => {
  assert.equal(lib.parseNextLink(undefined), null);
});

test('isSubmitted covers submitted, graded and unsubmitted', () => {
  assert.equal(lib.isSubmitted({ submitted_at: '2026-01-01T00:00:00Z' }), true);
  assert.equal(lib.isSubmitted({ workflow_state: 'graded' }), true);
  assert.equal(lib.isSubmitted({ workflow_state: 'unsubmitted' }), false);
  assert.equal(lib.isSubmitted(null), false);
});

const NOON = new Date('2026-03-10T12:00:00Z').getTime();
const at = (iso) => ({ dueAt: iso, name: iso ?? 'none', submitted: false });

test('bucketOf sorts by urgency relative to now', () => {
  assert.equal(lib.bucketOf(at('2026-03-09T12:00:00Z'), NOON), 'overdue');
  assert.equal(lib.bucketOf(at('2026-03-10T23:00:00Z'), NOON), 'today');
  assert.equal(lib.bucketOf(at('2026-03-14T12:00:00Z'), NOON), 'week');
  assert.equal(lib.bucketOf(at('2026-04-30T12:00:00Z'), NOON), 'later');
  assert.equal(lib.bucketOf(at(null), NOON), 'nodue');
});
test('bucketOf treats an hour ago today as overdue, not due today', () => {
  assert.equal(lib.bucketOf(at('2026-03-10T11:00:00Z'), NOON), 'overdue');
});
test('bucketOf survives a malformed date', () => {
  assert.equal(lib.bucketOf(at('not-a-date'), NOON), 'nodue');
});

test('organize drops submitted work and orders groups by urgency', () => {
  const items = [
    { name: 'later', dueAt: '2026-04-01T12:00:00Z', submitted: false },
    { name: 'done', dueAt: '2026-03-09T12:00:00Z', submitted: true },
    { name: 'overdue', dueAt: '2026-03-08T12:00:00Z', submitted: false },
    { name: 'today', dueAt: '2026-03-10T20:00:00Z', submitted: false },
  ];
  const groups = lib.organize(items, NOON);
  assert.deepEqual(groups.map((g) => g.id), ['overdue', 'today', 'later']);
  assert.equal(groups.flatMap((g) => g.items).some((i) => i.name === 'done'), false);
});
test('organize sorts within a group by due date', () => {
  const items = [
    { name: 'friday', dueAt: '2026-03-13T12:00:00Z', submitted: false },
    { name: 'wednesday', dueAt: '2026-03-11T12:00:00Z', submitted: false },
  ];
  const [group] = lib.organize(items, NOON);
  assert.deepEqual(group.items.map((i) => i.name), ['wednesday', 'friday']);
});
test('organize omits empty groups', () => {
  const groups = lib.organize([{ name: 'x', dueAt: null, submitted: false }], NOON);
  assert.deepEqual(groups.map((g) => g.id), ['nodue']);
});

test('formatDue words overdue and upcoming work differently', () => {
  assert.match(lib.formatDue(at('2026-03-08T12:00:00Z'), NOON), /Was due 2 days ago/);
  assert.match(lib.formatDue(at('2026-03-09T12:00:00Z'), NOON), /Was due yesterday/);
  assert.match(lib.formatDue(at('2026-03-10T20:00:00Z'), NOON), /^Today at /);
  assert.match(lib.formatDue(at('2026-03-11T20:00:00Z'), NOON), /^Tomorrow at /);
  assert.match(lib.formatDue(at('2026-03-13T20:00:00Z'), NOON), /^Friday at /);
  assert.equal(lib.formatDue(at(null), NOON), 'No due date');
});

test('subtitleFor packs course, timing, points and missing flag', () => {
  const line = lib.subtitleFor(
    { courseCode: 'BIO 101', dueAt: '2026-03-08T12:00:00Z', points: 50, missing: true },
    NOON,
  );
  assert.equal(line, 'BIO 101 · Was due 2 days ago · 50 pts · MISSING');
});

/* ------------------------------------------------- loadEverything, live */

const courses = [
  { id: 1, name: 'Biology', course_code: 'BIO 101' },
  { id: 2, name: 'History', course_code: 'HIST 210' },
  { id: 3, name: 'Not started yet', access_restricted_by_date: true },
  { id: 4, name: 'Broken Course', course_code: 'ERR 500' },
];

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (req.headers.authorization !== 'Bearer good') {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    return res.end('{"errors":[{"message":"Invalid access token."}]}');
  }
  const json = (body, headers = {}) => {
    res.writeHead(200, { 'Content-Type': 'application/json', ...headers });
    res.end(JSON.stringify(body));
  };

  if (url.pathname === '/api/v1/courses') {
    // Page 1 of 2, to exercise Link-header pagination.
    if (url.searchParams.get('page') === '2') return json(courses.slice(2));
    const next = `http://127.0.0.1:${PORT}/api/v1/courses?page=2`;
    return json(courses.slice(0, 2), { Link: `<${next}>; rel="next"` });
  }
  const match = url.pathname.match(/^\/api\/v1\/courses\/(\d+)\/assignments$/);
  if (match) {
    const id = Number(match[1]);
    if (id === 4) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      return res.end('{"errors":"boom"}');
    }
    if (id === 1) {
      return json([
        { id: 11, name: 'Lab Report', due_at: '2026-03-08T12:00:00Z', points_possible: 50, published: true,
          submission_types: ['online_upload'], submission: { missing: true }, html_url: 'https://c/1' },
        { id: 12, name: 'Quiz 1', due_at: '2026-03-11T12:00:00Z', points_possible: 20, published: true,
          submission_types: ['online_quiz'], submission: { workflow_state: 'graded' } },
        { id: 13, name: 'Hidden draft', published: false },
      ]);
    }
    return json([
      { id: 21, name: 'Essay', due_at: '2026-03-20T12:00:00Z', points_possible: 100, published: true, submission_types: ['online_text_entry'] },
    ]);
  }
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end('{"errors":"not found"}');
});

const PORT = 9791;

async function nodeFetchJson(url, token) {
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' } });
  if (res.status === 401) throw new Error('Canvas rejected your token');
  if (!res.ok) throw new Error(`Canvas returned HTTP ${res.status}`);
  return { body: await res.json(), next: lib.parseNextLink(res.headers.get('link')) };
}

(async () => {
  await new Promise((r) => server.listen(PORT, '127.0.0.1', r));
  const host = `http://127.0.0.1:${PORT}`;

  await testAsync('loadEverything pages through courses and skips restricted ones', async () => {
    const data = await lib.loadEverything(nodeFetchJson, host, 'good');
    assert.equal(data.courseCount, 3, 'restricted course should be dropped, paged course kept');
  });

  await testAsync('loadEverything skips unpublished assignments', async () => {
    const data = await lib.loadEverything(nodeFetchJson, host, 'good');
    assert.equal(data.items.some((i) => i.name === 'Hidden draft'), false);
  });

  await testAsync('loadEverything records a per-course failure as a warning', async () => {
    const data = await lib.loadEverything(nodeFetchJson, host, 'good');
    assert.equal(data.warnings.length, 1);
    assert.match(data.warnings[0], /Broken Course/);
    assert.equal(data.items.length, 3, 'the other courses still load');
  });

  await testAsync('graded work is marked submitted and hidden from the list', async () => {
    const data = await lib.loadEverything(nodeFetchJson, host, 'good');
    const quiz = data.items.find((i) => i.name === 'Quiz 1');
    assert.equal(quiz.submitted, true);
    assert.equal(quiz.isQuiz, true);
    const shown = lib.organize(data.items, NOON).flatMap((g) => g.items.map((i) => i.name));
    assert.deepEqual(shown, ['Lab Report', 'Essay']);
  });

  await testAsync('a bad token surfaces as an error, not empty results', async () => {
    await assert.rejects(() => lib.loadEverything(nodeFetchJson, host, 'wrong'), /rejected your token/);
  });

  server.close();

  console.log(`${passed} passed, ${failures.length} failed`);
  for (const failure of failures) console.log(`  FAIL  ${failure}`);
  process.exit(failures.length ? 1 : 0);
})();
