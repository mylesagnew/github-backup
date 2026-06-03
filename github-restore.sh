#!/usr/bin/env bash
# github-restore.sh — interactive menu-driven restore for github-backup archives
# https://github.com/mylesagnew/github-backup
set -euo pipefail

# ── Locate lib dir relative to this script ────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
[[ -d "$LIB_DIR" ]] || { echo "ERROR: lib/ directory not found at ${LIB_DIR}" >&2; exit 1; }

# ── Configuration (overridable via env) ───────────────────────────────────────
GITHUB_USER="${GITHUB_USER:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/github-backups}"
RESTORE_ROOT="${RESTORE_ROOT:-$HOME/github-restores}"
mkdir -p "$RESTORE_ROOT"
LOG_FILE="${RESTORE_ROOT}/restore-$(date +%Y%m%d-%H%M%S).log"

# ── Runtime state ─────────────────────────────────────────────────────────────
MODE="push"
FORCE=false
DRY_RUN=false
ARCHIVE=""
FILTER_REPOS=()

# ── Source libraries (order matters) ─────────────────────────────────────────
# shellcheck source=lib/ui.sh
source "${LIB_DIR}/ui.sh"
# shellcheck source=lib/github_api.sh
source "${LIB_DIR}/github_api.sh"
# shellcheck source=lib/archive.sh
source "${LIB_DIR}/archive.sh"
# shellcheck source=lib/restore_engine.sh
source "${LIB_DIR}/restore_engine.sh"

# ── Preflight ─────────────────────────────────────────────────────────────────
for cmd in git curl tar jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed"
done

# ═════════════════════════════════════════════════════════════════════════════
# SETTINGS DISPLAY
# ═════════════════════════════════════════════════════════════════════════════
show_settings() {
  local archive_label user_label token_label mode_label repos_label

  [[ -n "$ARCHIVE" ]] && archive_label="$(basename "$ARCHIVE")" \
    || archive_label="${DIM}(not selected)${RESET}"
  [[ -n "$GITHUB_USER" ]] && user_label="$GITHUB_USER" \
    || user_label="${DIM}(not set)${RESET}"
  [[ -n "$GITHUB_TOKEN" ]] && token_label="${GREEN}set${RESET}" \
    || token_label="${DIM}not set${RESET}"

  case "$MODE" in
    push)  mode_label="Push to GitHub only" ;;
    local) mode_label="Extract locally only" ;;
    both)  mode_label="Push to GitHub + save locally" ;;
  esac

  [[ ${#FILTER_REPOS[@]} -eq 0 ]] \
    && repos_label="All repos" \
    || repos_label="${#FILTER_REPOS[@]} selected: ${FILTER_REPOS[*]}"

  printf "  ${DIM}Archive     :${RESET} %b\n"  "$archive_label"
  printf "  ${DIM}GitHub User :${RESET} %b\n"  "$user_label"
  printf "  ${DIM}Token       :${RESET} %b\n"  "$token_label"
  printf "  ${DIM}Mode        :${RESET} %s\n"  "$mode_label"
  printf "  ${DIM}Force-push  :${RESET} %s\n"  "$($FORCE && echo yes || echo no)"
  printf "  ${DIM}Dry-run     :${RESET} %s\n"  "$($DRY_RUN && echo yes || echo no)"
  printf "  ${DIM}Repos       :${RESET} %s\n"  "$repos_label"
  printf "  ${DIM}Backup dir  :${RESET} %s\n"  "$BACKUP_ROOT"
  printf "  ${DIM}Restore dir :${RESET} %s\n"  "$RESTORE_ROOT"
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
    warn "No .tar.gz archives found in ${BACKUP_ROOT}"
    echo ""
    prompt "Enter full path to archive:"
    read -r ARCHIVE
    [[ -f "$ARCHIVE" ]] || die "File not found: $ARCHIVE"
    return
  fi

  local labels=()
  for a in "${archives[@]}"; do
    local size; size=$(du -sh "$a" 2>/dev/null | cut -f1)
    local chk=""
    [[ -f "${a}.sha256" ]] && chk=" ${GREEN}[✔ sha256]${RESET}"
    labels+=("$(basename "$a")  ${DIM}(${size})${RESET}${chk}")
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

  info "Reading archive contents ..."
  mapfile -t repo_names < <(list_archive_repos "$ARCHIVE")

  if [[ ${#repo_names[@]} -eq 0 ]]; then
    warn "Could not list repos from archive — will attempt to restore all"
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

  # Toggle UI
  local selected=()
  for _ in "${repo_names[@]}"; do selected+=(false); done

  while true; do
    banner
    printf "${BOLD}  Step 3 of 5 — Select Repositories${RESET}\n"
    printf "  ${DIM}Toggle repos then press d when done${RESET}\n\n"
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
      a) for i in "${!selected[@]}"; do selected[$i]=true;  done ;;
      c) for i in "${!selected[@]}"; do selected[$i]=false; done ;;
      d) break ;;
      ''|*[!0-9]*) warn "Enter a number, a, c, or d" ;;
      *)
        if [[ "$sel" -ge 1 && "$sel" -le "${#repo_names[@]}" ]]; then
          local idx=$(( sel - 1 ))
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
    warn "Nothing selected — will restore all"
  else
    success "Selected ${#FILTER_REPOS[@]} repo(s): ${FILTER_REPOS[*]}"
  fi
}

