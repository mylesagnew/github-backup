#!/usr/bin/env bash
# lib/github_api.sh — GitHub REST API, credential management, and Git auth
#
# Token handling:
#   curl  — reads Authorization header from a chmod-600 temp file via -H @file,
#           so the token never appears in process argv or shell history.
#   git   — GIT_CONFIG_GLOBAL is pointed at a chmod-600 temp config file that
#           sets http.extraheader. This avoids -c "...=Bearer TOKEN" in argv.
#
# Call setup_github_auth() once after credentials are known.
# Register cleanup_github_auth in the script's EXIT trap.

_GITHUB_HEADER_FILE=""
_GIT_CONFIG_FILE=""

setup_github_auth() {
  # curl header file: one header per line
  _GITHUB_HEADER_FILE=$(mktemp)
  chmod 600 "$_GITHUB_HEADER_FILE"
  printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$_GITHUB_HEADER_FILE"

  # git config file: sets http.extraheader for github.com
  _GIT_CONFIG_FILE=$(mktemp)
  chmod 600 "$_GIT_CONFIG_FILE"
  printf '[http "https://github.com/"]\n\textraheader = Authorization: Bearer %s\n' \
    "$GITHUB_TOKEN" > "$_GIT_CONFIG_FILE"

  export GIT_CONFIG_GLOBAL="$_GIT_CONFIG_FILE"
  export _GITHUB_HEADER_FILE
}

cleanup_github_auth() {
  rm -f "$_GITHUB_HEADER_FILE" "$_GIT_CONFIG_FILE"
  unset GIT_CONFIG_GLOBAL _GITHUB_HEADER_FILE _GIT_CONFIG_FILE
}

# ── Internal: shared curl base args ──────────────────────────────────────────
_curl_auth() {
  curl -s -w "\n%{http_code}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H @"$_GITHUB_HEADER_FILE" \
    "$@"
}

# ── Rate-limit sleep ──────────────────────────────────────────────────────────
_ratelimit_sleep() {
  local url="$1"
  local reset
  reset=$(curl -sI \
    -H @"$_GITHUB_HEADER_FILE" \
    "$url" | grep -i x-ratelimit-reset | awk '{print $2}' | tr -d '\r')
  local wait=$(( reset - $(date +%s) + 5 ))
  if [[ "$wait" -gt 0 && "$wait" -lt 3600 ]]; then
    warn "Rate-limited; waiting ${wait}s"
    sleep "$wait"
  else
    sleep 60
  fi
}

# ── GET with retry — used by both backup and restore ─────────────────────────
github_get() {
  local url="$1" attempt

  for attempt in 1 2 3; do
    local raw http_code body
    raw=$(_curl_auth "$url")
    http_code=$(tail -1 <<<"$raw")
    body=$(sed '$d' <<<"$raw")

    case "$http_code" in
      200) printf '%s' "$body"; return 0 ;;
      401) die "GitHub API: authentication failed — check GITHUB_TOKEN" ;;
      403) _ratelimit_sleep "$url" ;;
      404) return 1 ;;
      *)   warn "API HTTP ${http_code} on attempt ${attempt}/3; retrying in 5s"; sleep 5 ;;
    esac
  done
  die "GitHub API GET failed after 3 attempts: $url"
}

# ── POST/PATCH/DELETE ─────────────────────────────────────────────────────────
github_api() {
  local method="$1" path="$2" data="${3:-}"
  local url="https://api.github.com/${path}"
  local attempt

  for attempt in 1 2 3; do
    local extra_args=()
    [[ -n "$data" ]] && extra_args+=(-H "Content-Type: application/json" -d "$data")

    local raw http_code body
    raw=$(curl -s -w "\n%{http_code}" \
      -X "$method" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H @"$_GITHUB_HEADER_FILE" \
      "${extra_args[@]}" \
      "$url")
    http_code=$(tail -1 <<<"$raw")
    body=$(sed '$d' <<<"$raw")

    case "$http_code" in
      200|201) printf '%s' "$body"; return 0 ;;
      401) die "GitHub API: authentication failed — check GITHUB_TOKEN" ;;
      403) warn "Rate-limited (attempt ${attempt}/3)"; sleep 60 ;;
      404) return 1 ;;
      *)   warn "API HTTP ${http_code} on attempt ${attempt}/3; retrying in 5s"; sleep 5 ;;
    esac
  done
  die "GitHub API ${method} ${path} failed after 3 attempts"
}

# ── Restore-specific helpers ──────────────────────────────────────────────────

repo_exists_on_github() {
  local repo="$1"
  github_api GET "repos/${GITHUB_USER}/${repo}" 2>/dev/null \
    | jq -e '.full_name' >/dev/null 2>&1
}

create_github_repo() {
  local repo="$1"
  info "Creating GitHub repo: ${GITHUB_USER}/${repo}"
  if $DRY_RUN; then warn "[DRY-RUN] skipped create"; return; fi
  local payload
  payload=$(jq -n --arg name "$repo" \
    '{name: $name, private: true, auto_init: false}')
  github_api POST "user/repos" "$payload" > /dev/null \
    || die "Failed to create repo ${repo} on GitHub"
}

# Push all refs from a bare mirror.
# GIT_CONFIG_GLOBAL (set by setup_github_auth) supplies credentials without
# placing the token in the git process's argv.
push_mirror() {
  local repo="$1" repo_dir="$2" target_owner="${3:-$GITHUB_USER}"
  local remote_url="https://github.com/${target_owner}/${repo}.git"
  info "Pushing all refs for ${repo} ..."
  if $DRY_RUN; then
    warn "[DRY-RUN] would: git push --mirror ${remote_url}"
    return 0
  fi
  git -C "$repo_dir" push --mirror "$remote_url" 2>>"$LOG_FILE" \
    && return 0 || return 1
}
