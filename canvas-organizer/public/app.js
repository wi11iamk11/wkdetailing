/* Canvas Organizer — front end. Talks only to this app's own /api routes. */

const $ = (sel) => document.querySelector(sel);

const ui = {
  setup: $('#setup'),
  setupForm: $('#connect-form'),
  setupError: $('#setup-error'),
  app: $('#app'),
  syncedAt: $('#synced-at'),
  sync: $('#sync'),
  disconnect: $('#disconnect'),
  stats: $('#stats'),
  buckets: $('#buckets'),
  courses: $('#courses'),
  search: $('#search'),
  hideDone: $('#hide-done'),
  sort: $('#sort'),
  addTask: $('#add-task'),
  warnings: $('#warnings'),
  list: $('#list'),
  taskDialog: $('#task-dialog'),
  taskForm: $('#task-form'),
  toast: $('#toast'),
};

const state = {
  data: { items: [], courses: [], warnings: [], user: null, syncedAt: null },
  bucket: 'all',
  courseId: null,
  search: '',
  hideDone: true,
  sort: 'due',
  openNotes: new Set(),
};

const BUCKETS = [
  { id: 'all', label: 'Everything', icon: '📋' },
  { id: 'overdue', label: 'Overdue', icon: '🔥' },
  { id: 'today', label: 'Due today', icon: '⏰' },
  { id: 'week', label: 'Next 7 days', icon: '📆' },
  { id: 'later', label: 'Later', icon: '🗓' },
  { id: 'nodue', label: 'No due date', icon: '∅' },
  { id: 'done', label: 'Finished', icon: '✓' },
];
const BUCKET_LABEL = Object.fromEntries(BUCKETS.map((b) => [b.id, b.label]));

/* ------------------------------------------------------------------ api */

async function api(method, path, body) {
  const res = await fetch(path, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  const payload = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(payload.error || `${method} ${path} failed (${res.status})`);
  return payload;
}

let toastTimer;
function toast(message, bad = false) {
  ui.toast.textContent = message;
  ui.toast.classList.toggle('bad', bad);
  ui.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    ui.toast.hidden = true;
  }, bad ? 6000 : 2800);
}

/* ---------------------------------------------------------------- dates */

const DAY = 86_400_000;

function startOfDay(date) {
  const d = new Date(date);
  d.setHours(0, 0, 0, 0);
  return d;
}

function daysUntil(iso) {
  return Math.round((startOfDay(new Date(iso)) - startOfDay(new Date())) / DAY);
}

function bucketOf(item) {
  if (item.status === 'done' || item.status === 'skipped') return 'done';
  if (!item.dueAt) return 'nodue';
  const due = new Date(item.dueAt);
  if (Number.isNaN(due.getTime())) return 'nodue';
  if (due.getTime() < Date.now()) return 'overdue';
  const days = daysUntil(item.dueAt);
  if (days <= 0) return 'today';
  if (days <= 7) return 'week';
  return 'later';
}

function formatDue(item) {
  if (!item.dueAt) return { text: 'No due date', className: '' };
  const due = new Date(item.dueAt);
  if (Number.isNaN(due.getTime())) return { text: 'No due date', className: '' };

  const time = due.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  const days = daysUntil(item.dueAt);
  const past = due.getTime() < Date.now();
  const finished = item.status === 'done' || item.status === 'skipped';

  if (past && !finished) {
    const late = Math.abs(days);
    const how = late === 0 ? `earlier today, ${time}` : late === 1 ? 'yesterday' : `${late} days ago`;
    return { text: `Was due ${how}`, className: 'is-overdue' };
  }
  if (days === 0) return { text: `Today at ${time}`, className: past ? '' : 'is-soon' };
  if (days === 1) return { text: `Tomorrow at ${time}`, className: 'is-soon' };
  if (days > 1 && days <= 7) {
    return {
      text: `${due.toLocaleDateString([], { weekday: 'long' })} at ${time}`,
      className: days <= 3 ? 'is-soon' : '',
    };
  }
  return {
    text: due.toLocaleDateString([], { month: 'short', day: 'numeric', year: days > 300 ? 'numeric' : undefined }),
    className: '',
  };
}

