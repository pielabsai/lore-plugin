# lore-plugin

A Claude Code plugin that gives Claude persistent, compounding long-term memory via [Lore](https://lore.dev).

Every time a Claude session ends, the transcript is automatically posted to your Lore namespace, where an LLM worker integrates it into a self-maintaining wiki. Mid-session, Claude can read from and write to that wiki to answer questions with context it has seen before.

## What you get

- **`lore-memory` skill** — Claude auto-invokes this when the conversation references your long-term memory, asks a question prior context might answer, or states a durable fact worth keeping. It reads the wiki's `_index`, follows `[[wikilinks]]` between files, and calls `remember` to ingest new content.
- **`lore-setup` skill** — one-time interactive flow that asks for your Lore API key, App ID, and Namespace ID, then verifies the credentials.
- **`SessionEnd` hook** — auto-ingests every session transcript, fire-and-forget. No action required from you.

## Install

You need:

- [Claude Code](https://code.claude.com) (CLI or Desktop, version with plugin support)
- A [Lore](https://lore.dev) account with at least one app, one namespace, and an API key
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

Once installed, run the setup skill in any Claude Code session:

```
Use the lore-setup skill to connect this plugin to my Lore account.
```

Claude will ask you for three values — App ID, Namespace ID, and API key — and wire everything up. After that, just use Claude normally. Your sessions will be ingested automatically, and Claude will consult your Lore wiki when it's relevant.

## How it works

```
┌────────────────────────────────┐
│  Claude Code session           │
│                                │
│  ┌──────────────────────────┐  │
│  │ lore-memory skill        │  │──── read/write via curl ───▶  Lore REST API
│  │  ↳ lore.sh get [key]     │  │                                    │
│  │  ↳ lore.sh remember      │  │                                    │
│  └──────────────────────────┘  │                                    │
│                                │                                    │
│  SessionEnd                    │                                    │
│   ↳ ingest-session.sh          │──── POST /ingest ──────────────────┘
└────────────────────────────────┘
```

- **Reads/writes** go through `plugins/lore/scripts/lore.sh`, which reads credentials from `${CLAUDE_PLUGIN_DATA}/config.env` and hits the Lore REST API with your API key in the `Authorization` header.
- **Auto-ingest** runs in `plugins/lore/scripts/ingest-session.sh` on `SessionEnd`. It reads the transcript file the hook payload points at, formats user/assistant turns as markdown (ignoring tool-use noise), and POSTs it to `/v1/apps/{app}/namespaces/{ns}/ingest`.
- **Nothing is stored locally beyond your credentials** (in `${CLAUDE_PLUGIN_DATA}/config.env`, mode `600`). The wiki lives on Lore's servers.

## Reconfiguring

To change your API key, App ID, or Namespace ID, re-run the `lore-setup` skill. It overwrites the config file with the new values.

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
- Session transcripts are posted to the Lore API you configure (defaults to `https://api.lore.dev`, overridable via `LORE_API_BASE` in the config file).
- Tool-use / tool-result blocks are stripped from transcripts before ingest — only user and assistant text goes over the wire.
- The `lore-memory` skill is instructed not to ingest content that looks like secrets (API keys, passwords, tokens) and to respect any "don't remember this" requests from you.

## License

MIT
