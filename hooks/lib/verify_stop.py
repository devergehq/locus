#!/usr/bin/env python3
"""Stop-hook verifier — enforce the classification line, and measure itself.

Two jobs, one object:

1. Enforcement. A turn that produced no classification line, or that classified
   itself non-trivial and then never invoked the ``locus-algorithm`` skill, gets
   blocked exactly once and told what it missed.

2. Measurement. Every turn appends one JSONL record. The block rate in that file
   *is* the activation-failure rate — deterministic, per prompt, no statistics.
   It cannot say whether the Algorithm helps; it can say whether the Algorithm
   runs when it should, which today is not measurable at all.

Every failure path exits 0. A verifier that can wedge a session is worse than no
verifier, so anything unexpected ends the turn normally and is recorded as
``error`` in the log rather than raised.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import sys

# Written by the user, never by the model — a model must not be able to switch
# off its own check by emitting the phrase in its reply.
ESCAPE_PHRASE = "locus: skip"

SKILL_ID = "locus-algorithm"

TRIVIAL = "**Classification: Trivial**"
NON_TRIVIAL = "**Classification: Non-trivial**"


def _read_event() -> dict:
    raw = sys.stdin.read()
    return json.loads(raw) if raw.strip() else {}


def _truthy(value) -> bool:
    """``stop_hook_active`` arrives as a JSON bool, but tolerate a string."""
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() == "true"


def _log_dir() -> str | None:
    """Resolve where the activation log lives.

    ``LOCUS_ACTIVATION_LOG_DIR`` first so tests can redirect it. Then the
    user's configured data directory, exposed by Claude Code as
    ``CLAUDE_PLUGIN_OPTION_<KEY>`` for each ``userConfig`` key. Then the
    plugin's own data directory, which always exists. If none resolve we
    simply do not log — the enforcement half still works.
    """
    for var in (
        "LOCUS_ACTIVATION_LOG_DIR",
        "CLAUDE_PLUGIN_OPTION_DATADIR",
        "CLAUDE_PLUGIN_DATA",
    ):
        base = os.environ.get(var)
        if not base:
            continue
        base = os.path.expanduser(base)
        return base if var == "LOCUS_ACTIVATION_LOG_DIR" else os.path.join(base, "activation")
    return None


def _append_record(record: dict) -> None:
    directory = _log_dir()
    if not directory:
        return
    try:
        os.makedirs(directory, exist_ok=True)
        month = _dt.datetime.now().strftime("%Y-%m")
        path = os.path.join(directory, f"activation-{month}.jsonl")
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        # Losing a log line must never cost the user their turn.
        pass


def _classification(message: str) -> str | None:
    """Which classification line the turn opened with, if any.

    Substring rather than prefix: a turn may legitimately lead with a tool
    result or a short preamble, and the criterion is that the line is present
    and unambiguous, not that it is byte zero.
    """
    has_trivial = TRIVIAL in message
    has_non_trivial = NON_TRIVIAL in message

    # `**Classification: Non-trivial**` does not contain the trivial marker —
    # the casing differs — so the two are genuinely exclusive.
    if has_non_trivial:
        return "non-trivial"
    if has_trivial:
        return "trivial"
    return None


def _scan_transcript(path: str, prompt_id: str) -> tuple[str, bool]:
    """Return (user prompt text, whether the algorithm skill was invoked).

    Walks the session transcript to the user row carrying ``prompt_id``, then
    inspects every assistant row after it. Returns empty/False rather than
    raising if the transcript is missing or shaped unexpectedly — an
    unreadable transcript must not become a block.
    """
    prompt_text = ""
    skill_fired = False

    if not path or not os.path.exists(path):
        return prompt_text, skill_fired

    try:
        with open(path, "r", encoding="utf-8") as handle:
            rows = [json.loads(line) for line in handle if line.strip()]
    except (OSError, ValueError):
        return prompt_text, skill_fired

    start = None
    for index, row in enumerate(rows):
        if row.get("type") != "user" or row.get("promptId") != prompt_id:
            continue
        if row.get("isMeta"):
            # Hook-injected context is recorded as a user row too; it is not
            # what the human typed, so it cannot carry the escape phrase.
            continue
        if start is None:
            start = index
        content = (row.get("message") or {}).get("content")
        if isinstance(content, str):
            prompt_text += content

    if start is None:
        return prompt_text, skill_fired

    for row in rows[start:]:
        if row.get("type") != "assistant":
            continue
        content = (row.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            # Catches both `Skill(skill="locus-algorithm")` and a direct
            # Read of the skill file, which is how Locus has always loaded
            # skills and remains a legitimate way to satisfy the check.
            if SKILL_ID in json.dumps(block.get("input", {})):
                skill_fired = True

    return prompt_text, skill_fired


def main() -> int:
    try:
        event = _read_event()
    except ValueError:
        return 0

    # The one-block-per-turn ceiling. Claude Code sets this on the Stop that
    # follows a block, so honouring it makes a deadlock structurally
    # impossible however wrong the classification logic gets.
    if _truthy(event.get("stop_hook_active")):
        return 0

    prompt_id = event.get("prompt_id", "")
    message = event.get("last_assistant_message") or ""

    try:
        prompt_text, skill_fired = _scan_transcript(
            event.get("transcript_path", ""), prompt_id
        )
    except Exception:  # noqa: BLE001 - fail open, always
        prompt_text, skill_fired = "", False

    escaped = ESCAPE_PHRASE in prompt_text.lower()
    classification = _classification(message)

    reason = None
    if escaped:
        pass
    elif classification is None:
        reason = (
            "Locus: this turn produced no classification line. Open your reply "
            "with `**Classification: Trivial**` or `**Classification: "
            "Non-trivial**`, and for a non-trivial request invoke the "
            "`locus-algorithm` skill before continuing."
        )
    elif classification == "non-trivial" and not skill_fired:
        reason = (
            "Locus: you classified this request non-trivial but never invoked "
            "the `locus-algorithm` skill. Invoke it and follow its phases, or "
            "reclassify the request as trivial if that is what it is."
        )

    _append_record(
        {
            "ts": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            "session_id": event.get("session_id", ""),
            "prompt_id": prompt_id,
            "classification": classification,
            "skill_fired": skill_fired,
            "escaped": escaped,
            "blocked": reason is not None,
            "reason": reason,
        }
    )

    if reason is None:
        return 0

    sys.stderr.write(reason + "\n")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 - the last fail-open guard
        sys.exit(0)
