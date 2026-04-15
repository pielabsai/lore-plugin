#!/usr/bin/env bash
# Lore plugin — per-project credential setup.
#
# Writes two files at the project root:
#
#   .lore.env          (mode 644, CHECKED IN)
#     export LORE_APP='...'
#     export LORE_NAMESPACE='...'
#     [export LORE_API_BASE='...']        # only if non-default
#
#   .lore.env.local    (mode 600, GITIGNORED)
#     export LORE_API_KEY='...'
#
# The split means team members share the app/namespace wiring via git, while
# each developer's API key stays on their own machine. A strict .gitignore
# gate prevents .lore.env.local from being committed.
#
# Inputs come from the environment (not CLI args) so secrets stay out of
# `ps` and shell history:
#
#   LORE_API_KEY        (required)
#   LORE_APP            (required unless .lore.env already exists here)
#   LORE_NAMESPACE      (required unless .lore.env already exists here)
#   LORE_API_BASE       (optional; default is the public Lore API)
#   LORE_PROJECT_DIR    (optional; overrides the auto-detected project root)
#
# Invoked by the `lore-setup` skill. Not meant to be run directly.

set -euo pipefail

: "${LORE_API_KEY:?Set LORE_API_KEY in the environment}"

# ---------- determine project root ----------

# The skill can pin the target directory explicitly via LORE_PROJECT_DIR.
# Otherwise, prefer the nearest existing .lore.env (so re-runs update in
# place), then fall back to the git top-level, then to $PWD.
if [[ -n "${LORE_PROJECT_DIR:-}" ]]; then
  project_dir=$(cd "$LORE_PROJECT_DIR" 2>/dev/null && pwd -P) || {
    echo "Error: LORE_PROJECT_DIR='$LORE_PROJECT_DIR' is not a directory." >&2
    exit 1
  }
else
  # Walk up from $PWD looking for an existing .lore.env.
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/_resolve_config.sh"
  if existing_dir=$(_lore_walk_up "$PWD" 2>/dev/null); then
    project_dir="$existing_dir"
  elif git_top=$(git rev-parse --show-toplevel 2>/dev/null); then
    project_dir=$(cd "$git_top" && pwd -P)
  else
    project_dir=$(pwd -P)
  fi
fi

# Refuse to write at $HOME — that's the global-config failure mode we're
# explicitly designing against.
home_abs=$(cd "$HOME" 2>/dev/null && pwd -P) || home_abs="$HOME"
if [[ "$project_dir" == "$home_abs" ]]; then
  echo "Error: refusing to write .lore.env directly at \$HOME." >&2
  echo "Run /lore-setup from inside a specific project directory — config is per-project by design." >&2
  exit 1
fi

# ---------- read existing values (for partial re-configuration) ----------

existing_app=""
existing_namespace=""
existing_base=""
if [[ -f "$project_dir/.lore.env" ]]; then
  # Source in a subshell so we don't pollute our own environment.
  existing_app=$(bash -c "source '$project_dir/.lore.env' && printf '%s' \"\${LORE_APP:-}\"" 2>/dev/null || true)
  existing_namespace=$(bash -c "source '$project_dir/.lore.env' && printf '%s' \"\${LORE_NAMESPACE:-}\"" 2>/dev/null || true)
  existing_base=$(bash -c "source '$project_dir/.lore.env' && printf '%s' \"\${LORE_API_BASE:-}\"" 2>/dev/null || true)
fi

# Provided vars override existing; existing fills in the blanks for the
# "teammate onboarding" case where .lore.env is already committed and the
# user only needs to add their own API key.
app="${LORE_APP:-$existing_app}"
namespace="${LORE_NAMESPACE:-$existing_namespace}"
api_base="${LORE_API_BASE:-${existing_base:-https://lore-api-245179047688.us-central1.run.app}}"

if [[ -z "$app" || -z "$namespace" ]]; then
  echo "Error: LORE_APP and LORE_NAMESPACE must be set (either in the environment, or in an existing $project_dir/.lore.env)." >&2
  exit 1
fi

# ---------- gitignore gate (strict) ----------

# Find the .gitignore that governs .lore.env.local. In practice that's the
# one at the same level as .lore.env (the project root), but we also honor
# a top-level .gitignore if project_dir is inside a git repo.
gitignore_path="$project_dir/.gitignore"

# Check whether .lore.env.local is already ignored by any rule. Prefer
# `git check-ignore` if project_dir is inside a repo; otherwise fall back to
# a literal grep against $gitignore_path.
already_ignored=0
if git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$project_dir" check-ignore -q .lore.env.local 2>/dev/null; then
    already_ignored=1
  fi
