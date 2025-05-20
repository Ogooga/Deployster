#!/usr/bin/env bash

# push-to-deploy setup script (run on target server as cPanel user)
# Automates bare Git repo setup, hook installation, and deploy instructions.
# Refactored into functions for clarity and testability.

# Prevent word splitting on spaces in filenames or inputs
OLD_IFS=$IFS
IFS=$'\n\t'
set -euo pipefail
trap 'IFS=$OLD_IFS' EXIT

# Default verbosity
VERBOSE=0

print_help() {
  cat <<EOF
Usage: $0 [-v] [-h]
Options:
  -v    Enable verbose debug output
  -h    Show this help message and exit
EOF
}

# Parse options
while getopts "vh" opt; do
  case "$opt" in
    v) VERBOSE=1;;
    h) print_help; exit 0;;
    *) print_help; exit 1;;
  esac
done
shift $((OPTIND-1))

# Logging
log() {
  (( VERBOSE )) && echo "[DEBUG] $*"
}

# Global vars
STATE_FILE="$HOME/.push_deploy_state"
CURRENT_STEP=1

# Pre-flight checks: path resolution tool fallback
if command -v realpath >/dev/null 2>&1; then
  PATH_RESOLVE="realpath -m"
elif command -v readlink >/dev/null 2>&1; then
  PATH_RESOLVE="readlink -f"
else
  echo "ERROR: neither realpath nor readlink is available. Please install one of them." >&2
  exit 1
fi

# Ensure USER_NAME and HOST_FQDN are set
USER_NAME="$USER"
HOST_FQDN="$(hostname -f)"

# State management
get_saved_step() {
  awk -F: -v repo="$REPO_NAME" '$1==repo{print $2}' "$STATE_FILE" 2>/dev/null || :
}
save_state() {
  local step=$1 tmp
  tmp=$(mktemp --tmpdir)
  grep -v -F "${REPO_NAME}:" "$STATE_FILE" >"$tmp" 2>/dev/null || :
  echo "${REPO_NAME}:${step}" >>"$tmp"
  mv "$tmp" "$STATE_FILE"
  log "Saved state $step for $REPO_NAME"
}
clear_state() {
  local tmp
  tmp=$(mktemp --tmpdir)
  grep -v -F "${REPO_NAME}:" "$STATE_FILE" >"$tmp" 2>/dev/null || :
  mv "$tmp" "$STATE_FILE"
  log "Cleared state for $REPO_NAME"
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
  log "$var_name set to ${!var_name}"
}

# Hook template generators
gen_hook_specific() {
  cat <<EOF
#!/bin/sh
while read old new ref; do
  [[ "\$ref" = "refs/heads/$BRANCH" ]] && git --work-tree="$WORK_TREE" checkout -f "$BRANCH"
done
EOF
}
gen_hook_any() {
  cat <<EOF
#!/bin/sh
while read old new ref; do
  branch=\$(git rev-parse --abbrev-ref "\$ref")
  git --work-tree="$WORK_TREE" checkout -f "\$branch"
done
EOF
}
gen_hook_prune() {
  cat <<EOF
#!/bin/sh
echo "WARNING: deletes other branches"
if [[ ! -d "refs/heads" ]]; then echo "No refs/heads found." >&2; exit 1; fi
while read old new ref; do
  branch=\$(git rev-parse --abbrev-ref "\$ref")
  git --work-tree="$WORK_TREE" checkout -f "\$branch"
  git for-each-ref --format="%(refname:short)" refs/heads | while IFS= read -r head; do
    [[ "\$head" != "\$branch" ]] && git update-ref -d "refs/heads/\$head"
  done
done
EOF
}

# Step functions
configure() {
  echo; printf "=== Step 1: Configuration ===\n"
  prompt_required REPO_NAME "Repository name (without .git)" "myproject"
  [[ -e "$STATE_FILE" ]] || touch "$STATE_FILE"
  local saved=$(get_saved_step)
  if [[ -n "$saved" ]]; then
    while true; do
      read -p "Resume $REPO_NAME from step $((saved+1))? (y/n): " ans
      case "$ans" in
        [Yy]) CURRENT_STEP=$((saved+1)); break;;
        [Nn]) clear_state; break;;
        *) echo "Enter y or n.";;
      esac
    done
  fi
  if (( CURRENT_STEP <= 1 )); then
    prompt_required REPO_ROOT "Bare repo root folder" "$HOME/.gitrepo"
    prompt_required WORK_TREE "Deployment target folder" "$HOME/public_html"
    save_state 1; CURRENT_STEP=2
  fi
}

prepare_repo() {
  (( CURRENT_STEP > 2 )) && return
  echo; printf "=== Step 2: Prepare bare repository ===\n"
  REPO_ROOT=$($PATH_RESOLVE "$REPO_ROOT")
  WORK_TREE=$($PATH_RESOLVE "$WORK_TREE")
  log "Resolved REPO_ROOT to $REPO_ROOT, WORK_TREE to $WORK_TREE"
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
  [[ "$BARE_DIR" == "/" ]] && { echo "ERROR: BARE_DIR cannot be '/'." >&2; exit 1; }
  printf "Location: %s\n" "$BARE_DIR"
  if [[ -d "$BARE_DIR" ]]; then
    echo "Bare repo exists. Skipping initialization."
  else
    mkdir -p "$BARE_DIR"
    git init --bare "$BARE_DIR"
    echo "Initialized bare repo."
  fi
  save_state 2; CURRENT_STEP=3
}

select_hook() {
  (( CURRENT_STEP > 3 )) && return
  echo; printf "=== Step 3: Select hook type ===\n"
  echo "1) Specific branch"
  echo "2) Any branch"
  echo "3) Any branch & prune others"
  while true; do
    read -p "Choice (1-3): " c
    case "$c" in
      1) HOOK_TYPE="Specific branch"; break;;
      2) HOOK_TYPE="Any branch"; break;;
      3) HOOK_TYPE="Any branch & prune others"; break;;
      *) echo "Invalid choice.";;
    esac
  done
  case "$HOOK_TYPE" in
    "Specific branch")
      prompt_required BRANCH "Branch to deploy" "main"
      # Validate branch exists in bare repo
      if ! git --git-dir="$BARE_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
        echo "WARNING: Branch '$BRANCH' not found in bare repo. It will be created on first push."
        read -p "Continue anyway? (y/n): " conf
        [[ ! "${conf}" =~ ^[Yy] ]] && { echo "Aborting."; exit 1; }
      fi
      HOOK_SCRIPT=$(gen_hook_specific)
      ;;  
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
  if command -v dos2unix >/dev/null 2>&1; then
    dos2unix "$HOOK_PATH" >/dev/null
  else
    tr -d '\r' < "$HOOK_PATH" >"$HOOK_PATH.tmp" && mv "$HOOK_PATH.tmp" "$HOOK_PATH"
  fi
  echo "Hook installed at $HOOK_PATH"
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
  echo "Add remote: git remote add production $FULL_URL"
  echo "Or shorthand: git remote add production $SHORT_URL"
  echo "Deploy via: git push production ${BRANCH:-<branch>}"
  clear_state
}

# Main execution
configure
prepare_repo
select_hook
install_hook
finalize
