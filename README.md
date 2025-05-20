# Push-to-Deploy Setup Script

This Bash script automates initializing a bare Git repository on your target server, configuring a `post-receive` hook for automated deployments, and prints local Git commands for easy setup. It supports resuming an interrupted setup.

## Prerequisites

- A user account with SSH access to the server (e.g., cPanel user).
- Git installed on the server.
- SSH key already added/authorized in your cPanel **SSH Access**.

## Usage

1. Upload the script (`setup_push_deploy.sh`) to your server and make it executable:

```bash
chmod +x setup_push_deploy.sh
```
2. Run it:

```bash
./setup_push_deploy.sh
```
3. Follow the interactive prompts to:

- Specify a repository name.
- Choose or resume your setup progress.
- Define the bare repo path (~/.gitrepo/<repo>.git by default).
- Select a deployment strategy (specific branch, any branch, any branch + prune).
- Confirm and create the bare repo, install the hook, and finalize.

4. Upon completion, copy one of the suggested git remote add commands into your local project, then deploy with:

```bash
git push production <branch>
```

## Features

- **Automatic resume**: Detects partial setups and lets you continue or restart.
- **Multi-repo state**: Tracks progress for multiple repositories in one state file.
- **Robust input validation**: Enforces required inputs and valid menu selections.
- **CRLF stripping**: Ensures post-receive hooks run without DOS line-ending issues.
- **Safe defaults**: Uses sensible defaults for paths, with absolute-path normalization.

## Advanced

- To clear saved progress for a repo:
```bash
# simply delete or edit ~/.push_deploy_state
```
- You can customize the default repo root and web root inside the script.