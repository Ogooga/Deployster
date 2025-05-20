#!/usr/bin/env bash

# push-to-deploy setup script (run on target server as cPanel user)
# Automates bare Git repo setup, hook installation, and deploy instructions.

OLD_IFS=$IFS
IFS=$'\n\t'
set -euo pipefail
trap 'IFS=$OLD_IFS' EXIT

VERBOSE=0

# --- COLORS AND UI HELPERS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
RESET='\033[0m'

banner() {
  echo -e "${BOLD}${CYAN}"
  echo "========================================="
  echo "     Push-to-Deploy Git Setup Wizard     "
  echo "========================================="
  echo -e "${RESET}Automates bare Git repo and post-receive hook setup."
  echo
}

maybe_clear() { (( VERBOSE )) || clear; }

step_title() {
  local n=$1 total=$2 msg=$3
  echo -e "${BOLD}${CYAN}[${n}/${total}] ${msg}${RESET}"
}

info()   { echo -e "${CYAN}$*${RESET}"; }
warn()   { echo -e "${YELLOW}$*${RESET}"; }
error()  { echo -e "${RED}$*${RESET}" >&2; }
success(){ echo -e "${GREEN}$*${RESET}"; }
prompt() { echo -en "${BOLD}$*${RESET}"; }

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
  (( VERBOSE )) && info "[DEBUG] $*"
}

STATE_FILE="$HOME/.push_deploy_state"
CURRENT_STEP=1

USER_NAME="${USER:-$(whoami)}"
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"

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
      prompt "$prompt_text [${CYAN}${default}${RESET}]: "
      read input
      input="${input:-$default}"
    else
      prompt "$prompt_text: "
      read input
    fi
    if [[ -n "$input" ]]; then
      break
    else
      warn "This value is required."
    fi
  done
  printf -v "$var_name" "%s" "$input"
  if [[ $(declare -p "$var_name" 2>/dev/null) ]]; then
    log "$var_name set to [${!var_name}]"
  else
    log "$var_name not set"
  fi
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
  maybe_clear
  banner
  step_title 1 5 "Configuration"
  prompt_required REPO_NAME "Repository name (without .git)" "myproject"
  [[ -e "$STATE_FILE" ]] || touch "$STATE_FILE"
  local saved
  saved=$(grep -F "${REPO_NAME}:" "$STATE_FILE" 2>/dev/null || true)
  if [[ -n "$saved" ]]; then
    restore_state_vars
    while true; do
      prompt "${YELLOW}Resume $REPO_NAME from step $((CURRENT_STEP+1))? (y/n): ${RESET}"
      read ans
      case "$ans" in
        [Yy]) CURRENT_STEP=$((CURRENT_STEP+1)); break;;
        [Nn]) clear_state; unset REPO_ROOT WORK_TREE BRANCH HOOK_TYPE; CURRENT_STEP=1; break;;
        *) warn "Enter y or n.";;
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
  maybe_clear
  step_title 2 5 "Prepare bare repository"
  REPO_ROOT=$(resolve_path "$REPO_ROOT")
  WORK_TREE=$(resolve_path "$WORK_TREE")
  log "Resolved REPO_ROOT to $REPO_ROOT, WORK_TREE to $WORK_TREE"
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
  [[ "$BARE_DIR" == "/" ]] && { error "BARE_DIR cannot be '/'."; exit 1; }
  info "Location: $BARE_DIR"
  if [[ -d "$BARE_DIR" ]]; then
    warn "Bare repo exists. Skipping initialization."
  else
    mkdir -p "$BARE_DIR"
    git init --bare "$BARE_DIR"
    success "Initialized bare repo."
  fi
  sleep 0.4
  save_state 2
  CURRENT_STEP=3
}

select_hook() {
  maybe_clear
  step_title 3 5 "Select deployment hook type"
  REPO_ROOT=${REPO_ROOT:-$HOME/.gitrepo}
  WORK_TREE=${WORK_TREE:-$HOME/public_html}
  REPO_ROOT=$(resolve_path "$REPO_ROOT")
  WORK_TREE=$(resolve_path "$WORK_TREE")
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
  info "Choose deployment mode:"
  echo -e "${YELLOW}1)${RESET} Specific branch (recommended)"
  echo -e "${YELLOW}2)${RESET} Any branch"
  echo -e "${YELLOW}3)${RESET} Any branch & prune others ${RED}(danger)${RESET}"
  while true; do
    prompt "Choice (1-3): "
    read c
    case "$c" in
      1) HOOK_TYPE="Specific branch"; break;;
      2) HOOK_TYPE="Any branch"; break;;
      3) HOOK_TYPE="Any branch & prune others"; break;;
      *) warn "Invalid choice.";;
    esac
  done
  case "$HOOK_TYPE" in
    "Specific branch")
      prompt_required BRANCH "Branch to deploy" "${BRANCH:-master}"
      if ! git --git-dir="$BARE_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
        warn "Branch '$BRANCH' not found in bare repo. It will be created on first push."
      fi
      HOOK_GENERATOR=gen_hook_specific
      ;;
    "Any branch") HOOK_GENERATOR=gen_hook_any;;
    *) HOOK_GENERATOR=gen_hook_prune;;
  esac
  sleep 0.4
  save_state 3
  CURRENT_STEP=4
}

install_hook() {
  maybe_clear
  step_title 4 5 "Install post-receive hook"
  REPO_ROOT=${REPO_ROOT:-$HOME/.gitrepo}
  WORK_TREE=${WORK_TREE:-$HOME/public_html}
  REPO_ROOT=$(resolve_path "$REPO_ROOT")
  WORK_TREE=$(resolve_path "$WORK_TREE")
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
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
    error "Could not set executable permissions for $HOOK_PATH"
    exit 1
  fi
  owner=$(stat -c %U "$HOOK_PATH")
  if [[ "$owner" != "$USER_NAME" ]]; then
    warn "$HOOK_PATH is not owned by $USER_NAME. Ownership: $owner"
  fi

  success "Hook installed at $HOOK_PATH"
  sleep 0.4
  save_state 4
  CURRENT_STEP=5
}

finalize() {
  maybe_clear
  step_title 5 5 "Complete"
  REPO_ROOT=${REPO_ROOT:-$HOME/.gitrepo}
  WORK_TREE=${WORK_TREE:-$HOME/public_html}
  REPO_ROOT=$(resolve_path "$REPO_ROOT")
  WORK_TREE=$(resolve_path "$WORK_TREE")
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
  local pathp shortp
  pathp="${BARE_DIR#/}"
  shortp="~/${BARE_DIR#${HOME}/}"
  printf -v FULL_URL "ssh://%s@%s/%s" "$USER_NAME" "$HOST_FQDN" "$pathp"
  printf -v SHORT_URL "ssh://%s@%s/%s" "$USER_NAME" "$HOST_FQDN" "$shortp"
  echo ""
  info "Add remote to your local Git project:"
  echo -e "${BOLD}git remote add production $FULL_URL${RESET}"
  info "Or shorthand:"
  echo -e "${BOLD}git remote add production $SHORT_URL${RESET}"
  echo ""
  info "To deploy, push your branch:"
  echo -e "${GREEN}git push production ${BRANCH:-<branch>}${RESET}"
  echo ""
  success "Setup complete! 🚀  Push to deploy is now enabled."
  clear_state
  sleep 1
}

# Main execution
banner
configure
prepare_repo
select_hook
install_hook
finalize
