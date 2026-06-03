# Shared helpers loaded by every test file via `load helpers`

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB_DIR="${REPO_ROOT}/lib"

# Source only the lib files that don't require live network/credentials.
# github_api.sh is excluded; tests that need its functions stub them.
load_libs() {
  export LOG_FILE="${BATS_TMPDIR}/test.log"
  touch "$LOG_FILE"

  # Minimal env so lib files don't error on load
  export GITHUB_USER="test-user"
  export GITHUB_TOKEN="test-token"
  export RESTORE_ROOT="${BATS_TMPDIR}/restores"
  export BACKUP_ROOT="${BATS_TMPDIR}/backups"
  export MODE="push"
  export FORCE=false
  export DRY_RUN=false
  export FILTER_REPOS=()

  mkdir -p "$RESTORE_ROOT" "$BACKUP_ROOT"

  # Suppress colour codes in test output
  export BOLD='' DIM='' CYAN='' GREEN='' YELLOW='' RED='' BLUE='' RESET=''

  source "${LIB_DIR}/ui.sh"
  source "${LIB_DIR}/archive.sh"
}

# Build a minimal .tar.gz containing bare-mirror stubs for the given repo names.
# Usage: make_archive <output_path> <repo1> [repo2 ...]
make_archive() {
  local out="$1"; shift
  local repos=("$@")
  local tmp; tmp=$(mktemp -d)

  for r in "${repos[@]}"; do
    mkdir -p "${tmp}/${r}.git"
    # Bare git init so the dir looks like a real mirror
    git init --bare --quiet "${tmp}/${r}.git"
  done

  tar -czf "$out" -C "$tmp" .
  rm -rf "$tmp"
}

# Build an archive with an unsafe path traversal entry.
make_unsafe_archive() {
  local out="$1"
  local tmp; tmp=$(mktemp -d)
  mkdir -p "${tmp}/safe-repo.git"
  git init --bare --quiet "${tmp}/safe-repo.git"
  # Inject an unsafe path via a raw tar append
  local evil; evil=$(mktemp -d)
  echo "pwned" > "${evil}/evil.txt"
  # Create archive with safe content first, then append ../evil entry
  tar -czf "$out" -C "$tmp" .
  # Append a path traversal entry using tar's --transform
  echo "evil" | tar -rf "${out%.gz}" --transform 's|.*|../escape.txt|' - 2>/dev/null || true
  gzip -f "${out%.gz}" 2>/dev/null || true
  rm -rf "$tmp" "$evil"
}
