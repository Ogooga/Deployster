#!/usr/bin/env bash

# push-to-deploy setup script (run on target server as cPanel user)
# Automates bare Git repo setup, hook installation, and deploy instructions.
# Refactored into functions for clarity and testability.

OLD_IFS=$IFS
IFS=$'\n\t'
set -euo pipefail
trap 'IFS=$OLD_IFS' EXIT

VERBOSE=0

print_help() {
  cat <<EOF
Usage: $0 [-v] [-h]
Options:
  -v    Enable verbose debug output
  -h    Show this help message and exit
EOF
}

while getopts "vh" opt; do
  case "$opt" in
    v) VERBOSE=1;;
    h) print_help; exit 0;;
    *) print_help; exit 1;;
  esac
done
shift $((OPTIND-1))

log() {
  (( VERBOSE )) && echo "[DEBUG] $*"
}

STATE_FILE="$HOME/.push_deploy_state"
CURRENT_STEP=1

USER_NAME="$USER"
HOST_FQDN="$(hostname -f)"

# --- PATH RESOLVER ---
resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null || realpath -m "$1" 2>/dev/null || echo "$1"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f "$1" 2>/dev/null || echo "$1"
  else
    echo "$1"
  fi
}

# --- STATE MANAGEMENT ---
save_state() {
  local step=$1 tmp
  tmp=$(mktemp --tmpdir)
  grep -v -F "${REPO_NAME}:" "$STATE_FILE" >"$tmp" 2>/dev/null || :
  echo "${REPO_NAME}:step=${step}:REPO_ROOT=${REPO_ROOT:-}:WORK_TREE=${WORK_TREE:-}:BRANCH=${BRANCH:-}:HOOK_TYPE=${HOOK_TYPE:-}" >>"$tmp"
  mv "$tmp" "$STATE_FILE"
  log "Saved state $step for $REPO_NAME"
}

restore_state_vars() {
  local line key val pair
  line=$(grep -F "${REPO_NAME}:" "$STATE_FILE" 2>/dev/null || true)
  line=${line#${REPO_NAME}:}
  IFS=: read -ra pairs <<< "$line"
  for pair in "${pairs[@]}"; do
    key=${pair%%=*}
    val=${pair#*=}
    case "$key" in
      step) CURRENT_STEP=$val;;
      REPO_ROOT) REPO_ROOT=$val;;
      WORK_TREE) WORK_TREE=$val;;
      BRANCH) BRANCH=$val;;
      HOOK_TYPE) HOOK_TYPE=$val;;
    esac
  done
  log "Restored state for $REPO_NAME: step=$CURRENT_STEP, REPO_ROOT=$REPO_ROOT, WORK_TREE=$WORK_TREE, BRANCH=${BRANCH:-}, HOOK_TYPE=${HOOK_TYPE:-}"
}

clear_state() {
  local tmp
  tmp=$(mktemp --tmpdir)
  grep -v -F "${REPO_NAME}:" "$STATE_FILE" >"$tmp" 2>/dev/null || :
  mv "$tmp" "$STATE_FILE"
  log "Cleared state for $REPO_NAME"
}

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

gen_hook_specific() {
  cat <<EOF
#!/bin/sh

# Define the Git work tree path
GIT_WORK_TREE="$WORK_TREE"

# Define the branch name
BRANCH="$BRANCH"  # e.g., 'master', 'production', etc.

# Checkout the branch on push
while read old new ref; do
  [ "\$ref" = "refs/heads/\$BRANCH" ] && GIT_WORK_TREE="\$GIT_WORK_TREE" git checkout -f "\$BRANCH"
done
EOF
}

gen_hook_any() {
  cat <<EOF
#!/bin/sh

# Define the Git work tree path
GIT_WORK_TREE="$WORK_TREE"

while read old new ref; do
  branch=\$(GIT_WORK_TREE="\$GIT_WORK_TREE" git rev-parse --symbolic --abbrev-ref "\$ref")
  GIT_WORK_TREE="\$GIT_WORK_TREE" git checkout -f "\$branch"
done
EOF
}

gen_hook_prune() {
  cat <<EOF
#!/bin/sh

# Define the Git work tree path
GIT_WORK_TREE="$WORK_TREE"

while read old new ref; do
  branch=\$(GIT_WORK_TREE="\$GIT_WORK_TREE" git rev-parse --symbolic --abbrev-ref "\$ref")
  GIT_WORK_TREE="\$GIT_WORK_TREE" git checkout -f "\$branch"
  git branch | grep -v "\$branch" | xargs git branch -D
done
EOF
}

configure() {
  echo; printf "=== Step 1: Configuration ===\n"
  prompt_required REPO_NAME "Repository name (without .git)" "myproject"
  [[ -e "$STATE_FILE" ]] || touch "$STATE_FILE"
  local saved
  saved=$(grep -F "${REPO_NAME}:" "$STATE_FILE" 2>/dev/null || true)
  if [[ -n "$saved" ]]; then
    restore_state_vars
    while true; do
      read -p "Resume $REPO_NAME from step $((CURRENT_STEP+1))? (y/n): " ans
      case "$ans" in
        [Yy]) CURRENT_STEP=$((CURRENT_STEP+1)); break;;
        [Nn]) clear_state; unset REPO_ROOT WORK_TREE BRANCH HOOK_TYPE; CURRENT_STEP=1; break;;
        *) echo "Enter y or n.";;
      esac
    done
  fi
  if (( CURRENT_STEP <= 1 )); then
    prompt_required REPO_ROOT "Bare repo root folder (full folder path)" "${REPO_ROOT:-$HOME/.gitrepo}"
    prompt_required WORK_TREE "Deployment target folder (full folder path)" "${WORK_TREE:-$HOME/public_html}"
    save_state 1
    CURRENT_STEP=2
  fi
}

