#!/usr/bin/env bats
# Tests for dry-run mode — no filesystem writes, no GitHub calls should occur

load helpers

setup() {
  load_libs

  # Track whether network stubs are called
  export PUSH_CALLED=false
  export CREATE_CALLED=false

  github_api()            { echo '{}'; }
  repo_exists_on_github() { return 1; }
  create_github_repo()    { CREATE_CALLED=true; }
  push_mirror()           { PUSH_CALLED=true; return 0; }

  source "${LIB_DIR}/restore_engine.sh"

  export DRY_RUN=true
  export MODE="push"
  export FORCE=false
  export FILTER_REPOS=()

  ARCHIVE="${BATS_TMPDIR}/dryrun-test.tar.gz"
  make_archive "$ARCHIVE" repo-one repo-two
}

@test "dry-run does not call push_mirror" {
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  [ "$PUSH_CALLED" = "false" ]
}

@test "dry-run does not call create_github_repo" {
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  [ "$CREATE_CALLED" = "false" ]
}

@test "dry-run does not write any files to RESTORE_ROOT" {
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  # RESTORE_ROOT should contain only log files, no .git dirs
  local git_dirs
  git_dirs=$(find "$RESTORE_ROOT" -maxdepth 2 -type d -name "*.git" | wc -l)
  [ "$git_dirs" -eq 0 ]
}

@test "dry-run output mentions DRY-RUN" {
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "dry-run local mode does not copy any mirrors" {
  MODE="local"
  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  local copied
  copied=$(find "$RESTORE_ROOT" -maxdepth 1 -type d -name "*.git" | wc -l)
  [ "$copied" -eq 0 ]
}
