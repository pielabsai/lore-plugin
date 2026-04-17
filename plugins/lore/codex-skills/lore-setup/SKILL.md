---
name: lore-setup
description: Walk the user through connecting the Lore plugin to the current project — credentials, namespace schema addendum, and optional seeding from recent GitHub PRs. Invoke this when the user has just installed the Lore plugin, when they explicitly ask to (re)configure Lore for this project, when a SessionStart hook flags that the project is unconfigured, or when a teammate has cloned a repo that already has `.lore.env` committed and needs to add their own API key.
---

# Lore Setup

Lore configuration is **per-project**. Every repo that wants Lore memory has its own:

- **`.lore.env`** — committed to git, shared with the team, contains `LORE_APP` and `LORE_NAMESPACE`.
- **`.lore.env.local`** — gitignored, per-developer, contains `LORE_API_KEY`.

There is no global config. Each teammate runs the `lore-setup` skill in the repo to add their own API key; the app/namespace wiring is inherited from what's already committed.

Before running any setup commands, locate the installed Lore plugin root in Codex:

```bash
LORE_PLUGIN_ROOT="$(
  python3 - <<'PY'
import glob, os, sys

candidates = glob.glob(
    os.path.expanduser("~/.codex/plugins/cache/*/lore/*/.codex-plugin/plugin.json")
)
if not candidates:
    sys.stderr.write("Lore plugin not found in ~/.codex/plugins/cache\n")
    raise SystemExit(1)
candidates.sort(key=os.path.getmtime, reverse=True)
print(os.path.dirname(os.path.dirname(candidates[0])))
PY
)"
```

If that locator fails, tell the user to install or re-enable the Lore plugin in Codex and stop.

Walk the user through three phases:

1. **Credentials** — determine the project root, figure out which of three scenarios this is, and write the appropriate file(s).
2. **Schema** — ask what kinds of things they'd like remembered, turn that into a namespace schema addendum, and PUT it.
3. **Seed (optional)** — if this workspace is a GitHub repo, offer to ingest the last N PRs so the wiki starts with real context.

At each step, confirm with the user before writing anything. If they want to skip a step, skip it and move on — do not re-prompt.

---

## Phase 1 — Credentials

### 1a. Determine the project root and detect the scenario

Run this to find the project root (git top-level):

```bash
git rev-parse --show-toplevel 2>/dev/null || pwd
```

Call this `$PROJECT_ROOT` in your head. Now detect which scenario you're in by checking which files exist:

| `$PROJECT_ROOT/.lore.env` | `$PROJECT_ROOT/.lore.env.local` | Scenario                                |
|:-------------------------:|:-------------------------------:|:----------------------------------------|
| **missing**               | missing                         | **A — Fresh project**                   |
| **present**               | **missing**                     | **B — Teammate onboarding**             |
| **present**               | **present**                     | **C — Reconfigure existing project**    |

Tell the user in one sentence which scenario they're in so they know what to expect. Then proceed to 1b.

### 1b. Collect the values you need

**Scenario A (Fresh project)** — ask for all three:

1. **Lore API key** — starts with `lore_sk_`. From the Lore dashboard under the app's "Keys" tab. Secret: never log it, never echo it back in full, never paste it into git-tracked files.
2. **App ID** — the slug of the Lore app this key belongs to (e.g. `personal`, `work`, `research`). Shown on the dashboard next to the app name.
3. **Namespace ID** — the slug of the namespace inside that app where memory will be stored (e.g. `default`, `books`, `projects`). If the user only has one namespace, use that.

**Scenario B (Teammate onboarding)** — read the existing values and ask only for the API key:

```bash
bash -c 'source "$PROJECT_ROOT/.lore.env" && echo "app=$LORE_APP namespace=$LORE_NAMESPACE"'
```

Show the user what's already committed (`This project is wired to <app>/<namespace>`) and ask for just their **API key**. They do not pick the app or namespace — those are the team's.

**Scenario C (Reconfigure)** — read existing values, show them, and ask what the user wants to change:

```bash
bash -c 'source "$PROJECT_ROOT/.lore.env" && echo "app=$LORE_APP namespace=$LORE_NAMESPACE"'
```

Ask: *"Currently wired to `<app>/<namespace>`. What do you want to change — the API key, the app/namespace, or both?"* Collect only the values they're changing; keep the rest.

### 1c. Run the setup script

