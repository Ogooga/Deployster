#!/usr/bin/env bash

# Deployster: Push-to-Deploy Git Setup Script (run on target server as cPanel user or any Linux user)
# All state and log files are stored in ~/.deployster/

set -euo pipefail
IFS=$'\n\t'
OLD_IFS=$IFS

# --- COLORS AND UI HELPERS (for fancy CLI output) ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
UNDER='\033[4m'
RESET='\033[0m'

SEPARATOR="${BOLD}${CYAN}============================================================${RESET}"
CHECK="${GREEN}✔${RESET}"
CROSS="${RED}❌${RESET}"
WARN_EMOJI="${YELLOW}⚠${RESET}"
PROGRESS_BAR=(
  "[${GREEN}#    ${RESET}]"
  "[${GREEN}##   ${RESET}]"
  "[${GREEN}###  ${RESET}]"
  "[${GREEN}#### ${RESET}]"
  "[${GREEN}#####${RESET}]"
)

# Banner and UI functions for improved user experience
banner() {
  echo -e "$SEPARATOR"
  echo -e "${BOLD}${CYAN}            Deployster Setup Wizard         ${RESET}"
  echo -e "$SEPARATOR"
  echo -e "${RESET}Automates bare Git repo and post-receive hook setup."
  echo
}
maybe_clear() { (( VERBOSE )) || clear; }

step_title() {
  local n=$1 total=$2 msg=$3
  local idx=$((n-1))
  local bar="${PROGRESS_BAR[$idx]}"
  echo -e "$bar ${BOLD}${CYAN}Step $n/$total:${RESET} $msg"
  echo -e "$SEPARATOR"
}

info()   { echo -e "${CYAN}$*${RESET}"; }
warn()   { echo -e "${YELLOW}$*${RESET}"; }
error()  { echo -e "${RED}$*${RESET}" >&2; }
success(){ echo -e "${GREEN}$*${RESET}"; }
prompt() { echo -en "${BOLD}$*${RESET}"; }

# --- SETUP WORKDIR FOR STATE AND LOG FILES ---
DEPLOYSTER_DIR="$HOME/.deployster"
mkdir -p "$DEPLOYSTER_DIR"

VERBOSE=0
LOG_TO_FILE=0
LOG_FILE="$DEPLOYSTER_DIR/deployster_setup_$(date +%Y%m%d_%H%M%S).log"
STATE_FILE="$DEPLOYSTER_DIR/state"

# --- COMMAND-LINE HELP ---
print_help() {
  cat <<EOF
Usage: $0 [-v|--verbose] [--log] [-h|--help]
Options:
  -v, --verbose      Enable verbose debug output
      --log          Log all script output to a file (implies non-verbose)
  -h, --help         Show this help message and exit
EOF
}

# --- ARGUMENT PARSING ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift ;;
    --log) LOG_TO_FILE=1; VERBOSE=0; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) print_help; exit 1 ;;
  esac
done

# --- LOGGING SETUP ---
if (( LOG_TO_FILE )); then
  exec > >(tee "$LOG_FILE") 2>&1
  info "Logging to $LOG_FILE"
fi

log() {
  (( VERBOSE )) && info "[DEBUG] $*"
}

# --- GLOBALS AND INIT ---
CURRENT_STEP=1
UNDO_STACK=()
REDO_STACK=()
USER_NAME="${USER:-$(whoami)}"
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"

# --- ENVIRONMENT AND DEPENDENCY CHECKS ---
sys_check() {
  echo -e "$SEPARATOR"
  info "${BOLD}${UNDER}Environment checks${RESET}"
  if [[ $EUID -eq 0 ]]; then
    warn "${WARN_EMOJI} It is not recommended to run this as root. Proceed with caution."
    sleep 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    error "${CROSS} git is not installed! Aborting."
    exit 1
  fi
  if ! command -v ssh >/dev/null 2>&1; then
    error "${CROSS} ssh is not installed! Aborting."
    exit 1
  fi
  gitver=$(git --version | awk '{print $3}')
  if [[ "$gitver" < "2.11" ]]; then
    warn "${WARN_EMOJI} Git version is quite old ($gitver); upgrade is recommended."
  fi
}

