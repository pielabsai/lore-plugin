---
name: lore-setup
description: Walk the user through connecting the Lore plugin end-to-end — credentials, namespace schema addendum, and optional seeding from recent GitHub PRs. Invoke this when the user has just installed the Lore plugin, when they explicitly ask to (re)configure Lore, or when the SessionStart hook flags that Lore is not yet connected.
---

# Lore Setup

The user has installed the Lore plugin but it is not yet connected to their Lore account. Walk them through three phases, in order, without skipping:

1. **Credentials** — App ID, Namespace ID, API key.
2. **Schema** — ask what kinds of things they'd like remembered, turn that into a namespace schema addendum, and PUT it.
3. **Seed (optional)** — if this workspace is a GitHub repo, offer to ingest the last N PRs so the wiki starts with real context.

At each step, confirm with the user before writing anything to their Lore account. If they want to skip a step, skip it and move on — do not re-prompt.

---

## Phase 1 — Credentials

### 1a. Ask the user for the three values

Ask for these one at a time, or as a grouped request. Explain what each is:

1. **Lore API key** — starts with `lore_sk_`. They get this from the Lore dashboard under their app's "Keys" tab. It is a secret; do not log it, do not echo it back in full, and do not paste it into git-tracked files.
2. **App ID** — the slug of the Lore app this key belongs to (for example `personal`, `work`, `research`). Shown on the dashboard next to the app name.
3. **Namespace ID** — the slug of the namespace inside that app where memory will be stored (for example `default`, `books`, `projects`). If the user only has one namespace, use that.

If the user doesn't know any of these, point them at the Lore dashboard and ask them to copy the values from there.

### 1b. Run the setup script

Once you have all three values, run the setup script via the Bash tool, passing the values as environment variables so they don't appear in shell history:

```bash
LORE_API_KEY='<key>' LORE_APP='<app>' LORE_NAMESPACE='<namespace>' bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh"
```

The script will:
- Write the config to `${CLAUDE_PLUGIN_DATA}/config.env` with `chmod 600`.
- Make a test call to the Lore API to verify the credentials.
- Print `OK` on success, or an error message on failure.

**On failure:** show the user the exact error from the script and ask them to double-check which value is wrong. Common issues: typo in the API key, wrong app slug, namespace doesn't exist yet. Do **not** proceed to phase 2 until credentials verify.

**On success:** briefly confirm ("Connected to Lore as `<app>/<namespace>`") and continue to phase 2.

---

## Phase 2 — Namespace schema addendum

The schema addendum is a short piece of markdown that tells the Lore LLM worker how to organize this namespace's wiki — what kinds of things belong in it, how files should be named, what fields each file should have. A good addendum makes every future ingest integrate more cleanly.

### 2a. Read the current addendum

Before writing anything, see what's already there:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/set-schema.sh" get
```

- If it prints nothing (or just whitespace), there is no addendum yet. Proceed to 2b.
- If it prints existing markdown, show the user what's there and ask: *"You already have a schema addendum. Do you want to keep it as-is, replace it, or append to it?"* Proceed based on their answer. If they say keep it, skip to phase 3.

### 2b. Ask the user what they want remembered

Ask an open-ended question, tuned to their likely use case. Examples — pick one, or tailor to what you know about them:

- *"What kinds of things would you like me to remember in this namespace? For example: decisions and their rationale, people and their roles, ongoing projects and their status, preferences about your tools and stack…"*
- *"When you come back to this workspace in a week or a month, what should already be in my memory so I can pick up where we left off?"*

Let them answer in whatever form is natural — a list, a paragraph, a few keywords. Do **not** force a template.

### 2c. Draft the schema addendum

Turn their answer into a concise markdown document. Keep it under ~30 lines. It should:

- Open with a one-sentence summary of what this namespace is for.
- List the **entity kinds** the wiki should track (people, projects, decisions, systems, preferences, etc.), each as a short bullet describing what belongs under that kind.
- If the user mentioned naming conventions or structure, include them; otherwise omit.
- End with a short note on what **not** to keep (secrets, one-off answers, content the user explicitly asks to forget).

Example skeleton (adapt to the user's actual answer — do not paste this verbatim):

```markdown
# Namespace: <app>/<namespace>

This namespace holds long-term context about <short summary of user's intent>.

## Entity kinds

