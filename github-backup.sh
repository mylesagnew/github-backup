#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
GITHUB_USER="${GITHUB_USER:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/github-backups}"
RETENTION_DAYS=90
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)
ARCHIVE_NAME="github-backup-${GITHUB_USER}-${DATE}.tar.gz"
WORK_DIR="$(mktemp -d)"
LOG_FILE="${BACKUP_ROOT}/backup.log"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[${TIMESTAMP}] $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# ── Preflight checks ──────────────────────────────────────────────────────────
[[ -z "$GITHUB_USER" ]]  && die "GITHUB_USER is not set. Export it or set it at the top of this script."
[[ -z "$GITHUB_TOKEN" ]] && die "GITHUB_TOKEN is not set. Export it or set it at the top of this script."
command -v git  >/dev/null 2>&1 || die "git is not installed"
command -v curl >/dev/null 2>&1 || die "curl is not installed"

mkdir -p "$BACKUP_ROOT"
log "──────────────────────────────────────────"
log "Starting backup for GitHub account: ${GITHUB_USER}"
log "Archive : ${BACKUP_ROOT}/${ARCHIVE_NAME}"
log "Work dir: ${WORK_DIR}"

# ── Fetch all repo clone URLs (handles pagination) ───────────────────────────
fetch_repos() {
    local page=1
    local per_page=100
    local urls=()

    while true; do
        local response
        response=$(curl -sf \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/user/repos?affiliation=owner&per_page=${per_page}&page=${page}")

        local batch
        batch=$(echo "$response" | grep -o '"clone_url": *"[^"]*"' | awk -F'"' '{print $4}')

        [[ -z "$batch" ]] && break
        mapfile -t -O "${#urls[@]}" urls < <(echo "$batch")

        # Stop if fewer results than a full page
        local count
        count=$(echo "$batch" | wc -l)
        (( count < per_page )) && break
        (( page++ ))
    done

    printf '%s\n' "${urls[@]}"
}

mapfile -t REPOS < <(fetch_repos)
TOTAL=${#REPOS[@]}
[[ $TOTAL -eq 0 ]] && die "No repositories found (check credentials and account name)"
log "Found ${TOTAL} repositories"

# ── Clone each repo as a bare mirror ─────────────────────────────────────────
FAILED=0
for url in "${REPOS[@]}"; do
    # Embed token in URL for auth; extract repo name for the directory
    auth_url="${url/https:\/\//https://${GITHUB_TOKEN}@}"
    repo_name=$(basename "$url" .git)

    log "  Cloning ${repo_name} ..."
    if git clone --mirror --quiet "$auth_url" "${WORK_DIR}/${repo_name}.git" 2>>"$LOG_FILE"; then
        log "  ✓ ${repo_name}"
    else
        log "  ✗ ${repo_name} — clone failed (skipping)"
        (( FAILED++ )) || true
    fi
done

log "Clone phase complete. Failed: ${FAILED}/${TOTAL}"

# ── Create compressed archive ────────────────────────────────────────────────
log "Creating archive ${ARCHIVE_NAME} ..."
tar -czf "${BACKUP_ROOT}/${ARCHIVE_NAME}" -C "$WORK_DIR" .
ARCHIVE_SIZE=$(du -sh "${BACKUP_ROOT}/${ARCHIVE_NAME}" | cut -f1)
log "Archive created: ${BACKUP_ROOT}/${ARCHIVE_NAME} (${ARCHIVE_SIZE})"

# ── Prune archives older than RETENTION_DAYS ─────────────────────────────────
log "Pruning archives older than ${RETENTION_DAYS} days ..."
find "$BACKUP_ROOT" \
    -maxdepth 1 \
    -name "github-backup-*.tar.gz" \
    -mtime "+${RETENTION_DAYS}" \
    -print \
    -delete \
    2>>"$LOG_FILE" | while read -r f; do
        log "  Deleted old archive: $f"
    done

# ── Summary ───────────────────────────────────────────────────────────────────
log "Backup complete. Repos: ${TOTAL}, Failed: ${FAILED}, Archive: ${ARCHIVE_SIZE}"
log "Current archives in ${BACKUP_ROOT}:"
ls -lh "${BACKUP_ROOT}"/github-backup-*.tar.gz 2>/dev/null | tee -a "$LOG_FILE" || true
