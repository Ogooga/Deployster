# Deployster: Effortless Push-to-Deploy Git Setup Wizard

*A modern Bash wizard to automate initializing a **bare Git repository** on your target server, set up a secure `post-receive` deployment hook, and provide ready-to-use Git commands for seamless push-to-deploy workflows. Deployster works with cPanel or any modern Linux system with SSH access.*

---

## Features

* **Interactive stepper UI:** Clean, colored, user-friendly prompts with progress indicators.
* **Automatic resume:** Detects incomplete setups and lets you resume, edit, or start over.
* **Undo at each step:** Type `undo` at most prompts to go back to the previous step.
* **Multi-repo state:** Tracks setup progress for multiple repositories.
* **Robust input validation:** Checks branch names, paths, permissions, and prevents unsafe destinations.
* **Modern logging:** Verbose and/or file-based logs, with easy troubleshooting.
* **Automatic backup:** Any existing Git hooks are automatically backed up before overwrite.
* **Inline help:** Type `h` at menus for context-sensitive help.
* **CRLF stripping:** Ensures hooks are safe from DOS line endings.
* **Environment checks:** Fails early with clear messages if required tools or permissions are missing.
* **Clean separation:** All config/state/log files are kept in `~/.deployster/`.
* **Recovery on interrupt:** Ctrl+C lets you save or discard partial progress.
* **No root required:** Warns against running as root, and validates user permissions.

---

## Requirements

* **Linux server** (cPanel or non-cPanel) with:

  * Bash 4.x+
  * Git 2.11+
  * SSH access (with authorized public key)
  * Either `realpath` or `readlink -f` (for robust path handling)
* Local Git client on your workstation
* (Recommended) `dos2unix` for line-ending safety

> **Note:** You must have your SSH public key added/authorized for your shell user before you can push code. You do *not* need it to run the Deployster wizard itself.

---

## Install

1. **Download** the script to your server (as the user you want to deploy as):

   ```bash
   wget https://raw.githubusercontent.com/Ogooga/Deployster/master/deployster.sh
   chmod +x deployster.sh
   ```

2. **(Optional):** Copy to a folder in your PATH (e.g. `~/bin/`)

---

## Usage

```bash
./deployster.sh [-v|--verbose] [--log] [-h|--help]
```

* `-v, --verbose`    Enable verbose (debug) output
* `--log`            Log output to a file in `~/.deployster/` (disables verbose on-screen debug)
* `-h, --help`       Show usage and exit

### Guided Workflow

The wizard will prompt you step-by-step:

1. **Repository name** (used for folder names and tracking)
2. **Resume/edit/start over** if previous state detected
3. **Bare repo path** (default: `~/.gitrepo/<name>.git`)
4. **Deploy target** (absolute path to your project folder)
5. **Deployment strategy**:

   * 1: **Specific branch** (recommended for production)
   * 2: Any branch (for dev/test)
   * 3: Any branch + prune (experimental, not for production)
6. **Review summary and confirm**
7. **Hook install & finish** (existing hooks are backed up automatically)

### Example

```bash
$ ./deployster.sh
```

* Answer prompts (use Enter for defaults, or type `undo` to go back)
* At completion, copy/paste the `git remote add` command to your local workstation:

  ```bash
  git remote add production ssh://user@host/~/.gitrepo/myproject.git
  ```
* Deploy with:

  ```bash
  git push production master
  ```

---

## Options & Commands

* **Undo:** At any prompt, type `undo` to go back a step
* **Help:** At main menus, type `h` for context-sensitive info
* **Verbose:** Use `-v` for debug output
* **Log:** Use `--log` to save a session log in `~/.deployster/`
* **Resume:** If interrupted, script will offer to resume or edit previous setup
* **Edit:** When resuming, you may interactively edit paths/branch before continuing
* **Safe confirmation:** Always see a summary before the final install
* **Backups:** Previous hooks are backed up with a timestamped `.bak` extension
* **Ctrl+C Handling:** On interrupt, choose to save, discard, or continue the setup

---

## Limitations & Security

* **Must NOT be run as root.** Script will warn and continue, but best practice is per-user setup.
* **Absolute paths required** for repo and deploy folder.
* **Do NOT use `/` as a destination.** The script checks for this and will abort.
* **SSH key must be authorized** for your user before pushing code.
* **Only tested on bash 4.x+**. Should work on most Linux distros. MacOS not officially supported (due to BSD differences in some commands).
* **Default branch is `master`.**

---

## Advanced / Troubleshooting

* **Clear saved state:**

  ```bash
  sed -i '/^myproject:/d' ~/.deployster/state
  ```
* **Logs:**
  All logs are saved in `~/.deployster/` if you use `--log`.
* **Manual override:**
  You can safely edit/delete files in `~/.deployster/` if troubleshooting.
* **State file format:**
  One line per repo, with colon-separated `key=value` pairs.
* **Repo root/web root:**
  You can edit these interactively, or override defaults at setup.
* **See the installed hook:**
  After setup, review/edit the generated `post-receive` file in your bare repo's `hooks/` folder.

---

## Contribution Guidelines

* **Bug reports, issues, and pull requests are welcome** on [GitHub](https://github.com/Ogooga/Deployster).
* Please:

  * Open clear issues for feature requests, bugs, or docs.
  * Follow the code style and UX conventions in the script.
  * Test thoroughly on non-production systems before PRs.
  * Add comments and keep prompts clear!

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

## Credits

Made by Ogooga ([https://ogooga.com](https://ogooga.com)) with ❤️ for sysadmins, developers, and teams everywhere.

For documentation, issues, and latest releases: [https://github.com/Ogooga/Deployster](https://github.com/Ogooga/Deployster)
