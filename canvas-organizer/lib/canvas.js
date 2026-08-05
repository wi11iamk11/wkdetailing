/**
 * Minimal Canvas LMS REST client.
 *
 * Only needs a Canvas base URL (e.g. https://myschool.instructure.com) and a
 * user-generated access token (Canvas -> Account -> Settings -> New Access Token).
 * Every request is read-only; this client never writes back to Canvas.
 */

const USER_AGENT = 'canvas-organizer/1.0 (+local)';

export class CanvasError extends Error {
  constructor(message, { status = 0, cause } = {}) {
    super(message, { cause });
    this.name = 'CanvasError';
    this.status = status;
  }
}

/** Accepts "myschool.instructure.com" or a full URL; returns a clean origin. */
export function normalizeBaseUrl(input) {
  const raw = String(input ?? '').trim();
  if (!raw) throw new CanvasError('Canvas URL is required', { status: 400 });
  const withScheme = /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
  let url;
  try {
    url = new URL(withScheme);
  } catch {
    throw new CanvasError(`"${raw}" is not a valid Canvas URL`, { status: 400 });
  }
  if (url.protocol !== 'https:' && url.hostname !== 'localhost') {
    throw new CanvasError('Canvas URL must use https', { status: 400 });
  }
  return url.origin;
}

function parseNextLink(header) {
  if (!header) return null;
  for (const part of header.split(',')) {
    const match = part.match(/<([^>]+)>\s*;\s*rel="?next"?/i);
    if (match) return match[1];
  }
  return null;
}

export class CanvasClient {
  constructor({ baseUrl, token }) {
    this.baseUrl = normalizeBaseUrl(baseUrl);
    this.token = String(token ?? '').trim();
    if (!this.token) throw new CanvasError('Access token is required', { status: 400 });
  }

