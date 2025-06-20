#!/usr/bin/env bash

# Deployster: Push-to-Deploy Git Setup Script (run on target server as cPanel user or any Linux user)
# All state and log files are stored in ~/.deployster/

set -uo pipefail
IFS=$'\n\t'
OLD_IFS=$IFS

# --- SETUP WORKDIR FOR STATE AND LOG FILES ---
DEPLOYSTER_DIR="$HOME/.deployster"
if [[ -e "$DEPLOYSTER_DIR" && ! -d "$DEPLOYSTER_DIR" ]]; then
  echo "ERROR: $DEPLOYSTER_DIR exists and is not a directory. Please remove or rename it."
  exit 1
fi
mkdir -p "$DEPLOYSTER_DIR"

VERBOSE=0
LOG_TO_FILE=0
LOG_FILE="$DEPLOYSTER_DIR/deployster_setup_$(date +%Y%m%d_%H%M%S).log"
STATE_FILE="$DEPLOYSTER_DIR/state"

# --- LOGGING: DEFINE FIRST! ---
log_ts() {
  local level="$1"
  shift
  local now
  now=$(date '+%Y-%m-%d %H:%M:%S')
  if [[ "$level" == "ERROR" ]]; then
    echo -e "$now [$level] $*" >&2
  else
    echo -e "$now [$level] $*"
  fi
}
log_info()    { log_ts "INFO" "$@"; }
log_warn()    { log_ts "WARN" "$@"; }
log_error()   { log_ts "ERROR" "$@"; }
log_success() { log_ts "OK" "$@"; }

# --- ARGUMENT PARSING ---
print_help() {
  cat <<EOF
Usage: $0 [-v|--verbose] [--log] [-h|--help]
Options:
  -v, --verbose      Enable verbose debug output
      --log          Log all script output to a file (implies non-verbose)
  -h, --help         Show this help message and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift ;;
    --log) LOG_TO_FILE=1; VERBOSE=0; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) print_help; exit 1 ;;
  esac
done

# --- COLORS AND UI HELPERS (disable for log file/non-tty) ---
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

USE_COLOR=1
if (( LOG_TO_FILE )) || ! [[ -t 1 ]]; then
  USE_COLOR=0
fi
if (( ! USE_COLOR )); then
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; UNDER=''; RESET=''
  SEPARATOR="============================================================"
  CHECK="✔"
  CROSS="❌"
  WARN_EMOJI="⚠"
  PROGRESS_BAR=(
    "[#    ]"
    "[##   ]"
    "[###  ]"
    "[#### ]"
    "[#####]"
  )
fi

# --- LOGGING SETUP ---
if (( LOG_TO_FILE )); then
  exec > >(tee "$LOG_FILE") 2>&1
  log_info "Logging to $LOG_FILE"
fi

# --- STANDARD ECHO HELPERS (COLOR TO TTY ONLY) ---
info()    { echo -e "${CYAN}$*${RESET}"; }
warn()    { echo -e "${YELLOW}$*${RESET}"; }
error()   { echo -e "${RED}$*${RESET}" >&2; }
success() { echo -e "${GREEN}$*${RESET}"; }
prompt()  { echo -en "${BOLD}$*${RESET}"; }

CURRENT_STEP=1
UNDO_STACK=()
REDO_STACK=()
USER_NAME="${USER:-$(whoami)}"
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"

# --- Banner and UI functions ---
banner() {
  echo -e "$SEPARATOR"
  echo -e "${BOLD}${CYAN}            Deployster Setup Wizard         ${RESET}"
  echo -e "$SEPARATOR"
  echo -e "${RESET}Automates bare Git repo and post-receive hook setup."
  echo
}
maybe_clear() {
  if (( VERBOSE )); then
    return
  fi
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
    clear
  fi
}
step_title() {
  local n=$1 total=$2 msg=$3
  local idx=$((n-1))
  local bar="${PROGRESS_BAR[$idx]}"
  echo -e "$bar ${BOLD}${CYAN}Step $n/$total:${RESET} $msg"
  echo -e "$SEPARATOR"
}

