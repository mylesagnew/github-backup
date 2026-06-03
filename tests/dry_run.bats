#!/usr/bin/env bats
# Tests for dry-run mode: no filesystem writes and no GitHub API calls occur.
#
# Stub functions write marker files to disk instead of setting variables,
# because `run` executes in a subshell where variable assignments are lost.

load helpers

setup() {
  load_libs

  export PUSH_MARKER="${BATS_TMPDIR}/push_called_$$"
  export CREATE_MARKER="${BATS_TMPDIR}/create_called_$$"
  rm -f "$PUSH_MARKER" "$CREATE_MARKER"

  repo_exists_on_github() { return 1; }
  create_github_repo()    { touch "$CREATE_MARKER"; }
  push_mirror()           { touch "$PUSH_MARKER"; return 0; }

  source "${LIB_DIR}/restore_engine.sh"

  export DRY_RUN=true
  export MODE="push"
  export FORCE=false
  export FILTER_REPOS=()

  ARCHIVE="${BATS_TMPDIR}/dryrun-test-$$.tar.gz"
  make_archive "$ARCHIVE" repo-one repo-two
}

teardown() {
  rm -f "$PUSH_MARKER" "$CREATE_MARKER"
}

@test "dry-run: push_mirror is never called" {
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  [ ! -f "$PUSH_MARKER" ]
}

@test "dry-run: create_github_repo is never called" {
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  [ ! -f "$CREATE_MARKER" ]
}

@test "dry-run: no .git directories written to RESTORE_ROOT" {
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  local count
  count=$(find "$RESTORE_ROOT" -maxdepth 2 -type d -name "*.git" | wc -l)
  [ "$count" -eq 0 ]
}

@test "dry-run: output contains DRY-RUN marker" {
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "dry-run local mode: no .git directories copied to RESTORE_ROOT" {
  export MODE="local"
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  local count
  count=$(find "$RESTORE_ROOT" -maxdepth 1 -type d -name "*.git" | wc -l)
  [ "$count" -eq 0 ]
}

@test "dry-run: exits successfully even when repos would exist on GitHub" {
  repo_exists_on_github() { return 0; }   # pretend everything already exists
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
}