# --- INTERRUPT/CLEANUP HANDLER ---
INTERRUPTED=0
trap_handler() {
  INTERRUPTED=1
  echo
  warn "${WARN_EMOJI} Interrupt received (Ctrl+C)."
  # If state file exists for this repo, offer recovery
  if [[ -n "${REPO_NAME:-}" && -f "$STATE_FILE" && $(grep -c "^${REPO_NAME}:" "$STATE_FILE" 2>/dev/null || echo 0) -gt 0 ]]; then
    while true; do
      prompt "${YELLOW}Save partial progress and exit (s), discard and cleanup (c), or continue (r)? [s/c/r]: ${RESET}"
      read choice
      case "$choice" in
        s|S) info "Partial progress saved. You can resume later."; exit 130;;
        c|C) clear_state; info "State cleared. Exiting."; exit 130;;
        r|R) info "Continuing..."; return;;
        *) warn "Enter s, c, or r.";;
      esac
    done
  else
    info "Exiting (no saved state to clean)."
    exit 130
  fi
}
trap trap_handler SIGINT

# --- PATH RESOLUTION (realpath/readlink fallback) ---
resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null || realpath -m "$1" 2>/dev/null || echo "$1"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f "$1" 2>/dev/null || echo "$1"
  else
    echo "$1"
  fi
}

# --- STATE MANAGEMENT (persistent progress) ---
save_state() {
  local step=$1 tmp
  tmp=$(mktemp --tmpdir)
  grep -v -F "${REPO_NAME}:" "$STATE_FILE" >"$tmp" 2>/dev/null || :
  echo "${REPO_NAME}:step=${step}:REPO_ROOT=${REPO_ROOT:-}:WORK_TREE=${WORK_TREE:-}:BRANCH=${BRANCH:-}:HOOK_TYPE=${HOOK_TYPE:-}" >>"$tmp"
  mv "$tmp" "$STATE_FILE"
  log "Saved state $step for $REPO_NAME"
}
restore_state_vars() {
  # Restore progress from state file for this repo
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
  # Remove state for current repo
  local tmp
  tmp=$(mktemp --tmpdir)
  grep -v -F "${REPO_NAME}:" "$STATE_FILE" >"$tmp" 2>/dev/null || :
  mv "$tmp" "$STATE_FILE"
  log "Cleared state for $REPO_NAME"
}

