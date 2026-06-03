#!/usr/bin/env bash
# lib/restore_engine.sh — core restore loop
# Requires: GITHUB_USER, RESTORE_ROOT, MODE, FORCE, DRY_RUN,
#           FILTER_REPOS (array), LOG_FILE, and functions from ui.sh,
#           github_api.sh, and archive.sh.

run_restore() {
  local archive="$1"

  log "======================================================"
  log "Restore starting"
  log "Archive : ${archive}"
  log "Mode    : ${MODE}"
  log "Dry-run : ${DRY_RUN}"
  log "======================================================"

  local work_dir
  work_dir=$(mktemp -d "${RESTORE_ROOT}/restore-XXXXXX")
  # shellcheck disable=SC2064
  trap "log 'Cleaning up temp dir'; rm -rf '${work_dir}'" EXIT

  # Always extract into the private temp dir — needed to enumerate repos.
  # In dry-run mode, no content is written to RESTORE_ROOT or GitHub.
  extract_archive "$archive" "$work_dir"

  if $DRY_RUN; then
    warn "DRY-RUN: archive extracted to temp workspace only; no GitHub or local writes will occur"
  fi

  # Locate repos — archive may wrap everything in one top-level directory
  local repos_dir="$work_dir"
  local subdirs
  mapfile -t subdirs < <(find "$work_dir" -mindepth 1 -maxdepth 1 -type d ! -name "*.git")
  if [[ ${#subdirs[@]} -eq 1 ]]; then
    repos_dir="${subdirs[0]}"
  fi

  mapfile -t repo_dirs < <(find "$repos_dir" -maxdepth 1 -type d -name "*.git" | sort)
  [[ ${#repo_dirs[@]} -gt 0 ]] || die "No bare repo directories found in archive"

  info "Found ${#repo_dirs[@]} repo(s) in archive"
  echo ""

  local total=0 skipped=0 failed=0 pushed=0

  for repo_dir in "${repo_dirs[@]}"; do
    local dir_name repo_name target_owner
    dir_name=$(basename "$repo_dir" .git)

    # Detect org__repo naming written by github-backup.sh for org repos
    if [[ "$dir_name" == *"__"* ]]; then
      target_owner="${dir_name%%__*}"
      repo_name="${dir_name#*__}"
    else
      target_owner="$GITHUB_USER"
      repo_name="$dir_name"
    fi

    # Apply filter list (filters on repo_name only, not owner prefix)
    if [[ ${#FILTER_REPOS[@]} -gt 0 ]]; then
      local match=false
      local f
      for f in "${FILTER_REPOS[@]}"; do
        [[ "$f" == "$repo_name" || "$f" == "$dir_name" ]] && match=true && break
      done
      if ! $match; then
        log "Skipping ${dir_name} (not selected)"
        (( skipped++ )) || true
        continue
      fi
    fi

    (( total++ )) || true
    printf '\n%s  ── %s %s(%d)%s\n' "$BOLD" "$dir_name" "$DIM" "$total" "$RESET"

    # ── Dry-run short-circuit: enumerate only, no writes ─────────────────────
    if $DRY_RUN; then
      case "$MODE" in
        local) warn "[DRY-RUN] would copy ${dir_name} → ${RESTORE_ROOT}/${dir_name}.git" ;;
        push)  warn "[DRY-RUN] would push ${dir_name} → github.com/${target_owner}/${repo_name}" ;;
        both)  warn "[DRY-RUN] would push ${dir_name} → github.com/${target_owner}/${repo_name} and copy locally" ;;
      esac
      (( pushed++ )) || true
      continue
    fi

    # ── Local-only mode ───────────────────────────────────────────────────────
    if [[ "$MODE" == "local" ]]; then
      local dest="${RESTORE_ROOT}/${dir_name}.git"
      copy_mirror "$repo_dir" "$dest"
      success "Saved to ${dest}"
      info "Clone with: git clone ${dest}"
      continue
    fi

    # ── Push (or both) mode ───────────────────────────────────────────────────
    if repo_exists_on_github "$repo_name"; then
      if ! $FORCE; then
        warn "${repo_name} already exists on GitHub — skipping (enable force-push to overwrite)"
        (( skipped++ )) || true
        if [[ "$MODE" == "both" ]]; then
          _save_local "$dir_name" "$repo_dir"
        fi
        continue
      fi
      warn "${repo_name} already exists — force-pushing"
    else
      create_github_repo "$repo_name"
    fi

    if push_mirror "$repo_name" "$repo_dir" "$target_owner"; then
      success "Pushed ${repo_name}"
      (( pushed++ )) || true
    else
      err "Push failed for ${repo_name}"
      (( failed++ )) || true
    fi

    [[ "$MODE" == "both" ]] && _save_local "$dir_name" "$repo_dir"
  done

  _print_summary "$total" "$pushed" "$skipped" "$failed"
  log "Restore complete — processed=${total} pushed=${pushed} skipped=${skipped} failed=${failed}"
}

_save_local() {
  local dir_name="$1" repo_dir="$2"
  local dest="${RESTORE_ROOT}/${dir_name}.git"
  copy_mirror "$repo_dir" "$dest"
  info "Bare mirror saved to ${dest}"
}

_print_summary() {
  local total="$1" pushed="$2" skipped="$3" failed="$4"
  echo ""
  hr
  printf '%s  Restore Complete%s\n\n' "$BOLD" "$RESET"
  printf '  %sTotal processed :%s %d\n' "$DIM"    "$RESET" "$total"
  printf '  %sPushed          :%s %d\n' "$GREEN"  "$RESET" "$pushed"
  printf '  %sSkipped         :%s %d\n' "$YELLOW" "$RESET" "$skipped"
  if [[ "$failed" -gt 0 ]]; then
    printf '  %sFailed          :%s %d\n' "$RED" "$RESET" "$failed"
  else
    printf '  %sFailed          :%s 0\n'  "$DIM" "$RESET"
  fi
  printf '  %sLog             :%s %s\n' "$DIM" "$RESET" "$LOG_FILE"
  hr
}