  async request(pathOrUrl, { params, timeoutMs = 30_000, attempt = 0 } = {}) {
    const url = pathOrUrl.startsWith('http')
      ? new URL(pathOrUrl)
      : new URL(pathOrUrl.replace(/^\/?/, '/api/v1/'), this.baseUrl);

    for (const [key, value] of Object.entries(params ?? {})) {
      if (value === undefined || value === null) continue;
      if (Array.isArray(value)) value.forEach((v) => url.searchParams.append(key, v));
      else url.searchParams.set(key, value);
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let res;
    try {
      res = await fetch(url, {
        headers: {
          Authorization: `Bearer ${this.token}`,
          Accept: 'application/json',
          'User-Agent': USER_AGENT,
        },
        signal: controller.signal,
      });
    } catch (err) {
      if (err.name === 'AbortError') {
        throw new CanvasError(`Canvas took too long to respond (${url.pathname})`, { status: 504, cause: err });
      }
      throw new CanvasError(`Could not reach ${this.baseUrl} — check the URL and your connection`, {
        status: 502,
        cause: err,
      });
    } finally {
      clearTimeout(timer);
    }

    // Canvas throttles with 403 + a "Rate Limit Exceeded" body, and 5xx happens.
    if ((res.status === 403 || res.status >= 500) && attempt < 3) {
      const body = await res.text();
      if (res.status >= 500 || /rate limit/i.test(body)) {
        await new Promise((r) => setTimeout(r, 2 ** attempt * 1000));
        return this.request(pathOrUrl, { params, timeoutMs, attempt: attempt + 1 });
      }
      throw new CanvasError(describeStatus(res.status, url), { status: res.status });
    }

    if (!res.ok) {
      throw new CanvasError(describeStatus(res.status, url), { status: res.status });
    }

    const body = await res.json().catch((err) => {
      throw new CanvasError('Canvas returned a response that was not JSON', { status: 502, cause: err });
    });
    return { body, next: parseNextLink(res.headers.get('link')) };
  }

  /** Follows Link-header pagination and concatenates the pages. */
  async getAll(path, { params, maxPages = 20 } = {}) {
    const out = [];
    let target = path;
    let query = { per_page: 100, ...params };
    for (let page = 0; page < maxPages && target; page++) {
      const { body, next } = await this.request(target, { params: query });
      if (!Array.isArray(body)) {
        throw new CanvasError(`Expected a list from ${path}`, { status: 502 });
      }
      out.push(...body);
      target = next;
      query = undefined; // the "next" URL already carries the query string
    }
    return out;
  }

  profile() {
    return this.request('users/self/profile').then((r) => r.body);
  }

  courses() {
    return this.getAll('courses', {
      params: {
        enrollment_state: 'active',
        'state[]': ['available'],
        'include[]': ['term', 'total_scores'],
      },
    });
  }

  async colors() {
    try {
      const { body } = await this.request('users/self/colors');
      return body?.custom_colors ?? {};
    } catch {
      return {}; // cosmetic only — never fail a sync over it
    }
  }

  assignments(courseId) {
    return this.getAll(`courses/${courseId}/assignments`, {
      params: { 'include[]': ['submission'], order_by: 'due_at' },
    });
  }
}

function describeStatus(status, url) {
  if (status === 401) return 'Canvas rejected the access token (401). Generate a new one and try again.';
  if (status === 403) return 'Canvas denied access (403). The token may lack permission for this data.';
  if (status === 404) return `Canvas has no endpoint at ${url.pathname} (404). Check the Canvas URL.`;
  return `Canvas returned HTTP ${status} for ${url.pathname}`;
}

const FALLBACK_COLORS = [
  '#2f7bd6', '#d1495b', '#2a9d8f', '#e07a1f', '#7b5ea7',
  '#0f8a8a', '#c2185b', '#5c7c2f', '#8a5a2b', '#3f51b5',
];

function colorFor(courseId, customColors, index) {
  const custom = customColors[`course_${courseId}`];
  if (typeof custom === 'string' && /^#[0-9a-f]{3,8}$/i.test(custom)) return custom;
  return FALLBACK_COLORS[index % FALLBACK_COLORS.length];
}

function isSubmitted(submission) {
  if (!submission) return false;
  if (submission.submitted_at) return true;
  return ['graded', 'complete', 'pending_review'].includes(submission.workflow_state);
}

/**
 * Pulls everything the dashboard needs and flattens it into plain records.
 * Returns { user, courses, items, syncedAt, warnings }.
 */
export async function fetchEverything(client, { onProgress } = {}) {
  const warnings = [];
  const [user, rawCourses, customColors] = await Promise.all([
    client.profile(),
    client.courses(),
    client.colors(),
  ]);

  const courses = rawCourses
    .filter((c) => c && c.id && !c.access_restricted_by_date)
    .map((c, i) => ({
      id: c.id,
      name: c.name ?? `Course ${c.id}`,
      code: c.course_code ?? '',
      term: c.term?.name ?? '',
      url: `${client.baseUrl}/courses/${c.id}`,
      color: colorFor(c.id, customColors, i),
    }));

  onProgress?.({ phase: 'courses', total: courses.length });

  // A few courses at a time: enough to be quick, gentle enough to avoid throttling.
  const items = [];
  const CONCURRENCY = 4;
  for (let i = 0; i < courses.length; i += CONCURRENCY) {
    const batch = courses.slice(i, i + CONCURRENCY);
    const results = await Promise.allSettled(batch.map((course) => client.assignments(course.id)));
    results.forEach((result, j) => {
      const course = batch[j];
      if (result.status === 'rejected') {
        warnings.push(`Could not load assignments for ${course.name}: ${result.reason?.message ?? result.reason}`);
        return;
      }
      for (const a of result.value) {
        if (!a || a.published === false) continue;
        items.push(normalizeAssignment(a, course));
      }
    });
    onProgress?.({ phase: 'assignments', done: Math.min(i + CONCURRENCY, courses.length), total: courses.length });
  }

  return {
    user: { id: user.id, name: user.name ?? user.short_name ?? 'You', baseUrl: client.baseUrl },
    courses,
    items,
    warnings,
    syncedAt: new Date().toISOString(),
  };
}

function normalizeAssignment(a, course) {
  const submission = a.submission ?? null;
  const types = a.submission_types ?? [];
  return {
    id: `a-${a.id}`,
    source: 'canvas',
    canvasId: a.id,
    courseId: course.id,
    name: a.name ?? 'Untitled assignment',
    description: stripHtml(a.description ?? ''),
    dueAt: a.due_at ?? null,
    unlockAt: a.unlock_at ?? null,
    lockAt: a.lock_at ?? null,
    pointsPossible: typeof a.points_possible === 'number' ? a.points_possible : null,
    url: a.html_url ?? `${course.url}/assignments/${a.id}`,
    kind: types.includes('online_quiz') ? 'quiz' : types.includes('discussion_topic') ? 'discussion' : 'assignment',
    gradingType: a.grading_type ?? null,
    submitted: isSubmitted(submission),
    submittedAt: submission?.submitted_at ?? null,
    graded: submission?.workflow_state === 'graded',
    score: typeof submission?.score === 'number' ? submission.score : null,
    missing: submission?.missing === true,
    late: submission?.late === true,
    lockedForUser: a.locked_for_user === true,
  };
}

function stripHtml(html) {
  return String(html)
    .replace(/<[^>]*>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 400);
}
