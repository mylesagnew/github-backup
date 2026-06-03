# github-backup

![github-backup logo](github-backup.png)

[![ShellCheck & Bats](https://github.com/mylesagnew/github-backup/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/mylesagnew/github-backup/actions/workflows/shellcheck.yml)

A pair of Bash scripts that snapshot every GitHub repository owned by an account — including org repos — compress them into a timestamped, checksummed archive, and restore them with an interactive menu-driven wizard.

> **Scope:** these scripts back up and restore Git history only (branches, tags, refs). They do not capture issues, pull requests, releases, Actions workflows, branch protection rules, collaborators, secrets, or other GitHub metadata.

---

## Repository layout

```
├── github-backup.sh          # backup entrypoint
├── github-restore.sh         # restore entrypoint (sources lib/)
├── lib/
│   ├── ui.sh                 # colours, logging, prompts, menus
│   ├── github_api.sh         # REST API, credential helpers, push_mirror
│   ├── archive.sh            # validation, checksum, extraction, copy_mirror
│   └── restore_engine.sh     # core restore loop and filter logic
└── tests/
    ├── helpers.bash           # shared Bats setup and archive fixtures
    ├── archive_listing.bats
    ├── archive_validation.bats
    ├── repo_filtering.bats
    └── dry_run.bats
```

---

## github-backup.sh

### Features

- Clones all owned repos as **bare mirrors** — every branch, tag, and ref
- Handles **org repos** correctly — clones from the repo's actual owner namespace, not `GITHUB_USER`
- Paginates the GitHub API to cover accounts with more than 100 repos
- Archive names include a full timestamp (`github-backup-<USER>-<YYYYMMDDTHHmmSS>.tar.gz`) — unique per run, no same-day overwrites
- Writes a matching `.sha256` checksum file alongside every archive
- **Parallel cloning** via `xargs -P` (default 4 workers, configurable)
- Automatically prunes archives and checksums older than 90 days
- GitHub API retry loop with rate-limit backoff (reads `x-ratelimit-reset`)
- **Token never in argv** — `curl` reads auth from a `chmod 600` header file; `git` reads from a `chmod 600` config via `GIT_CONFIG_GLOBAL`
- JSON parsed with `jq` — not grep/awk
- Fails if any clone fails unless `ALLOW_PARTIAL_BACKUP=true`

### Requirements

- `git`, `curl`, `jq`, `tar`
- A GitHub **fine-grained Personal Access Token** with read-only `Contents` and `Metadata` repository permissions  
  _(Settings → Developer settings → Personal access tokens → Fine-grained tokens)_

### Credential setup

Store credentials in a restricted file — never inline in shell history or crontab:

```bash
cat > ~/.github-backup.env <<'EOF'
export GITHUB_USER="your-username"
export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
EOF
chmod 600 ~/.github-backup.env
```

### Usage

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
| `RETENTION_DAYS` | `90` | Days before archives and checksums are pruned |
| `PARALLEL_JOBS` | `4` | Concurrent clone workers (positive integer) |
| `ALLOW_PARTIAL_BACKUP` | `false` | Set `true` to archive even when some clones fail |

### Archive layout

```
~/github-backups/
├── github-backup-myuser-2026-06-03T020001.tar.gz
├── github-backup-myuser-2026-06-03T020001.tar.gz.sha256
├── github-backup-myuser-2026-06-02T020001.tar.gz
├── github-backup-myuser-2026-06-02T020001.tar.gz.sha256
│   ...
└── backup.log
```

Each `.tar.gz` contains one bare directory per repository:
- Personal repos: `reponame.git`
- Org repos: `orgname__reponame.git` (forward slash replaced with `__`)

### Automate with cron

Load credentials from the env file — never put the token inline:

```
0 2 * * * bash -c 'source ~/.github-backup.env && /path/to/github-backup.sh'
```

---

## github-restore.sh

An interactive, menu-driven wizard for restoring repositories from any backup archive.

### Features

- **5-step wizard** — credentials → archive → repo selection → options → review & run
- **Archive safety checks** before any extraction:
  - Verifies sha256 checksum (warns if absent, fails on mismatch)
  - Rejects path traversal (`../`), absolute paths, symlinks, and hard links
  - Extracts with `--no-same-owner --no-same-permissions --delay-directory-restore`
- **Three restore modes**
  - `push` — re-create repos on GitHub and push all branches, tags, and refs
  - `local` — extract bare mirrors to disk only (no GitHub writes)
  - `both` — push to GitHub and save mirrors locally
- **Selective restore** — toggle individual repos on/off in a checklist menu
- **Dry-run mode** — enumerates what would happen; no GitHub calls, no filesystem writes
- **Force-push** — overwrite repos that already exist on GitHub
- **Atomic local copies** — mirrors copied via temp dir + rename; interrupted copies cannot corrupt an existing destination
- `rsync --delete` for local copies (idempotent)
- **Token never in argv** — same secure credential handling as the backup script
- Colour-coded output and a timestamped log file per run

### Requirements

- `git`, `curl`, `tar`, `jq`
- `rsync` (recommended; falls back to `cp` if absent)
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

| Step | What it does |
|------|-------------|
| 1 — Credentials | Enter or confirm GitHub username and token |
| 2 — Archive | Pick from a dated list; verified archives show `[✔ sha256]` |
| 3 — Repositories | Toggle repos on/off, or restore all |
| 4 — Options | Set restore mode, force-push, and dry-run |
| 5 — Review & Run | Full settings summary before any changes are made |

---

## Quick-start

```bash
# One-time credential setup
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

## Security notes

| Concern | Mitigation |
|---------|-----------|
| Token in process argv | `curl` reads auth from a `chmod 600` temp file; `git` uses `GIT_CONFIG_GLOBAL` pointing to a `chmod 600` config — neither puts the token in the command line |
| Token in cron | Sourced from a `chmod 600` env file, not written inline |
| Malicious archive | Path traversal, absolute paths, symlinks, and hard links all rejected before extraction |
| Archive tampering | sha256 checksum verified before extraction; mismatch aborts restore |
| Incomplete backup | Script exits non-zero if any clone fails (override with `ALLOW_PARTIAL_BACKUP=true`) |
| Overly broad token | Use a fine-grained read-only token for backup; a narrowly scoped `repo` token for restore |

---

## Development

### Linting

```bash
shellcheck --severity=warning --exclude=SC1091 \
  github-backup.sh github-restore.sh lib/*.sh tests/*.bash
```

### Tests

```bash
# macOS
brew install bats-core git rsync

# Debian / Ubuntu
sudo apt-get install -y bats git rsync

# Run suite
bats --print-output-on-failure tests/
```

CI runs ShellCheck and the full Bats suite on every push and pull request. Actions are pinned to commit SHAs and the workflow uses `permissions: contents: read`.

---

## License

MIT