# ── Step 4: Options ───────────────────────────────────────────────────────────
menu_options() {
  banner
  printf "${BOLD}  Step 4 of 5 — Restore Options${RESET}\n\n"

  choose_from "Restore mode:" \
    "Push to GitHub  (re-create repos, push all branches/tags)" \
    "Extract locally  (save bare mirrors to ${RESTORE_ROOT})" \
    "Both  (push to GitHub AND save bare mirrors locally)"
  case $CHOSEN_IDX in
    0) MODE="push"  ;;
    1) MODE="local" ;;
    2) MODE="both"  ;;
  esac

  if [[ "$MODE" != "local" ]]; then
    echo ""
    choose_from "If a repo already exists on GitHub:" \
      "Skip it  (safe default)" \
      "Force-push  (overwrites remote history)"
    [[ $CHOSEN_IDX -eq 1 ]] && FORCE=true || FORCE=false
  fi

  echo ""
  choose_from "Run mode:" \
    "Live run  (make actual changes)" \
    "Dry-run   (preview actions without changing anything)"
  [[ $CHOSEN_IDX -eq 1 ]] && DRY_RUN=true || DRY_RUN=false

  success "Options saved"
}

# ── Step 5: Confirm & run ─────────────────────────────────────────────────────
menu_confirm_and_run() {
  banner
  printf "${BOLD}  Step 5 of 5 — Review & Run${RESET}\n\n"
  show_settings
  echo ""
  hr
  $DRY_RUN && printf "  ${YELLOW}DRY-RUN mode — no changes will be made${RESET}\n\n"

  choose_from "Proceed?" \
    "Start restore" \
    "Return to main menu" \
    "Abort"

  case $CHOSEN_IDX in
    0) : ;;
    1) return 1 ;;
    2) echo "Aborted."; exit 0 ;;
  esac

  if [[ "$MODE" != "local" ]]; then
    [[ -n "$GITHUB_USER" ]]  || die "GitHub username is not set (Step 1)"
    [[ -n "$GITHUB_TOKEN" ]] || die "GitHub token is not set (Step 1)"
  fi
  [[ -f "$ARCHIVE" ]] || die "Archive not found: ${ARCHIVE}"

  run_restore "$ARCHIVE"
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
        [[ -n "$ARCHIVE" ]] \
          || { warn "Select an archive first (option 2)"; pause; continue; }
        menu_select_repos
        ;;
      4) menu_options ;;
      5)
        [[ -n "$ARCHIVE" ]] \
          || { warn "Select an archive first (option 2)"; pause; continue; }
        menu_confirm_and_run || true
        pause
        ;;
      q|Q) echo "Goodbye."; exit 0 ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

main_menu
