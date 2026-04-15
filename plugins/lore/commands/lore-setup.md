---
description: Connect the Lore plugin to the current project — writes .lore.env (committed) + .lore.env.local (gitignored), sets up schema, optionally seeds from GitHub PRs.
---

The user invoked the `/lore-setup` slash command. Run the `lore-setup` skill from this plugin to walk them through the full setup flow for the **current project**:

1. Credentials — writes `<project-root>/.lore.env` (committed, contains `LORE_APP` + `LORE_NAMESPACE`) and `<project-root>/.lore.env.local` (gitignored, contains `LORE_API_KEY`).
2. Namespace schema addendum — asks what kinds of things they'd like remembered, drafts a short markdown schema, and PUTs it.
3. Optional GitHub PR seeding — if this workspace is a GitHub repo.

Detect the scenario first (fresh project / teammate onboarding / reconfigure) by checking which files already exist at the project root. Follow the skill's instructions exactly. Do not skip steps.
