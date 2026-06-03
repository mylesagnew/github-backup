# github-backup

![github-backup logo](github-backup.png)

[![ShellCheck & Bats](https://github.com/mylesagnew/github-backup/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/mylesagnew/github-backup/actions/workflows/shellcheck.yml)

A pair of Bash scripts that snapshot every GitHub repository owned by an account, compress them into a timestamped archive, and restore them — in full — with an interactive menu-driven interface.

## Repository layout

```
├── github-backup.sh       # backup entrypoint
├── github-restore.sh      # restore entrypoint (sources lib/)
├── lib/
│   ├── ui.sh              # colours, logging, prompts, menus
│   ├── github_api.sh      # REST API calls, push_mirror (no token in URLs)
│   ├── archive.sh         # validation, checksum, extraction, copy_mirror
│   └── restore_engine.sh  # core restore loop and filter logic
└── tests/
    ├── helpers.bash        # shared Bats setup and archive fixtures
    ├── archive_listing.bats
    ├── archive_validation.bats
    ├── repo_filtering.bats
    └── dry_run.bats
```

---

## github-backup.sh

### Features

- Clones all owned repos as **bare mirrors** — captures every branch, tag, and ref
- Paginates the GitHub API so accounts with more than 100 repos are fully covered
- Archives named `github-backup-<USER>-<TIMESTAMP>.tar.gz` — unique per run, never overwrites
- Writes a matching `<archive>.sha256` checksum file alongside each backup
- Parallel cloning via `xargs -P` (default 4 workers, configurable)
- Automatically deletes archives and checksums older than **90 days**
- GitHub API retry loop with rate-limit backoff (`x-ratelimit-reset`)
- Token passed via `http.extraheader` — **never embedded in remote URLs**
- JSON parsing via `jq` — immune to field-ordering or escaping edge cases

### Requirements

- `git`, `curl`, `jq`, `tar`
- A GitHub **fine-grained Personal Access Token** with **read-only** `Contents` and `Metadata` repository permissions  
  _(Settings → Developer settings → Personal access tokens → Fine-grained tokens)_

### Credential setup

Store credentials in a restricted file — do not put them inline in shell history or cron:

```bash
# Create a credentials file readable only by your user
cat > ~/.github-backup.env <<'EOF'
export GITHUB_USER="your-username"
export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
EOF
chmod 600 ~/.github-backup.env
```

Then source it before running:

```bash
source ~/.github-backup.env
./github-backup.sh
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `GITHUB_USER` | _(required)_ | GitHub account to back up |
| `GITHUB_TOKEN` | _(required)_ | Personal access token |
| `BACKUP_ROOT` | `~/github-backups` | Directory where archives are stored |
| `RETENTION_DAYS` | `90` | Days before archives are pruned |
| `PARALLEL_JOBS` | `4` | Concurrent clone workers |

### Archive layout

```
~/github-backups/
├── github-backup-myuser-2026-06-03T020001.tar.gz
├── github-backup-myuser-2026-06-03T020001.tar.gz.sha256
├── github-backup-myuser-2026-06-02T020001.tar.gz
│   ...
└── backup.log
```

Each `.tar.gz` contains one `<reponame>.git` bare directory per repository.

### Automate with cron

Load credentials from the restricted env file — never put the token inline in crontab:

```
0 2 * * * source ~/.github-backup.env && /path/to/github-backup.sh
```

---

## github-restore.sh

An interactive, menu-driven wizard that walks you through restoring repositories from any backup archive.

### Features

- **5-step wizard** — credentials → archive → repo selection → options → review & run
- **Archive safety** — validates all paths before extraction (blocks `../` traversal and absolute paths), verifies sha256 checksum when present
- **Three restore modes**
  - `push` — re-create repos on GitHub and push all branches, tags, and refs
  - `local` — extract bare mirrors to disk only (no GitHub writes)
  - `both` — push to GitHub and save mirrors locally
- **Selective restore** — toggle individual repos on/off inside the menu
- **Dry-run mode** — preview every action without changing anything
- **Force-push** — overwrite existing remote repos when needed
- `rsync --delete` for local copies (idempotent; won't partially merge an existing dir)
- Token passed via `http.extraheader` — never embedded in remote URLs
- Colour-coded output and a timestamped log file per run

### Requirements

- `git`, `curl`, `tar`, `jq`
- A GitHub **Personal Access Token** with `repo` scope (for `push` / `both` modes)

### Credential setup

```bash
source ~/.github-backup.env   # same file as backup
./github-restore.sh
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `GITHUB_USER` | _(required for push)_ | GitHub account to restore into |
| `GITHUB_TOKEN` | _(required for push)_ | Personal access token |
| `BACKUP_ROOT` | `~/github-backups` | Directory scanned for available archives |
| `RESTORE_ROOT` | `~/github-restores` | Working directory for extraction and local mirrors |

### Menu walkthrough

```
  ┌─────────────────────────────────────────┐
  │        GitHub Backup — Restore          │
  └─────────────────────────────────────────┘

  Archive     : github-backup-myuser-2026-06-03T020001.tar.gz  [✔ sha256]
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
**Step 2 — Archive:** Choose from a dated list; verified archives show `[✔ sha256]`.  
**Step 3 — Repositories:** Toggle individual repos on/off, or restore all.  
**Step 4 — Options:** Set restore mode, force-push, and dry-run.  
**Step 5 — Review & Run:** Full summary before any changes are made.

---

## Quick-start

```bash
# Store credentials securely (one-time setup)
cat > ~/.github-backup.env <<'EOF'
export GITHUB_USER="myuser"
export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
EOF
chmod 600 ~/.github-backup.env

# Back up
source ~/.github-backup.env && ./github-backup.sh

# Restore interactively
source ~/.github-backup.env && ./github-restore.sh
```

---

## Development

### Linting

```bash
shellcheck github-backup.sh github-restore.sh lib/*.sh
```

### Tests

```bash
# Install Bats (macOS)
brew install bats-core

# Install Bats (Debian/Ubuntu)
sudo apt-get install bats

# Run suite
bats tests/
```

CI runs ShellCheck and the full Bats suite on every push and pull request.

---

## License

MIT
