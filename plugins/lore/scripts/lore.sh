#!/usr/bin/env bash
# Lore plugin — mid-session read/write helper.
#
# Usage:
#   lore.sh get            # returns the namespace _index
#   lore.sh get <key>      # returns one file by key
#   lore.sh remember       # reads markdown from stdin and ingests it (fire-and-forget)
#
# Loads credentials via the project-local config resolver (walks up from the
# current working directory looking for .lore.env + .lore.env.local).
# Invoked by the `lore-memory` skill via Claude's Bash tool.

set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_resolve_config.sh"
resolve_lore_config "${CLAUDE_PROJECT_DIR:-$PWD}" || true

case "${LORE_CONFIG_STATUS:-missing}" in
  ok) ;;
  missing)
    echo "Error: Lore not configured for this project. Run /lore-setup to connect it." >&2
    exit 1
    ;;
  key_missing)
    echo "Error: Lore config found at ${LORE_CONFIG_DIR}/.lore.env but no API key set." >&2
    echo "Add your key to ${LORE_CONFIG_DIR}/.lore.env.local (export LORE_API_KEY=...) or run /lore-setup." >&2
    exit 1
    ;;
  incomplete)
    echo "Error: Lore config at ${LORE_CONFIG_DIR}/.lore.env is missing LORE_APP or LORE_NAMESPACE." >&2
    echo "Re-run /lore-setup to fix it." >&2
    exit 1
    ;;
  *)
    echo "Error: Lore config resolver returned unknown status '${LORE_CONFIG_STATUS}'." >&2
    exit 1
    ;;
esac

BASE="$LORE_API_BASE/v1/apps/$LORE_APP/namespaces/$LORE_NAMESPACE"

cmd="${1:-}"
case "$cmd" in
  get)
    key="${2:-}"
    if [[ -z "$key" ]]; then
      # No key → return the namespace index as clean markdown.
      #
      # The Lore API wraps every response in an envelope:
      #   {"data": {"content": "..."}, "meta": {...}, "errors": [...]}
      # We extract `data.content` so the caller sees raw markdown, not JSON.
      resp=$(curl -sS -f -H "Authorization: Bearer $LORE_API_KEY" "$BASE/index")
      RESP="$resp" python3 - <<'PY'
import json, os, sys
try:
    r = json.loads(os.environ["RESP"])
except Exception:
    sys.stderr.write("Error: unparseable response from Lore index endpoint\n")
    sys.exit(1)
data = (r.get("data") or {}) if isinstance(r, dict) else {}
sys.stdout.write(data.get("content", "") or "")
PY
    else
      # Single file: return the full file payload (content + title + backlinks
      # + metadata) as pretty-printed JSON so Claude can pull both the body and
      # the backlinks for graph navigation.
      resp=$(curl -sS -f -H "Authorization: Bearer $LORE_API_KEY" "$BASE/files/$key")
      RESP="$resp" python3 - <<'PY'
import json, os, sys
try:
    r = json.loads(os.environ["RESP"])
except Exception:
    sys.stderr.write("Error: unparseable response from Lore file endpoint\n")
    sys.exit(1)
data = r.get("data") if isinstance(r, dict) else None
if not isinstance(data, dict):
    data = r if isinstance(r, dict) else {}
print(json.dumps(data, indent=2, ensure_ascii=False))
PY
    fi
    ;;
  remember)
    # Read markdown content from stdin. Build a JSON body safely via python.
    content=$(cat)
    if [[ -z "${content// /}" ]]; then
      echo "Error: nothing to remember (stdin was empty)." >&2
      exit 2
    fi
    body=$(CONTENT="$content" python3 -c '
import json, os
print(json.dumps({"source": {"content": os.environ["CONTENT"]}}))
')
    curl -sS -f -X POST \
      -H "Authorization: Bearer $LORE_API_KEY" \
      -H "Content-Type: application/json" \
      --data-raw "$body" \
      "$BASE/ingest"
    ;;
  *)
    echo "Usage: lore.sh get [file-key] | lore.sh remember (content via stdin)" >&2
    exit 2
    ;;
esac
