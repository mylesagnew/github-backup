#!/usr/bin/env bash
# lib/restore_engine.sh — core restore loop
# Requires: GITHUB_USER, GITHUB_TOKEN, RESTORE_ROOT, MODE, FORCE, DRY_RUN,
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

  # Extract into a private temp dir inside RESTORE_ROOT
  local work_dir
  work_dir=$(mktemp -d "${RESTORE_ROOT}/restore-XXXXXX")
  # shellcheck disable=SC2064
  trap "log 'Cleaning up ${work_dir}'; rm -rf '${work_dir}'" EXIT

  if $DRY_RUN; then
    warn "[DRY-RUN] would extract: $(basename "$archive")"
  else
    extract_archive "$archive" "$work_dir"
  fi

  # Locate repos — archive may wrap everything in one top-level dir
  local repos_dir="$work_dir"
  local subdirs=("${work_dir}"/*/); subdirs=("${subdirs[@]%/}")
  if [[ ${#subdirs[@]} -eq 1 && -d "${subdirs[0]}" \
        && ! "${subdirs[0]}" =~ \.git$ ]]; then
    repos_dir="${subdirs[0]}"
  fi

  mapfile -t repo_dirs < <(find "$repos_dir" -maxdepth 1 -type d -name "*.git" | sort)
  [[ ${#repo_dirs[@]} -gt 0 ]] || die "No bare repo directories found in archive"

  info "Found ${#repo_dirs[@]} repo(s) in archive"
  echo ""

  local total=0 skipped=0 failed=0 pushed=0

  for repo_dir in "${repo_dirs[@]}"; do
    local repo_name; repo_name=$(basename "$repo_dir" .git)

    # Apply filter list if repos were selected individually
    if [[ ${#FILTER_REPOS[@]} -gt 0 ]]; then
      local match=false
      for f in "${FILTER_REPOS[@]}"; do
        [[ "$f" == "$repo_name" ]] && match=true && break
      done
      if ! $match; then
        log "Skipping ${repo_name} (not selected)"
        (( skipped++ )) || true
        continue
      fi
    fi

    (( total++ )) || true
    printf "\n${BOLD}  ── %s ${DIM}(%d)${RESET}\n" "$repo_name" "$total"

    # ── local-only mode ──────────────────────────────────────────────────────
    if [[ "$MODE" == "local" ]]; then
      local dest="${RESTORE_ROOT}/${repo_name}.git"
      if $DRY_RUN; then
        warn "[DRY-RUN] would copy bare mirror to ${dest}"
      else
        copy_mirror "$repo_dir" "$dest"
        success "Saved to ${dest}"
        info "Clone with: git clone ${dest}"
      fi
      continue
    fi

    # ── push (or both) mode ──────────────────────────────────────────────────
    if repo_exists_on_github "$repo_name"; then
      if ! $FORCE; then
        warn "${repo_name} already exists — skipping (use force-push to overwrite)"
        (( skipped++ )) || true
        if [[ "$MODE" == "both" ]]; then
          _save_local "$repo_name" "$repo_dir"
        fi
        continue
      fi
      warn "${repo_name} already exists — force-pushing"
    else
      create_github_repo "$repo_name"
    fi

    if push_mirror "$repo_name" "$repo_dir"; then
      success "Pushed ${repo_name}"
      (( pushed++ )) || true
    else
      err "Push failed for ${repo_name}"
      (( failed++ )) || true
    fi

    [[ "$MODE" == "both" ]] && _save_local "$repo_name" "$repo_dir"
  done

  _print_summary "$total" "$pushed" "$skipped" "$failed"
  log "Restore complete — processed=${total} pushed=${pushed} skipped=${skipped} failed=${failed}"
}

# ── Internal: save a bare mirror locally ─────────────────────────────────────
_save_local() {
  local repo_name="$1" repo_dir="$2"
  local dest="${RESTORE_ROOT}/${repo_name}.git"
  if $DRY_RUN; then
    warn "[DRY-RUN] would copy bare mirror to ${dest}"
  else
    copy_mirror "$repo_dir" "$dest"
    info "Bare mirror saved to ${dest}"
  fi
}

# ── Internal: print final summary ────────────────────────────────────────────
_print_summary() {
  local total="$1" pushed="$2" skipped="$3" failed="$4"
  echo ""
  hr
  printf "${BOLD}  Restore Complete${RESET}\n\n"
  printf "  ${DIM}Total processed :${RESET} %d\n" "$total"
  printf "  ${GREEN}Pushed          :${RESET} %d\n" "$pushed"
  printf "  ${YELLOW}Skipped         :${RESET} %d\n" "$skipped"
  if [[ "$failed" -gt 0 ]]; then
    printf "  ${RED}Failed          :${RESET} %d\n" "$failed"
  else
    printf "  ${DIM}Failed          :${RESET} 0\n"
  fi
  printf "  ${DIM}Log             :${RESET} %s\n" "$LOG_FILE"
  hr
}
