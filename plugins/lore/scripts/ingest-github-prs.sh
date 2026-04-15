#!/usr/bin/env bash
# Lore plugin — seed the namespace from recent GitHub PRs in the current repo.
#
# Usage (from the `lore-setup` skill, after the user has consented):
#   ingest-github-prs.sh [limit]
#
# Detects the current workspace's GitHub repo via `git remote get-url origin`,
# uses the `gh` CLI to list up to `limit` PRs (default 500), formats each as
# markdown, and POSTs them one-by-one to the Lore ingest endpoint. Progress is
# streamed to stderr so the skill can watch it live. Failures on individual
# PRs are logged but do not abort the run.
#
# Dependencies: git, gh (authenticated), jq, curl, python3.

set -uo pipefail

LIMIT="${1:-500}"

# --- preflight -----------------------------------------------------------------

CONFIG_FILE="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/lore}/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Lore not configured. Run the lore-setup skill first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${LORE_API_KEY:?LORE_API_KEY missing from config}"
: "${LORE_APP:?LORE_APP missing from config}"
: "${LORE_NAMESPACE:?LORE_NAMESPACE missing from config}"
LORE_API_BASE="${LORE_API_BASE:-https://lore-api-245179047688.us-central1.run.app}"

for bin in git gh jq curl python3; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Error: required command '$bin' not found on PATH." >&2
    exit 1
  fi
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: current directory is not a git working tree." >&2
  exit 1
fi

remote_url=$(git remote get-url origin 2>/dev/null || true)
if [[ -z "$remote_url" ]]; then
  echo "Error: no 'origin' remote configured in this repo." >&2
  exit 1
fi

# Normalize GitHub remotes (https / ssh) to "owner/repo".
REPO=$(REMOTE="$remote_url" python3 - <<'PY'
import os, re, sys
url = os.environ["REMOTE"].strip()
m = re.match(r"^(?:https?://github\.com/|git@github\.com:)([^/]+)/([^/]+?)(?:\.git)?/?$", url)
if not m:
    sys.stderr.write(f"Not a GitHub remote: {url}\n")
    sys.exit(2)
print(f"{m.group(1)}/{m.group(2)}")
PY
)
if [[ -z "$REPO" ]]; then
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

echo "Seeding Lore namespace '$LORE_APP/$LORE_NAMESPACE' from up to $LIMIT PRs in $REPO..." >&2

# --- fetch PR list -------------------------------------------------------------

# Sort by created desc so newest come first — if the user cancels mid-run they
# still get the most recent context ingested.
pr_json=$(gh pr list \
  --repo "$REPO" \
  --state all \
  --limit "$LIMIT" \
  --json number,title,body,author,state,createdAt,updatedAt,mergedAt,closedAt,url,labels,baseRefName,headRefName,isDraft \
  2>/tmp/lore-gh-err.$$) || {
    echo "Error: gh pr list failed:" >&2
    cat /tmp/lore-gh-err.$$ >&2 2>/dev/null || true
    rm -f /tmp/lore-gh-err.$$
    exit 1
}
rm -f /tmp/lore-gh-err.$$

total=$(printf '%s' "$pr_json" | jq 'length')
if [[ -z "$total" || "$total" == "0" ]]; then
  echo "No PRs found in $REPO. Nothing to ingest." >&2
  exit 0
fi

echo "Found $total PRs. Starting ingest..." >&2

# --- ingest loop ---------------------------------------------------------------

ok_count=0
fail_count=0

# Stream each PR object as a single JSON line to a while loop. jq -c gives us
# compact one-per-line output regardless of the original array shape.
while IFS= read -r pr; do
  # Shell out to python to build both the markdown body and the ingest JSON
  # payload atomically. This avoids brittle shell escaping around PR titles
  # and bodies that may contain quotes, newlines, backticks, etc.
  payload=$(PR_JSON="$pr" REPO="$REPO" python3 - <<'PY'
import json, os, sys

pr = json.loads(os.environ["PR_JSON"])
repo = os.environ["REPO"]

num = pr.get("number")
title = pr.get("title") or ""
body = pr.get("body") or ""
author = (pr.get("author") or {}).get("login") or "unknown"
state = pr.get("state") or ""
created = pr.get("createdAt") or ""
merged = pr.get("mergedAt") or ""
closed = pr.get("closedAt") or ""
url = pr.get("url") or ""
labels = [l.get("name", "") for l in (pr.get("labels") or []) if l.get("name")]
base = pr.get("baseRefName") or ""
head = pr.get("headRefName") or ""
is_draft = pr.get("isDraft") or False

# Build a readable markdown record. The Lore worker will integrate this into
# whatever wiki structure the schema says; our job is just to give it a
# single self-contained, human-readable document per PR.
lines = []
lines.append(f"# {repo}#{num}: {title}".rstrip())
lines.append("")
lines.append(f"- **Repo:** {repo}")
lines.append(f"- **PR:** [#{num}]({url})")
lines.append(f"- **Author:** @{author}")
lines.append(f"- **State:** {state}{' (draft)' if is_draft else ''}")
if base or head:
    lines.append(f"- **Branch:** `{head}` → `{base}`")
if created:
    lines.append(f"- **Created:** {created}")
if merged:
    lines.append(f"- **Merged:** {merged}")
elif closed and state.upper() == "CLOSED":
    lines.append(f"- **Closed:** {closed}")
if labels:
    lines.append(f"- **Labels:** {', '.join(labels)}")
lines.append("")
if body.strip():
    lines.append("## Description")
    lines.append("")
    lines.append(body.strip())
else:
    lines.append("_No description._")

content = "\n".join(lines) + "\n"

ingest = {
    "source": {
        "content": content,
        "metadata": {
            "kind": "github-pr",
            "repo": repo,
            "pr_number": num,
            "url": url,
            "title": title,
            "author": author,
            "state": state,
            "merged_at": merged,
            "created_at": created,
        },
    },
}
sys.stdout.write(json.dumps(ingest))
PY
) || {
    fail_count=$((fail_count + 1))
    echo "  [skip] failed to build payload for PR" >&2
    continue
  }

  # POST the ingest. Capture HTTP status so we can report per-PR outcome.
  num=$(printf '%s' "$pr" | jq -r '.number')
  title=$(printf '%s' "$pr" | jq -r '.title' | tr '\n' ' ' | cut -c1-72)

  tmp=$(mktemp)
  code=$(curl -sS -o "$tmp" -w '%{http_code}' -X POST \
    --max-time 20 \
    -H "Authorization: Bearer $LORE_API_KEY" \
    -H "Content-Type: application/json" \
    --data-raw "$payload" \
    "$LORE_API_BASE/v1/apps/$LORE_APP/namespaces/$LORE_NAMESPACE/ingest" \
    2>/dev/null || echo "000")

  case "$code" in
    2*)
      ok_count=$((ok_count + 1))
      printf '  [%3d/%3d] ok   #%s %s\n' "$((ok_count + fail_count))" "$total" "$num" "$title" >&2
      ;;
    *)
      fail_count=$((fail_count + 1))
      printf '  [%3d/%3d] FAIL #%s (HTTP %s) %s\n' "$((ok_count + fail_count))" "$total" "$num" "$code" "$title" >&2
      head -c 400 "$tmp" >&2 2>/dev/null || true
      echo >&2
      ;;
  esac
  rm -f "$tmp"

done < <(printf '%s' "$pr_json" | jq -c '.[]')

echo >&2
echo "Done. Ingested $ok_count PRs. Failures: $fail_count." >&2
echo "The Lore worker will integrate these asynchronously — the wiki will grow over the next minute or two." >&2

exit 0
