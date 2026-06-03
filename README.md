# github-backup

![github-backup logo](github-backup.png)

A pair of Bash scripts that snapshot every GitHub repository owned by an account, compress them into a dated archive, and restore them — in full — with an interactive menu-driven interface.

## Scripts

| Script | Purpose |
|--------|---------|
| `github-backup.sh` | Clone all repos as bare mirrors and archive them |
| `github-restore.sh` | Interactive menu to restore repos from any archive |

---

## github-backup.sh

### Features

- Clones all owned repos as **bare mirrors** — captures every branch, tag, and ref
- Paginates the GitHub API so accounts with more than 100 repos are fully covered
- Archives to a single `github-backup-<USER>-<DATE>.tar.gz` per run
- Automatically deletes archives older than **90 days**
- Appends a timestamped log to `backup.log` in the backup directory
- Skips failed clones and reports a summary rather than aborting

### Requirements

- `git`
- `curl`
- A GitHub **Personal Access Token** with the `repo` scope  
  _(Settings → Developer settings → Personal access tokens)_

### Usage

```bash
export GITHUB_USER="your-username"
export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
./github-backup.sh
```

Archives are written to `~/github-backups/` by default.

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `GITHUB_USER` | _(required)_ | GitHub account to back up |
| `GITHUB_TOKEN` | _(required)_ | Personal access token (`repo` scope) |
| `BACKUP_ROOT` | `~/github-backups` | Directory where archives are stored |

### Archive layout

```
~/github-backups/
├── github-backup-myuser-2026-06-03.tar.gz
├── github-backup-myuser-2026-06-02.tar.gz
│   ...
└── backup.log
```

Each `.tar.gz` contains one `<reponame>.git` bare directory per repository.

### Automate with cron

Run daily at 2 AM:

```
0 2 * * * GITHUB_USER=myuser GITHUB_TOKEN=ghp_xxx /path/to/github-backup.sh
```

---

## github-restore.sh

An interactive, menu-driven wizard that walks you through restoring repositories from any backup archive.

### Features

- **5-step wizard** — credentials → archive → repo selection → options → review & run
- **Three restore modes**
  - `push` — re-create repos on GitHub and push all branches, tags, and refs
  - `local` — extract bare mirrors to disk only (no GitHub writes)
  - `both` — push to GitHub and save mirrors locally
- **Selective restore** — toggle individual repos on/off inside the menu
- **Dry-run mode** — preview every action without changing anything
- **Force-push** — overwrite existing remote repos when needed
- Colour-coded output and a timestamped log file per run

### Requirements

- `git`
- `curl`
- `tar`
- A GitHub **Personal Access Token** with the `repo` scope (for `push` / `both` modes)

### Usage

```bash
export GITHUB_USER="your-username"
export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
./github-restore.sh
```

The script opens an interactive menu — no flags required.

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `GITHUB_USER` | _(required for push)_ | GitHub account to restore into |
| `GITHUB_TOKEN` | _(required for push)_ | Personal access token (`repo` scope) |
| `BACKUP_ROOT` | `~/github-backups` | Directory scanned for available archives |
| `RESTORE_ROOT` | `~/github-restores` | Working directory for extraction and local mirrors |

### Menu walkthrough

```
  ┌─────────────────────────────────────────┐
  │        GitHub Backup — Restore          │
  └─────────────────────────────────────────┘

  Archive     : github-backup-myuser-2026-06-03.tar.gz
  GitHub User : myuser
  Token       : set
  Mode        : Push to GitHub only
  Force-push  : no
  Dry-run     : no
  Repos       : All repos

  [1] Set credentials
  [2] Select archive
  [3] Select repositories
  [4] Set options
  [5] Review & run restore
  [q] Quit
```

**Step 1 — Credentials:** Enter or confirm your GitHub username and token.  
**Step 2 — Archive:** Choose from a dated list of available backups.  
**Step 3 — Repositories:** Toggle individual repos on/off, or restore all.  
**Step 4 — Options:** Set restore mode, force-push, and dry-run.  
**Step 5 — Review & Run:** Full summary before any changes are made.

---

## Quick-start: backup then restore

```bash
# 1. Back up all your repos
export GITHUB_USER="myuser"
export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
./github-backup.sh

# 2. Restore interactively
./github-restore.sh
```

---

## License

MIT
