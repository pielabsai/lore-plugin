#!/usr/bin/env bash
# Lore plugin — SessionEnd hook.
#
# Reads the hook payload from stdin (JSON with session_id, transcript_path,
# reason, cwd, etc.), extracts the transcript, formats it as markdown, and
# POSTs it to the Lore ingest endpoint. Never blocks session exit: any
# failure is logged to stderr and the script still exits 0.
#
# Uses the project-local config resolver, starting the walk from the
# session's `cwd` (reported in the hook payload) so that a session ended
# from deep inside a project tree still finds the project's .lore.env.

set -uo pipefail

payload="$(cat)"
if [[ -z "$payload" ]]; then
  exit 0
fi

# Extract transcript_path and session metadata from the hook payload.
read -r transcript_path session_id reason cwd < <(
  PAYLOAD="$payload" python3 - <<'PY'
import json, os
try:
    p = json.loads(os.environ.get("PAYLOAD", "{}"))
except Exception:
    p = {}
print(
    (p.get("transcript_path") or "").replace("\n", " "),
    (p.get("session_id") or "").replace("\n", " "),
    (p.get("reason") or "").replace("\n", " "),
    (p.get("cwd") or "").replace("\n", " "),
)
PY
)

# Resolve project-local config, walking up from the session's cwd.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_resolve_config.sh"
resolve_lore_config "${cwd:-$PWD}" || true

# If the project isn't configured, silently skip ingest. SessionEnd never
# nags — the SessionStart hook is the right place to prompt for setup.
if [[ "${LORE_CONFIG_STATUS:-missing}" != "ok" ]]; then
  exit 0
fi

if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
  # No transcript available — nothing to ingest.
  exit 0
fi

# Format transcript as markdown.
content=$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/format-transcript.py" "$transcript_path" 2>/dev/null || true)
if [[ -z "${content// /}" ]]; then
  exit 0
fi

# Build the ingest body. Pass content and metadata via env vars to avoid
# shell-quoting issues with arbitrary markdown.
body=$(
  CONTENT="$content" \
  SESSION_ID="$session_id" \
  REASON="$reason" \
  CWD="$cwd" \
  python3 - <<'PY'
import json, os
body = {
    "source": {
        "content": os.environ["CONTENT"],
        "metadata": {
            "kind": "claude-session-transcript",
            "session_id": os.environ.get("SESSION_ID", ""),
            "reason": os.environ.get("REASON", ""),
            "cwd": os.environ.get("CWD", ""),
        },
    },
}
print(json.dumps(body))
PY
)

# Fire-and-forget POST. Never block on network.
curl -sS -X POST \
  --max-time 10 \
  -H "Authorization: Bearer $LORE_API_KEY" \
  -H "Content-Type: application/json" \
  --data-raw "$body" \
  "$LORE_API_BASE/v1/apps/$LORE_APP/namespaces/$LORE_NAMESPACE/ingest" \
  >/dev/null 2>&1 || true

exit 0
