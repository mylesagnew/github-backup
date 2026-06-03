#!/usr/bin/env bash
# lib/archive.sh — archive validation, checksum, extraction, and copy helpers

# ── Path-traversal and content validation ────────────────────────────────────
# Git bare mirrors created by --mirror do not contain symlinks or hardlinks.
# Any such entries in an archive indicate corruption or a malicious payload.
validate_archive() {
  local archive="$1"
  info "Validating archive safety ..."

  # Reject absolute paths and any ../ sequences
  local bad_paths
  bad_paths=$(tar -tzf "$archive" 2>/dev/null \
    | grep -E '(^|/)\.\.(/|$)|^/' || true)
  if [[ -n "$bad_paths" ]]; then
    err "Unsafe paths detected in archive:"
    while IFS= read -r p; do err "  ${p}"; done <<<"$bad_paths"
    return 1
  fi

  # Reject all symlinks (absolute and relative — relative targets like ../../x
  # can escape the extraction root after multiple hops)
  local symlinks
  symlinks=$(tar -tvzf "$archive" 2>/dev/null | awk '/^l/ {print $NF}' || true)
  if [[ -n "$symlinks" ]]; then
    err "Archive contains symlinks (not expected in git mirror archives):"
    while IFS= read -r l; do err "  ${l}"; done <<<"$symlinks"
    return 1
  fi

  # Reject hard links (tar listing prefix 'h')
  local hardlinks
  hardlinks=$(tar -tvzf "$archive" 2>/dev/null | awk '/^h/ {print $NF}' || true)
  if [[ -n "$hardlinks" ]]; then
    err "Archive contains hard links (not expected in git mirror archives):"
    while IFS= read -r h; do err "  ${h}"; done <<<"$hardlinks"
    return 1
  fi

  success "Archive passed safety validation"
}

# ── Checksum verification ─────────────────────────────────────────────────────
# Checks for a matching .sha256 file. Returns 0 if it matches or is absent.
verify_checksum() {
  local archive="$1"
  local checksum_file="${archive}.sha256"

  if [[ ! -f "$checksum_file" ]]; then
    warn "No checksum file found — skipping integrity check"
    return 0
  fi

  info "Verifying checksum ..."

  local ok=false
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum --check "$checksum_file" --status 2>>"$LOG_FILE" && ok=true
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 --check "$checksum_file" --status 2>>"$LOG_FILE" && ok=true
  else
    warn "No sha256sum/shasum found — skipping checksum verification"
    return 0
  fi

  if $ok; then
    success "Checksum OK"
  else
    err "Checksum mismatch — archive may be corrupted"
    return 1
  fi
}

# ── Safe extraction ───────────────────────────────────────────────────────────
extract_archive() {
  local archive="$1" dest="$2"

  verify_checksum "$archive" || die "Aborting: checksum verification failed"
  validate_archive "$archive" || die "Aborting: archive failed safety check"

  info "Extracting archive to ${dest} ..."
  tar -xzf "$archive" -C "$dest" \
    --no-same-owner \
    --no-same-permissions \
    --delay-directory-restore \
    2>>"$LOG_FILE"
  success "Extraction complete"
}

# ── List bare repo names inside an archive ────────────────────────────────────
# Pure-shell implementation — avoids xargs word-splitting on unusual filenames.
list_archive_repos() {
  local archive="$1" line name

  while IFS= read -r line; do
    # Strip trailing slash, then any leading directory component
    line="${line%/}"
    name="${line##*/}"
    # Strip .git suffix
    name="${name%.git}"
    [[ -n "$name" ]] && printf '%s\n' "$name"
  done < <(tar -tzf "$archive" 2>/dev/null \
    | grep -E '^([^/]+/)?[^/]+\.git/?$' \
    | sort -u)
}

# ── Atomic local mirror copy ──────────────────────────────────────────────────
# Copies src into dest using a sibling temp dir, then renames atomically.
# Interrupted copies leave a .tmp dir that can be cleaned up safely.
copy_mirror() {
  local src="$1" dest="$2"
  local parent; parent=$(dirname "$dest")
  local tmp; tmp=$(mktemp -d "${parent}/.mirror-tmp-XXXXXX")

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${src}/" "$tmp" 2>>"$LOG_FILE"
  else
    cp -rp "${src}/." "$tmp/"
  fi

  if [[ -d "$dest" ]]; then
    local old; old="${dest}.old.$$"
    mv "$dest" "$old"
    mv "$tmp"  "$dest"
    rm -rf "$old"
  else
    mv "$tmp" "$dest"
  fi
}
