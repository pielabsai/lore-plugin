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
# Loads credentials via the project-local config resolver.

set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_resolve_config.sh"
resolve_lore_config "${CLAUDE_PROJECT_DIR:-$PWD}" || true

case "${LORE_CONFIG_STATUS:-missing}" in
  ok) ;;
  missing)
    echo "Error: Lore not configured for this project. Run /lore-setup first." >&2
    exit 1
    ;;
  key_missing)
    echo "Error: Lore config found at ${LORE_CONFIG_DIR}/.lore.env but no API key set." >&2
    echo "Add your key to ${LORE_CONFIG_DIR}/.lore.env.local or run /lore-setup." >&2
    exit 1
    ;;
  incomplete)
    echo "Error: Lore config at ${LORE_CONFIG_DIR}/.lore.env is missing LORE_APP or LORE_NAMESPACE." >&2
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
    # Endpoint returns 200 even when empty. Responses are wrapped in the
    # standard Lore envelope:
    #   {"data": {"content": "..."}, "meta": {...}, "errors": [...]}
    # We extract `data.content` so the caller sees raw markdown on stdout.
    tmp=$(mktemp)
    code=$(curl -sS -o "$tmp" -w '%{http_code}' \
      -H "Authorization: Bearer $LORE_API_KEY" \
      "$BASE/schema-addendum" || echo "000")
    case "$code" in
      2*)
        RESP_FILE="$tmp" python3 - <<'PY'
import json, os, sys
try:
    with open(os.environ["RESP_FILE"], "r") as f:
        r = json.load(f)
except Exception:
    sys.stderr.write("Error: unparseable response from schema-addendum GET\n")
    sys.exit(1)
data = r.get("data") if isinstance(r, dict) else None
if not isinstance(data, dict):
    data = r if isinstance(r, dict) else {}
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
