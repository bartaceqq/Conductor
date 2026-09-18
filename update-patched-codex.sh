#!/usr/bin/env bash
# Rebase the /effort patch onto a newer upstream Codex, build it, run the tests, and install only
# if everything passed.
#
# A working patched build is never replaced by a broken one: the rebase happens on a scratch
# branch, and the installed binary is only swapped after the build and the test suite succeed.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$PROJECT_DIR/codex"
RUST_DIR="$SOURCE_DIR/codex-rs"
PATCH_BRANCH="${CODEX_ORCHESTRATOR_BRANCH:-orchestrator/effort}"

TARGET_TAG=""
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --tag=*) TARGET_TAG="${arg#*=}" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,7p' "${BASH_SOURCE[0]}"
      echo
      echo "Usage: update-patched-codex.sh [--tag=rust-vX.Y.Z] [--dry-run]"
      echo "  --tag      upstream tag to rebase onto (default: the newest rust-v* release tag)"
      echo "  --dry-run  rebase and build, but do not install"
      exit 0
      ;;
    *) echo "update-patched-codex.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cd "$SOURCE_DIR"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ -z "$(git status --porcelain)" ]] || die "the source tree has uncommitted changes; commit or stash them first"

say "Fetching upstream"
git fetch --tags --quiet origin

if [[ -z "$TARGET_TAG" ]]; then
  # Newest stable release tag: rust-vX.Y.Z with no pre-release suffix.
  TARGET_TAG="$(git tag --list 'rust-v*' --sort=-v:refname \
    | grep -E '^rust-v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
  [[ -n "$TARGET_TAG" ]] || die "could not determine a target tag; pass --tag=..."
fi
say "Target upstream tag: $TARGET_TAG"

BASE_TAG="$(git describe --tags --abbrev=0 --match 'rust-v*' "$CURRENT_BRANCH" 2>/dev/null || true)"
if [[ "$BASE_TAG" == "$TARGET_TAG" ]]; then
  say "Already based on $TARGET_TAG; nothing to rebase."
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
WORK_BRANCH="${PATCH_BRANCH}-${TARGET_TAG#rust-v}"
BACKUP_BRANCH="${CURRENT_BRANCH}-backup-${STAMP}"

say "Saving the current patch branch as $BACKUP_BRANCH"
git branch "$BACKUP_BRANCH" "$CURRENT_BRANCH"

say "Rebasing onto $TARGET_TAG in $WORK_BRANCH"
git checkout -q -B "$WORK_BRANCH" "$CURRENT_BRANCH"
if ! git rebase "$TARGET_TAG"; then
  git rebase --abort || true
  git checkout -q "$CURRENT_BRANCH"
  git branch -D "$WORK_BRANCH" || true
  cat >&2 <<EOF

The patch did not apply cleanly to $TARGET_TAG.

Your working build is untouched and still installed. To resolve by hand:

    cd $SOURCE_DIR
    git checkout -B $WORK_BRANCH $BACKUP_BRANCH
    git rebase $TARGET_TAG      # fix the conflicts, then: git rebase --continue
    $PROJECT_DIR/update-patched-codex.sh --tag=$TARGET_TAG

The files the patch touches are listed in $PROJECT_DIR/README.md.
EOF
  exit 1
fi

say "Building"
cd "$RUST_DIR"
if ! CARGO_PROFILE_RELEASE_DEBUG=none \
     CARGO_PROFILE_RELEASE_STRIP=symbols \
     CARGO_NET_GIT_FETCH_WITH_CLI=true \
     cargo build --release -p codex-cli --bin codex; then
  cd "$SOURCE_DIR"
  git checkout -q "$CURRENT_BRANCH"
  die "build failed on $TARGET_TAG; the installed binary was not touched (rebased branch kept as $WORK_BRANCH)"
fi

say "Running the /effort tests"
if ! "$PROJECT_DIR/bin/run-effort-tests.sh"; then
  cd "$SOURCE_DIR"
  git checkout -q "$CURRENT_BRANCH"
  die "tests failed on $TARGET_TAG; the installed binary was not touched (rebased branch kept as $WORK_BRANCH)"
fi

if [[ "$DRY_RUN" == 1 ]]; then
  say "--dry-run: build and tests passed on $WORK_BRANCH; not installing."
  exit 0
fi

say "Installing the rebased build"
"$PROJECT_DIR/install.sh" --skip-build

cat <<EOF

Updated to $TARGET_TAG.

  patch branch     : $WORK_BRANCH
  previous branch  : $BACKUP_BRANCH (delete it once you are happy)

To roll back:

    cd $SOURCE_DIR && git checkout $BACKUP_BRANCH
    $PROJECT_DIR/install.sh
EOF