else
  if [[ -f "$gitignore_path" ]] && grep -qxF '.lore.env.local' "$gitignore_path" 2>/dev/null; then
    already_ignored=1
  fi
fi

if [[ "$already_ignored" -ne 1 ]]; then
  # Append the line to .gitignore at project root. Create the file if it
  # doesn't exist. This is the "strict gate": setup refuses to write the
  # secret file until the ignore is in place, and fixes the ignore itself
  # so the user doesn't have to context-switch.
  if [[ -f "$gitignore_path" ]]; then
    # Ensure the file ends with a newline before appending.
    if [[ -s "$gitignore_path" ]] && [[ -n "$(tail -c 1 "$gitignore_path")" ]]; then
      printf '\n' >> "$gitignore_path"
    fi
    printf '# Lore plugin — per-developer secrets, do not commit.\n.lore.env.local\n' >> "$gitignore_path"
    echo "Appended '.lore.env.local' to $gitignore_path"
  else
    cat > "$gitignore_path" <<'GITIGNORE_EOF'
# Lore plugin — per-developer secrets, do not commit.
.lore.env.local
GITIGNORE_EOF
    echo "Created $gitignore_path with '.lore.env.local' excluded"
  fi
fi

# ---------- write .lore.env (committed) ----------

# Only (re-)write if fields actually changed, to avoid touching the file on
# teammate-onboarding runs that only supply the API key.
need_write_env=0
if [[ ! -f "$project_dir/.lore.env" ]]; then
  need_write_env=1
elif [[ "$app" != "$existing_app" || "$namespace" != "$existing_namespace" ]]; then
  need_write_env=1
elif [[ -n "${LORE_API_BASE:-}" && "$api_base" != "$existing_base" ]]; then
  need_write_env=1
fi

if [[ "$need_write_env" -eq 1 ]]; then
  {
    echo "# Lore plugin — project config. Checked in. Shared with your team."
    echo "# Contains no secrets. Your API key lives in .lore.env.local (gitignored)."
    echo "# Re-run /lore-setup to change these values."
    echo "export LORE_APP='$app'"
    echo "export LORE_NAMESPACE='$namespace'"
    # Only write LORE_API_BASE if it's non-default — keeps the file minimal
    # and avoids committing stale overrides.
    if [[ "$api_base" != "https://lore-api-245179047688.us-central1.run.app" ]]; then
      echo "export LORE_API_BASE='$api_base'"
    fi
  } > "$project_dir/.lore.env"
  chmod 644 "$project_dir/.lore.env"
  echo "Wrote $project_dir/.lore.env"
else
  echo "Kept existing $project_dir/.lore.env (app/namespace unchanged)"
fi

# ---------- write .lore.env.local (secret) ----------

umask 077
{
  echo "# Lore plugin — local secrets. DO NOT COMMIT."
  echo "# This file is gitignored by /lore-setup. Each developer provides their own."
  echo "export LORE_API_KEY='$LORE_API_KEY'"
} > "$project_dir/.lore.env.local"
chmod 600 "$project_dir/.lore.env.local"
echo "Wrote $project_dir/.lore.env.local (mode 600)"

# ---------- verify ----------

echo "Verifying credentials against $api_base..."

verify_tmp=$(mktemp)
http_code=$(curl -sS -o "$verify_tmp" -w '%{http_code}' \
  -H "Authorization: Bearer $LORE_API_KEY" \
  "$api_base/v1/apps/$app/namespaces/$namespace/index" || echo "000")

case "$http_code" in
  2*)
    rm -f "$verify_tmp"
    echo "OK — connected to Lore as $app/$namespace"
    echo ""
    echo "Project root: $project_dir"
    echo "  .lore.env        (committed; contains app + namespace)"
    echo "  .lore.env.local  (gitignored; contains your API key)"
    ;;
  401|403)
    echo "Error: API key rejected (HTTP $http_code). Check that LORE_API_KEY is correct and scoped to app='$app'." >&2
    cat "$verify_tmp" >&2 2>/dev/null || true
    rm -f "$verify_tmp"
    exit 1
    ;;
  404)
    echo "Error: app or namespace not found (HTTP 404). Check that LORE_APP='$app' and LORE_NAMESPACE='$namespace' exist." >&2
    rm -f "$verify_tmp"
    exit 1
    ;;
  000)
    echo "Error: could not reach $api_base. Check your network connection." >&2
    rm -f "$verify_tmp"
    exit 1
    ;;
  *)
    echo "Error: unexpected HTTP $http_code from Lore API." >&2
    cat "$verify_tmp" >&2 2>/dev/null || true
    rm -f "$verify_tmp"
    exit 1
    ;;
esac
