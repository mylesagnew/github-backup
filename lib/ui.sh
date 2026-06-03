#!/usr/bin/env bash
# lib/ui.sh — terminal colours, logging, and interactive prompts

# Colours use $'...' so variables hold the actual ESC bytes.
# printf can then use %s safely without relying on format-string escape interpretation.
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'   DIM=$'\033[2m'    CYAN=$'\033[1;36m'  GREEN=$'\033[1;32m'
  YELLOW=$'\033[1;33m' RED=$'\033[1;31m' BLUE=$'\033[1;34m'  RESET=$'\033[0m'
else
  BOLD='' DIM='' CYAN='' GREEN='' YELLOW='' RED='' BLUE='' RESET=''
fi

# LOG_FILE must be set by the sourcing script before the first log call.
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info()    { printf '%s  →  %s%s\n'    "$CYAN"   "$RESET" "$*"; log "$*"; }
success() { printf '%s  ✔  %s%s\n'    "$GREEN"  "$RESET" "$*"; log "$*"; }
warn()    { printf '%s  ⚠  %s%s\n'    "$YELLOW" "$RESET" "$*"; log "WARNING: $*"; }
err()     { printf '%s  ✖  %s%s\n'    "$RED"    "$RESET" "$*" >&2; log "ERROR: $*"; }
die()     { err "$*"; exit 1; }

hr()     { printf '%s%s%s\n' "$DIM" "──────────────────────────────────────────────────" "$RESET"; }
prompt() { printf '%s%s?%s %s%s%s ' "$BOLD" "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
pause()  { read -rp "$(printf '%s  Press Enter to continue...%s' "$DIM" "$RESET")"; }
clear_screen() { printf '\033[2J\033[H'; }

banner() {
  clear_screen
  printf '%s%s' "$CYAN" "$BOLD"
  cat <<'EOF'
  ┌─────────────────────────────────────────┐
  │        GitHub Backup — Restore          │
  └─────────────────────────────────────────┘
EOF
  printf '%s' "$RESET"
  printf '%s  Log: %s%s\n\n' "$DIM" "$LOG_FILE" "$RESET"
}

# Numbered menu — sets global CHOSEN_IDX (0-based).
# Usage: choose_from "Title" "Option A" "Option B" ...
# shellcheck disable=SC2034  # used by sourcing scripts after choose_from returns
CHOSEN_IDX=0
choose_from() {
  local title="$1"; shift
  local items=("$@")
  echo ""
  printf '%s  %s%s\n' "$BOLD" "$title" "$RESET"
  hr
  for i in "${!items[@]}"; do
    printf '%s  [%d]%s %s\n' "$CYAN" "$((i+1))" "$RESET" "${items[$i]}"
  done
  hr
  while true; do
    prompt "Enter choice [1-${#items[@]}]:"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#items[@]}" ]]; then
      # shellcheck disable=SC2034  # read by sourcing scripts after this function returns
      CHOSEN_IDX=$(( choice - 1 ))
      return
    fi
    warn "Invalid — enter a number between 1 and ${#items[@]}"
  done
}