function formatSynced(iso) {
  if (!iso) return 'Never synced';
  const mins = Math.round((Date.now() - new Date(iso).getTime()) / 60_000);
  if (mins < 1) return 'Synced just now';
  if (mins < 60) return `Synced ${mins} min ago`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `Synced ${hours} hr ago`;
  return `Synced ${new Date(iso).toLocaleDateString()}`;
}

/* -------------------------------------------------------------- filtering */

function visibleItems() {
  const needle = state.search.trim().toLowerCase();
  return state.data.items.filter((item) => {
    const bucket = bucketOf(item);
    const finished = bucket === 'done';
    if (state.bucket === 'all' ? state.hideDone && finished : bucket !== state.bucket) return false;
    if (state.courseId !== null && item.courseId !== state.courseId) return false;
    if (needle) {
      const haystack = `${item.name} ${item.courseName} ${item.notes}`.toLowerCase();
      if (!haystack.includes(needle)) return false;
    }
    return true;
  });
}

function sortItems(items) {
  const byDue = (a, b) => {
    if (!a.dueAt && !b.dueAt) return a.name.localeCompare(b.name);
    if (!a.dueAt) return 1;
    if (!b.dueAt) return -1;
    return new Date(a.dueAt) - new Date(b.dueAt);
  };
  const comparators = {
    due: byDue,
    course: (a, b) => a.courseName.localeCompare(b.courseName) || byDue(a, b),
    points: (a, b) => (b.pointsPossible ?? -1) - (a.pointsPossible ?? -1) || byDue(a, b),
    name: (a, b) => a.name.localeCompare(b.name),
  };
  return [...items].sort((a, b) => (b.pinned - a.pinned) || comparators[state.sort](a, b));
}

function groupItems(items) {
  if (state.sort === 'course') {
    const groups = new Map();
    for (const item of items) {
      if (!groups.has(item.courseName)) groups.set(item.courseName, []);
      groups.get(item.courseName).push(item);
    }
    return [...groups].map(([title, list]) => ({ title, list, kind: '' }));
  }
  if (state.sort !== 'due' || state.bucket !== 'all') {
    return [{ title: BUCKET_LABEL[state.bucket] ?? 'Results', list: items, kind: state.bucket }];
  }
  return BUCKETS.filter((b) => b.id !== 'all')
    .map((b) => ({ title: b.label, kind: b.id, list: items.filter((i) => bucketOf(i) === b.id) }))
    .filter((g) => g.list.length);
}

/* -------------------------------------------------------------- rendering */

function el(tag, props = {}, ...children) {
  const node = Object.assign(document.createElement(tag), props);
  for (const child of children.flat()) {
    if (child == null || child === false) continue;
    node.append(child.nodeType ? child : document.createTextNode(String(child)));
  }
  return node;
}

/** Stats, sidebar counts and the synced-at line — everything outside the list. */
function renderChrome() {
  const all = state.data.items;
  const counts = Object.fromEntries(BUCKETS.map((b) => [b.id, 0]));
  for (const item of all) {
    counts[bucketOf(item)] += 1;
    counts.all += 1;
  }
  renderStats(all, counts);
  renderBuckets(counts);
  renderCourses(all);
  renderWarnings();
  ui.syncedAt.textContent = formatSynced(state.data.syncedAt);
}

function render() {
  renderChrome();

  const all = state.data.items;
  const items = sortItems(visibleItems());
  ui.list.replaceChildren();

  if (!items.length) {
    ui.list.append(
      el(
        'div',
        { className: 'empty' },
        el('h3', {}, all.length ? 'Nothing here' : 'No coursework yet'),
        el(
          'p',
          { className: 'muted' },
          all.length ? 'Try another filter, or clear the search box.' : 'Hit Sync to pull your Canvas assignments.',
        ),
      ),
    );
    return;
  }

  for (const group of groupItems(items)) {
    ui.list.append(
      el(
        'section',
        {},
        el(
          'h2',
          { className: `group-title ${group.kind === 'overdue' ? 'overdue' : ''}` },
          group.title,
          el('span', { className: 'n' }, group.list.length),
        ),
        el('div', { className: 'group-items' }, group.list.map(renderItem)),
      ),
    );
  }
}

