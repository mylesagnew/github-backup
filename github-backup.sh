#!/usr/bin/env bash
# github-backup.sh — mirror all owned GitHub repos into a timestamped archive
# https://github.com/mylesagnew/github-backup
set -euo pipefail

# ── Locate lib dir ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# ── Configuration (overridable via env) ───────────────────────────────────────
GITHUB_USER="${GITHUB_USER:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/github-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-90}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
ALLOW_PARTIAL_BACKUP="${ALLOW_PARTIAL_BACKUP:-false}"

TIMESTAMP=$(date +%Y-%m-%dT%H%M%S)
ARCHIVE_NAME="github-backup-${GITHUB_USER}-${TIMESTAMP}.tar.gz"
WORK_DIR="$(mktemp -d)"
LOG_FILE="${BACKUP_ROOT}/backup.log"

# ── Bootstrap logging before lib is loaded ────────────────────────────────────
# (lib/ui.sh requires LOG_FILE; BACKUP_ROOT may not exist yet — use /tmp first)
_BOOTSTRAP_LOG=$(mktemp)
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$_BOOTSTRAP_LOG"; }
die() { log "ERROR: $*"; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ -z "$GITHUB_USER" ]]  && die "GITHUB_USER is not set"
[[ -z "$GITHUB_TOKEN" ]] && die "GITHUB_TOKEN is not set"

