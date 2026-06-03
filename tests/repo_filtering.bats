#!/usr/bin/env bats
# Tests for lib/restore_engine.sh — FILTER_REPOS behaviour via dry-run

load helpers

setup() {
  load_libs

  # Stub out network functions so the engine never touches GitHub
  github_api()           { echo '{"full_name":"test-user/stub"}'; }
  repo_exists_on_github() { return 1; }  # treat all repos as new
  create_github_repo()   { :; }
  push_mirror()          { return 0; }

  # shellcheck source=../lib/github_api.sh
  source "${LIB_DIR}/restore_engine.sh"

  export DRY_RUN=true  # safe — nothing is written
  export MODE="push"
  export FORCE=false

  # Build a test archive with three repos
  ARCHIVE="${BATS_TMPDIR}/filter-test.tar.gz"
  make_archive "$ARCHIVE" alpha beta gamma
}

@test "empty FILTER_REPOS processes all repos" {
  FILTER_REPOS=()

  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"*  ]]
  [[ "$output" == *"gamma"* ]]
}

@test "FILTER_REPOS limits restore to selected repos" {
  FILTER_REPOS=("alpha" "gamma")

  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" != *"beta"*  ]]
  [[ "$output" == *"gamma"* ]]
}

@test "FILTER_REPOS with a single repo restores only that repo" {
  FILTER_REPOS=("beta")

  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"alpha"* ]]
  [[ "$output" == *"beta"*  ]]
  [[ "$output" != *"gamma"* ]]
}

@test "FILTER_REPOS with an unknown name skips silently" {
  FILTER_REPOS=("does-not-exist")

  run run_restore "$ARCHIVE"
  [ "$status" -eq 0 ]
  # Summary should show 0 processed, 3 skipped
  [[ "$output" == *"Total processed : 0"* ]] || \
  [[ "$output" == *"processed=0"*         ]]
}
