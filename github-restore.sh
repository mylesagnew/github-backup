#!/usr/bin/env bash
# github-restore.sh — interactive menu-driven restore for github-backup archives
# Pairs with: https://github.com/mylesagnew/github-backup

set -euo pipefail

# ── Configuration (overridable via env) ───────────────────────────────────────
GITHUB_USER="${GITHUB_USER:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/github-backups}"
RESTORE_ROOT="${RESTORE_ROOT:-$HOME/github-restores}"
mkdir -p "$RESTORE_ROOT"
LOG_FILE="$RESTORE_ROOT/restore-$(date +%Y%m%d-%H%M%S).log"

# ── Runtime state ─────────────────────────────────────────────────────────────
MODE="push"
FORCE=false
DRY_RUN=false
ARCHIVE=""
FILTER_REPOS=()

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD='\033[1m'; DIM='\033[2m'; CYAN='\033[1;36m'; GREEN='\033[1;32m'
  YELLOW='\033[1;33m'; RED='\033[1;31m'; BLUE='\033[1;34m'; RESET='\033[0m'
else
  BOLD=''; DIM=''; CYAN=''; GREEN=''; YELLOW=''; RED=''; BLUE=''; RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info()    { printf "${CYAN}  →  ${RESET}%s\n" "$*"; log "$*"; }
success() { printf "${GREEN}  ✔  ${RESET}%s\n" "$*"; log "$*"; }
warn()    { printf "${YELLOW}  ⚠  ${RESET}%s\n" "$*"; log "WARNING: $*"; }
err()     { printf "${RED}  ✖  ${RESET}%s\n" "$*" >&2; log "ERROR: $*"; }
die()     { err "$*"; exit 1; }

hr()      { printf "${DIM}%s${RESET}\n" "──────────────────────────────────────────────────"; }

prompt()  { printf "${BOLD}${BLUE}?${RESET} ${BOLD}%s${RESET} " "$*"; }

pause()   { read -rp "$(printf "${DIM}  Press Enter to continue...${RESET}")"; }

clear_screen() { printf '\033[2J\033[H'; }

# ── Header banner ─────────────────────────────────────────────────────────────
banner() {
  clear_screen
  printf "${CYAN}${BOLD}"
  cat <<'EOF'
  ┌─────────────────────────────────────────┐
  │        GitHub Backup — Restore          │
  └─────────────────────────────────────────┘
EOF
  printf "${RESET}"
  printf "  ${DIM}Log: %s${RESET}\n\n" "$LOG_FILE"
}