[[ "$GITHUB_USER" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "Invalid GITHUB_USER — expected alphanumeric, hyphens, dots, or underscores"
[[ "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]] \
  || die "PARALLEL_JOBS must be a positive integer (got: '${PARALLEL_JOBS}')"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] \
  || die "RETENTION_DAYS must be a non-negative integer (got: '${RETENTION_DAYS}')"

for cmd in git curl jq tar; do
  command -v "$cmd" >/dev/null 2>&1 || die "'${cmd}' is required but not installed"
done

mkdir -p "$BACKUP_ROOT"

# Redirect real log file now that BACKUP_ROOT exists; re-define log()
cat "$_BOOTSTRAP_LOG" >> "$LOG_FILE"; rm -f "$_BOOTSTRAP_LOG"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ── Load shared library ───────────────────────────────────────────────────────
[[ -d "$LIB_DIR" ]] || die "lib/ directory not found at ${LIB_DIR}"
# shellcheck source=lib/ui.sh
source "${LIB_DIR}/ui.sh"
# shellcheck source=lib/github_api.sh
source "${LIB_DIR}/github_api.sh"

# ── Auth setup ────────────────────────────────────────────────────────────────
setup_github_auth
trap 'cleanup_github_auth; rm -rf "$WORK_DIR"' EXIT

log "──────────────────────────────────────────────────"
log "Starting backup for: ${GITHUB_USER}"
log "Archive : ${BACKUP_ROOT}/${ARCHIVE_NAME}"
log "Workers : ${PARALLEL_JOBS}"

# ── Fetch all owned repos — store full_name<TAB>clone_url pairs ───────────────
# Using full_name (e.g. "myorg/repo") ensures org-owned repos clone from the
# correct namespace, not incorrectly from GITHUB_USER/repo.
fetch_repos() {
  local page=1 per_page=100
  while true; do
    local response
    response=$(github_get \
      "https://api.github.com/user/repos?affiliation=owner&per_page=${per_page}&page=${page}")

    jq -r '.[] | [.full_name, .clone_url] | @tsv' <<<"$response"

    local count
    count=$(jq 'length' <<<"$response")
    (( count < per_page )) && break
    (( page++ ))
  done
}

mapfile -t REPO_LINES < <(fetch_repos)
TOTAL=${#REPO_LINES[@]}
[[ $TOTAL -eq 0 ]] && die "No repositories found (check credentials and affiliation)"
log "Found ${TOTAL} repositories"

# ── Clone each repo as a bare mirror (parallel) ───────────────────────────────
# GIT_CONFIG_GLOBAL (set by setup_github_auth) supplies the Authorization header
# so the token never appears in any process's argv.
#
# Safe archive name: owner/repo → owner__repo.git
# (forward slash replaced by double-underscore to stay filesystem-safe)
clone_repo() {
  local tsv_line="$1"
  local full_name clone_url safe_name
  full_name=$(cut -f1 <<<"$tsv_line")
  clone_url=$(cut -f2 <<<"$tsv_line")
  safe_name="${full_name//\//__}"

  local dest="${WORK_DIR}/${safe_name}.git"
  local flag="${WORK_DIR}/.fail.${safe_name}"

  if git clone --mirror --quiet "$clone_url" "$dest" 2>>"$LOG_FILE"; then
    log "  ✓ ${full_name}"
  else
    log "  ✗ ${full_name} — clone failed"
    touch "$flag"
  fi
}

export -f clone_repo
export WORK_DIR LOG_FILE   # GIT_CONFIG_GLOBAL already exported by setup_github_auth

log "Cloning ${TOTAL} repos (${PARALLEL_JOBS} parallel workers) ..."
printf '%s\n' "${REPO_LINES[@]}" \
  | xargs -P "$PARALLEL_JOBS" -I{} bash -c 'clone_repo "$@"' _ {}

# ── Count failures ────────────────────────────────────────────────────────────
FAILED=0
FAIL_NAMES=()
while IFS= read -r -d '' flag; do
  name=$(basename "$flag" | sed 's/^\.fail\.//')
  FAIL_NAMES+=("$name")
  (( FAILED++ )) || true
done < <(find "$WORK_DIR" -maxdepth 1 -name '.fail.*' -print0 2>/dev/null)

log "Clone phase complete — failed: ${FAILED}/${TOTAL}"
[[ ${#FAIL_NAMES[@]} -gt 0 ]] && log "  Failed: ${FAIL_NAMES[*]}"

# ── Partial backup gate ───────────────────────────────────────────────────────
if (( FAILED > 0 )) && [[ "$ALLOW_PARTIAL_BACKUP" != "true" ]]; then
  die "${FAILED}/${TOTAL} repos failed to clone. " \
      "Set ALLOW_PARTIAL_BACKUP=true to archive the partial result anyway."
fi

# ── Create archive ────────────────────────────────────────────────────────────
ARCHIVE_PATH="${BACKUP_ROOT}/${ARCHIVE_NAME}"
log "Creating archive ${ARCHIVE_NAME} ..."
tar -czf "$ARCHIVE_PATH" -C "$WORK_DIR" \
  --exclude='.fail.*' \
  .
ARCHIVE_SIZE=$(du -sh "$ARCHIVE_PATH" | cut -f1)
log "Archive created: ${ARCHIVE_PATH} (${ARCHIVE_SIZE})"

# ── Checksum ──────────────────────────────────────────────────────────────────
CHECKSUM_FILE="${ARCHIVE_PATH}.sha256"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ARCHIVE_PATH" > "$CHECKSUM_FILE"
elif command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$ARCHIVE_PATH" > "$CHECKSUM_FILE"
fi
[[ -f "$CHECKSUM_FILE" ]] && log "Checksum written: ${CHECKSUM_FILE}"

# ── Prune old archives ────────────────────────────────────────────────────────
log "Pruning archives older than ${RETENTION_DAYS} days ..."
find "$BACKUP_ROOT" -maxdepth 1 \
  \( -name "github-backup-*.tar.gz" -o -name "github-backup-*.tar.gz.sha256" \) \
  -mtime "+${RETENTION_DAYS}" -print -delete 2>>"$LOG_FILE" \
  | while IFS= read -r f; do log "  Deleted: ${f}"; done

# ── Summary ───────────────────────────────────────────────────────────────────
log "Backup complete — repos: ${TOTAL}, failed: ${FAILED}, size: ${ARCHIVE_SIZE}"
log "Current archives:"
find "$BACKUP_ROOT" -maxdepth 1 -name "github-backup-*.tar.gz" | sort -r | \
  while IFS= read -r f; do
    sz=$(du -sh "$f" 2>/dev/null | cut -f1)
    log "  ${sz}  $(basename "$f")"
  done
