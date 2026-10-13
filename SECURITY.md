# Security Policy

## Supported versions

Only the latest commit on `main` receives fixes.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through GitHub's
[private vulnerability reporting](https://github.com/mylesagnew/github-backup/security/advisories/new).
Include the affected script, steps to reproduce, and the impact you observed.
You can expect an acknowledgement within 5 business days.

## In scope

- Token exposure (argv, logs, temp files, archives)
- Archive extraction issues (path traversal, symlink / hard-link escapes)
- Checksum verification bypass
- Restore writing to an unintended owner, org, or repository

## Out of scope

- Data GitHub does not expose through `git clone --mirror` (issues, PRs,
  releases, Actions secrets); see the **Scope** note in the README
- Compromise of the host running the scripts

## Hardening guidance

See [Security notes](README.md#security-notes) in the README. In short: use a
fine-grained, read-only token for backups, keep credential files at `chmod 600`,
and store archives on encrypted, access-controlled storage. Archives contain
the full history of every repository, including private ones.