# --- ENVIRONMENT AND DEPENDENCY CHECKS ---
sys_check() {
  echo -e "$SEPARATOR"
  if (( LOG_TO_FILE )); then
    log_info "Environment checks"
  else
    info "${BOLD}${UNDER}Environment checks${RESET}"
  fi
  if [[ $EUID -eq 0 ]]; then
    # Uncomment below to hard-abort if run as root (optional)
    # log_error "Running as root is not supported for safety. Abort."; exit 1
    if (( LOG_TO_FILE )); then
      log_warn "It is not recommended to run this as root. Proceed with caution."
    else
      warn "${WARN_EMOJI} It is not recommended to run this as root. Proceed with caution."
    fi
    sleep 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    if (( LOG_TO_FILE )); then log_error "git is not installed! Aborting."; else error "${CROSS} git is not installed! Aborting."; fi
    exit 1
  fi
  if ! command -v ssh >/dev/null 2>&1; then
    if (( LOG_TO_FILE )); then log_error "ssh is not installed! Aborting."; else error "${CROSS} ssh is not installed! Aborting."; fi
    exit 1
  fi
  gitver=$(git --version | awk '{print $3}')
  if [[ "$gitver" < "2.11" ]]; then
    if (( LOG_TO_FILE )); then
      log_warn "Git version is quite old ($gitver); upgrade is recommended."
    else
      warn "${WARN_EMOJI} Git version is quite old ($gitver); upgrade is recommended."
    fi
  fi
}

# --- INTERRUPT/CLEANUP HANDLER ---
INTERRUPTED=0
trap_handler() {
  INTERRUPTED=1
  echo
  if (( LOG_TO_FILE )); then
    log_warn "Interrupt received (Ctrl+C)."
  else
    warn "${WARN_EMOJI} Interrupt received (Ctrl+C)."
  fi
  if [[ -n "${REPO_NAME:-}" && -f "$STATE_FILE" && $(grep -c "^${REPO_NAME}:" "$STATE_FILE" 2>/dev/null || echo 0) -gt 0 ]]; then
    while true; do
      prompt "${YELLOW}Save partial progress and exit (s), discard and cleanup (c), or continue (r)? [s/c/r]: ${RESET}"
      read choice || { log_error "Input stream closed. Exiting."; exit 1; }
      case "$choice" in
        s|S) log_info "Partial progress saved. You can resume later."; exit 130;;
        c|C) clear_state; log_info "State cleared. Exiting."; exit 130;;
        r|R) log_info "Continuing..."; return;;
        *) log_warn "Enter s, c, or r.";;
      esac
    done
  else
    log_info "Exiting (no saved state to clean)."
    exit 130
  fi
}
trap trap_handler SIGINT

resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null || realpath -m "$1" 2>/dev/null || echo "$1"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f "$1" 2>/dev/null || echo "$1"
  else
    echo "$1"
  fi
}

save_state() {
  local step=$1 tmp
  tmp=$(mktemp --tmpdir)
  grep -v -F "${REPO_NAME}:" "$STATE_FILE" >"$tmp" 2>/dev/null || :
  echo "${REPO_NAME}:step=${step}:REPO_ROOT=${REPO_ROOT:-}:WORK_TREE=${WORK_TREE:-}:BRANCH=${BRANCH:-}:HOOK_TYPE=${HOOK_TYPE:-}" >>"$tmp"
  mv "$tmp" "$STATE_FILE"
  log_info "Saved state $step for $REPO_NAME"
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
  log_info "Restored state for $REPO_NAME: step=$CURRENT_STEP, REPO_ROOT=$REPO_ROOT, WORK_TREE=$WORK_TREE, BRANCH=${BRANCH:-}, HOOK_TYPE=${HOOK_TYPE:-}"
}
clear_state() {
  local tmp
  tmp=$(mktemp --tmpdir)
  grep -v -F "${REPO_NAME}:" "$STATE_FILE" >"$tmp" 2>/dev/null || :
  mv "$tmp" "$STATE_FILE"
  log_info "Cleared state for $REPO_NAME"
}