# --- UNDO LOGIC: allow stepping back one prompt at a time ---
undo_step() {
  if [[ ${#UNDO_STACK[@]} -gt 0 ]]; then
    local prev_step="${UNDO_STACK[-1]}"
    unset 'UNDO_STACK[-1]'
    CURRENT_STEP="$prev_step"
    warn "Went back to previous step ($CURRENT_STEP)."
  else
    warn "No previous step to undo."
  fi
}

# --- INPUT PROMPTS WITH 'undo' SUPPORT, robust error handling, and color ---
prompt_required() {
  local var_name="$1" prompt_text="$2" default="$3" input prompt_line
  while true; do
    if [[ -n "$default" ]]; then
      prompt_line="${BOLD}${prompt_text}${RESET} [${CYAN}${default}${RESET}]: "
    else
      prompt_line="${BOLD}${prompt_text}${RESET}: "
    fi
    # Print color prompt using variables, then read input
    echo -ne "$prompt_line"
    if ! read -e input; then
      # Read error or EOF
      return 2
    fi
    [[ "$input" == "undo" ]] && { undo_step; return 1; }
    if [[ -n "$default" && -z "$input" ]]; then input="$default"; fi
    if [[ -z "$input" ]]; then
      warn "This value is required."
      continue
    fi
    printf -v "$var_name" "%s" "$input"
    log "$var_name set to ${!var_name}"
    return 0
  done
}

# --- HOOK FILE TEMPLATES FOR GIT DEPLOYMENT ---
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

# --- MAIN WIZARD STEPS ---

configure() {
  step_title 1 5 "Repository configuration"
  # Prompt for repo name (with undo support and robust error handling)
  while true; do
    prompt_required REPO_NAME "Repository name (without .git)" "myproject"
    rc=$?
    [[ $rc -eq 0 ]] && break
    [[ $rc -eq 1 ]] && continue
    error "Prompt error or input stream closed. Aborting."
    exit 1
  done
  [[ -e "$STATE_FILE" ]] || touch "$STATE_FILE"
  local saved
  saved=$(grep -F "${REPO_NAME}:" "$STATE_FILE" 2>/dev/null || true)
  if [[ -n "$saved" ]]; then
    maybe_clear
    restore_state_vars
    info "Detected previous incomplete setup for '${REPO_NAME}'."
    echo -e "State: step=$CURRENT_STEP, REPO_ROOT=$REPO_ROOT, WORK_TREE=$WORK_TREE, BRANCH=${BRANCH:-}, HOOK_TYPE=${HOOK_TYPE:-}"
    while true; do
      prompt "Resume, edit, or start over? [r/e/s]: "
      read res
      [[ "$res" == "undo" ]] && { undo_step; continue; }
      case "$res" in
        r|R) info "Resuming from saved state."; CURRENT_STEP=$((CURRENT_STEP+1)); break;;
        e|E)
          while true; do
            prompt_required REPO_ROOT "Bare repo root folder (full folder path)" "${REPO_ROOT:-$HOME/.gitrepo}"
            rc=$?
            [[ $rc -eq 0 ]] && break
            [[ $rc -eq 1 ]] && continue
            error "Prompt error. Aborting."; exit 1
          done
          while true; do
            prompt_required WORK_TREE "Deployment target folder (full folder path)" "${WORK_TREE:-$HOME/public_html}"
            rc=$?
            [[ $rc -eq 0 ]] && break
            [[ $rc -eq 1 ]] && continue
            error "Prompt error. Aborting."; exit 1
          done
          if [[ "${HOOK_TYPE:-}" == "Specific branch" ]]; then
            while true; do
              prompt_required BRANCH "Branch to deploy" "${BRANCH:-master}"
              rc=$?
              [[ $rc -eq 0 ]] && break
              [[ $rc -eq 1 ]] && continue
              error "Prompt error. Aborting."; exit 1
            done
          fi
          save_state "$CURRENT_STEP"
          info "Edited and saved. Resuming."
          CURRENT_STEP=$((CURRENT_STEP+1)); break;;
        s|S) clear_state; unset REPO_ROOT WORK_TREE BRANCH HOOK_TYPE; CURRENT_STEP=1; break;;
        *) warn "Enter r (resume), e (edit), or s (start over).";;
      esac
    done
  fi
  if (( CURRENT_STEP <= 1 )); then
    while true; do
      prompt_required REPO_ROOT "Bare repo root folder (full folder path)" "${REPO_ROOT:-$HOME/.gitrepo}"
      rc=$?
      [[ $rc -eq 0 ]] && break
      [[ $rc -eq 1 ]] && continue
      error "Prompt error. Aborting."; exit 1
    done
    while true; do
      prompt_required WORK_TREE "Deployment target folder (full folder path)" "${WORK_TREE:-$HOME/public_html}"
      rc=$?
      [[ $rc -eq 0 ]] && break
      [[ $rc -eq 1 ]] && continue
      error "Prompt error. Aborting."; exit 1
    done
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
  printf "Location: %s\n" "$BARE_DIR"
  if [[ -d "$BARE_DIR" ]]; then
    warn "Bare repo exists. Skipping initialization."
  else
    mkdir -p "$BARE_DIR"
    git init --bare "$BARE_DIR"
    success "Initialized bare repo."
  fi
  save_state 2
  UNDO_STACK+=("1")
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
  echo "1) Specific branch"
  echo "2) Any branch"
  echo "3) Any branch & prune others"
  while true; do
    prompt "Choice (1-3) [h for help]: "
    read c
    [[ "$c" == "undo" ]] && { undo_step; continue; }
    case "$c" in
      1) HOOK_TYPE="Specific branch"; break;;
      2) HOOK_TYPE="Any branch"; break;;
      3) HOOK_TYPE="Any branch & prune others"; break;;
      h|H)
        info "Specific branch: Deploys only a named branch (safest for production)."
        info "Any branch: Deploys whatever branch was just pushed."
        info "Any branch & prune: Deploys and deletes all others (NOT FOR PRODUCTION!)."
        ;;
      *) warn "Invalid choice. Enter 1, 2, 3, or h for help.";;
    esac
  done
  case "$HOOK_TYPE" in
    "Specific branch")
      while true; do
        prompt_required BRANCH "Branch to deploy" "${BRANCH:-master}"
        rc=$?
        [[ $rc -eq 0 ]] && break
        [[ $rc -eq 1 ]] && continue
        error "Prompt error. Aborting."; exit 1
      done
      if ! [[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        warn "Branch name invalid. Must match Git conventions."
        select_hook; return
      fi
      if ! git --git-dir="$BARE_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
        warn "Branch '$BRANCH' not found in bare repo. It will be created on first push."
      fi
      HOOK_GENERATOR=gen_hook_specific
      ;;
    "Any branch") HOOK_GENERATOR=gen_hook_any;;
    *) HOOK_GENERATOR=gen_hook_prune;;
  esac
  save_state 3
  UNDO_STACK+=("2")
  CURRENT_STEP=4
}

