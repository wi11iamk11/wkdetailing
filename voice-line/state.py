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
from pathlib import Path

import config

STATE_PATH = Path(os.environ.get("VOICE_LINE_STATE_PATH") or str(config.ROOT / "jarvis_state.json"))

_PREFIX = "STATE_UPDATE:"


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


def merge(state: dict, update: dict) -> dict:
    merged = dict(state)
    merged.update(update)
    return merged