# ── Current settings summary ──────────────────────────────────────────────────
show_settings() {
  local archive_label="${ARCHIVE:-${DIM}(not selected)${RESET}}"
  local user_label="${GITHUB_USER:-${DIM}(not set)${RESET}}"
  local token_label
  [[ -n "$GITHUB_TOKEN" ]] && token_label="${GREEN}set${RESET}" || token_label="${DIM}not set${RESET}"
  local mode_label
  case "$MODE" in
    push)  mode_label="Push to GitHub only" ;;
    local) mode_label="Extract locally only" ;;
    both)  mode_label="Push to GitHub + extract locally" ;;
  esac
  local repos_label
  [[ ${#FILTER_REPOS[@]} -eq 0 ]] && repos_label="All repos" \
    || repos_label="${#FILTER_REPOS[@]} selected: ${FILTER_REPOS[*]}"

  printf "  ${DIM}Archive     :${RESET} %b\n"   "$(basename "$archive_label" 2>/dev/null || echo "$archive_label")"
  printf "  ${DIM}GitHub User :${RESET} %b\n"   "$user_label"
  printf "  ${DIM}Token       :${RESET} %b\n"   "$token_label"
  printf "  ${DIM}Mode        :${RESET} %s\n"   "$mode_label"
  printf "  ${DIM}Force-push  :${RESET} %s\n"   "$($FORCE && echo yes || echo no)"
  printf "  ${DIM}Dry-run     :${RESET} %s\n"   "$($DRY_RUN && echo yes || echo no)"
  printf "  ${DIM}Repos       :${RESET} %s\n"   "$repos_label"
  printf "  ${DIM}Backup dir  :${RESET} %s\n"   "$BACKUP_ROOT"
  printf "  ${DIM}Restore dir :${RESET} %s\n"   "$RESTORE_ROOT"
}

# ── Menu: numbered list, returns chosen index (0-based) ──────────────────────
# Usage: choose_from TITLE item1 item2 ...  → sets $CHOSEN_IDX
CHOSEN_IDX=0
choose_from() {
  local title="$1"; shift
  local items=("$@")
  echo ""
  printf "${BOLD}  %s${RESET}\n" "$title"
  hr
  for i in "${!items[@]}"; do
    printf "  ${CYAN}[%d]${RESET} %s\n" "$((i+1))" "${items[$i]}"
  done
  hr
  while true; do
    prompt "Enter choice [1-${#items[@]}]:"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#items[@]}" ]]; then
      CHOSEN_IDX=$((choice-1))
      return
    fi
    warn "Invalid choice — please enter a number between 1 and ${#items[@]}"
  done
}

# ── GitHub API helpers ────────────────────────────────────────────────────────
github_api() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-s -f -X "$method"
    -H "Authorization: token $GITHUB_TOKEN"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28")
  [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")
  curl "${args[@]}" "https://api.github.com/$path"
}

repo_exists_on_github() {
  github_api GET "repos/$GITHUB_USER/$1" 2>/dev/null | grep -q '"full_name"'
}

create_github_repo() {
  local repo="$1"
  info "Creating GitHub repo: $GITHUB_USER/$repo"
  $DRY_RUN && { warn "[DRY-RUN] skipped create"; return; }
  github_api POST "user/repos" \
    "{\"name\":\"$repo\",\"private\":true,\"auto_init\":false}" \
    > /dev/null || die "Failed to create repo $repo on GitHub"
}

push_mirror() {
  local repo="$1" repo_dir="$2"
  local remote_url="https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${repo}.git"
  info "Pushing all refs for $repo ..."
  if $DRY_RUN; then
    warn "[DRY-RUN] would run: git push --mirror <redacted-url>"
    return 0
  fi
  git -C "$repo_dir" push --mirror "$remote_url" && return 0 || return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# MENU SCREENS
# ═════════════════════════════════════════════════════════════════════════════

# ── Step 1: Credentials ───────────────────────────────────────────────────────
menu_credentials() {
  banner
  printf "${BOLD}  Step 1 of 5 — GitHub Credentials${RESET}\n\n"

  if [[ -n "$GITHUB_USER" && -n "$GITHUB_TOKEN" ]]; then
    printf "  Credentials already set:\n"
    printf "  ${DIM}User :${RESET} %s\n" "$GITHUB_USER"
    printf "  ${DIM}Token:${RESET} ${GREEN}set${RESET}\n\n"
    choose_from "Keep or update?" \
      "Keep existing credentials" \
      "Enter new credentials"
    [[ $CHOSEN_IDX -eq 0 ]] && return
  fi

  echo ""
  prompt "GitHub username:"
  read -r GITHUB_USER
  [[ -n "$GITHUB_USER" ]] || die "Username cannot be empty"

  prompt "GitHub personal access token (repo scope):"
  read -rs GITHUB_TOKEN; echo ""
  [[ -n "$GITHUB_TOKEN" ]] || die "Token cannot be empty"
  success "Credentials saved"
}

# ── Step 2: Select archive ────────────────────────────────────────────────────
menu_select_archive() {
  banner
  printf "${BOLD}  Step 2 of 5 — Select Backup Archive${RESET}\n\n"

  mapfile -t archives < <(find "$BACKUP_ROOT" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | sort -r)

  if [[ ${#archives[@]} -eq 0 ]]; then
    warn "No .tar.gz archives found in $BACKUP_ROOT"
    echo ""
    prompt "Enter full path to archive:"
    read -r ARCHIVE
    [[ -f "$ARCHIVE" ]] || die "File not found: $ARCHIVE"
    return
  fi

  local labels=()
  for a in "${archives[@]}"; do
    local size; size=$(du -sh "$a" 2>/dev/null | cut -f1)
    labels+=("$(basename "$a")  ${DIM}(${size})${RESET}")
  done
  labels+=("Enter path manually")

  choose_from "Available backups (newest first):" "${labels[@]}"

  if [[ $CHOSEN_IDX -eq ${#archives[@]} ]]; then
    prompt "Enter full path to archive:"
    read -r ARCHIVE
    [[ -f "$ARCHIVE" ]] || die "File not found: $ARCHIVE"
  else
    ARCHIVE="${archives[$CHOSEN_IDX]}"
  fi
  success "Selected: $(basename "$ARCHIVE")"
}

# ── Step 3: Select repos ──────────────────────────────────────────────────────
menu_select_repos() {
  banner
  printf "${BOLD}  Step 3 of 5 — Select Repositories${RESET}\n\n"

  # Peek inside the archive to list repos
  info "Reading archive contents ..."
  local repo_names=()
  while IFS= read -r line; do
    local name; name=$(basename "$line" .git)
    repo_names+=("$name")
  done < <(tar -tzf "$ARCHIVE" 2>/dev/null \
    | grep -E '^[^/]+\.git/?$' \
    | sed 's|/$||' \
    | sort -u)

  if [[ ${#repo_names[@]} -eq 0 ]]; then
    warn "Could not list repos from archive (will restore all on run)"
    pause
    return
  fi

  printf "\n  ${DIM}Archive contains %d repo(s)${RESET}\n" "${#repo_names[@]}"

  choose_from "What would you like to restore?" \
    "All repositories  (${#repo_names[@]} total)" \
    "Choose specific repositories"

  if [[ $CHOSEN_IDX -eq 0 ]]; then
    FILTER_REPOS=()
    success "Will restore all ${#repo_names[@]} repos"
    return
  fi

  # Multi-select: toggle repos
  local selected=()
  for _ in "${repo_names[@]}"; do selected+=(false); done

  while true; do
    banner
    printf "${BOLD}  Step 3 of 5 — Select Repositories${RESET}\n"
    printf "  ${DIM}(toggle repos on/off, then choose Done)${RESET}\n\n"
    hr

    for i in "${!repo_names[@]}"; do
      if ${selected[$i]}; then
        printf "  ${GREEN}[✔] [%d]${RESET} %s\n" "$((i+1))" "${repo_names[$i]}"
      else
        printf "      [%d]  %s\n" "$((i+1))" "${repo_names[$i]}"
      fi
    done
    hr
    printf "  ${CYAN}[a]${RESET} Select all    ${CYAN}[c]${RESET} Clear all    ${CYAN}[d]${RESET} Done\n\n"

    prompt "Toggle repo number, or [a/c/d]:"
    read -r sel

    case "$sel" in
      a) for i in "${!selected[@]}"; do selected[$i]=true; done ;;
      c) for i in "${!selected[@]}"; do selected[$i]=false; done ;;
      d) break ;;
      ''|*[!0-9]*)
        warn "Enter a number, a, c, or d" ;;
      *)
        if [[ "$sel" -ge 1 && "$sel" -le "${#repo_names[@]}" ]]; then
          local idx=$((sel-1))
          ${selected[$idx]} && selected[$idx]=false || selected[$idx]=true
        else
          warn "Number out of range"
        fi
        ;;
    esac
  done

  FILTER_REPOS=()
  for i in "${!selected[@]}"; do
    ${selected[$i]} && FILTER_REPOS+=("${repo_names[$i]}")
  done

  if [[ ${#FILTER_REPOS[@]} -eq 0 ]]; then
    warn "No repos selected — will restore all"
  else
    success "Selected ${#FILTER_REPOS[@]} repo(s): ${FILTER_REPOS[*]}"
  fi
}

# ── Step 4: Options ───────────────────────────────────────────────────────────
menu_options() {
  banner
  printf "${BOLD}  Step 4 of 5 — Restore Options${RESET}\n\n"

  # Mode
  choose_from "Restore mode:" \
    "Push to GitHub  (re-create repos and push all branches/tags)" \
    "Extract locally  (save bare mirrors to $RESTORE_ROOT)" \
    "Both  (push to GitHub AND save bare mirrors locally)"
  case $CHOSEN_IDX in
    0) MODE="push" ;;
    1) MODE="local" ;;
    2) MODE="both" ;;
  esac

  # Force-push
  if [[ "$MODE" != "local" ]]; then
    echo ""
    choose_from "If a repo already exists on GitHub:" \
      "Skip it  (safe default)" \
      "Force-push  (overwrites remote history)"
    [[ $CHOSEN_IDX -eq 1 ]] && FORCE=true || FORCE=false
  fi

  # Dry-run
  echo ""
  choose_from "Run mode:" \
    "Live run  (make actual changes)" \
    "Dry-run   (preview actions without changing anything)"
  [[ $CHOSEN_IDX -eq 1 ]] && DRY_RUN=true || DRY_RUN=false

  success "Options set"
}

# ── Step 5: Confirm & run ─────────────────────────────────────────────────────
menu_confirm_and_run() {
  banner
  printf "${BOLD}  Step 5 of 5 — Review & Run${RESET}\n\n"
  show_settings
  echo ""
  hr

  if $DRY_RUN; then
    printf "  ${YELLOW}DRY-RUN mode — no changes will be made${RESET}\n\n"
  fi

  choose_from "Proceed?" \
    "Start restore" \
    "Go back to main menu" \
    "Abort"

  case $CHOSEN_IDX in
    0) : ;;          # continue
    1) return 1 ;;   # back
    2) echo "Aborted."; exit 0 ;;
  esac

  # Validate requirements before running
  for cmd in git curl tar; do
    command -v "$cmd" &>/dev/null || die "'$cmd' is required but not found"
  done
  if [[ "$MODE" != "local" ]]; then
    [[ -n "$GITHUB_USER" ]]  || die "GitHub username is not set"
    [[ -n "$GITHUB_TOKEN" ]] || die "GitHub token is not set"
  fi
  [[ -f "$ARCHIVE" ]] || die "Archive not found: $ARCHIVE"

  run_restore
}

# ── Core restore logic ────────────────────────────────────────────────────────
run_restore() {
  banner
  printf "${BOLD}  Running Restore${RESET}\n\n"

  log "======================================================"
  log "github-restore.sh starting"
  log "Archive : $ARCHIVE"
  log "Mode    : $MODE"
  log "Dry-run : $DRY_RUN"
  log "======================================================"

  # Extract
  local WORK_DIR
  WORK_DIR=$(mktemp -d "$RESTORE_ROOT/restore-XXXXXX")
  trap 'log "Cleaning up $WORK_DIR"; rm -rf "$WORK_DIR"' EXIT

  info "Extracting archive ..."
  if $DRY_RUN; then
    warn "[DRY-RUN] would extract: $(basename "$ARCHIVE")"
  else
    tar -xzf "$ARCHIVE" -C "$WORK_DIR"
  fi

  # Locate repos inside extracted dir
  local REPOS_DIR="$WORK_DIR"
  local subdirs=("$WORK_DIR"/*/)
  [[ ${#subdirs[@]} -eq 1 && -d "${subdirs[0]}" ]] && REPOS_DIR="${subdirs[0]}"

  mapfile -t repo_dirs < <(find "$REPOS_DIR" -maxdepth 1 -type d -name "*.git" | sort)
  [[ ${#repo_dirs[@]} -gt 0 ]] || die "No bare repo directories found inside the archive"

  info "Found ${#repo_dirs[@]} repo(s) in archive"
  echo ""

  local total=0 skipped=0 failed=0 pushed=0

  for repo_dir in "${repo_dirs[@]}"; do
    local repo_name; repo_name=$(basename "$repo_dir" .git)

    # Filter
    if [[ ${#FILTER_REPOS[@]} -gt 0 ]]; then
      local match=false
      for f in "${FILTER_REPOS[@]}"; do [[ "$f" == "$repo_name" ]] && match=true && break; done
      if ! $match; then
        log "Skipping $repo_name (not selected)"
        ((skipped++)) || true
        continue
      fi
    fi

    ((total++)) || true
    printf "\n${BOLD}  ── %s ${DIM}(%d)${RESET}\n" "$repo_name" "$total"

    # Local-only mode
    if [[ "$MODE" == "local" ]]; then
      local dest="$RESTORE_ROOT/$repo_name.git"
      if $DRY_RUN; then
        warn "[DRY-RUN] would copy bare mirror to $dest"
      else
        cp -r "$repo_dir" "$dest"
        success "Saved to $dest"
        info "Clone with: git clone $dest"
      fi
      continue
    fi

    # Push / both
    if repo_exists_on_github "$repo_name"; then
      if ! $FORCE; then
        warn "$repo_name already exists on GitHub — skipping (enable force-push to overwrite)"
        ((skipped++)) || true
        if [[ "$MODE" == "both" ]]; then
          local dest="$RESTORE_ROOT/$repo_name.git"
          $DRY_RUN || cp -r "$repo_dir" "$dest"
          info "Bare mirror saved to $dest"
        fi
        continue
      fi
      warn "$repo_name already exists — force-pushing"
    else
      create_github_repo "$repo_name"
    fi

    if push_mirror "$repo_name" "$repo_dir"; then
      success "Pushed $repo_name"
      ((pushed++)) || true
    else
      err "Push failed for $repo_name"
      ((failed++)) || true
    fi

    if [[ "$MODE" == "both" ]]; then
      local dest="$RESTORE_ROOT/$repo_name.git"
      if $DRY_RUN; then
        warn "[DRY-RUN] would copy bare mirror to $dest"
      else
        cp -r "$repo_dir" "$dest"
        info "Bare mirror also saved to $dest"
      fi
    fi
  done

  # Summary
  echo ""
  hr
  printf "${BOLD}  Restore Complete${RESET}\n\n"
  printf "  ${DIM}Total processed :${RESET} %d\n" "$total"
  printf "  ${GREEN}Pushed          :${RESET} %d\n" "$pushed"
  printf "  ${YELLOW}Skipped         :${RESET} %d\n" "$skipped"
  [[ $failed -gt 0 ]] \
    && printf "  ${RED}Failed          :${RESET} %d\n" "$failed" \
    || printf "  ${DIM}Failed          :${RESET} 0\n"
  printf "  ${DIM}Log             :${RESET} %s\n" "$LOG_FILE"
  hr
  log "Restore complete — processed=$total pushed=$pushed skipped=$skipped failed=$failed"
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN MENU
# ═════════════════════════════════════════════════════════════════════════════
main_menu() {
  while true; do
    banner
    show_settings
    echo ""
    hr
    printf "  ${CYAN}[1]${RESET} Set credentials\n"
    printf "  ${CYAN}[2]${RESET} Select archive\n"
    printf "  ${CYAN}[3]${RESET} Select repositories\n"
    printf "  ${CYAN}[4]${RESET} Set options\n"
    printf "  ${CYAN}[5]${RESET} Review & run restore\n"
    printf "  ${CYAN}[q]${RESET} Quit\n"
    hr
    echo ""
    prompt "Choice:"
    read -r choice

    case "$choice" in
      1) menu_credentials ;;
      2) menu_select_archive ;;
      3)
        [[ -n "$ARCHIVE" ]] || { warn "Select an archive first (option 2)"; pause; continue; }
        menu_select_repos
        ;;
      4) menu_options ;;
      5)
        [[ -n "$ARCHIVE" ]] || { warn "Select an archive first (option 2)"; pause; continue; }
        menu_confirm_and_run || true
        pause
        ;;
      q|Q) echo "Goodbye."; exit 0 ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

main_menu
