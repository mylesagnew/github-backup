#!/usr/bin/env bash
# lib/archive.sh — archive validation, checksum, and extraction helpers
# Requires: LOG_FILE and ui.sh functions.

# ── Path-traversal validation ─────────────────────────────────────────────────
# Rejects archives containing absolute paths, ../ sequences, or symlinks that
# could escape the destination directory.
validate_archive() {
  local archive="$1"
  info "Validating archive safety ..."

  local bad
  bad=$(tar -tzf "$archive" 2>/dev/null \
    | grep -E '(^|/)\.\.(/|$)|^/' || true)

  if [[ -n "$bad" ]]; then
    err "Unsafe paths detected in archive:"
    echo "$bad" | while read -r p; do err "  $p"; done
    return 1
  fi

  # Reject any symlinks pointing outside the tree
  local links
  links=$(tar -tvzf "$archive" 2>/dev/null \
    | awk '/^l/ {print $NF}' \
    | grep -E '^\/' || true)
  if [[ -n "$links" ]]; then
    err "Archive contains absolute symlink targets:"
    echo "$links" | while read -r l; do err "  $l"; done
    return 1
  fi

  success "Archive passed safety validation"
}

# ── Checksum verification ──────────────────────────────────────────────────────
# Checks for a matching .sha256 file alongside the archive.
# Returns 0 if checksum matches or no .sha256 exists; 1 on mismatch.
verify_checksum() {
  local archive="$1"
  local checksum_file="${archive}.sha256"

  if [[ ! -f "$checksum_file" ]]; then
    warn "No checksum file found — skipping integrity check"
    return 0
  fi

  info "Verifying checksum ..."
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum --check "$checksum_file" --status 2>>"$LOG_FILE" \
      && { success "Checksum OK"; return 0; } \
      || { err "Checksum mismatch — archive may be corrupted"; return 1; }
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 --check "$checksum_file" --status 2>>"$LOG_FILE" \
      && { success "Checksum OK"; return 0; } \
      || { err "Checksum mismatch — archive may be corrupted"; return 1; }
  else
    warn "No sha256sum/shasum found — skipping checksum verification"
  fi
}

# ── Safe extraction ───────────────────────────────────────────────────────────
# Extracts only after validation and checksum checks pass.
extract_archive() {
  local archive="$1" dest="$2"

  verify_checksum "$archive" || die "Aborting: checksum failed"
  validate_archive "$archive" || die "Aborting: archive failed safety check"

  info "Extracting archive to ${dest} ..."
  tar -xzf "$archive" -C "$dest" \
    --no-same-owner \
    --no-same-permissions \
    2>>"$LOG_FILE"
  success "Extraction complete"
}

# ── List bare repo names inside an archive ────────────────────────────────────
list_archive_repos() {
  local archive="$1"
  tar -tzf "$archive" 2>/dev/null \
    | grep -E '^([^/]+/)?[^/]+\.git/?$' \
    | sed 's|/$||' \
    | xargs -I{} basename {} .git \
    | sort -u
}

# ── Safe local mirror copy ────────────────────────────────────────────────────
# Uses rsync --delete so repeated restores to the same path are idempotent.
# Falls back to cp -r if rsync is unavailable.
copy_mirror() {
  local src="$1" dest="$2"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${src}/" "$dest" 2>>"$LOG_FILE"
  else
    rm -rf "$dest"
    cp -r "$src" "$dest"
  fi
}
