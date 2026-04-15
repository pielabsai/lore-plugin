#!/usr/bin/env bash
# Lore plugin — SessionStart hook.
#
# Checks whether the plugin has been configured yet. If not, injects a small
# piece of additional context into the session so Claude proactively offers
# to run the lore-setup skill on the user's first turn. Once configured,
# stays silent.
#
# Emits JSON on stdout following the Claude Code hookSpecificOutput contract
# for SessionStart.

set -uo pipefail

CONFIG_FILE="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/lore}/config.env"

if [[ -f "$CONFIG_FILE" ]]; then
  # Already configured — nothing to say.
  exit 0
fi

# Read the hook payload from stdin so we don't leave it buffered, but we
# don't actually need any of its fields for this check.
cat >/dev/null 2>&1 || true

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
