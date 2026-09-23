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
PATCH_BRANCH_PREFIX="${CODEX_ORCHESTRATOR_BRANCH_PREFIX:-orchestrator/effort}"

TARGET_TAG=""
DRY_RUN=0
FORCE=0
RESOLVER="${CODEX_ORCHESTRATOR_RESOLVER:-auto}"
for arg in "$@"; do
  case "$arg" in
    --tag=*) TARGET_TAG="${arg#*=}" ;;
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --resolver=*) RESOLVER="${arg#*=}" ;;
    -h|--help)
      sed -n '2,7p' "${BASH_SOURCE[0]}"
      echo
      echo "Usage: update-patched-codex.sh [--tag=rust-vX.Y.Z] [--dry-run] [--force] [--resolver=auto|claude|codex|none]"
      echo "  --tag       upstream tag to rebase onto (default: the newest rust-v* release tag)"
      echo "  --dry-run   rebase and build, but do not install"
      echo "  --force     rebuild even when already based on the target tag"
      echo "  --resolver  who resolves rebase conflicts (default: auto = claude, else codex, else none)."
      echo "              The build and test gate still decides whether the result is installed."
      exit 0
      ;;
    *) echo "update-patched-codex.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -d "$SOURCE_DIR/.git" ]] || die "no patched Codex checkout at $SOURCE_DIR; run ./install.sh first"
for tool in git cargo rustc; do
  command -v "$tool" >/dev/null || die "$tool not found; install it before updating (see ./install.sh --help)"
done

if [[ "$RESOLVER" == auto ]]; then
  if command -v claude >/dev/null; then RESOLVER=claude
  elif [[ -x "$PROJECT_DIR/pkg/bin/codex" ]] || command -v codex >/dev/null; then RESOLVER=codex
  else RESOLVER=none
  fi
fi
case "$RESOLVER" in claude|codex|none) ;; *) die "unknown resolver: $RESOLVER" ;; esac

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
if [[ "$BASE_TAG" == "$TARGET_TAG" && "$FORCE" == 0 ]]; then
  say "Already based on $TARGET_TAG; nothing to do (pass --force to rebuild anyway)."
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
WORK_BRANCH="${PATCH_BRANCH_PREFIX}-${TARGET_TAG#rust-v}"
BACKUP_BRANCH="${CURRENT_BRANCH}-backup-${STAMP}"

say "Saving the current patch branch as $BACKUP_BRANCH"
git branch "$BACKUP_BRANCH" "$CURRENT_BRANCH"

rebase_in_progress() {
  [[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]]
}

# Hand the conflicted files of the commit being replayed to an AI CLI. It may only read and edit;
# staging and continuing stay here, and the build + test gate below judges the outcome.
resolve_conflicts() {
  local files="$1" commit prompt
  commit="$(git log -1 --format='%h %s' REBASE_HEAD 2>/dev/null || echo '<unknown>')"
  prompt="You are resolving git rebase conflicts in the OpenAI Codex repository at $SOURCE_DIR.
Our local patch (adds the /effort slash command and multi-model agent routing) is being rebased
from ${BASE_TAG:-an older release} onto upstream $TARGET_TAG. The commit being replayed is: $commit

Conflicted files:
$files

Resolve every conflict in exactly these files:
- HEAD is upstream $TARGET_TAG; the other side is our patch.
- Keep upstream's changes AND our patch's additions. Usually both sides simply added entries to
  the same enum, match, mod list or test list, and both belong.
- If upstream removed or renamed something that only appears in our side's hunk as context (not
  as part of the /effort feature), follow upstream and drop it.
- Keep lists in the order and style of the surrounding code.
- Remove every conflict marker. Do not edit any other file. Do not run git add, commit or rebase.
Use 'git diff', 'git show REBASE_HEAD' and 'git log' to understand both sides. Finish with a
one-line summary per file."
  say "Resolving conflicts with $RESOLVER: $(echo $files)"
  case "$RESOLVER" in
    claude)
      timeout 30m claude -p "$prompt" \
        --permission-mode acceptEdits \
        --allowedTools "Read,Edit,Grep,Glob,Bash(git diff:*),Bash(git show:*),Bash(git log:*),Bash(git status:*)"
      ;;
    codex)
      local codex_bin="$PROJECT_DIR/pkg/bin/codex"
      [[ -x "$codex_bin" ]] || codex_bin="$(command -v codex)"
      timeout 30m "$codex_bin" exec --sandbox workspace-write -C "$SOURCE_DIR" "$prompt" </dev/null
      ;;
  esac
}

# Drive a stopped rebase to completion, resolving each conflicting commit in turn.
finish_rebase() {
  local files
  [[ "$RESOLVER" != none ]] || return 1
  while rebase_in_progress; do
    files="$(git diff --name-only --diff-filter=U)"
    [[ -n "$files" ]] || return 1   # stopped for a reason other than conflicts
    resolve_conflicts "$files" || return 1
    # shellcheck disable=SC2086
    if grep -lE '^(<<<<<<<|>>>>>>>) ' $files; then
      echo "conflict markers are still present in the files above" >&2
      return 1
    fi
    # shellcheck disable=SC2086
    git add -- $files
    GIT_EDITOR=true git rebase --continue || true
  done
}

# Upstream tags each release on its own branch, so the old tag is usually not an ancestor of
# the new one. Replay only our commits on top of BASE_TAG, not the old release branch's history.
if [[ -n "$BASE_TAG" ]]; then
  REBASE_ARGS=(--onto "$TARGET_TAG" "$BASE_TAG")
else
  REBASE_ARGS=("$TARGET_TAG")
fi

say "Rebasing onto $TARGET_TAG in $WORK_BRANCH"
git checkout -q -B "$WORK_BRANCH" "$CURRENT_BRANCH"
if ! git rebase "${REBASE_ARGS[@]}" && ! finish_rebase; then
  git rebase --abort 2>/dev/null || true
  git checkout -q "$CURRENT_BRANCH"
  git branch -D "$WORK_BRANCH" || true
  cat >&2 <<EOF

The patch did not apply cleanly to $TARGET_TAG (resolver: $RESOLVER).

Your working build is untouched and still installed. To resolve by hand:

    cd $SOURCE_DIR
    git checkout -B $WORK_BRANCH $BACKUP_BRANCH
    git rebase --onto $TARGET_TAG ${BASE_TAG:-<old-tag>}   # fix the conflicts, then: git rebase --continue
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
if ! bash "$PROJECT_DIR/bin/run-effort-tests.sh"; then
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
