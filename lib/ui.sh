#!/usr/bin/env bash
# lib/ui.sh — terminal colours, logging, and interactive prompts

# ── Colours (auto-disabled when not a TTY) ────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD='\033[1m'; DIM='\033[2m'; CYAN='\033[1;36m'; GREEN='\033[1;32m'
  YELLOW='\033[1;33m'; RED='\033[1;31m'; BLUE='\033[1;34m'; RESET='\033[0m'
else
  BOLD=''; DIM=''; CYAN=''; GREEN=''; YELLOW=''; RED=''; BLUE=''; RESET=''
fi

# ── Logging ───────────────────────────────────────────────────────────────────
# LOG_FILE must be set by the sourcing script before any log call.
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info()    { printf "${CYAN}  →  ${RESET}%s\n" "$*"; log "$*"; }
success() { printf "${GREEN}  ✔  ${RESET}%s\n" "$*"; log "$*"; }
warn()    { printf "${YELLOW}  ⚠  ${RESET}%s\n" "$*"; log "WARNING: $*"; }
err()     { printf "${RED}  ✖  ${RESET}%s\n" "$*" >&2; log "ERROR: $*"; }
die()     { err "$*"; exit 1; }

# ── Layout helpers ────────────────────────────────────────────────────────────
hr()           { printf "${DIM}%s${RESET}\n" "──────────────────────────────────────────────────"; }
prompt()       { printf "${BOLD}${BLUE}?${RESET} ${BOLD}%s${RESET} " "$*"; }
pause()        { read -rp "$(printf "${DIM}  Press Enter to continue...${RESET}")"; }
clear_screen() { printf '\033[2J\033[H'; }

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

# ── Numbered menu — sets global CHOSEN_IDX (0-based) ─────────────────────────
# Usage: choose_from "Title" "Option A" "Option B" ...
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
      CHOSEN_IDX=$(( choice - 1 ))
      return
    fi
    warn "Invalid — enter a number between 1 and ${#items[@]}"
  done
}
