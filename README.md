# github-backup

![github-backup logo](github-backup.png)

A Bash script that snapshots every GitHub repository owned by an account, compresses them into a dated archive, and automatically rotates archives older than 90 days.

## Features

- Clones all owned repos as **bare mirrors** — captures every branch, tag, and ref
- Paginates the GitHub API so accounts with more than 100 repos are fully covered
- Archives to a single `github-backup-<USER>-<DATE>.tar.gz` per run
- Automatically deletes archives older than **90 days**
- Appends a timestamped log to `backup.log` in the backup directory
- Skips failed clones and reports a summary rather than aborting

## Requirements

- `git`
- `curl`
- A GitHub **Personal Access Token** with the `repo` scope  
  _(Settings → Developer settings → Personal access tokens)_

## Usage

```bash
export GITHUB_USER="your-username"
export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
./github-backup.sh
```

Archives are written to `~/github-backups/` by default.

## Configuration

All options are controlled via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `GITHUB_USER` | _(required)_ | GitHub account to back up |
| `GITHUB_TOKEN` | _(required)_ | Personal access token (`repo` scope) |
| `BACKUP_ROOT` | `~/github-backups` | Directory where archives are stored |

## Archive layout

```
~/github-backups/
├── github-backup-myuser-2026-06-03.tar.gz
├── github-backup-myuser-2026-06-02.tar.gz
│   ...
└── backup.log
```

Each `.tar.gz` contains one `<reponame>.git` bare directory per repository.

## Restore a repository

```bash
# Extract one repo from an archive
tar -xzf github-backup-myuser-2026-06-03.tar.gz ./myrepo.git

# Clone it to a normal working copy
git clone myrepo.git my-restored-repo
```

## Automate with cron

Run daily at 2 AM:

```bash
crontab -e
```

```
0 2 * * * GITHUB_USER=myuser GITHUB_TOKEN=ghp_xxx /path/to/github-backup.sh
```

## License

MIT