function renderStats(all, counts) {
  const active = all.filter((i) => bucketOf(i) !== 'done');
  const points = active.reduce((sum, i) => sum + (i.pointsPossible ?? 0), 0);
  const cards = [
    { key: 'overdue', value: counts.overdue, label: 'Overdue' },
    { key: 'today', value: counts.today, label: 'Due today' },
    { key: 'week', value: counts.week, label: 'Next 7 days' },
    { key: '', value: active.length, label: 'Still to do' },
    { key: '', value: Math.round(points), label: 'Points at stake' },
    { key: 'done', value: counts.done, label: 'Finished' },
  ];
  ui.stats.replaceChildren(
    ...cards.map((c) => el('div', { className: `stat ${c.key}` }, el('b', {}, c.value), el('span', {}, c.label))),
  );
}

function renderBuckets(counts) {
  ui.buckets.replaceChildren(
    ...BUCKETS.map((b) =>
      el(
        'button',
        {
          className: `filter ${state.bucket === b.id ? 'active' : ''}`,
          onclick: () => {
            state.bucket = b.id;
            render();
          },
        },
        el('span', { className: 'label' }, `${b.icon} ${b.label}`),
        el('span', { className: 'count' }, counts[b.id] ?? 0),
      ),
    ),
  );
}

function renderCourses(all) {
  const openByCourse = new Map();
  for (const item of all) {
    if (bucketOf(item) === 'done') continue;
    openByCourse.set(item.courseId, (openByCourse.get(item.courseId) ?? 0) + 1);
  }

  const rows = [
    el(
      'button',
      {
        className: `filter ${state.courseId === null ? 'active' : ''}`,
        onclick: () => {
          state.courseId = null;
          render();
        },
      },
      el('span', { className: 'dot', style: 'background:var(--muted)' }),
      el('span', { className: 'label' }, 'All courses'),
      el('span', { className: 'count' }, [...openByCourse.values()].reduce((a, b) => a + b, 0)),
    ),
    ...state.data.courses.map((course) =>
      el(
        'button',
        {
          className: `filter ${state.courseId === course.id ? 'active' : ''}`,
          title: `${course.name} — ${openByCourse.get(course.id) ?? 0} unfinished`,
          onclick: () => {
            state.courseId = state.courseId === course.id ? null : course.id;
            render();
          },
        },
        el('span', { className: 'dot', style: `background:${course.color}` }),
        el('span', { className: 'label' }, course.code || course.name),
        el('span', { className: 'count' }, openByCourse.get(course.id) ?? 0),
      ),
    ),
  ];
  ui.courses.replaceChildren(...rows);
}

function renderWarnings() {
  const warnings = state.data.warnings ?? [];
  ui.warnings.hidden = warnings.length === 0;
  ui.warnings.replaceChildren(
    ...warnings.map((w) => el('div', {}, `⚠️ ${w}`)),
  );
}

const CHECK_GLYPH = { todo: '', doing: '◐', done: '✓', skipped: '–' };
const NEXT_STATUS = { todo: 'doing', doing: 'done', done: 'todo', skipped: 'todo' };

