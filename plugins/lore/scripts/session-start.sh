#!/usr/bin/env bash
# Lore plugin — SessionStart hook.
#
# Two responsibilities, both emitted via hookSpecificOutput.additionalContext:
#
#   1. If the plugin is not yet configured, inject a nudge telling Claude to
#      proactively offer the `lore-setup` skill on the user's first real turn.
#
#   2. If the plugin IS configured, fetch the namespace `_index` and inject it
#      as the session's initial memory context. This gives Claude the wiki's
#      navigable catalog from turn 1 — no lazy round-trip needed before the
#      first substantive answer. Fire-and-forget with a short hard timeout;
#      any failure is silent and never blocks session start.
#
# Opt-out: set LORE_PRELOAD_INDEX=0 in config.env to disable preload.
# Tuning:  set LORE_PRELOAD_INDEX_MAX_BYTES (default 8192) to change the cap.

set -uo pipefail

CONFIG_FILE="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/lore}/config.env"

# Read and discard stdin so we don't leave the hook payload buffered.
cat >/dev/null 2>&1 || true

# ---------- not-yet-configured: setup nudge ----------

if [[ ! -f "$CONFIG_FILE" ]]; then
  python3 - <<'PY'
import json
message = (
    "The Lore plugin is installed but not yet connected to a Lore account. "
    "When the user sends their next substantive message, proactively offer "
    "to run the `lore-setup` skill to connect it. The setup flow will ask "
    "for their App ID, Namespace ID, and API key, then optionally configure "
    "a namespace schema and seed the wiki from recent GitHub PRs in the "
    "current workspace. Do not interrupt a trivial greeting, but do bring "
    "it up as soon as the user asks for anything substantive."
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": message,
    }
}))
PY
  exit 0
fi

# ---------- configured: preload the namespace index ----------

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${LORE_API_KEY:?}"
: "${LORE_APP:?}"
: "${LORE_NAMESPACE:?}"
LORE_API_BASE="${LORE_API_BASE:-https://lore-api-245179047688.us-central1.run.app}"

# Opt-out: any of 0/false/no disables preload. Default is on.
preload="${LORE_PRELOAD_INDEX:-1}"
case "$preload" in
  0|false|no|off) exit 0 ;;
esac

max_bytes="${LORE_PRELOAD_INDEX_MAX_BYTES:-8192}"

# Fetch the index. Hard 3s timeout, silent on any failure so we never block
# session start on a slow or unreachable Lore API.
tmp=$(mktemp 2>/dev/null) || exit 0
trap 'rm -f "$tmp"' EXIT

code=$(curl -sS -o "$tmp" -w '%{http_code}' \
  --max-time 3 \
  -H "Authorization: Bearer $LORE_API_KEY" \
  "$LORE_API_BASE/v1/apps/$LORE_APP/namespaces/$LORE_NAMESPACE/index" \
  2>/dev/null || echo "000")

case "$code" in
  2*) ;;
  *)  exit 0 ;;  # any non-2xx: silently skip preload
esac

# Parse the Lore envelope: {"data": {"content": "..."}, "meta": {...}, "errors": [...]}.
# Truncate by bytes if oversized (back off to the last newline so we don't
# slice mid-line), then inject as additionalContext.
RESP_FILE="$tmp" \
MAX_BYTES="$max_bytes" \
LORE_APP="$LORE_APP" \
LORE_NAMESPACE="$LORE_NAMESPACE" \
python3 - <<'PY' || true
import json, os, sys

try:
    with open(os.environ["RESP_FILE"], "r") as f:
        resp = json.load(f)
except Exception:
    sys.exit(0)

# Defend against API shape drift: accept both the envelope and a bare object.
data = resp.get("data") if isinstance(resp, dict) else None
if not isinstance(data, dict):
    data = resp if isinstance(resp, dict) else {}
content = data.get("content", "") or ""

if not content.strip():
    # Empty namespace — nothing useful to preload.
    sys.exit(0)

try:
    max_bytes = int(os.environ.get("MAX_BYTES", "8192"))
except ValueError:
    max_bytes = 8192

encoded = content.encode("utf-8")
truncated = False
if len(encoded) > max_bytes:
    encoded = encoded[:max_bytes]
    # Decode ignoring a partial multibyte sequence at the slice boundary.
    content = encoded.decode("utf-8", errors="ignore")
    # Back off to the last newline so we don't cut a line in half.
    if "\n" in content:
        content = content.rsplit("\n", 1)[0]
    truncated = True

app = os.environ["LORE_APP"]
ns = os.environ["LORE_NAMESPACE"]

preamble = (
    f"# Lore wiki index for `{app}/{ns}`\n\n"
    f"The block below is the live `_index` of the user's Lore wiki for this "
    f"namespace, fetched at session start. Treat it as the authoritative, "
    f"pre-loaded table of contents for the user's persistent long-term memory. "
    f"You do not need to call `lore.sh get` with no key to fetch it again "
    f"unless you have specific reason to believe it has changed during this "
    f"session.\n\n"
    f"To read a specific file, call `bash \"${{CLAUDE_PLUGIN_ROOT}}/scripts/lore.sh\" "
    f"get <file-key>`. Follow `[[wikilinks]]` as needed. To remember new durable "
    f"content, use the `lore-memory` skill's `remember` flow.\n\n"
    f"---\n\n"
)

footer = ""
if truncated:
    footer = (
        f"\n\n---\n\n_(Index preamble truncated to ~{max_bytes // 1024} KB for "
        f"context-window efficiency. The full index is still available via "
        f"`bash \"${{CLAUDE_PLUGIN_ROOT}}/scripts/lore.sh\" get` with no key.)_"
    )

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": preamble + content + footer,
    }
}))
PY

exit 0
