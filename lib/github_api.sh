#!/usr/bin/env bash
# lib/github_api.sh — GitHub REST API helpers
# Requires: GITHUB_USER, GITHUB_TOKEN, LOG_FILE, and ui.sh functions.
# Token is NEVER embedded in URLs — always sent via Authorization header
# or git's http.extraheader config key to stay out of process lists and logs.

# ── Raw API call with retry ───────────────────────────────────────────────────
# Usage: github_api METHOD path [json-body]
# Returns response body on stdout; dies on unrecoverable errors.
github_api() {
  local method="$1" path="$2" data="${3:-}"
  local url="https://api.github.com/${path}"
  local attempt

  for attempt in 1 2 3; do
    local args=(-s -w "\n%{http_code}"
      -X "$method"
      -H "Authorization: Bearer ${GITHUB_TOKEN}"
      -H "Accept: application/vnd.github+json"
      -H "X-GitHub-Api-Version: 2022-11-28")
    [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")

    local raw; raw=$(curl "${args[@]}" "$url")
    local http_code; http_code=$(tail -1 <<<"$raw")
    local body;      body=$(sed '$d'   <<<"$raw")

    case "$http_code" in
      200|201) echo "$body"; return 0 ;;
      401) die "GitHub API: authentication failed — check GITHUB_TOKEN" ;;
      403)
        # Check for rate-limit reset header
        local reset
        reset=$(curl -sI \
          -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          "$url" | grep -i x-ratelimit-reset | awk '{print $2}' | tr -d '\r')
        local wait=$(( reset - $(date +%s) + 5 ))
        if [[ $wait -gt 0 && $wait -lt 3600 ]]; then
          warn "Rate-limited; waiting ${wait}s before retry"
          sleep "$wait"
        else
          sleep 60
        fi
        ;;
      404) return 1 ;;   # caller checks existence; not fatal
      *)
        warn "API HTTP ${http_code} on attempt ${attempt}/3; retrying in 5s"
        sleep 5
        ;;
    esac
  done
  die "GitHub API failed after 3 attempts: ${method} ${path}"
}

# ── Convenience wrappers ──────────────────────────────────────────────────────
repo_exists_on_github() {
  local repo="$1"
  github_api GET "repos/${GITHUB_USER}/${repo}" 2>/dev/null \
    | jq -e '.full_name' >/dev/null 2>&1
}

create_github_repo() {
  local repo="$1"
  info "Creating GitHub repo: ${GITHUB_USER}/${repo}"
  if $DRY_RUN; then warn "[DRY-RUN] skipped create"; return; fi
  github_api POST "user/repos" \
    "{\"name\":\"${repo}\",\"private\":true,\"auto_init\":false}" \
    > /dev/null || die "Failed to create repo ${repo} on GitHub"
}

# Push all refs from a bare mirror back to GitHub.
# Token is passed via git's http.extraheader — not in the remote URL.
push_mirror() {
  local repo="$1" repo_dir="$2"
  local remote_url="https://github.com/${GITHUB_USER}/${repo}.git"
  info "Pushing all refs for ${repo} ..."
  if $DRY_RUN; then
    warn "[DRY-RUN] would: git push --mirror ${remote_url}"
    return 0
  fi
  git -C "$repo_dir" \
    -c "http.https://github.com/.extraheader=Authorization: Bearer ${GITHUB_TOKEN}" \
    push --mirror "$remote_url" 2>>"$LOG_FILE" \
    && return 0 || return 1
}