function renderItem(item) {
  const due = formatDue(item);
  const finished = item.status === 'done' || item.status === 'skipped';

  const check = el('button', {
    className: 'check',
    title: `Mark as ${NEXT_STATUS[item.status]}`,
    textContent: CHECK_GLYPH[item.status] ?? '',
    onclick: () => setStatus(item, NEXT_STATUS[item.status]),
  });
  check.dataset.status = item.status;

  const name = item.url
    ? el('a', { className: 'item-name', href: item.url, target: '_blank', rel: 'noopener' }, item.name)
    : el('span', { className: 'item-name' }, item.name);

  const meta = el(
    'div',
    { className: 'item-meta' },
    el('span', { className: 'course-chip' }, el('span', { className: 'dot', style: `background:${item.courseColor}` }), item.courseCode || item.courseName),
    el('span', { className: `due ${finished ? '' : due.className}` }, due.text),
    item.pointsPossible ? el('span', {}, `${item.pointsPossible} pts`) : null,
    item.kind === 'quiz' ? el('span', { className: 'badge' }, 'Quiz') : null,
    item.kind === 'discussion' ? el('span', { className: 'badge' }, 'Discussion') : null,
    item.kind === 'task' ? el('span', { className: 'badge' }, 'Personal') : null,
    item.missing ? el('span', { className: 'badge missing' }, 'Missing') : null,
    item.late ? el('span', { className: 'badge late' }, 'Late') : null,
    item.graded && item.score !== null
      ? el('span', { className: 'badge graded' }, `Scored ${item.score}${item.pointsPossible ? `/${item.pointsPossible}` : ''}`)
      : null,
    item.statusIsManual ? el('span', { className: 'muted' }, '(set by you)') : null,
  );

  const side = el(
    'div',
    { className: 'item-side' },
    el('button', {
      className: `icon-btn ${item.pinned ? 'on' : ''}`,
      title: item.pinned ? 'Unpin' : 'Pin to top',
      textContent: '📌',
      onclick: () => patchItem(item.id, { pinned: !item.pinned }),
    }),
    el('button', {
      className: `icon-btn ${item.notes ? 'on' : ''}`,
      title: 'Notes',
      textContent: '📝',
      onclick: () => {
        if (state.openNotes.has(item.id)) state.openNotes.delete(item.id);
        else state.openNotes.add(item.id);
        refreshRow(item.id);
        ui.list.querySelector(`[data-id="${CSS.escape(item.id)}"] .notes`)?.focus();
      },
    }),
    item.source === 'local'
      ? el('button', {
          className: 'icon-btn',
          title: 'Delete task',
          textContent: '🗑',
          onclick: () => deleteTask(item),
        })
      : el('button', {
          className: `icon-btn ${item.status === 'skipped' ? 'on' : ''}`,
          title: item.status === 'skipped' ? 'Un-ignore' : 'Ignore this one',
          textContent: '✕',
          onclick: () => setStatus(item, item.status === 'skipped' ? 'todo' : 'skipped'),
        }),
  );

  const row = el(
    'article',
    { className: `item ${finished ? 'is-done' : ''} ${item.status === 'doing' ? 'is-doing' : ''}` },
    check,
    el('div', { className: 'item-main' }, name, meta),
    side,
  );
  row.style.setProperty('--course', item.courseColor);
  row.dataset.id = item.id;

  if (state.openNotes.has(item.id)) {
    const box = el('textarea', {
      className: 'notes',
      value: item.notes,
      placeholder: 'Notes — what is left, where the file lives, questions to ask…',
    });
    box.addEventListener('input', () => queueNotes(item.id, box.value));
    box.addEventListener('blur', () => flushNotes());
    row.append(box);
  } else if (item.notes) {
    row.append(el('div', { className: 'note-preview' }, item.notes));
  }

  return row;
}

/* --------------------------------------------------------------- actions */

function applyPayload(payload) {
  if (payload && !payload.empty) state.data = payload;
  render();
}

/**
 * Redraws a single row without re-sorting the list. Toggling a status or a pin
 * must not make every other row jump — the next full render (filter change,
 * sync, reload) is when things re-sort.
 */
function refreshRow(id) {
  const item = state.data.items.find((i) => i.id === id);
  const row = ui.list.querySelector(`[data-id="${CSS.escape(id)}"]`);
  if (!item || !row) return render();
  row.replaceWith(renderItem(item));
  renderChrome();
}

/** Mirrors the server's merge rules so the click feels instant. */
function echoLocally(item, patch) {
  if ('pinned' in patch) item.pinned = Boolean(patch.pinned);
  if ('notes' in patch) item.notes = patch.notes;
  if ('status' in patch) {
    const derived = item.submitted || item.graded ? 'done' : 'todo';
    item.status = patch.status ?? derived;
    item.statusIsManual = patch.status !== null && patch.status !== undefined;
  }
}

async function patchItem(id, patch) {
  const item = state.data.items.find((i) => i.id === id);
  if (item) {
    echoLocally(item, patch);
    refreshRow(id);
  }
  try {
    const payload = await api('PATCH', `/api/items/${encodeURIComponent(id)}`, patch);
    if (payload && !payload.empty) {
      state.data = payload;
      refreshRow(id);
    }
  } catch (err) {
    toast(err.message, true);
    render(); // drop the optimistic echo
  }
}

function setStatus(item, status) {
  // Clicking back to "todo" on something Canvas already shows as submitted should
  // drop the manual override rather than fight it.
  const derived = item.submitted || item.graded ? 'done' : 'todo';
  return patchItem(item.id, { status: status === derived ? null : status });
}