undo_step() {
  if [[ ${#UNDO_STACK[@]} -gt 0 ]]; then
    local prev_step="${UNDO_STACK[-1]}"
    unset 'UNDO_STACK[-1]'
    CURRENT_STEP="$prev_step"
    log_warn "Went back to previous step ($CURRENT_STEP)."
  else
    log_warn "No previous step to undo."
  fi
}

prompt_required() {
  local var_name="$1" prompt_text="$2" default="$3" input prompt_line
  while true; do
    if [[ -n "$default" ]]; then
      prompt_line="${BOLD}${prompt_text}${RESET} [${CYAN}${default}${RESET}]: "
    else
      prompt_line="${BOLD}${prompt_text}${RESET}: "
    fi
    echo -ne "$prompt_line"
    read -e input || { log_error "Input stream closed. Exiting."; exit 1; }
    [[ "$input" == "undo" ]] && { undo_step; return 1; }
    # Repo name safety check
    if [[ "$var_name" == "REPO_NAME" ]] && ! [[ "$input" =~ ^[A-Za-z0-9._-]+$ ]]; then
      log_warn "Repository name contains invalid characters. Only letters, digits, dot, underscore, and hyphen allowed."
      continue
    fi
    if [[ -n "$default" && -z "$input" ]]; then input="$default"; fi
    if [[ -z "$input" ]]; then
      log_warn "This value is required."
      continue
    fi
    printf -v "$var_name" "%s" "$input"
    log_info "$var_name set to ${!var_name}"
    return 0
  done
}

gen_hook_specific() {
  cat <<EOF
#!/bin/sh

# Define the Git work tree path
GIT_WORK_TREE="$WORK_TREE"

# Ensure deployment folder exists
mkdir -p "\$GIT_WORK_TREE"

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

# Ensure deployment folder exists
mkdir -p "\$GIT_WORK_TREE"

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

# Ensure deployment folder exists
mkdir -p "\$GIT_WORK_TREE"

while read old new ref; do
  branch=\$(GIT_WORK_TREE="\$GIT_WORK_TREE" git rev-parse --symbolic --abbrev-ref "\$ref")
  GIT_WORK_TREE="\$GIT_WORK_TREE" git checkout -f "\$branch"
  git branch | grep -v "\$branch" | xargs git branch -D
done
EOF
}

configure() {
  step_title 1 5 "Repository configuration"
  while ! prompt_required REPO_NAME "Repository name (without .git)" "myproject"; do :; done
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
      read res || { log_error "Input stream closed. Exiting."; exit 1; }
      [[ "$res" == "undo" ]] && { undo_step; return; }
      case "$res" in
        r|R) log_info "Resuming from saved state."; CURRENT_STEP=$((CURRENT_STEP+1)); break;;
        e|E)
          while ! prompt_required REPO_ROOT "Bare repo root folder (full folder path)" "${REPO_ROOT:-$HOME/.gitrepo}"; do :; done
          while ! prompt_required WORK_TREE "Deployment target folder (full folder path)" "${WORK_TREE:-$HOME/public_html}"; do :; done
          [[ "${HOOK_TYPE:-}" == "Specific branch" ]] && while ! prompt_required BRANCH "Branch to deploy" "${BRANCH:-master}"; do :; done
          save_state "$CURRENT_STEP"
          log_info "Edited and saved. Resuming."
          CURRENT_STEP=$((CURRENT_STEP+1)); break;;
        s|S) clear_state; unset REPO_ROOT WORK_TREE BRANCH HOOK_TYPE; CURRENT_STEP=1; break;;
        *) log_warn "Enter r (resume), e (edit), or s (start over).";;
      esac
    done
  fi
  if (( CURRENT_STEP <= 1 )); then
    while ! prompt_required REPO_ROOT "Bare repo root folder (full folder path)" "${REPO_ROOT:-$HOME/.gitrepo}"; do :; done
    while ! prompt_required WORK_TREE "Deployment target folder (full folder path)" "${WORK_TREE:-$HOME/public_html}"; do :; done
    save_state 1
    CURRENT_STEP=2
  fi
}

