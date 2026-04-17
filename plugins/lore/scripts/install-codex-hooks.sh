#!/usr/bin/env bash
# Lore plugin — install or update Codex hooks in ~/.codex/hooks.json.
#
# Hooks remain a Codex config concern rather than a plugin-packaging concern,
# so this helper merges Lore's hook entries into the user's existing hook
# file without removing unrelated hooks.

set -euo pipefail

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
dest="${1:-$HOME/.codex/hooks.json}"

mkdir -p "$(dirname "$dest")"

PLUGIN_ROOT="$plugin_root" DEST="$dest" python3 - <<'PY'
import json
import os
from pathlib import Path

plugin_root = Path(os.environ["PLUGIN_ROOT"])
dest = Path(os.environ["DEST"])

try:
    existing = json.loads(dest.read_text(encoding="utf-8"))
except FileNotFoundError:
    existing = {}
except json.JSONDecodeError as exc:
    raise SystemExit(f"{dest} is not valid JSON: {exc}")

if not isinstance(existing, dict):
    raise SystemExit(f"{dest} must contain a top-level JSON object")

hooks = existing.setdefault("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit(f"{dest} must contain a top-level 'hooks' object")

entries = {
    "SessionStart": {
        "matcher": "startup|resume",
        "hooks": [
            {
                "type": "command",
                "command": f"{plugin_root / 'scripts' / 'codex-session-start.sh'}",
                "statusMessage": "Lore: loading wiki index",
            }
        ],
    },
    "UserPromptSubmit": {
        "matcher": "",
        "hooks": [
            {
                "type": "command",
                "command": f"{plugin_root / 'scripts' / 'codex-user-prompt-submit.sh'}",
            }
        ],
    },
    "Stop": {
        "matcher": "",
        "hooks": [
            {
                "type": "command",
                "command": f"{plugin_root / 'scripts' / 'codex-stop.sh'}",
            }
        ],
    },
}

def signature(item: dict) -> tuple:
    return (
        item.get("matcher", ""),
        tuple(
            (
                hook.get("type", ""),
                hook.get("command", ""),
                hook.get("statusMessage", ""),
            )
            for hook in item.get("hooks", [])
            if isinstance(hook, dict)
        ),
    )

updated = False
for event, entry in entries.items():
    event_list = hooks.setdefault(event, [])
    if not isinstance(event_list, list):
        raise SystemExit(f"hooks.{event} must be a JSON array")
    sig = signature(entry)
    if any(isinstance(item, dict) and signature(item) == sig for item in event_list):
        continue
    event_list.append(entry)
    updated = True

dest.write_text(json.dumps(existing, indent=2) + "\n", encoding="utf-8")
if updated:
    print(f"Updated {dest} with Lore Codex hooks.")
else:
    print(f"Lore Codex hooks already present in {dest}.")
PY

cat <<EOF
Lore hook entries are installed at $dest.
If you have not enabled Codex hooks yet, add the following to ~/.codex/config.toml:

[features]
codex_hooks = true
EOF