Once you have the values, invoke `setup.sh` via Bash, passing them as environment variables so they never appear in shell history:

**Scenario A:**
```bash
LORE_API_KEY='<key>' LORE_APP='<app>' LORE_NAMESPACE='<namespace>' \
  bash "$LORE_PLUGIN_ROOT/scripts/setup.sh"
```

**Scenario B (only API key — `setup.sh` reads app/namespace from the existing `.lore.env`):**
```bash
LORE_API_KEY='<key>' bash "$LORE_PLUGIN_ROOT/scripts/setup.sh"
```

**Scenario C:** pass whichever subset of `LORE_API_KEY`, `LORE_APP`, `LORE_NAMESPACE` the user is changing. Unspecified values are inherited from the existing `.lore.env`.

What `setup.sh` does:

1. Determines the project root (git top-level, or the directory of an existing `.lore.env` found by walk-up). Refuses to write at `$HOME`.
2. **Strict gitignore gate**: checks whether `.lore.env.local` is already git-ignored at the project root. If not, it appends `.lore.env.local` to `$PROJECT_ROOT/.gitignore` (creating the file if needed) **before** writing the secret file. Tell the user if this happened — they may want to commit the `.gitignore` change.
3. Writes `.lore.env` (mode 644) with `LORE_APP` + `LORE_NAMESPACE` (+ optional `LORE_API_BASE` if non-default). Only re-writes when values actually changed.
4. Writes `.lore.env.local` (mode 600) with just `LORE_API_KEY`.
5. Verifies by calling `GET /v1/apps/<app>/namespaces/<namespace>/index`. Prints `OK — connected...` or an error.

**On failure:** show the exact error. Common issues:

- `API key rejected (HTTP 401/403)` — the key is wrong or scoped to a different app. Re-ask for the key and re-run.
- `app or namespace not found (HTTP 404)` — the app slug or namespace slug is wrong, or the namespace hasn't been created yet. Ask the user to double-check on the Lore dashboard.
- `could not reach...` — network problem. Not the user's config; tell them and stop.

Do **not** proceed to phase 2 until verification succeeds.

**On success:** briefly confirm (`Connected to Lore as <app>/<namespace>. Config written to <project-root>/.lore.env + .lore.env.local.`) and continue to phase 2. If `setup.sh` created or modified `.gitignore`, mention that the user should `git add .gitignore` and probably also `git add .lore.env` (but **not** `.lore.env.local`).

---

## Phase 2 — Namespace schema addendum

The schema addendum is a short markdown document that tells the Lore worker how to organize this namespace's wiki. It's per-namespace, not per-project — so if multiple projects share a namespace, the addendum is shared too.

**Scenario B note**: when onboarding a teammate to an existing project, the schema addendum is probably already set by whoever ran setup first. Still run 2a to check, and only replace it if the user explicitly asks to.

### 2a. Read the current addendum

```bash
bash "$LORE_PLUGIN_ROOT/scripts/set-schema.sh" get
```

- If it prints nothing (or just whitespace), there is no addendum yet. Proceed to 2b.
- If it prints existing markdown, show the user and ask: *"This namespace already has a schema addendum. Keep it, replace it, or append to it?"* Proceed based on their answer. If they say keep, skip to phase 3.

### 2b. Ask the user what they want remembered

Ask an open-ended question, tuned to their likely use case:

- *"What kinds of things would you like me to remember in this namespace? For example: decisions and their rationale, people and their roles, ongoing projects and their status, preferences about your tools and stack…"*
- *"When you come back to this project in a week or a month, what should already be in my memory so I can pick up where we left off?"*

Let them answer in whatever form is natural — a list, a paragraph, a few keywords. Do **not** force a template.

### 2c. Draft the schema addendum

Turn their answer into a concise markdown document. Keep it under ~30 lines. It should:

- Open with a one-sentence summary of what this namespace is for.
- List the **entity kinds** the wiki should track (people, projects, decisions, systems, preferences, etc.), each as a short bullet describing what belongs under that kind.
- If the user mentioned naming conventions or structure, include them; otherwise omit.
- End with a short note on what **not** to keep (secrets, one-off answers, content the user explicitly asks to forget).

### 2d. Confirm and write

Show the drafted addendum to the user in a fenced code block and ask: *"Here's what I'll save as the schema addendum for `<app>/<namespace>`. Want me to write this, tweak it, or skip?"*