prepare_repo() {
  maybe_clear
  step_title 2 5 "Prepare bare repository"
  REPO_ROOT=$(resolve_path "$REPO_ROOT")
  WORK_TREE=$(resolve_path "$WORK_TREE")
  log_info "Resolved REPO_ROOT to $REPO_ROOT, WORK_TREE to $WORK_TREE"
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
  [[ "$BARE_DIR" == "/" ]] && { log_error "BARE_DIR cannot be '/'."; exit 1; }
  printf "Location: %s\n" "$BARE_DIR"
  if [[ -d "$BARE_DIR" ]]; then
    log_warn "Bare repo exists. Skipping initialization."
  else
    mkdir -p "$BARE_DIR"
    git init --bare "$BARE_DIR"
    log_success "Initialized bare repo."
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
    read c || { log_error "Input stream closed. Exiting."; exit 1; }
    [[ "$c" == "undo" ]] && { undo_step; return; }
    case "$c" in
      1) HOOK_TYPE="Specific branch"; break;;
      2) HOOK_TYPE="Any branch"; break;;
      3) HOOK_TYPE="Any branch & prune others"; break;;
      h|H)
        info "Specific branch: Deploys only a named branch (safest for production)."
        info "Any branch: Deploys whatever branch was just pushed."
        info "Any branch & prune: Deploys and deletes all others (NOT FOR PRODUCTION!)."
        ;;
      *) log_warn "Invalid choice. Enter 1, 2, 3, or h for help.";;
    esac
  done
  case "$HOOK_TYPE" in
    "Specific branch")
      while ! prompt_required BRANCH "Branch to deploy" "${BRANCH:-master}"; do :; done
      if ! [[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        log_warn "Branch name invalid. Must match Git conventions."
        select_hook; return
      fi
      if ! git --git-dir="$BARE_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
        log_warn "Branch '$BRANCH' not found in bare repo. It will be created on first push."
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
    log_warn "Existing hook backed up to $backup"
  fi
  # Generate hook to a temporary file first
  tmp_hook=$(mktemp)
  $HOOK_GENERATOR > "$tmp_hook" || { log_error "Failed to generate hook."; rm -f "$tmp_hook"; exit 1; }
  cat "$tmp_hook" > "$HOOK_PATH"
  rm -f "$tmp_hook"
  if command -v dos2unix >/dev/null 2>&1; then
    dos2unix "$HOOK_PATH" >/dev/null
  else
    tr -d '\r' < "$HOOK_PATH" > "$HOOK_PATH.tmp" && mv "$HOOK_PATH.tmp" "$HOOK_PATH"
  fi
  if ! chmod 755 "$HOOK_PATH"; then
    log_error "Could not set executable permissions for $HOOK_PATH"
    exit 1
  fi
  owner=$(stat -c %U "$HOOK_PATH")
  if [[ "$owner" != "$USER_NAME" ]]; then
    log_warn "$HOOK_PATH is not owned by $USER_NAME. Ownership: $owner"
  fi
  log_success "Hook installed at $HOOK_PATH"
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
  read conf || { log_error "Input stream closed. Exiting."; exit 1; }
  [[ "$conf" == "undo" ]] && { undo_step; return; }
  [[ "$conf" =~ ^[Yy]$ ]] || { log_warn "Aborted at confirmation step."; exit 1; }
  REPO_ROOT=$(resolve_path "$REPO_ROOT")
  BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
  local pathp shortp
  pathp="${BARE_DIR#/}"
  shortp="~/${BARE_DIR#${HOME}/}"
  printf -v FULL_URL "ssh://%s@%s/%s" "$USER_NAME" "$HOST_FQDN" "$pathp"
  printf -v SHORT_URL "ssh://%s@%s/%s" "$USER_NAME" "$HOST_FQDN" "$shortp"
  echo ""
  log_success "Setup complete! 🚀"
  echo -e "${CYAN}Add remote (for copy/paste):\n${RESET}git remote add production\t$FULL_URL"
  echo -e "${CYAN}Or shorthand:\n${RESET}git remote add production\t$SHORT_URL"
  echo -e "${CYAN}Deploy via:\n${RESET}git push production ${BRANCH:-<branch>}"
  echo -e "${CYAN}Docs:\n${RESET}https://github.com/Ogooga/Deployster"
  clear_state
}

banner
sys_check
configure
prepare_repo
select_hook
install_hook
finalize
