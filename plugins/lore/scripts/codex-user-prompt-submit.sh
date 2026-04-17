#!/usr/bin/env bash
# Lore plugin — Codex UserPromptSubmit hook.
#
# Codex does not currently expose a SessionEnd hook, so we persist the current
# turn's user prompt here and pair it with the final assistant message in the
# Stop hook.

set -uo pipefail

payload="$(cat)"
if [[ -z "$payload" ]]; then
  exit 0
fi

STATE_ROOT="${TMPDIR:-/tmp}/lore-codex-turns" \
PAYLOAD="$payload" \
python3 - <<'PY' >/dev/null 2>&1 || true
import hashlib
import json
import os
from pathlib import Path

try:
    payload = json.loads(os.environ.get("PAYLOAD", "{}"))
except Exception:
    raise SystemExit(0)

session_id = payload.get("session_id") or ""
turn_id = payload.get("turn_id") or ""
prompt = payload.get("prompt") or ""

if not session_id or not turn_id or not prompt.strip():
    raise SystemExit(0)

turn_key = hashlib.sha256(turn_id.encode("utf-8")).hexdigest()
state_dir = Path(os.environ["STATE_ROOT"]) / session_id
state_dir.mkdir(parents=True, exist_ok=True)
state_file = state_dir / f"{turn_key}.json"

record = {
    "prompt": prompt,
    "cwd": payload.get("cwd") or "",
    "session_id": session_id,
    "turn_id": turn_id,
}
state_file.write_text(json.dumps(record), encoding="utf-8")
PY

exit 0
