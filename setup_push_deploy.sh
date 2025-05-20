#!/usr/bin/env bash

# push-to-deploy setup script (run on target server as cPanel user)
# Automates bare Git repo setup, hook installation, and deploy instructions.
# Refactored into functions for clarity and testability.

# Prevent word splitting on spaces in filenames or inputs
OLD_IFS=$IFS
IFS=$'\n\t'
set -euo pipefail
trap 'IFS=$OLD_IFS' EXIT

# Global vars
STATE_FILE="$HOME/.push_deploy_state"
CURRENT_STEP=1

# Pre-flight checks
command -v git >/dev/null 2>&1 || { echo "ERROR: git is not installed." >&2; exit 1; }
command -v realpath >/dev/null 2>&1 || { echo "ERROR: realpath is required." >&2; exit 1; }

# State management
get_saved_step() {
  awk -F: -v repo="$REPO_NAME" '$1==repo{print $2}' "$STATE_FILE" 2>/dev/null || :
}
save_state() {
  tmp=$(mktemp --tmpdir)
  grep -v -F "${REPO_NAME}:" "$STATE_FILE" >"$tmp" 2>/dev/null || :
  echo "${REPO_NAME}:$1" >>"$tmp"
  mv "$tmp" "$STATE_FILE"
}
clear_state() {
  tmp=$(mktemp --tmpdir)
  grep -v -F "${REPO_NAME}:" "$STATE_FILE" >"$tmp" 2>/dev/null || :
  mv "$tmp" "$STATE_FILE"
}

# Prompt helper
prompt_required() {
  local var_name="$1" prompt_text="$2" default="$3" input
  while true; do
    if [[ -n "$default" ]]; then
      read -p "$prompt_text [$default]: " input
      input="${input:-$default}"; break
    else
      read -p "$prompt_text: " input
      [[ -n "$input" ]] && break || echo "This value is required."
    fi
  done
  printf -v "$var_name" "%s" "$input"
}

# Hook generators
gen_hook_specific() {
  cat <<EOF
#!/bin/sh
while read old new ref; do
  [[ "\$ref" = "refs/heads/$BRANCH" ]] && git --work-tree="$WORK_TREE" checkout -f "$BRANCH"
done
EOF
}
gen_hook_any() {
  cat <<'EOF'
#!/bin/sh
while read old new ref; do
  branch=$(git rev-parse --abbrev-ref "$ref")
  git --work-tree="${WORK_TREE}" checkout -f "$branch"
done
EOF
}
gen_hook_prune() {
  cat <<'EOF'
#!/bin/sh
echo "WARNING: deletes other branches"
if [[ ! -d "refs/heads" ]]; then echo "No refs/heads" >&2; exit 1; fi
while read old new ref; do
  branch=$(git rev-parse --abbrev-ref "$ref")
  git --work-tree="${WORK_TREE}" checkout -f "$branch"
  git for-each-ref --format="%(refname:short)" refs/heads | while IFS= read -r head; do
    [[ "$head" != "$branch" ]] && git update-ref -d "refs/heads/$head"
  done
done
EOF
}

# Steps as functions
configure() {
  echo; printf "=== Step 1: Configuration ===\n"
  DEFAULT_REPO_ROOT="$HOME/.gitrepo"
  DEFAULT_WEB_ROOT="$HOME/public_html"
  DEFAULT_BRANCH="main"
  HOST_FQDN="$(hostname -f)"
  USER_NAME="$USER"

  prompt_required REPO_NAME "Repository name (without .git)" "myproject"
  [ -n "$STATE_FILE" ] && touch "$STATE_FILE"
  local saved; saved=$(get_saved_step)
  if [[ -n "$saved" ]]; then
    while true; do
      read -p "Resume $REPO_NAME from step $((saved+1))? (y/n): " ans
      case "$ans" in
        [Yy]) CURRENT_STEP=$((saved+1)); break;;
        [Nn]) clear_state; break;;
      esac
    done
  fi
  if (( CURRENT_STEP <= 1 )); then
    prompt_required REPO_ROOT "Bare repo root folder" "$DEFAULT_REPO_ROOT"
    prompt_required WORK_TREE "Deployment target folder" "$DEFAULT_WEB_ROOT"
    save_state 1; CURRENT_STEP=2
  fi
}

prepare_repo() {
  (( CURRENT_STEP > 2 )) && return
  echo; printf "=== Step 2: Prepare bare repository ===\n"
  REPO_ROOT=$(realpath -m "$REPO_ROOT")
  WORK_TREE=$(realpath -m "$WORK_TREE")
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
  [[ "$BARE_DIR" == "/" ]] && { echo "Invalid BARE_DIR." >&2; exit 1; }
  printf "Location: %s\n" "$BARE_DIR"
  if [[ -d "$BARE_DIR" ]]; then
    echo "Skipping init."; else
    mkdir -p "$BARE_DIR"; git init --bare "$BARE_DIR"; echo "Initialized."; fi
  save_state 2; CURRENT_STEP=3
}

select_hook() {
  (( CURRENT_STEP > 3 )) && return
  echo; printf "=== Step 3: Select hook type ===\n"
  PS3="Choose hook: "
  select HOOK_TYPE in "Specific branch" "Any branch" "Any branch & delete others"; do
    [[ -n "$HOOK_TYPE" ]] && break; done
  case "$HOOK_TYPE" in
    "Specific branch") prompt_required BRANCH "Branch" "$DEFAULT_BRANCH"; HOOK_SCRIPT=$(gen_hook_specific);;
    "Any branch") HOOK_SCRIPT=$(gen_hook_any);;
    *) HOOK_SCRIPT=$(gen_hook_prune);;
  esac
  save_state 3; CURRENT_STEP=4
}

install_hook() {
  (( CURRENT_STEP > 4 )) && return
  echo; printf "=== Step 4: Install hook ===\n"
  HOOK_PATH="$BARE_DIR/hooks/post-receive"
  mkdir -p "$(dirname "$HOOK_PATH")"
  printf "%s\n" "$HOOK_SCRIPT" > "$HOOK_PATH"
  chmod +x "$HOOK_PATH"
  # Strip CRLF
  if command -v dos2unix >/dev/null; then dos2unix "$HOOK_PATH"; else tr -d '\r' < "$HOOK_PATH" >"$HOOK_PATH.tmp" && mv "$HOOK_PATH.tmp" "$HOOK_PATH"; fi
  echo "Installed at $HOOK_PATH"
  save_state 4; CURRENT_STEP=5
}

finalize() {
  (( CURRENT_STEP > 5 )) && return
  echo; printf "=== Step 5: Complete ===\n"
  local pathp shortp
  pathp="${BARE_DIR#/}"
  shortp="~/${BARE_DIR#${HOME}/}"
  printf -v FULL_URL "ssh://%s@%s/%s" "$USER_NAME" "$HOST_FQDN" "$pathp"
  printf -v SHORT_URL "ssh://%s@%s/%s" "$USER_NAME" "$HOST_FQDN" "$shortp"
  echo "git remote add production $FULL_URL"
  echo "git remote add production $SHORT_URL"
  echo "git push production ${BRANCH:-<branch>}"
  clear_state
}

# Main
configure
prepare_repo
select_hook
install_hook
finalize