On approval, pipe it into the setter:

```bash
cat <<'LORE_ADDENDUM' | bash "$LORE_PLUGIN_ROOT/scripts/set-schema.sh" put
<the approved markdown>
LORE_ADDENDUM
```

Use a unique heredoc marker (`LORE_ADDENDUM`, not `EOF`) to avoid collisions with any `EOF` tokens in the addendum body. The script will print `OK — schema addendum updated…` on success. Report that briefly, then move on.

If the user wants to tweak it, incorporate their changes and re-show it before writing.

---

## Phase 3 — Optional: seed from GitHub PRs

If this workspace is a GitHub repo, offer to pre-populate the wiki with the repo's recent PR history. This gives Codex immediate context on what has been built, by whom, and why — without waiting for the user to organically re-ingest it.

**Scenario B note**: on teammate onboarding, the PRs have probably already been seeded by an earlier run. Ask the user whether to re-seed — default to no.

### 3a. Detect whether to offer seeding

Check, in order:

1. Is this a git working tree? Run `git rev-parse --is-inside-work-tree` — if it errors, skip phase 3 entirely.
2. Does it have a GitHub `origin` remote? Run `git remote get-url origin` and check the URL matches `github.com`. If not, skip.
3. Is `gh` installed and authenticated? Run `gh auth status`. If not, mention to the user that you could seed from GitHub PRs if they install/auth `gh`, then skip.

If all three pass, proceed to 3b.

### 3b. Ask permission

Tell the user what you'd do, concretely:

> *"This workspace is a GitHub repo (`owner/repo`). I can seed your Lore namespace with up to the last 500 PRs — each one gets ingested as a single markdown record with its title, author, description, state, and labels. The Lore worker will integrate them into your wiki over the next minute or two. This runs locally via `gh`, nothing else gets sent anywhere besides your own Lore namespace. Want me to go ahead? If you prefer a smaller number, say how many."*

Wait for explicit consent. If the user says no or doesn't answer clearly, skip this phase.

### 3c. Run the seeder

With consent, invoke the seeding script. Pass the limit the user chose (or the default 500):

```bash
bash "$LORE_PLUGIN_ROOT/scripts/ingest-github-prs.sh" <limit>
```

The script streams per-PR progress to stderr (`[  1/250] ok #123 Title…`) so you can show the user roughly where it is. It fails gracefully on individual PRs and prints a final summary line like `Done. Ingested 247 PRs. Failures: 3.`

Report the final counts in one sentence. Do **not** re-print the full progress log.

---

## Phase 4 — Wrap up

Tell the user setup is complete and summarize what just got wired up:

- **Project config** lives at `<project-root>/.lore.env` (committed) and `<project-root>/.lore.env.local` (gitignored, your API key only).
- **Mid-session memory** is available via the `lore-memory` skill — Codex can now read from and write to this project's Lore namespace.
- **SessionStart preload** — the next time you start a Codex session in this project, the wiki's `_index` will be pre-loaded into context automatically if the Lore hooks are installed.
- **Auto-ingest on turn stop** — when the optional Codex hooks are installed, each completed user/assistant turn gets posted to Lore and integrated into the wiki.
- **Schema addendum** (if they set one) — Lore will use it to shape future ingests.
- **PR seed** (if they ran it) — the wiki will finish integrating over the next minute or two.

If `setup.sh` touched `.gitignore`, remind the user to commit it: `git add .gitignore .lore.env && git commit -m "Add Lore plugin project config"`.

Also mention: to change any of this later, they can re-run the `lore-setup` skill in the same project.

---

## Important guardrails

- **Never print the raw API key back to the user.** Refer to it as "your API key" and show at most a prefix like `lore_sk_****`.
- **Never commit `.lore.env.local`.** The setup script enforces a strict `.gitignore` gate, but double-check: `git check-ignore .lore.env.local` at the project root should succeed.
- **Never write at `$HOME`.** `setup.sh` refuses this explicitly. If the user runs the skill from their home directory (no project context), tell them to `cd` into a specific project first.
- If the user provides values with extra whitespace, trailing newlines, or paste-from-password-manager quotes, strip them before passing to the scripts.
- **Do not skip phases silently.** If you skip a phase (e.g., not a GitHub repo), say so in one sentence so the user knows what you did and didn't do.
- If any script fails, report the exact error. Do not retry in a loop.
