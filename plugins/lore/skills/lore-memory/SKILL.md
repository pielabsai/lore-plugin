---
name: lore-memory
description: Access the user's persistent Lore knowledge base — browse the index, read entries, follow wikilinks, and remember new durable facts. Use whenever the user references their long-term memory, asks a question prior context might answer, states a preference or decision worth keeping beyond this session, or says "remember that…".
---

# Lore Memory

The user has a persistent, compounding knowledge base stored in Lore. It is organized as a wiki: a navigable `_index` catalog plus individual markdown files addressed by a stable `key`. Files cross-reference each other via `[[wikilink]]` style references.

You interact with it through a helper script that wraps the Lore REST API. The script reads credentials from the project's `.lore.env` + `.lore.env.local` (walked up from the current working directory — config is **per-project**, so every repo has its own). If the script errors with "Lore not configured for this project" or "no API key set", tell the user to run the `/lore-setup` slash command (or the `lore-setup` skill) in this project and stop.

## When to use this skill

Invoke it proactively when any of these are true:

- The user asks something that prior context they've shared might answer (their preferences, their stack, their projects, their ongoing work).
- The user says "remember that…", "I decided…", "my X is Y", or otherwise states a durable fact worth keeping.
- You're about to give a substantive answer and long-term context would materially change it.
- The user explicitly references "my Lore", "my wiki", "my memory", or similar.

Do **not** invoke it for:

- Trivial throwaway questions (definitions, quick lookups).
- Anything the user has asked you to keep private or ephemeral.
- System/tooling issues unrelated to user context.

## Reading the wiki

### Start with the index

The namespace `_index` is a navigable catalog of every file, with keys, titles, and short descriptions. **In most sessions it has already been pre-loaded for you as `additionalContext` by the `SessionStart` hook** — look for a block titled "Lore wiki index for `<app>/<namespace>`" at the top of the session context. If you see it, use it directly; do **not** call `lore.sh get` redundantly.

If the preamble is absent (older sessions, or the hook failed at session start), fetch the index yourself:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lore.sh" get
```

This returns clean markdown — the content of `_index`, not an API envelope. You can also re-fetch it explicitly during a long session if you have reason to believe another session has ingested new content and the preamble has gone stale.

### Read individual files by key

From the index, pick file keys that look relevant to the user's question and read them one at a time:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lore.sh" get <file-key>
```

This returns a JSON object with `key`, `type`, `title`, `tags`, `content`, `inbound_count`, and a `backlinks` array of files that link **to** this one. The `content` field is the file body as markdown; `backlinks` is the graph edge data you use for navigation.

### Navigate the graph

Files reference each other with `[[other-key]]` wikilinks inside their `content`, and each file you read also comes with an explicit `backlinks` array — **both directions are available to you.** If reading a file surfaces a wikilink or a backlink that is clearly relevant to what the user asked, follow it with another `get <other-key>` call. **You are navigating the wiki yourself** — Lore does not do inference for you. Read the actual files, synthesize the answer from what you read, and cite the file keys you used.

Keep traversal proportional to the question. For simple questions, one or two files are usually enough. For substantive questions, follow a few wikilinks deep, but stop once you have enough to answer.

## Remembering new content

When the user shares something worth keeping beyond this session, ingest it:

```bash
echo 'The content to remember, written as a paragraph or two of markdown.' \
  | bash "${CLAUDE_PLUGIN_ROOT}/scripts/lore.sh" remember
```

Guidelines:

- Write the content as **markdown prose**, not JSON, not bullet points of terse fragments. The Lore worker will integrate it into the appropriate wiki files using the LLM — give it something readable.
- Include context the wiki will need to integrate the content correctly: who said it, what it's about, when (if relevant). For example: `"The user mentioned they prefer TypeScript over Python for new backend services, citing team familiarity and better typing for their domain."`
- It is **fire-and-forget**. The `remember` call returns immediately with a `202 Accepted`. Do not wait for or expect a structured response.
- Do not re-ingest the same content twice within a session unless the user explicitly asks.
- Do not ingest anything the user has asked you to forget, anything marked private, or anything that looks like secrets (API keys, passwords, access tokens).

## Errors

If the script prints an error like `Error: Lore not configured. Run /lore-setup first.`, tell the user to run the `lore-setup` skill and stop. Do not attempt to work around it.

If a `get` call returns a 404 for a specific key, tell the user that key doesn't exist (don't silently substitute another) and suggest re-reading the index.

If a `remember` call fails, tell the user the ingest didn't go through but continue with the conversation — do not retry in a loop.
