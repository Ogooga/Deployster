#!/usr/bin/env bash

# push-to-deploy setup script (run on target server as cPanel user)
# Initializes a bare Git repo, configures post-receive hook, and outputs deployment instructions.
# Supports resuming after failures or interruptions.

# Prevent word splitting on spaces in filenames or inputs
OLD_IFS=$IFS
IFS=$'\n\t'
set -euo pipefail

# Ensure IFS restored on any exit
trap 'IFS=$OLD_IFS' EXIT

# Initialize current step
CURRENT_STEP=1

# Pre-flight checks
if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git is not installed or not in PATH. Please install Git and retry." >&2
  exit 1
fi

# State file path (single file, multi-repo)
STATE_FILE="$HOME/.push_deploy_state"
if [[ ! -e "$STATE_FILE" ]]; then
  touch "$STATE_FILE" 2>/dev/null || {
    echo "ERROR: Cannot write to state file $STATE_FILE. Check directory permissions." >&2
    exit 1
  }
fi

# Helper to read saved step for a repo (fixed-string grep)
get_saved_step() {
  grep -F "${REPO_NAME}:" "$STATE_FILE" | cut -d: -f2
}

# Helper to save state: update or append "repo:step"
save_state() {
  local step=$1 tmp
  tmp=$(mktemp "${STATE_FILE}.tmp.XXXX")
  grep -v -F "${REPO_NAME}:" "$STATE_FILE" > "$tmp"
  echo "${REPO_NAME}:${step}" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
}

# Helper to clear state for a repo
clear_state() {
  local tmp
  tmp=$(mktemp "${STATE_FILE}.tmp.XXXX")
  grep -v -F "${REPO_NAME}:" "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

# 1. Gather parameters
echo; printf "=== Step 1: Configuration ===\n"
DEFAULT_REPO_ROOT="$HOME/.gitrepo"
DEFAULT_WEB_ROOT="$HOME/public_html"
DEFAULT_BRANCH="main"
HOST_FQDN="$(hostname -f)"
USER_NAME="$USER"

prompt() {
  local var_name="$1" prompt_text="$2" default_value="$3" input
  while true; do
    if [[ -n "$default_value" ]]; then
      read -p "$prompt_text [$default_value]: " input
      input="${input:-$default_value}"; break
    else
      read -p "$prompt_text: " input
      [[ -n "$input" ]] && break || echo "This value is required."
    fi
  done
  printf -v "$var_name" "%s" "$input"
}

# Repo name first for resume logic
prompt REPO_NAME "Repository name (without .git)" "myproject"
# Check saved state
SAVED_STEP=$(get_saved_step)
if [[ -n "$SAVED_STEP" ]]; then
  while true; do
    read -p "Resume '${REPO_NAME}' from step $((SAVED_STEP+1))? (y/n): " ans
    case "$ans" in [Yy]) CURRENT_STEP=$((SAVED_STEP+1)); break;;
               [Nn]) clear_state; CURRENT_STEP=1; break;;
               *) echo "Enter y or n.";;
    esac
  done
fi

# Continue with prompts
if (( CURRENT_STEP <= 1 )); then
  prompt REPO_ROOT "Bare repo root folder" "$DEFAULT_REPO_ROOT"
  prompt WORK_TREE "Deployment target folder" "$DEFAULT_WEB_ROOT"
  save_state 1; CURRENT_STEP=2
fi

# Validate and normalize paths
if command -v realpath >/dev/null 2>&1; then
  REPO_ROOT=$(realpath -m "$REPO_ROOT")
  WORK_TREE=$(realpath -m "$WORK_TREE")
