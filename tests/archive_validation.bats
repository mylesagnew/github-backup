#!/usr/bin/env bats
# Tests for lib/archive.sh — validate_archive() and verify_checksum()

load helpers

setup() { load_libs; }

# ── validate_archive ──────────────────────────────────────────────────────────

@test "validate_archive passes a clean archive" {
  local archive="${BATS_TMPDIR}/clean.tar.gz"
  make_archive "$archive" repo-a repo-b

  run validate_archive "$archive"
  [ "$status" -eq 0 ]
}

@test "validate_archive rejects an archive with an absolute path" {
  local archive="${BATS_TMPDIR}/absolute.tar.gz"
  local tmp; tmp=$(mktemp -d)
  echo "bad" > "${tmp}/file.txt"
  # Force an absolute path entry (requires GNU tar --absolute-names)
  tar -czf "$archive" --absolute-names "${tmp}/file.txt" 2>/dev/null || \
    tar -czf "$archive" -C / "tmp/file.txt" 2>/dev/null || \
    skip "Cannot create absolute-path archive on this platform"
  rm -rf "$tmp"

  run validate_archive "$archive"
  [ "$status" -ne 0 ]
}

@test "validate_archive rejects a path traversal entry" {
  # Build a tar that contains a ../escape style entry using --transform
  local raw="${BATS_TMPDIR}/traversal.tar"
  local archive="${BATS_TMPDIR}/traversal.tar.gz"
  local tmp; tmp=$(mktemp -d)
  echo "escape" > "${tmp}/payload.txt"
  tar -cf "$raw" --transform 's|payload.txt|../payload.txt|' \
    -C "$tmp" payload.txt 2>/dev/null \
    || skip "GNU tar --transform not available"
  gzip -c "$raw" > "$archive"
  rm -rf "$tmp" "$raw"

  run validate_archive "$archive"
  [ "$status" -ne 0 ]
}

# ── verify_checksum ───────────────────────────────────────────────────────────

@test "verify_checksum passes when sha256 matches" {
  local archive="${BATS_TMPDIR}/checksummed.tar.gz"
  make_archive "$archive" some-repo

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$archive" > "${archive}.sha256"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$archive" > "${archive}.sha256"
  else
    skip "No sha256 tool available"
  fi

  run verify_checksum "$archive"
  [ "$status" -eq 0 ]
}

@test "verify_checksum fails when sha256 does not match" {
  local archive="${BATS_TMPDIR}/tampered.tar.gz"
  make_archive "$archive" some-repo

  # Write a deliberately wrong checksum
  echo "0000000000000000000000000000000000000000000000000000000000000000  ${archive}" \
    > "${archive}.sha256"

  run verify_checksum "$archive"
  [ "$status" -ne 0 ]
}

@test "verify_checksum passes with a warning when no .sha256 file exists" {
  local archive="${BATS_TMPDIR}/no-checksum.tar.gz"
  make_archive "$archive" some-repo
  rm -f "${archive}.sha256"

  run verify_checksum "$archive"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No checksum file"* ]]
}