prepare_repo() {
  (( CURRENT_STEP > 2 )) && return
  echo; printf "=== Step 2: Prepare bare repository ===\n"
  REPO_ROOT=$(resolve_path "$REPO_ROOT")
  WORK_TREE=$(resolve_path "$WORK_TREE")
  log "Resolved REPO_ROOT to $REPO_ROOT, WORK_TREE to $WORK_TREE"
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
  [[ "$BARE_DIR" == "/" ]] && { echo "ERROR: BARE_DIR cannot be '/'." >&2; exit 1; }
  printf "Location: %s\n" "$BARE_DIR"
  if [[ -d "$BARE_DIR" ]]; then
    echo "Bare repo exists. Skipping initialization."
  else
    mkdir -p "$BARE_DIR"
    echo ""
    git init --bare "$BARE_DIR"
    echo ""
    echo "Initialized bare repo."
  fi
  save_state 2
  CURRENT_STEP=3
}

select_hook() {
  (( CURRENT_STEP > 3 )) && return
  # Restore variables if resuming after step 2
  REPO_ROOT=${REPO_ROOT:-$HOME/.gitrepo}
  WORK_TREE=${WORK_TREE:-$HOME/public_html}
  REPO_ROOT=$(resolve_path "$REPO_ROOT")
  WORK_TREE=$(resolve_path "$WORK_TREE")
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
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
      prompt_required BRANCH "Branch to deploy" "${BRANCH:-master}"
      if ! git --git-dir="$BARE_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
        echo "WARNING: Branch '$BRANCH' not found in bare repo. It will be created on first push."
        read -p "Continue anyway? (y/n): " conf
        [[ ! "${conf}" =~ ^[Yy] ]] && { echo "Aborting."; exit 1; }
      fi
      HOOK_GENERATOR=gen_hook_specific
      ;;
    "Any branch") HOOK_GENERATOR=gen_hook_any;;
    *) HOOK_GENERATOR=gen_hook_prune;;
  esac
  save_state 3
  CURRENT_STEP=4
}

install_hook() {
  (( CURRENT_STEP > 4 )) && return
  # Restore variables if resuming after step 3
  REPO_ROOT=${REPO_ROOT:-$HOME/.gitrepo}
  WORK_TREE=${WORK_TREE:-$HOME/public_html}
  REPO_ROOT=$(resolve_path "$REPO_ROOT")
  WORK_TREE=$(resolve_path "$WORK_TREE")
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
  echo; printf "=== Step 4: Install hook ===\n"
  HOOK_PATH="$BARE_DIR/hooks/post-receive"
  mkdir -p "$(dirname "$HOOK_PATH")"
  $HOOK_GENERATOR > "$HOOK_PATH"

  if command -v dos2unix >/dev/null 2>&1; then
    dos2unix "$HOOK_PATH" >/dev/null
  else
    tr -d '\r' < "$HOOK_PATH" > "$HOOK_PATH.tmp" && mv "$HOOK_PATH.tmp" "$HOOK_PATH"
  fi

  chmod 755 "$HOOK_PATH"
  if [[ ! -x "$HOOK_PATH" ]]; then
    echo "ERROR: Could not set executable permissions for $HOOK_PATH" >&2
    exit 1
  fi
  owner=$(stat -c %U "$HOOK_PATH")
  if [[ "$owner" != "$USER_NAME" ]]; then
    echo "WARNING: $HOOK_PATH is not owned by $USER_NAME. Ownership: $owner"
  fi

  echo "Hook installed at $HOOK_PATH"
  save_state 4
  CURRENT_STEP=5
}

finalize() {
  (( CURRENT_STEP > 5 )) && return
  # Restore variables if resuming after step 4
  REPO_ROOT=${REPO_ROOT:-$HOME/.gitrepo}
  WORK_TREE=${WORK_TREE:-$HOME/public_html}
  REPO_ROOT=$(resolve_path "$REPO_ROOT")
  WORK_TREE=$(resolve_path "$WORK_TREE")
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
  echo; printf "=== Step 5: Complete ===\n"
  local pathp shortp
  pathp="${BARE_DIR#/}"
  shortp="~/${BARE_DIR#${HOME}/}"
  printf -v FULL_URL "ssh://%s@%s/%s" "$USER_NAME" "$HOST_FQDN" "$pathp"
  printf -v SHORT_URL "ssh://%s@%s/%s" "$USER_NAME" "$HOST_FQDN" "$shortp"
  echo ""
  echo "Add remote: git remote add production $FULL_URL"
  echo ""
  echo "Or shorthand: git remote add production $SHORT_URL"
  echo ""
  echo "Deploy via: git push production ${BRANCH:-<branch>}"
  clear_state
}

# Main execution
configure
prepare_repo
select_hook
install_hook
finalize
