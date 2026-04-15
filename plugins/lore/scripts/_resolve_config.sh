#!/usr/bin/env bash
# Lore plugin — project-local config resolver.
#
# This file is meant to be `source`d, not executed. After sourcing, call:
#
#   resolve_lore_config [start-dir]
#
# and inspect:
#
#   $LORE_CONFIG_STATUS  — one of: ok | missing | key_missing | incomplete
#   $LORE_CONFIG_DIR     — directory containing .lore.env (when found)
#   $LORE_API_KEY, $LORE_APP, $LORE_NAMESPACE, $LORE_API_BASE
#                         — populated when status == ok
#
# Resolution order:
#
#   1. If $LORE_CONFIG_FILE is set (undocumented escape hatch), source it as
#      a single self-contained file. Its sibling .lore.env.local, if any, is
#      also sourced.
#
#   2. Otherwise, walk up from $start-dir (default: $CLAUDE_PROJECT_DIR or
#      $PWD) looking for a `.lore.env` file. Walk stops at $HOME — we never
#      traverse above the user's home directory.
#
#      When .lore.env is found, its sibling .lore.env.local (if present) is
#      sourced afterwards, so LORE_API_KEY (which lives in the gitignored
#      .local file) always wins over whatever the committed .lore.env says.
#
# The return code mirrors $LORE_CONFIG_STATUS: 0 on "ok", non-zero otherwise.
# Callers use the status string to pick a user-facing error message.

# Walk from $1 upward looking for .lore.env. Prints the containing dir on
# success, returns non-zero on miss. Never walks above $HOME (or above /).
_lore_walk_up() {
  local dir="$1"
  if [[ -z "$dir" ]]; then
    return 1
  fi
  # Resolve to absolute, canonical path so comparisons work.
  local abs
  abs=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  dir="$abs"

  local home_abs
  home_abs=$(cd "$HOME" 2>/dev/null && pwd -P) || home_abs="$HOME"

  while :; do
    if [[ -f "$dir/.lore.env" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    # Stop at $HOME — never look at ~/.lore.env or anything above.
    if [[ "$dir" == "$home_abs" ]]; then
      return 1
    fi
    # Stop at the filesystem root.
    local parent
    parent=$(dirname "$dir")
    if [[ -z "$parent" || "$parent" == "$dir" || "$parent" == "/" ]]; then
      return 1
    fi
    dir="$parent"
  done
}

resolve_lore_config() {
  LORE_CONFIG_STATUS="missing"
  LORE_CONFIG_DIR=""

  local start_dir="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"

  if [[ -n "${LORE_CONFIG_FILE:-}" ]]; then
    # Explicit override — power-user escape hatch.
    if [[ ! -f "$LORE_CONFIG_FILE" ]]; then
      LORE_CONFIG_STATUS="missing"
      return 1
    fi
    # shellcheck disable=SC1090
    source "$LORE_CONFIG_FILE"
    local override_dir
    override_dir=$(dirname "$LORE_CONFIG_FILE")
    if [[ -f "$override_dir/.lore.env.local" ]]; then
      # shellcheck disable=SC1090
      source "$override_dir/.lore.env.local"
    fi
    LORE_CONFIG_DIR="$override_dir"
  else
    local found_dir
    if ! found_dir=$(_lore_walk_up "$start_dir"); then
      LORE_CONFIG_STATUS="missing"
      return 1
    fi
    # shellcheck disable=SC1090
    source "$found_dir/.lore.env"
    if [[ -f "$found_dir/.lore.env.local" ]]; then
      # shellcheck disable=SC1090
      source "$found_dir/.lore.env.local"
    fi
    LORE_CONFIG_DIR="$found_dir"
  fi

  # Default API base only if a value wasn't provided by either file.
  : "${LORE_API_BASE:=https://lore-api-245179047688.us-central1.run.app}"

  # Validate. The three required values have distinct error modes because
  # the setup skill fixes them differently.
  if [[ -z "${LORE_APP:-}" || -z "${LORE_NAMESPACE:-}" ]]; then
    LORE_CONFIG_STATUS="incomplete"
    return 1
  fi
  if [[ -z "${LORE_API_KEY:-}" ]]; then
    LORE_CONFIG_STATUS="key_missing"
    return 1
  fi

  LORE_CONFIG_STATUS="ok"
  export LORE_API_KEY LORE_APP LORE_NAMESPACE LORE_API_BASE LORE_CONFIG_DIR LORE_CONFIG_STATUS
  return 0
}
