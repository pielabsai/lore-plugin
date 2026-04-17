#!/usr/bin/env bash
# Lore plugin — Codex SessionStart hook.
#
# Mirrors the Claude SessionStart behavior, but the injected guidance points
# Codex at the Lore skills instead of Claude-specific slash commands.

set -uo pipefail

payload="$(cat 2>/dev/null || true)"

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_resolve_config.sh"

hook_cwd="$PWD"
if [[ -n "$payload" ]]; then
  hook_cwd="$(
    PAYLOAD="$payload" python3 - <<'PY'
import json, os
try:
    payload = json.loads(os.environ.get("PAYLOAD", "{}"))
except Exception:
    payload = {}
print(payload.get("cwd") or os.getcwd())
PY
  )"
fi

resolve_lore_config "$hook_cwd" || true

case "${LORE_CONFIG_STATUS:-missing}" in
  missing)
    python3 - <<'PY'
import json
message = (
    "The Lore plugin is installed but this project is not configured. "
    "When the user sends their next substantive message, proactively offer "
    "to use the `lore-setup` skill to connect this project to Lore. The "
    "setup flow will ask for their App ID, Namespace ID, and API key, then "
    "write a committed `.lore.env` (app + namespace, shared with the team) "
    "and a gitignored `.lore.env.local` (API key, per-developer) at the "
    "project root. Do not interrupt a trivial greeting, but do bring it up "
    "as soon as the user asks for anything substantive."
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": message,
    }
}))
PY
    exit 0
    ;;

  key_missing)
    CONFIG_DIR="$LORE_CONFIG_DIR" \
    LORE_APP="${LORE_APP:-}" \
    LORE_NAMESPACE="${LORE_NAMESPACE:-}" \
    python3 - <<'PY'
import json, os
config_dir = os.environ.get("CONFIG_DIR", "")
app = os.environ.get("LORE_APP", "")
ns = os.environ.get("LORE_NAMESPACE", "")
message = (
    f"This project has a committed Lore config at `{config_dir}/.lore.env` "
    f"(app=`{app}`, namespace=`{ns}`), but no API key has been configured "
    f"on this machine yet — `.lore.env.local` is missing. On the user's "
    f"next substantive message, proactively offer to use the `lore-setup` "
    f"skill to finish the per-developer setup (it only needs their API key; "
    f"the app and namespace are already committed). Alternatively, they can "
    f"create `{config_dir}/.lore.env.local` manually with a single line: "
    f"`export LORE_API_KEY=...`. Do not interrupt a trivial greeting."
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": message,
    }
}))
PY
    exit 0
    ;;

  incomplete)
    CONFIG_DIR="$LORE_CONFIG_DIR" python3 - <<'PY'
import json, os
config_dir = os.environ.get("CONFIG_DIR", "")
message = (
    f"The Lore config at `{config_dir}/.lore.env` is incomplete — it's "
    f"missing either `LORE_APP` or `LORE_NAMESPACE`. On the user's next "
    f"substantive message, offer to re-run the `lore-setup` skill to fix it."
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": message,
    }
}))
PY
    exit 0
    ;;

  ok) ;;
  *) exit 0 ;;
esac

preload="${LORE_PRELOAD_INDEX:-1}"
case "$preload" in
  0|false|no|off) exit 0 ;;
esac

max_bytes="${LORE_PRELOAD_INDEX_MAX_BYTES:-8192}"
tmp=$(mktemp 2>/dev/null) || exit 0
trap 'rm -f "$tmp"' EXIT

code=$(curl -sS -o "$tmp" -w '%{http_code}' \
  --max-time 3 \
  -H "Authorization: Bearer $LORE_API_KEY" \
  "$LORE_API_BASE/v1/apps/$LORE_APP/namespaces/$LORE_NAMESPACE/index" \
  2>/dev/null || echo "000")

case "$code" in
  2*) ;;
  *) exit 0 ;;
esac

RESP_FILE="$tmp" \
MAX_BYTES="$max_bytes" \
LORE_APP="$LORE_APP" \
LORE_NAMESPACE="$LORE_NAMESPACE" \
python3 - <<'PY' || true
import json, os, sys

try:
    with open(os.environ["RESP_FILE"], "r", encoding="utf-8") as f:
        resp = json.load(f)
except Exception:
    sys.exit(0)

data = resp.get("data") if isinstance(resp, dict) else None
if not isinstance(data, dict):
    data = resp if isinstance(resp, dict) else {}
content = data.get("content", "") or ""

if not content.strip():
    sys.exit(0)

try:
    max_bytes = int(os.environ.get("MAX_BYTES", "8192"))
except ValueError:
    max_bytes = 8192

encoded = content.encode("utf-8")
truncated = False
if len(encoded) > max_bytes:
    encoded = encoded[:max_bytes]
    content = encoded.decode("utf-8", errors="ignore")
    if "\n" in content:
        content = content.rsplit("\n", 1)[0]
    truncated = True

app = os.environ["LORE_APP"]
ns = os.environ["LORE_NAMESPACE"]

preamble = (
    f"# Lore wiki index for `{app}/{ns}`\n\n"
    "The block below is the live `_index` of the user's Lore wiki for this "
    "namespace, fetched at session start. Treat it as the authoritative, "
    "pre-loaded table of contents for the user's persistent long-term memory. "
    "Use the `lore-memory` skill to read specific files by key or to remember "
    "new durable facts. You do not need to fetch the full index again unless "
    "you have reason to believe it changed during this session.\n\n"
    "---\n\n"
)

footer = ""
if truncated:
    footer = (
        f"\n\n---\n\n_(Index preamble truncated to ~{max_bytes // 1024} KB for "
        "context-window efficiency. The full index is still available via the "
        "`lore-memory` skill if needed.)_"
    )

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": preamble + content + footer,
    }
}))
PY

exit 0
