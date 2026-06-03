#!/usr/bin/env bats
# Tests for FILTER_REPOS behaviour in lib/restore_engine.sh.
#
# Runs with DRY_RUN=false so the full code path is exercised.
# Stub functions write per-repo marker files so tests can assert which repos
# were pushed/created without relying on subshell variable state.

load helpers

setup() {
  load_libs

  export PUSH_DIR="${BATS_TMPDIR}/pushed_$$"
  export CREATE_DIR="${BATS_TMPDIR}/created_$$"
  mkdir -p "$PUSH_DIR" "$CREATE_DIR"

  repo_exists_on_github() { return 1; }
  create_github_repo()    { touch "${CREATE_DIR}/$1"; }
  push_mirror()           { touch "${PUSH_DIR}/$1"; return 0; }

  source "${LIB_DIR}/restore_engine.sh"

  export DRY_RUN=false
  export MODE="push"
  export FORCE=false

  ARCHIVE="${BATS_TMPDIR}/filter-test-$$.tar.gz"
  make_archive "$ARCHIVE" alpha beta gamma
}

teardown() {
  rm -rf "$PUSH_DIR" "$CREATE_DIR"
}

@test "empty FILTER_REPOS: all repos are pushed" {
  export FILTER_REPOS=()
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  [ -f "${PUSH_DIR}/alpha" ]
  [ -f "${PUSH_DIR}/beta"  ]
  [ -f "${PUSH_DIR}/gamma" ]
}

@test "FILTER_REPOS=[alpha,gamma]: only alpha and gamma are pushed" {
  export FILTER_REPOS=("alpha" "gamma")
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  [ -f "${PUSH_DIR}/alpha"  ]
  [ ! -f "${PUSH_DIR}/beta" ]
  [ -f "${PUSH_DIR}/gamma"  ]
}

@test "FILTER_REPOS=[beta]: only beta is pushed" {
  export FILTER_REPOS=("beta")
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  [ ! -f "${PUSH_DIR}/alpha" ]
  [ -f  "${PUSH_DIR}/beta"   ]
  [ ! -f "${PUSH_DIR}/gamma" ]
}

@test "FILTER_REPOS=[does-not-exist]: nothing is pushed" {
  export FILTER_REPOS=("does-not-exist")
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  local total_pushed
  total_pushed=$(find "$PUSH_DIR" -type f | wc -l)
  [ "$total_pushed" -eq 0 ]
}

@test "FILTER_REPOS=[alpha,gamma]: beta create_github_repo is not called" {
  export FILTER_REPOS=("alpha" "gamma")
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  [ ! -f "${CREATE_DIR}/beta" ]
}
