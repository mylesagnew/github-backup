#!/usr/bin/env bats
# Tests for lib/archive.sh — list_archive_repos()

load helpers

setup() { load_libs; }

@test "list_archive_repos returns all repo names from a valid archive" {
  local archive="${BATS_TMPDIR}/multi.tar.gz"
  make_archive "$archive" alpha beta gamma

  run list_archive_repos "$archive"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"*  ]]
  [[ "$output" == *"gamma"* ]]
}

@test "list_archive_repos returns names without .git suffix" {
  local archive="${BATS_TMPDIR}/nosuffix.tar.gz"
  make_archive "$archive" my-repo

  run list_archive_repos "$archive"
  [ "$status" -eq 0 ]
  [[ "$output" == "my-repo" ]]
  [[ "$output" != *".git"* ]]
}

@test "list_archive_repos output is sorted" {
  local archive="${BATS_TMPDIR}/sorted.tar.gz"
  make_archive "$archive" zebra apple mango

  run list_archive_repos "$archive"
  [ "$status" -eq 0 ]
  local sorted; sorted=$(echo "$output" | sort)
  [ "$output" = "$sorted" ]
}

@test "list_archive_repos returns nothing for an empty archive" {
  local archive="${BATS_TMPDIR}/empty.tar.gz"
  tar -czf "$archive" -T /dev/null

  run list_archive_repos "$archive"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list_archive_repos handles single repo" {
  local archive="${BATS_TMPDIR}/single.tar.gz"
  make_archive "$archive" only-repo

  run list_archive_repos "$archive"
  [ "$status" -eq 0 ]
  [ "$output" = "only-repo" ]
}