install_hook() {
  maybe_clear
  step_title 4 5 "Install post-receive hook"
  REPO_ROOT=$(resolve_path "$REPO_ROOT")
  WORK_TREE=$(resolve_path "$WORK_TREE")
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
  HOOK_PATH="$BARE_DIR/hooks/post-receive"
  if [[ -f "$HOOK_PATH" ]]; then
    local backup="$HOOK_PATH.bak.$(date +%Y%m%d%H%M%S)"
    cp "$HOOK_PATH" "$backup"
    warn "Existing hook backed up to $backup"
  fi
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
  save_state 4
  UNDO_STACK+=("3")
  CURRENT_STEP=5
}

print_config_summary() {
  echo -e "${SEPARATOR}"
  echo -e "${BOLD}${UNDER}Configuration Summary${RESET}"
  echo -e "${BOLD}Repo Name:${RESET} $REPO_NAME"
  echo -e "${BOLD}Bare repo folder:${RESET} $REPO_ROOT"
  echo -e "${BOLD}Deployment target:${RESET} $WORK_TREE"
  echo -e "${BOLD}Hook type:${RESET} $HOOK_TYPE"
  [[ -n "${BRANCH:-}" ]] && echo -e "${BOLD}Branch:${RESET} $BRANCH"
  echo -e "${SEPARATOR}"
}

finalize() {
  maybe_clear
  step_title 5 5 "Complete setup"
  print_config_summary
  prompt "${YELLOW}Proceed with installation? (y/n): ${RESET}"
  read conf
  [[ "$conf" == "undo" ]] && { undo_step; finalize; return; }
  [[ "$conf" =~ ^[Yy]$ ]] || { warn "Aborted at confirmation step."; exit 1; }
  REPO_ROOT=$(resolve_path "$REPO_ROOT")
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
  local pathp shortp
  pathp="${BARE_DIR#/}"
  shortp="~/${BARE_DIR#${HOME}/}"
  printf -v FULL_URL "ssh://%s@%s/%s" "$USER_NAME" "$HOST_FQDN" "$pathp"
  printf -v SHORT_URL "ssh://%s@%s/%s" "$USER_NAME" "$HOST_FQDN" "$shortp"
  echo ""
  success "Setup complete! 🚀"
  echo -e "${CYAN}Add remote (for copy/paste):\n${RESET}git remote add production\t$FULL_URL"
  echo -e "${CYAN}Or shorthand:\n${RESET}git remote add production\t$SHORT_URL"
  echo -e "${CYAN}Deploy via:\n${RESET}git push production ${BRANCH:-<branch>}"
  echo -e "${CYAN}Docs:\n${RESET}https://github.com/Ogooga/Deployster"
  clear_state
}

# --- MAIN EXECUTION ENTRYPOINT ---
banner
sys_check
configure
prepare_repo
select_hook
install_hook
finalize
