# lore-plugin

A Lore plugin bundle for both Claude Code and Codex that provides persistent, compounding long-term memory via [Lore](https://lore.dev).

On Claude Code, every session ends with an automatic transcript ingest. On Codex, the plugin offers the same setup and memory skills, plus an optional hook install that preloads the Lore index at session start and ingests each completed user/assistant turn.

**Configuration is per-project.** Every repo that wants Lore memory has its own `.lore.env` (committed, contains app + namespace) and `.lore.env.local` (gitignored, contains your API key). There is no global config. Teammates cloning a configured repo only need to run `/lore-setup` once to add their own API key — the app/namespace wiring is inherited from git.

## What you get

- **`lore-memory` skill** — Claude auto-invokes this when the conversation references your long-term memory, asks a question prior context might answer, or states a durable fact worth keeping. It reads the wiki's `_index`, follows `[[wikilinks]]` between files, and calls `remember` to ingest new content.
- **`lore-setup` skill** — three-phase interactive connect flow: (1) credentials, (2) namespace schema addendum tailored to what you want remembered, (3) optional seeding from the last N GitHub PRs in the current workspace. Also available as the `/lore-setup` slash command. Handles three scenarios automatically: fresh project, teammate onboarding an existing repo, and reconfiguring a project that's already set up.
- **`SessionStart` hook** — once the project is configured, pre-loads your namespace `_index` into Claude's session context on every session start so the wiki's table of contents is available from turn 1 without a lazy round-trip. If the current project isn't configured yet (or your `.lore.env.local` is missing an API key), it instead nudges Claude to proactively offer `/lore-setup` on your first substantive message. Capped at 8 KB of index content by default (tunable); fails silently on a 3-second timeout so it never blocks session start.
- **`SessionEnd` hook** — auto-ingests every session transcript for configured projects, fire-and-forget. No action required from you. Skips silently in unconfigured projects.
- **Codex variant** — a Codex plugin manifest, Codex-specific `lore-memory` and `lore-setup` skills, and a hook installer that merges Lore's `SessionStart`, `UserPromptSubmit`, and `Stop` hooks into `~/.codex/hooks.json`.

## Install

You need:

- [Claude Code](https://code.claude.com) or Codex
- A Lore account with at least one app, one namespace, and an API key — sign up at [lore--pie-lore.us-central1.hosted.app](https://lore--pie-lore.us-central1.hosted.app)
- `python3`, `bash`, `curl`, and `git` on your PATH (standard on macOS and Linux)

### Claude Code

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

Once installed, **`cd` into a project you want Lore memory for** and kick off the setup flow:

```
/lore-setup
```

(Or just ask: *"Use the lore-setup skill to connect this project to my Lore account."* You can also wait — the `SessionStart` hook will remind Claude to offer setup the first time you ask for something substantive in an unconfigured project.)

The flow walks you through three phases:

1. **Credentials** — Claude asks for your **App ID**, **Namespace ID**, and **API key**, writes them into two files at the project root (`.lore.env` committed, `.lore.env.local` gitignored), appends `.lore.env.local` to your `.gitignore` if it isn't there yet, and verifies the credentials against the Lore API.
2. **Namespace schema** — Claude asks what you'd like remembered in this namespace (decisions, projects, people, preferences, whatever fits your workflow), drafts a short markdown schema addendum tailored to your answer, shows it to you for approval, and PUTs it so future ingests stay organized.
3. **Optional: seed from GitHub PRs** — if the current workspace is a GitHub repo and you have `gh` installed and authenticated, Claude offers to pre-populate your wiki by ingesting up to the last 500 PRs (title, author, description, state, labels). You can say no, or pick a smaller number. The Lore worker integrates them asynchronously over the next minute or two.

After that, just use Claude normally in this project. Sessions in this repo will be ingested automatically, and Claude will consult your Lore wiki when it's relevant.

Run `/lore-setup` again in any **other** project you want Lore memory for — each one gets its own `.lore.env` + `.lore.env.local`. Projects you never run setup in simply don't use Lore.

> **Optional for phase 3:** [`gh`](https://cli.github.com) (authenticated via `gh auth login`) and `jq`. If either is missing, Claude will skip PR seeding and tell you so — everything else still works.

### Codex

Codex support lives alongside the Claude plugin in this repo:

- Codex plugin manifest: `plugins/lore/.codex-plugin/plugin.json`
- Codex skills: `plugins/lore/codex-skills/`
- Codex repo marketplace: `.agents/plugins/marketplace.json`

Install the plugin from this repo's Codex marketplace, then install Lore's optional hooks:

```bash
bash plugins/lore/scripts/install-codex-hooks.sh
```

That command merges Lore hook entries into `~/.codex/hooks.json` without removing any unrelated hooks you already have.

Codex hooks are currently documented by OpenAI as **under development** and controlled by `features.codex_hooks`, so make sure your `~/.codex/config.toml` includes:

```toml
[features]
codex_hooks = true
```

Once the plugin is installed and hooks are enabled:

- use the `lore-setup` skill to connect the current project to Lore
- use the `lore-memory` skill whenever you want Codex to read or remember durable context
- Lore will preload the namespace index on `SessionStart`
- Lore will ingest each completed user/assistant turn on `Stop`

Codex does **not** currently expose a `SessionEnd` hook, so the Codex variant ingests turn-by-turn instead of session-by-session.

## Teammate onboarding

Because `.lore.env` is committed, cloning a configured repo gives you the team's app/namespace wiring for free. You only need to add your own API key:

```bash
git clone git@github.com:your-org/your-repo.git
cd your-repo
claude                 # start a Claude Code session
```

On the first substantive message in this project, the `SessionStart` hook will notice that `.lore.env` is present but `.lore.env.local` is missing, and Claude will offer to run `/lore-setup`. The setup flow detects the "teammate onboarding" scenario, reads the existing `LORE_APP` / `LORE_NAMESPACE` from the committed `.lore.env`, and asks you only for your Lore API key. Setup writes `.lore.env.local`, verifies, and you're done — 30 seconds, one value to paste.

No one ever copies the API key across projects by hand: each developer runs `/lore-setup` once per repo, and their `.lore.env.local` lives entirely on their machine.

## File layout

Every configured project has two files at its root:

```
your-project/
├── .git/
├── .gitignore                 # contains '.lore.env.local' (added by setup)
├── .lore.env                  # COMMITTED. app + namespace. shared with team.
├── .lore.env.local            # GITIGNORED. your API key. yours alone.
└── ...
```

**`.lore.env`** (mode 644):
```bash
# Lore plugin — project config. Checked in. Shared with your team.
export LORE_APP='your-app'
export LORE_NAMESPACE='your-namespace'
```

**`.lore.env.local`** (mode 600):
```bash
# Lore plugin — local secrets. DO NOT COMMIT.
export LORE_API_KEY='lore_sk_...'
```

All scripts in the plugin walk up from your current working directory looking for `.lore.env`, stopping at `$HOME`. Subdirectories of a configured project inherit the project's config automatically.

## How it works

```
┌──────────────────────────────────┐
│  Claude Code session             │
│                                  │
│  SessionStart                    │
│   ↳ session-start.sh             │── GET /index (preload, ≤8KB)  ▶
│      (resolved: preload index)   │   injected as additionalContext
│      (missing:   nudge setup)    │
│      (key_miss:  nudge .local)   │
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

Every script sources `plugins/lore/scripts/_resolve_config.sh`, which walks up from the session's effective working directory looking for `.lore.env`, then sources it together with the sibling `.lore.env.local`. The resolver reports one of four statuses:

- **`ok`** — both files present and complete. Scripts proceed normally.
- **`missing`** — no `.lore.env` anywhere up the tree. Plugin is unconfigured for this workspace. SessionStart nudges `/lore-setup`; SessionEnd silently skips; mid-session scripts error with a clear "run /lore-setup" message.
- **`key_missing`** — `.lore.env` found (team config committed) but no `.lore.env.local` or no `LORE_API_KEY`. SessionStart nudges the teammate-onboarding flow; mid-session scripts tell you which file to create and which variable to set.
- **`incomplete`** — `.lore.env` exists but is missing `LORE_APP` or `LORE_NAMESPACE`. Hand-edited or half-written. SessionStart nudges re-running setup.

Specifics:

- **Setup** is driven by the `lore-setup` skill and the `/lore-setup` slash command. `setup.sh` determines the project root (git top-level or the nearest existing `.lore.env`), enforces a strict `.gitignore` gate on `.lore.env.local`, writes both files, and verifies the credentials. The skill handles three entry scenarios — fresh project, teammate onboarding, reconfigure — by inspecting which files exist before asking for values.
- **Reads/writes mid-session** go through `plugins/lore/scripts/lore.sh`, which resolves config via walk-up and hits the Lore REST API with your API key in the `Authorization` header.
- **Auto-ingest** runs in `plugins/lore/scripts/ingest-session.sh` on `SessionEnd`. The hook payload tells us the session's `cwd`, so the resolver walks up from there. The script reads the transcript file the hook payload points at, formats user/assistant turns as markdown (ignoring tool-use noise), and POSTs it to `/v1/apps/{app}/namespaces/{ns}/ingest`.
- **The `SessionStart` hook** (`session-start.sh`) resolves the project config and picks one of three behaviors based on the status. On `ok`, it fetches `GET /index` with a hard 3-second timeout, extracts the markdown from the API envelope, truncates at ~8 KB to the last full line, wraps it in a short preamble, and injects it as `additionalContext`. Any failure (timeout, non-2xx, empty namespace) exits silently — it never blocks session start.
- **Codex turn ingest** uses `codex-user-prompt-submit.sh` + `codex-stop.sh`. The first stores the current user prompt keyed by `session_id` + `turn_id`; the second pairs it with `last_assistant_message` at `Stop` time and POSTs that turn to Lore. This is the Codex fallback for the missing `SessionEnd` hook.
- **Nothing lives in your home directory.** The plugin does not create or use any files under `~/.claude/lore`. Credentials are 100% per-project, in files you can see in `ls` at each repo root.

## Tuning the SessionStart index preload

By default, every session in a configured project starts with up to 8 KB of your namespace's `_index` injected as `additionalContext`. This is the right default for most users — Claude has immediate, zero-round-trip awareness of the wiki — but it does cost a small, fixed chunk of the context window on every session, whether or not memory is relevant.

You can adjust or disable it by editing the project's `.lore.env` (committed) or `.lore.env.local` (per-developer override) and adding either of these lines:

```bash
# Opt out entirely — Claude will still access the wiki lazily via the
# lore-memory skill, just without the preamble.
export LORE_PRELOAD_INDEX=0

# Keep preload on but change the byte cap on injected content.
# Default is 8192 (8 KB). Try 4096 for a tighter budget, or 16384 for a
# larger cap if your index is big and you want more of it in-context.
export LORE_PRELOAD_INDEX_MAX_BYTES=16384
```

Put these in `.lore.env` (committed) if you want them shared with your team, or in `.lore.env.local` (per-developer) if you want a personal override.

Truncation happens on the *index content*, not the wrapping preamble or preamble+content together, and always backs off to the last complete newline so you never see a mid-line cut. When truncation triggers, the injected context ends with a one-line footer telling Claude it can fetch the full index via `lore.sh get` if it needs more.

## Reconfiguring

To change your API key, App ID, or Namespace ID in a project, re-run `/lore-setup` in that project. The skill detects which values exist already, asks only for the ones you want to change, and rewrites `.lore.env` / `.lore.env.local` accordingly.

To only update the schema addendum (without touching credentials), ask Claude to: *"Update my Lore schema addendum for this namespace."* The `lore-setup` skill will read the current one, let you edit it, and PUT the new version.

To fully remove Lore from a project:

```bash
cd your-project
rm -f .lore.env .lore.env.local
# Optional: remove '.lore.env.local' from .gitignore
```

## Uninstall

```
/plugin uninstall lore@lore-plugin
```

This removes the plugin's skills and hooks. It does **not** remove your per-project `.lore.env` / `.lore.env.local` files or anything on the Lore server — those stay behind on disk for you to delete (or keep, if you plan to reinstall later).

To remove the Codex hook entries later, delete the Lore entries from `~/.codex/hooks.json` manually. The installer is additive and never removes unrelated hooks.

## Privacy

- Your API key lives only in each project's `.lore.env.local`, which setup refuses to write unless the file is already gitignored at the project root. It is never committed, never logged, and never written outside the project tree.
- Session transcripts are posted to the Lore API you configure (defaults to `https://lore-api-245179047688.us-central1.run.app`, the current Cloud Run deployment; dashboard lives separately at `https://lore--pie-lore.us-central1.hosted.app`). Override the API base via `LORE_API_BASE` in `.lore.env` (committed, shared) or `.lore.env.local` (per-developer).
- Tool-use / tool-result blocks are stripped from transcripts before ingest — only user and assistant text goes over the wire.
- **GitHub PR seeding runs locally via `gh`** and posts results only to your own Lore namespace. No third party is involved.
- The `lore-memory` skill is instructed not to ingest content that looks like secrets (API keys, passwords, tokens) and to respect any "don't remember this" requests from you.
- **Projects you never run `/lore-setup` in are entirely unaffected** — no hooks fire with real credentials, no data leaves your machine, and all scripts error or skip cleanly.

## License

MIT
