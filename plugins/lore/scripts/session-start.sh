#!/usr/bin/env bash
# Lore plugin — SessionStart hook.
#
# Three modes, selected by the project-local config resolver:
#
#   1. missing       — no .lore.env found walking up from the workspace.
#                      Inject a nudge telling Claude to proactively offer
#                      /lore-setup on the user's next substantive message.
#
#   2. key_missing   — .lore.env exists (team config is committed) but
#                      .lore.env.local is missing or empty. Inject a precise
#                      nudge telling the user exactly which file to create
#                      and which env var to set. This is the "teammate just
#                      cloned the repo" path.
#
#   3. ok            — everything resolved. Fetch the namespace `_index` and
#                      inject it as additionalContext so the wiki's table of
#                      contents is available from turn 1. Hard 3s timeout,
#                      silent on any failure — never blocks session start.
#
# Opt-out: set LORE_PRELOAD_INDEX=0 in .lore.env to disable preload.
# Tuning:  set LORE_PRELOAD_INDEX_MAX_BYTES (default 8192) to change the cap.

set -uo pipefail

# Read and discard stdin so we don't leave the hook payload buffered.
cat >/dev/null 2>&1 || true

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_resolve_config.sh"

# Start walk-up from CLAUDE_PROJECT_DIR (hook-provided workspace) if set.
resolve_lore_config "${CLAUDE_PROJECT_DIR:-$PWD}" || true

case "${LORE_CONFIG_STATUS:-missing}" in
  missing)
    python3 - <<'PY'
import json
message = (
    "The Lore plugin is installed but this project is not configured. "
    "When the user sends their next substantive message, proactively offer "
    "to run the `/lore-setup` slash command (or the `lore-setup` skill) to "
    "connect this project to Lore. The setup flow will ask for their App ID, "
    "Namespace ID, and API key, then write a committed `.lore.env` (app + "
    "namespace, shared with the team) and a gitignored `.lore.env.local` "
    "(API key, per-developer) at the project root. Do not interrupt a "
    "trivial greeting, but do bring it up as soon as the user asks for "
    "anything substantive."
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
    # Team config is committed but this developer hasn't added their key yet.
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
    f"next substantive message, proactively offer to run the `/lore-setup` "
    f"slash command to finish the per-developer setup (it only needs their "
    f"API key; the app and namespace are already committed). Alternatively, "
    f"they can create `{config_dir}/.lore.env.local` manually with a single "
    f"line: `export LORE_API_KEY=...`. Do not interrupt a trivial greeting."
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
    # .lore.env exists but is missing LORE_APP or LORE_NAMESPACE — probably
    # a hand-edited or half-written file. Point the user at re-running setup.
    CONFIG_DIR="$LORE_CONFIG_DIR" python3 - <<'PY'
import json, os
config_dir = os.environ.get("CONFIG_DIR", "")
message = (
    f"The Lore config at `{config_dir}/.lore.env` is incomplete — it's "
    f"missing either `LORE_APP` or `LORE_NAMESPACE`. On the user's next "
    f"substantive message, offer to re-run `/lore-setup` to fix it."
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

  ok) ;;  # fall through to preload
  *)  exit 0 ;;
esac

# ---------- configured: preload the namespace index ----------

# Opt-out: any of 0/false/no/off disables preload. Default is on.
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
