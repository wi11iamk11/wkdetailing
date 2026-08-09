"""Durable JARVIS state -- the facts that outlive a single voice session.

Loaded once when a session starts and substituted into the <state> block of
the system prompt. Updated only through the STATE_UPDATE line documented in
prompts/jarvis-system-prompt.md: brain.py pulls that line out of the stream
before it ever reaches the chunker, merges it here, and writes it back to
disk so the next launch sees it. A running session never sees its own
STATE_UPDATE reflected back into <state> mid-conversation -- that block is
fixed for the life of the prompt cache -- only the next one does.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timedelta
from pathlib import Path

import config

STATE_PATH = Path(os.environ.get("VOICE_LINE_STATE_PATH") or str(config.ROOT / "jarvis_state.json"))

_PREFIX = "STATE_UPDATE:"

# Lists that merge item-by-item instead of being replaced wholesale, and the
# fields that identify an item within them.
#
# A flat dict.update() would mean that adding one assignment requires the
# model to re-emit every assignment it already knows about -- dictated aloud,
# through a speech pipeline, in a single JSON line. One dropped token and the
# semester disappears. Merging on a natural key lets a turn say only what
# changed, which is also the only thing it reliably knows.
LIST_KEYS: dict[str, tuple[str, ...]] = {
    "courses": ("code",),
    "assignments": ("course", "title"),
    "exams": ("course", "title"),
}

# How far ahead the agenda looks. Past this, a deadline is real but not yet
# actionable, and putting it in front of him every session is how a briefing
# turns into noise he stops hearing.
AGENDA_HORIZON_DAYS = 14
AGENDA_MAX_ITEMS = 12


def load() -> dict:
    try:
        data = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def save(state: dict) -> None:
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(STATE_PATH)


def is_update_line(line: str) -> bool:
    """True for any line that claims to be a state update, valid or not.

    A line meeting this is never spoken -- checked separately from parsing
    so a malformed STATE_UPDATE still gets silenced instead of read aloud.
    """
    return line.strip().startswith(_PREFIX)


def extract_update(line: str) -> dict | None:
    """Pull the JSON object out of a STATE_UPDATE line, or None if malformed.

    A malformed match is dropped rather than partially applied: the prompt
    contract requires this so a corrupted write never silently clobbers
    state that was already known good.
    """
    line = line.strip()
    if not line.startswith(_PREFIX):
        return None
    payload = line[len(_PREFIX):].strip()
    try:
        parsed = json.loads(payload)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _identity(item: dict, fields: tuple[str, ...]) -> tuple:
    return tuple(str(item.get(f, "")).strip().lower() for f in fields)


def _merge_list(existing: list, incoming: list, fields: tuple[str, ...]) -> list:
    """Merge incoming items into existing ones by natural key.

    A matching item is updated field-by-field rather than replaced, so an
    update that says only {"status": "done"} keeps the due date it already
    had. Unmatched items are appended in the order given.
    """
    merged = [dict(item) if isinstance(item, dict) else item for item in existing]
    index = {
        _identity(item, fields): pos
        for pos, item in enumerate(merged)
        if isinstance(item, dict)
    }
    for item in incoming:
        if not isinstance(item, dict):
            continue
        key = _identity(item, fields)
        pos = index.get(key)
        if pos is None:
            index[key] = len(merged)
            merged.append(dict(item))
        else:
            merged[pos].update(item)
    return merged


def merge(state: dict, update: dict) -> dict:
    merged = dict(state)
    for key, value in update.items():
        fields = LIST_KEYS.get(key)
        if fields and isinstance(value, list) and isinstance(merged.get(key), list):
            merged[key] = _merge_list(merged[key], value, fields)
        else:
            merged[key] = value
    return merged


# ---------------------------------------------------------------------------
# The agenda
# ---------------------------------------------------------------------------


def parse_when(value) -> datetime | None:
    """Parse a due date leniently, as naive local time, or None.

    Dictated state is not clean state: a date can arrive as a bare day, a
    full timestamp, or something with a trailing Z. Anything unparseable is
    dropped rather than guessed at -- a wrong deadline is worse than a
    missing one.
    """
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith(("Z", "z")):
        text = text[:-1]
    try:
        when = datetime.fromisoformat(text)
    except ValueError:
        return None
    if when.tzinfo is not None:
        when = when.astimezone().replace(tzinfo=None)
    # A bare date means the end of that day, not midnight at its start --
    # "due Friday" is not overdue at breakfast on Friday.
    if len(text) == 10 and when.hour == 0 and when.minute == 0:
        when = when.replace(hour=23, minute=59)
    return when


def _is_open(item: dict) -> bool:
    return str(item.get("status", "open")).strip().lower() not in ("done", "complete",
                                                                   "completed", "submitted")


def upcoming(state: dict, now: datetime | None = None,
             horizon_days: int = AGENDA_HORIZON_DAYS) -> list[dict]:
    """Every open, dated obligation worth mentioning, soonest first.

    Overdue items are always included regardless of how far past they are:
    a missed deadline does not stop being his problem just because it aged
    out of the horizon.
    """
    now = now or datetime.now()
    horizon = now + timedelta(days=horizon_days)
    found: list[dict] = []

    for key, when_field, kind in (("assignments", "due", "assignment"),
                                  ("exams", "at", "exam")):
        for item in state.get(key) or []:
            if not isinstance(item, dict) or not _is_open(item):
                continue
            when = parse_when(item.get(when_field))
            if when is None or when > horizon:
                continue
            found.append({
                "kind": kind,
                "title": str(item.get("title", "")).strip() or f"untitled {kind}",
                "course": str(item.get("course", "")).strip(),
                "when": when,
                "overdue": when < now,
                "hours_left": (when - now).total_seconds() / 3600.0,
            })

    found.sort(key=lambda entry: entry["when"])
    return found[:AGENDA_MAX_ITEMS]


def _relative(entry: dict) -> str:
    hours = entry["hours_left"]
    if entry["overdue"]:
        late = -hours
        if late < 24:
            return f"OVERDUE by {round(late)} hours"
        return f"OVERDUE by {round(late / 24)} days"
    if hours < 1:
        return f"in {max(1, round(hours * 60))} minutes"
    if hours < 24:
        return f"in {round(hours)} hours"
    return f"in {round(hours / 24)} days"


def render_agenda(state: dict, now: datetime | None = None) -> str:
    """The agenda as lines for the prompt, or a plain statement of nothing.

    Derived on every launch rather than stored, because it is a function of
    the clock: the same state is a comfortable week out on Monday and a
    crisis on Thursday.
    """
    now = now or datetime.now()
    entries = upcoming(state, now)
    if not entries:
        return "Nothing dated is open in the next two weeks."
    lines = []
    for entry in entries:
        course = f" [{entry['course']}]" if entry["course"] else ""
        stamp = entry["when"].strftime("%a %d %b, %I:%M %p").replace(" 0", " ")
        preposition = "at" if entry["kind"] == "exam" else "due"
        lines.append(f"- {entry['kind']}: {entry['title']}{course} "
                     f"{preposition} {stamp} ({_relative(entry)})")
    return "\n".join(lines)
