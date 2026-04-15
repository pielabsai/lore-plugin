# lore-plugin

A Claude Code plugin that gives Claude persistent, compounding long-term memory via [Lore](https://lore.dev).

Every time a Claude session ends, the transcript is automatically posted to your Lore namespace, where an LLM worker integrates it into a self-maintaining wiki. Mid-session, Claude can read from and write to that wiki to answer questions with context it has seen before.

## What you get

- **`lore-memory` skill** — Claude auto-invokes this when the conversation references your long-term memory, asks a question prior context might answer, or states a durable fact worth keeping. It reads the wiki's `_index`, follows `[[wikilinks]]` between files, and calls `remember` to ingest new content.
- **`lore-setup` skill** — three-phase interactive connect flow: (1) credentials, (2) namespace schema addendum tailored to what you want remembered, (3) optional seeding from the last N GitHub PRs in the current workspace. Also available as the `/lore-setup` slash command.
- **`SessionStart` hook** — if the plugin is installed but not yet connected, nudges Claude to proactively offer `/lore-setup` on your first substantive message. Silent once configured.
- **`SessionEnd` hook** — auto-ingests every session transcript, fire-and-forget. No action required from you.

## Install

You need:

- [Claude Code](https://code.claude.com) (CLI or Desktop, version with plugin support)
- A Lore account with at least one app, one namespace, and an API key — sign up at [lore--pie-lore.us-central1.hosted.app](https://lore--pie-lore.us-central1.hosted.app)
- `python3`, `bash`, and `curl` on your PATH (standard on macOS and Linux)

Add the marketplace and install the plugin:

```shell
/plugin marketplace add pielabsai/lore-plugin
/plugin install lore@lore-plugin
```

Or from a terminal:

```bash
claude plugin marketplace add pielabsai/lore-plugin
claude plugin install lore@lore-plugin
```

Once installed, kick off the setup flow with the slash command:

```
/lore-setup
```

(Or just ask: *"Use the lore-setup skill to connect this plugin to my Lore account."* You can also wait — the `SessionStart` hook will remind Claude to offer setup the first time you ask for something substantive.)

The flow walks you through three phases:

1. **Credentials** — Claude asks for your **App ID**, **Namespace ID**, and **API key**, writes them to `${CLAUDE_PLUGIN_DATA}/config.env` (mode `600`), and verifies them against the Lore API.
2. **Namespace schema** — Claude asks what you'd like remembered in this namespace (decisions, projects, people, preferences, whatever fits your workflow), drafts a short markdown schema addendum tailored to your answer, shows it to you for approval, and PUTs it so future ingests stay organized.
3. **Optional: seed from GitHub PRs** — if the current workspace is a GitHub repo and you have `gh` installed and authenticated, Claude offers to pre-populate your wiki by ingesting up to the last 500 PRs (title, author, description, state, labels). You can say no, or pick a smaller number. The Lore worker integrates them asynchronously over the next minute or two.

After that, just use Claude normally. Your sessions will be ingested automatically, and Claude will consult your Lore wiki when it's relevant.

> **Optional for phase 3:** [`gh`](https://cli.github.com) (authenticated via `gh auth login`) and `jq`. If either is missing, Claude will skip PR seeding and tell you so — everything else still works.

## How it works

```
┌──────────────────────────────────┐
│  Claude Code session             │
│                                  │
│  SessionStart                    │
│   ↳ session-start.sh             │── nudges Claude to run /lore-setup
│      (if not yet configured)     │   on the first substantive turn
│                                  │
│  ┌────────────────────────────┐  │
│  │ /lore-setup  (skill)       │  │                         Lore REST API
│  │  ↳ setup.sh                │  │── GET  /index (verify) ────▶
│  │  ↳ set-schema.sh put       │  │── PUT /schema-addendum ────▶
│  │  ↳ ingest-github-prs.sh    │  │── POST /ingest × N ────────▶
│  └────────────────────────────┘  │
│                                  │
│  ┌────────────────────────────┐  │
│  │ lore-memory skill          │  │
│  │  ↳ lore.sh get [key]       │  │── GET /index, GET /files/{k} ▶
│  │  ↳ lore.sh remember        │  │── POST /ingest ─────────────▶
│  └────────────────────────────┘  │
│                                  │
│  SessionEnd                      │
│   ↳ ingest-session.sh            │── POST /ingest ─────────────▶
└──────────────────────────────────┘
```

- **Setup** is driven by the `lore-setup` skill and the `/lore-setup` slash command. `setup.sh` writes credentials to `${CLAUDE_PLUGIN_DATA}/config.env` and verifies them; `set-schema.sh` GETs/PUTs the per-namespace schema addendum (raw markdown body); `ingest-github-prs.sh` uses `gh` + `jq` to fetch PRs and POST them one-by-one to `/ingest` with `kind=github-pr` metadata.
- **Reads/writes mid-session** go through `plugins/lore/scripts/lore.sh`, which reads credentials from `${CLAUDE_PLUGIN_DATA}/config.env` and hits the Lore REST API with your API key in the `Authorization` header.
- **Auto-ingest** runs in `plugins/lore/scripts/ingest-session.sh` on `SessionEnd`. It reads the transcript file the hook payload points at, formats user/assistant turns as markdown (ignoring tool-use noise), and POSTs it to `/v1/apps/{app}/namespaces/{ns}/ingest`.
- **The `SessionStart` hook** (`session-start.sh`) checks for `config.env`; if it's missing, it returns a `hookSpecificOutput` message that tells Claude to proactively offer `/lore-setup` on the next real turn. Once configured, it exits silently and adds zero context.
- **Nothing is stored locally beyond your credentials** (in `${CLAUDE_PLUGIN_DATA}/config.env`, mode `600`). The wiki lives on Lore's servers.

## Reconfiguring

To change your API key, App ID, or Namespace ID, re-run `/lore-setup` (or the `lore-setup` skill). It overwrites the config file with the new values and gives you the chance to re-do the schema addendum and optionally re-seed from GitHub PRs.

To only update the schema addendum (without touching credentials), ask Claude to: *"Update my Lore schema addendum for this namespace."* The `lore-setup` skill will read the current one, let you edit it, and PUT the new version.

To fully remove credentials:

```bash
rm -f "${CLAUDE_PLUGIN_DATA:-$HOME/.claude/lore}/config.env"
```

## Uninstall

```
/plugin uninstall lore@lore-plugin
```

This removes the plugin's skills and hooks. It does **not** remove your credential file (see above) or anything on the Lore server.

## Privacy

- Your API key lives only in `${CLAUDE_PLUGIN_DATA}/config.env`, never committed or logged.
- Session transcripts are posted to the Lore API you configure (defaults to `https://lore-api-245179047688.us-central1.run.app`, the current Cloud Run deployment; dashboard lives separately at `https://lore--pie-lore.us-central1.hosted.app`). Override the API base via `LORE_API_BASE` in the config file.
- Tool-use / tool-result blocks are stripped from transcripts before ingest — only user and assistant text goes over the wire.
- **GitHub PR seeding runs locally via `gh`** and posts results only to your own Lore namespace. No third party is involved.
- The `lore-memory` skill is instructed not to ingest content that looks like secrets (API keys, passwords, tokens) and to respect any "don't remember this" requests from you.

## License

MIT
