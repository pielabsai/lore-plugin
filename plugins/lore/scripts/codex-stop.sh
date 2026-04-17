#!/usr/bin/env bash
# Lore plugin — Codex Stop hook.
#
# Reads the current turn's stored prompt plus the latest assistant message and
# ingests that user/assistant pair into Lore. This is the Codex fallback for
# the missing SessionEnd lifecycle event.

set -uo pipefail

payload="$(cat)"
if [[ -z "$payload" ]]; then
  exit 0
fi

cwd="$(
  PAYLOAD="$payload" python3 - <<'PY'
import json, os
try:
    payload = json.loads(os.environ.get("PAYLOAD", "{}"))
except Exception:
    payload = {}
print(payload.get("cwd") or os.getcwd())
PY
)"

if [[ -z "$cwd" ]]; then
  exit 0
fi

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_resolve_config.sh"
resolve_lore_config "${cwd:-$PWD}" || true

if [[ "${LORE_CONFIG_STATUS:-missing}" != "ok" ]]; then
  exit 0
fi

body_file="$(mktemp 2>/dev/null)" || exit 0
trap 'rm -f "$body_file"' EXIT

STATE_ROOT="${TMPDIR:-/tmp}/lore-codex-turns" \
PAYLOAD="$payload" \
CWD="$cwd" \
BODY_FILE="$body_file" \
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
assistant = payload.get("last_assistant_message") or ""

if not session_id or not turn_id or not assistant.strip():
    raise SystemExit(0)

turn_key = hashlib.sha256(turn_id.encode("utf-8")).hexdigest()
state_file = Path(os.environ["STATE_ROOT"]) / session_id / f"{turn_key}.json"
if not state_file.exists():
    raise SystemExit(0)

try:
    record = json.loads(state_file.read_text(encoding="utf-8"))
except Exception:
    state_file.unlink(missing_ok=True)
    raise SystemExit(0)

prompt = record.get("prompt") or ""
state_file.unlink(missing_ok=True)

if not prompt.strip():
    raise SystemExit(0)

content = (
    "# Codex turn transcript\n\n"
    "**User:**\n\n"
    f"{prompt.strip()}\n\n"
    "---\n\n"
    "**Assistant:**\n\n"
    f"{assistant.strip()}\n"
)

body = {
    "source": {
        "content": content,
        "metadata": {
            "kind": "codex-turn-transcript",
            "session_id": session_id,
            "turn_id": turn_id,
            "cwd": os.environ.get("CWD", ""),
        },
    },
}

Path(os.environ["BODY_FILE"]).write_text(json.dumps(body), encoding="utf-8")
PY

if [[ ! -s "$body_file" ]]; then
  exit 0
fi

curl -sS -X POST \
  --max-time 10 \
  -H "Authorization: Bearer $LORE_API_KEY" \
  -H "Content-Type: application/json" \
  --data @"$body_file" \
  "$LORE_API_BASE/v1/apps/$LORE_APP/namespaces/$LORE_NAMESPACE/ingest" \
  >/dev/null 2>&1 || true

exit 0