let notesTimer;
let pendingNotes = null;
function queueNotes(id, notes) {
  pendingNotes = { id, notes };
  clearTimeout(notesTimer);
  notesTimer = setTimeout(flushNotes, 700);
}
async function flushNotes() {
  clearTimeout(notesTimer);
  if (!pendingNotes) return;
  const { id, notes } = pendingNotes;
  pendingNotes = null;
  const item = state.data.items.find((i) => i.id === id);
  if (item) item.notes = notes; // keep local state in step so a re-render doesn't flicker
  try {
    const payload = await api('PATCH', `/api/items/${encodeURIComponent(id)}`, { notes });
    if (payload && !payload.empty) state.data = payload; // no re-render: don't yank focus
  } catch (err) {
    toast(err.message, true);
  }
}

async function deleteTask(item) {
  if (!confirm(`Delete "${item.name}"?`)) return;
  try {
    applyPayload(await api('DELETE', `/api/tasks/${encodeURIComponent(item.id)}`));
    toast('Task deleted');
  } catch (err) {
    toast(err.message, true);
  }
}

async function sync() {
  ui.sync.disabled = true;
  ui.sync.textContent = 'Syncing…';
  try {
    applyPayload(await api('POST', '/api/sync'));
    toast(`Synced ${state.data.items.filter((i) => i.source === 'canvas').length} assignments`);
  } catch (err) {
    toast(err.message, true);
    if (/401|token/i.test(err.message)) showSetup('Canvas rejected the saved token. Connect again.');
  } finally {
    ui.sync.disabled = false;
    ui.sync.textContent = 'Sync';
  }
}

/* ----------------------------------------------------------------- boot */

function showSetup(message) {
  ui.app.hidden = true;
  ui.setup.hidden = false;
  ui.setupError.hidden = !message;
  ui.setupError.textContent = message ?? '';
}

function showApp() {
  ui.setup.hidden = true;
  ui.app.hidden = false;
}

ui.setupForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = ui.setupForm.querySelector('button');
  button.disabled = true;
  button.textContent = 'Connecting…';
  ui.setupError.hidden = true;
  try {
    await api('POST', '/api/connect', {
      baseUrl: $('#baseUrl').value,
      token: $('#token').value,
    });
    $('#token').value = '';
    showApp();
    await sync();
  } catch (err) {
    ui.setupError.textContent = err.message;
    ui.setupError.hidden = false;
  } finally {
    button.disabled = false;
    button.textContent = 'Connect';
  }
});

ui.sync.addEventListener('click', sync);

ui.disconnect.addEventListener('click', async () => {
  if (!confirm('Forget this Canvas account? Your notes and personal tasks are kept.')) return;
  await api('POST', '/api/disconnect').catch((err) => toast(err.message, true));
  state.data = { items: [], courses: [], warnings: [], user: null, syncedAt: null };
  showSetup();
});

ui.search.addEventListener('input', () => {
  state.search = ui.search.value;
  render();
});
ui.hideDone.addEventListener('change', () => {
  state.hideDone = ui.hideDone.checked;
  render();
});
ui.sort.addEventListener('change', () => {
  state.sort = ui.sort.value;
  render();
});

ui.addTask.addEventListener('click', () => {
  $('#task-course').replaceChildren(
    el('option', { value: '' }, 'None'),
    ...state.data.courses.map((c) => el('option', { value: String(c.id) }, c.name)),
  );
  ui.taskForm.reset();
  ui.taskDialog.showModal();
});

ui.taskForm.addEventListener('submit', async (event) => {
  if (event.submitter?.value !== 'save') return;
  const name = $('#task-name').value.trim();
  if (!name) return;
  const dueLocal = $('#task-due').value;
  try {
    applyPayload(
      await api('POST', '/api/tasks', {
        name,
        dueAt: dueLocal ? new Date(dueLocal).toISOString() : null,
        courseId: $('#task-course').value || null,
      }),
    );
    toast('Task added');
  } catch (err) {
    toast(err.message, true);
  }
});

document.addEventListener('keydown', (event) => {
  if (event.key === '/' && document.activeElement?.tagName !== 'INPUT' && document.activeElement?.tagName !== 'TEXTAREA') {
    event.preventDefault();
    ui.search.focus();
  }
});

(async function boot() {
  try {
    const status = await api('GET', '/api/status');
    if (!status.connected) return showSetup();
    showApp();
    const data = await api('GET', '/api/data');
    if (data.empty) await sync();
    else applyPayload(data);
  } catch (err) {
    showSetup(err.message);
  }
})();
