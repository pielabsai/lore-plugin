#!/usr/bin/env bash
# Lore plugin — mid-session read/write helper.
#
# Usage:
#   lore.sh get            # returns the namespace _index
#   lore.sh get <key>      # returns one file by key
#   lore.sh remember       # reads markdown from stdin and ingests it (fire-and-forget)
#
# Loads credentials from ${CLAUDE_PLUGIN_DATA}/config.env, which is written by
# setup.sh. Invoked by the `lore-memory` skill via Claude's Bash tool.

set -euo pipefail

CONFIG_FILE="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/lore}/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Lore not configured. Run the lore-setup skill first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${LORE_API_KEY:?LORE_API_KEY missing from config}"
: "${LORE_APP:?LORE_APP missing from config}"
: "${LORE_NAMESPACE:?LORE_NAMESPACE missing from config}"
LORE_API_BASE="${LORE_API_BASE:-https://api.lore.dev}"

BASE="$LORE_API_BASE/v1/apps/$LORE_APP/namespaces/$LORE_NAMESPACE"

cmd="${1:-}"
case "$cmd" in
  get)
    key="${2:-}"
    if [[ -z "$key" ]]; then
      # No key → return the index.
      curl -sS -f -H "Authorization: Bearer $LORE_API_KEY" "$BASE/index"
    else
      curl -sS -f -H "Authorization: Bearer $LORE_API_KEY" "$BASE/files/$key"
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