else
  [[ "$REPO_ROOT" != /* ]] && REPO_ROOT="$HOME/$REPO_ROOT"
  [[ "$WORK_TREE" != /* ]] && WORK_TREE="$HOME/$WORK_TREE"
fi
BARE_DIR="$REPO_ROOT/${REPO_NAME}.git"
[[ "$BARE_DIR" == "/" ]] && { echo "ERROR: BARE_DIR cannot be '/'." >&2; exit 1; }

# 2. Prepare bare repository
if (( CURRENT_STEP <= 2 )); then
  echo; printf "=== Step 2: Prepare bare repository ===\n"
  printf "Location: %s\n" "$BARE_DIR"
  if [[ -d "$BARE_DIR" ]]; then
    echo "Exists, skipping."
  else
    mkdir -p "$BARE_DIR"
    git init --bare "$BARE_DIR"
    echo "Initialized."
  fi
  save_state 2; CURRENT_STEP=3
fi

# 3. Choose and build post-receive hook
if (( CURRENT_STEP <= 3 )); then
  echo; printf "=== Step 3: Select hook type ===\n"
  options=("Specific branch" "Any branch" "Any branch & delete others")
  for i in "${!options[@]}"; do printf "%d) %s\n" $((i+1)) "${options[i]}"; done
  while true; do
    read -p "Choice (1-${#options[@]}): " c
    ((c>=1&&c<=${#options[@]})) && break || echo "Invalid."
  done; HOOK_TYPE="${options[c-1]}"

  case "$HOOK_TYPE" in
    "Specific branch")
      prompt BRANCH "Branch to deploy" "$DEFAULT_BRANCH"
      HOOK_SCRIPT=$(cat <<EOF
#!/bin/sh
while read old new ref; do
  [[ "\$ref" = "refs/heads/$BRANCH" ]] && git --work-tree="$WORK_TREE" checkout -f "$BRANCH"
done
EOF
)
      ;;
    "Any branch")
      HOOK_SCRIPT=$(cat <<EOF
#!/bin/sh
while read old new ref; do
  branch=\$(git rev-parse --abbrev-ref "\$ref")
  git --work-tree="$WORK_TREE" checkout -f "\$branch"
done
EOF
)
      ;;
    "Any branch & delete others")
      HOOK_SCRIPT=$(cat <<EOF
#!/bin/sh
echo "WARNING: deletes other branches"
[[ -d "refs/heads" ]] || { echo "No refs/heads" >&2; exit 1; }
while read old new ref; do
  branch=\$(git rev-parse --abbrev-ref "\$ref")
  git --work-tree="$WORK_TREE" checkout -f "\$branch"
  git for-each-ref --format="%(refname:short)" refs/heads | while IFS= read -r head; do
    [[ "\$head" != "\$branch" ]] && git update-ref -d "refs/heads/\$head"
  done
done
EOF
)
      ;;
  esac
  save_state 3; CURRENT_STEP=4
fi

# 4. Install post-receive hook
if (( CURRENT_STEP <= 4 )); then
  echo; printf "=== Step 4: Install hook ===\n"
  HOOK_PATH="$BARE_DIR/hooks/post-receive"
  mkdir -p "$(dirname "$HOOK_PATH")"
  printf "%s\n" "$HOOK_SCRIPT" > "$HOOK_PATH"
  chmod +x "$HOOK_PATH"
  # strip CRLF
  if command -v dos2unix &>/dev/null; then
    dos2unix "$HOOK_PATH" &>/dev/null
  else
    sed -i 's/\r$//' "$HOOK_PATH"
  fi
  echo "Hook installed."
  save_state 4; CURRENT_STEP=5
fi

# 5. Final instructions
if (( CURRENT_STEP <= 5 )); then
  echo; printf "=== Step 5: Complete ===\n"
  # Build URL components safely
  PATH_PART="${BARE_DIR#/}"
  printf -v FULL_URL "ssh://%s@%s/%s" "$USER_NAME" "$HOST_FQDN" "$PATH_PART"
  # Home-based shorthand
  SHORT_PART="~/${BARE_DIR#${HOME}/}"
  printf -v SHORTHAND_URL "ssh://%s@%s/%s" "$USER_NAME" "$HOST_FQDN" "$SHORT_PART"

  echo "git remote add production $FULL_URL"
  echo "or"
  echo "git remote add production $SHORTHAND_URL"
  echo "git push production ${BRANCH:-<branch>}"
  clear_state
fi