- **Projects** — one file per active or recently-finished project, with status, goals, key decisions, and related people.
- **People** — one file per collaborator or contact, with their role, preferences, and ongoing threads.
- **Decisions** — durable decisions and their rationale, cross-linked to the projects they affect.
- **Preferences** — the user's preferences about tools, workflows, and style.

## Conventions

- Use `[[wikilinks]]` to cross-reference files by key.
- Prefer one concept per file; split long files when they cover multiple topics.

## Do not keep

- API keys, passwords, access tokens, or other secrets.
- Transient troubleshooting output.
- Anything the user asks to forget or mark private.
```

### 2d. Confirm and write

Show the drafted addendum to the user in a fenced code block and ask: *"Here's what I'll save as the schema addendum for `<app>/<namespace>`. Want me to write this, tweak it, or skip?"*

On approval, pipe it into the setter:

```bash
cat <<'LORE_ADDENDUM' | bash "${CLAUDE_PLUGIN_ROOT}/scripts/set-schema.sh" put
<the approved markdown>
LORE_ADDENDUM
```

Use a unique heredoc marker (`LORE_ADDENDUM`, not `EOF`) to avoid collisions with any `EOF` tokens in the addendum body. The script will print `OK — schema addendum updated…` on success. Report that briefly, then move on.

If the user wants to tweak it, incorporate their changes and re-show it before writing.

---

## Phase 3 — Optional: seed from GitHub PRs

If this workspace is a GitHub repo, offer to pre-populate the wiki with the repo's recent PR history. This gives Claude immediate context on what has been built, by whom, and why — without waiting for the user to organically re-ingest it.

### 3a. Detect whether to offer seeding

Check, in order:

1. Is this a git working tree? Run `git rev-parse --is-inside-work-tree` — if it errors, skip phase 3 entirely.
2. Does it have a GitHub `origin` remote? Run `git remote get-url origin` and check that the URL matches `github.com`. If not, skip phase 3.
3. Is `gh` installed and authenticated? Run `gh auth status`. If not, mention to the user that you could seed from GitHub PRs if they install/auth `gh`, then skip phase 3.

If all three pass, proceed to 3b.

### 3b. Ask permission

Tell the user what you'd do, concretely. For example:

> *"This workspace is a GitHub repo (`owner/repo`). I can seed your Lore namespace with up to the last 500 PRs — each one gets ingested as a single markdown record with its title, author, description, state, and labels. The Lore worker will integrate them into your wiki over the next minute or two. This runs locally via `gh`, nothing else gets sent anywhere besides your own Lore namespace. Want me to go ahead? If you prefer a smaller number, say how many."*

Wait for explicit consent. If the user says no or doesn't answer clearly, skip this phase.

### 3c. Run the seeder

With consent, invoke the seeding script. Pass the limit the user chose (or the default 500):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ingest-github-prs.sh" <limit>
```

Example: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ingest-github-prs.sh" 500`

The script streams per-PR progress to stderr (`[  1/250] ok #123 Title…`) so you can show the user roughly where it is. It fails gracefully on individual PRs and prints a final summary line like `Done. Ingested 247 PRs. Failures: 3.`

Report the final counts back to the user in one sentence. Do **not** re-print the full progress log — it's already in their terminal.

---

## Phase 4 — Wrap up

Tell the user setup is complete and summarize what just got wired up:

- **Credentials** are stored at `${CLAUDE_PLUGIN_DATA}/config.env` (mode 600).
- **Mid-conversation memory** is available via the `lore-memory` skill — Claude can now read from and write to their Lore wiki when it's relevant.
- **Auto-ingest on session end** — every time a Claude Code session ends, the transcript gets posted to Lore and integrated into the wiki.
- **Schema addendum** (if they set one) — Lore will use it to shape future ingests.
- **PR seed** (if they ran it) — the wiki will finish integrating over the next minute or two; they can watch it grow in the dashboard.

Also mention: to change any of this later, they can re-run `/lore-setup` or use the `lore-setup` skill.

---

## Important guardrails

- Never print the raw API key back to the user. Refer to it as "your API key" and show at most a prefix like `lore_sk_****`.
- Never commit the config file or paste its contents anywhere.
- If the user provides values with extra whitespace, trailing newlines, or paste-from-password-manager quotes, strip them before passing to the scripts.
- **Do not skip phases silently.** If you skip a phase (e.g., not a GitHub repo), say so in one sentence so the user knows what you did and didn't do.
- If any script fails, report the exact error. Do not retry in a loop.
