---
name: lore-setup
description: Configure the Lore plugin with the user's App ID, Namespace ID, and API key. Invoke this when the user has just installed the Lore plugin and needs to connect it to their Lore account, or when they explicitly ask to (re)configure Lore.
---

# Lore Setup

The user has installed the Lore plugin but it is not yet connected to their Lore account. Walk them through providing three values, then run the setup script.

## Step 1 — Ask the user for the three values

Ask for these one at a time, or as a grouped request. Explain what each is:

1. **Lore API key** — starts with `lore_sk_`. They get this from the Lore dashboard under their app's "Keys" tab. It is a secret; do not log it, do not echo it back to them in full, and do not paste it into git-tracked files.
2. **App ID** — the slug of the Lore app this key belongs to (for example `personal`, `work`, `research`). Shown on the dashboard next to the app name.
3. **Namespace ID** — the slug of the namespace inside that app where memory will be stored (for example `default`, `books`, `projects`). If the user only has one namespace, use that.

If the user doesn't know any of these, point them at `https://lore.dev/dashboard` (or whatever host they use) and ask them to copy the values from there.

## Step 2 — Run the setup script

Once you have all three values, run the setup script via the Bash tool, passing the values as environment variables so they don't appear in shell history:

```bash
LORE_API_KEY='<key>' LORE_APP='<app>' LORE_NAMESPACE='<namespace>' bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh"
```

The script will:
- Write the config to `${CLAUDE_PLUGIN_DATA}/config.env` with `chmod 600`.
- Make a test call to the Lore API to verify the credentials.
- Print `OK` on success, or an error message on failure.

## Step 3 — Report back

- **On success:** tell the user setup is complete and explain what just got wired up:
  - Claude can now read from and write to their Lore wiki mid-conversation (via the `lore-memory` skill).
  - Every time a Claude Code session ends, the transcript is automatically posted to Lore for ingestion.
  - To change any of the values later, they can re-run this setup flow.
- **On failure:** show them the exact error from the script and ask them to double-check which value is wrong. Common issues: typo in the API key, wrong app slug, namespace doesn't exist yet.

## Important

- Never print the raw API key back to the user in your response. Refer to it as "your API key" and show at most a prefix like `lore_sk_****`.
- Never commit the config file or paste its contents anywhere.
- If the user provides the values in a way that looks like they pasted from a password manager (with quotes, trailing newlines, etc.), strip them before passing to the script.
