#!/usr/bin/env bash
# github-backup.sh — mirror all owned GitHub repos into a dated archive
# https://github.com/mylesagnew/github-backup
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
GITHUB_USER="${GITHUB_USER:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/github-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-90}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"   # concurrent clone workers

# Timestamp granularity prevents same-day overwrites
TIMESTAMP=$(date +%Y-%m-%dT%H%M%S)
ARCHIVE_NAME="github-backup-${GITHUB_USER}-${TIMESTAMP}.tar.gz"
WORK_DIR="$(mktemp -d)"
LOG_FILE="${BACKUP_ROOT}/backup.log"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die()  { log "ERROR: $*"; exit 1; }
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ -z "$GITHUB_USER" ]]  && die "GITHUB_USER is not set"
[[ -z "$GITHUB_TOKEN" ]] && die "GITHUB_TOKEN is not set"
for cmd in git curl jq tar; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed"
done

mkdir -p "$BACKUP_ROOT"
log "──────────────────────────────────────────────────"
log "Starting backup for: ${GITHUB_USER}"
log "Archive : ${BACKUP_ROOT}/${ARCHIVE_NAME}"

# ── GitHub API with retry ──────────────────────────────────────────────────────
# Never embed $GITHUB_TOKEN in URLs — use an Authorization header only.
github_get() {
  local url="$1" attempt
  for attempt in 1 2 3; do
    local http_code body
    body=$(curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url")
    http_code=$(tail -1 <<<"$body")
    body=$(sed '$d' <<<"$body")

    case "$http_code" in
      200) echo "$body"; return 0 ;;
      401) die "GitHub API: authentication failed (check GITHUB_TOKEN)" ;;
      403)
        local reset; reset=$(curl -sI \
          -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          "$url" | grep -i x-ratelimit-reset | awk '{print $2}' | tr -d '\r')
        local wait=$(( reset - $(date +%s) + 5 ))
        [[ $wait -gt 0 && $wait -lt 3600 ]] && { log "Rate-limited; sleeping ${wait}s"; sleep "$wait"; } || sleep 60
        ;;
      404) die "GitHub API: not found — check GITHUB_USER" ;;
      *)   log "API returned HTTP ${http_code} (attempt ${attempt}/3); retrying in 5s"; sleep 5 ;;
    esac
  done
  die "GitHub API failed after 3 attempts: $url"
}

# ── Fetch all owned repo names (paginated) ────────────────────────────────────
fetch_repos() {
  local page=1 per_page=100
  while true; do
    local response
    response=$(github_get \
      "https://api.github.com/user/repos?affiliation=owner&per_page=${per_page}&page=${page}")

    local batch
    batch=$(jq -r '.[].name' <<<"$response")
    [[ -z "$batch" ]] && break

    echo "$batch"

    local count; count=$(jq 'length' <<<"$response")
    (( count < per_page )) && break
    (( page++ ))
  done
}

mapfile -t REPOS < <(fetch_repos)
TOTAL=${#REPOS[@]}
[[ $TOTAL -eq 0 ]] && die "No repositories found (check credentials)"
log "Found ${TOTAL} repositories"

# ── Clone repos in parallel ───────────────────────────────────────────────────
FAILED=0
FAIL_NAMES=()

# Worker: clone one repo; writes a flag file on failure so the parent can count
clone_repo() {
  local repo_name="$1"
  local clone_url="https://github.com/${GITHUB_USER}/${repo_name}.git"
  local dest="${WORK_DIR}/${repo_name}.git"
  local flag_file="${WORK_DIR}/.fail.${repo_name}"

  # Token passed via http.extraheader — never visible in process list or URLs
  if git clone --mirror --quiet \
      -c "http.https://github.com/.extraheader=Authorization: Bearer ${GITHUB_TOKEN}" \
      "$clone_url" "$dest" 2>>"$LOG_FILE"; then
    log "  ✓ ${repo_name}"
  else
    log "  ✗ ${repo_name} — clone failed"
    touch "$flag_file"
  fi
}

export -f clone_repo
export GITHUB_USER GITHUB_TOKEN WORK_DIR LOG_FILE

log "Cloning ${TOTAL} repos (${PARALLEL_JOBS} parallel workers) ..."

# Use xargs for portable parallelism (GNU parallel not required)
printf '%s\n' "${REPOS[@]}" \
  | xargs -P "$PARALLEL_JOBS" -I{} bash -c 'clone_repo "$@"' _ {}

# Count failures via flag files
while IFS= read -r -d '' flag; do
  repo=$(basename "$flag" | sed 's/^\.fail\.//')
  FAIL_NAMES+=("$repo")
  (( FAILED++ )) || true
done < <(find "$WORK_DIR" -maxdepth 1 -name '.fail.*' -print0 2>/dev/null)

log "Clone phase complete — failed: ${FAILED}/${TOTAL}"
[[ ${#FAIL_NAMES[@]} -gt 0 ]] && log "  Failed repos: ${FAIL_NAMES[*]}"

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
  | while read -r f; do log "  Deleted: $f"; done

# ── Summary ───────────────────────────────────────────────────────────────────
log "Backup complete — repos: ${TOTAL}, failed: ${FAILED}, size: ${ARCHIVE_SIZE}"
log "Current archives in ${BACKUP_ROOT}:"
ls -lh "${BACKUP_ROOT}"/github-backup-*.tar.gz 2>/dev/null | tee -a "$LOG_FILE" || true
