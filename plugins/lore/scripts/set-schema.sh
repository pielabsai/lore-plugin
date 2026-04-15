#!/usr/bin/env bash
# Lore plugin — namespace schema-addendum helper.
#
# Usage:
#   set-schema.sh get              # prints current schema addendum (404 -> empty)
#   set-schema.sh put              # reads markdown from stdin, PUTs as raw body
#
# The Lore API's PUT /schema-addendum endpoint takes the raw markdown body
# directly (NOT a JSON wrapper), so we pass stdin through as-is with
# Content-Type: text/markdown.
#
# Invoked by the `lore-setup` skill during the schema configuration step.

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
LORE_API_BASE="${LORE_API_BASE:-https://lore-api-245179047688.us-central1.run.app}"

BASE="$LORE_API_BASE/v1/apps/$LORE_APP/namespaces/$LORE_NAMESPACE"

cmd="${1:-}"
case "$cmd" in
  get)
    # Endpoint returns 200 with {"content": "..."} even when empty. Pull the
    # content field out so callers can just read the raw markdown on stdout.
    tmp=$(mktemp)
    code=$(curl -sS -o "$tmp" -w '%{http_code}' \
      -H "Authorization: Bearer $LORE_API_KEY" \
      "$BASE/schema-addendum" || echo "000")
    case "$code" in
      2*)
        RESP_FILE="$tmp" python3 - <<'PY'
import json, os, sys
with open(os.environ["RESP_FILE"], "r") as f:
    data = json.load(f)
sys.stdout.write(data.get("content", "") or "")
PY
        rm -f "$tmp"
        ;;
      *)
        echo "Error: schema-addendum GET failed (HTTP $code)" >&2
        cat "$tmp" >&2 2>/dev/null || true
        rm -f "$tmp"
        exit 1
        ;;
    esac
    ;;
  put)
    # Read raw markdown from stdin. The Lore API wants it unwrapped — it
    # calls io.ReadAll on the request body and passes the bytes straight
    # into SetNamespaceSchemaAddendum. Do NOT json-encode.
    content=$(cat)
    if [[ -z "${content// /}" ]]; then
      echo "Error: refusing to PUT an empty schema addendum." >&2
      exit 2
    fi
    tmp=$(mktemp)
    code=$(curl -sS -o "$tmp" -w '%{http_code}' -X PUT \
      -H "Authorization: Bearer $LORE_API_KEY" \
      -H "Content-Type: text/markdown" \
      --data-binary "$content" \
      "$BASE/schema-addendum" || echo "000")
    case "$code" in
      2*)
        rm -f "$tmp"
        echo "OK — schema addendum updated for $LORE_APP/$LORE_NAMESPACE"
        ;;
      *)
        echo "Error: schema-addendum PUT failed (HTTP $code)" >&2
        cat "$tmp" >&2 2>/dev/null || true
        rm -f "$tmp"
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Usage: set-schema.sh get | set-schema.sh put (markdown via stdin)" >&2
    exit 2
    ;;
esac
