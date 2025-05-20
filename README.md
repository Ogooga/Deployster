# Push-to-Deploy Setup Script

This Bash script automates initializing a bare Git repository on your target server, configuring a `post-receive` hook for automated deployments, and prints local Git commands for easy setup. It supports resuming an interrupted setup.

## Prerequisites

- A user account with SSH access to the server (e.g., cPanel user).
- Git installed on the server.
- Either **`realpath`** or **`readlink -f`** installed for path normalization.
- SSH key already added/authorized in your cPanel **SSH Access**.

## Usage

```bash
chmod +x setup_push_deploy.sh
./setup_push_deploy.sh [-v] [-h]
```

- `-v`: enable verbose (debug) output
- `-h`: show this help message and exit

Follow the interactive prompts to:

1. Specify a repository name.
2. Choose to resume or restart a previous partial setup.
3. Define the bare repo path (`~/.gitrepo/<repo>.git` by default).
4. Select a deployment strategy:
   - Specific branch (with sanity-check warning if the branch doesn’t yet exist)
   - Any branch
   - Any branch + prune others
5. Confirm and create the bare repo, install the hook, and finalize.

Upon completion, copy one of the suggested `git remote add` commands into your local project:

```bash
git remote add production ssh://user@host/~/.gitrepo/<repo>.git
# or the home-shorthand form:
git remote add production ssh://user@host/~/\.gitrepo/<repo>.git
```

Then deploy with:

```bash
git push production <branch>
```

## Features

- **Automatic resume**: Detects partial setups and lets you continue or restart.
- **Multi-repo state**: Tracks progress for multiple repositories in one state file.
- **Verbose logging (`-v`)**: See debug output to troubleshoot.
- **Branch validation**: Warns if your chosen branch doesn’t yet exist in the bare repo.
- **Robust input validation**: Enforces required inputs and valid menu selections.
- **CRLF stripping**: Ensures `post-receive` hooks run without DOS line-ending issues.
- **Safe defaults**: Uses sensible defaults for paths, with absolute-path normalization via `realpath`/`readlink`.

## Advanced

- Clear saved progress for a repo by editing or deleting the state file:

```bash
sed -i '/^myrepo:/d' ~/.push_deploy_state
```

- Customize default repo root and web root by editing the DEFAULT_REPO_ROOT and DEFAULT_WEB_ROOT variables at the top of the script.