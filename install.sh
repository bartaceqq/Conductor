#!/usr/bin/env bash
# Install the patched Codex binary (with the native /effort command) plus the orchestrator
# agent roles, routing skill and [agents] config, without touching the existing Codex install.
#
# Idempotent: re-running replaces our managed files and leaves everything else alone.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$PROJECT_DIR/codex"
RUST_DIR="$SOURCE_DIR/codex-rs"
PKG_DIR="$PROJECT_DIR/pkg"
BACKUP_DIR="$PROJECT_DIR/backup"
BIN_DIR="${CODEX_ORCHESTRATOR_BIN_DIR:-$HOME/.local/bin}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SKILLS_DIR="$CODEX_HOME/skills"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Single source of truth for which upstream release the patch is cut against. Keep this in step
# with patches/codex-orchestrator.patch; update-patched-codex.sh moves the patch to a newer tag.
UPSTREAM_REPO="${CODEX_ORCHESTRATOR_UPSTREAM:-https://github.com/openai/codex.git}"
UPSTREAM_TAG="${CODEX_ORCHESTRATOR_TAG:-rust-v0.155.0}"
PATCH_BRANCH="${CODEX_ORCHESTRATOR_BRANCH:-orchestrator/effort-${UPSTREAM_TAG#rust-v}}"
# A file that only exists once patches/codex-orchestrator.patch has been applied. Used to tell a
# patched checkout apart from a bare upstream one, so a half-finished run is never mistaken for a
# good one and silently built as vanilla Codex.
PATCH_SENTINEL="codex-rs/tui/src/effort_status.rs"

EXE=""
case "${OSTYPE:-}" in
  msys*|cygwin*|win32*) EXE=".exe" ;;
esac

SKIP_BUILD=0
MAX_AGENTS=4
AUTO_UPDATE=1
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --max-agents=*) MAX_AGENTS="${arg#*=}" ;;
    --no-auto-update) AUTO_UPDATE=0 ;;
    -h|--help)
      sed -n '2,8p' "${BASH_SOURCE[0]}"
      echo
      echo "Usage: install.sh [--skip-build] [--max-agents=N] [--no-auto-update]"
      echo "  --skip-build      reuse an existing release build instead of compiling"
      echo "  --max-agents=N    value written to [agents].max_concurrent_threads_per_session"
      echo "  --no-auto-update  do not install the daily systemd timer that follows upstream releases"
      echo
      echo "Environment:"
      echo "  CODEX_ORCHESTRATOR_BIN_DIR  where to install the 'codex' symlink (default ~/.local/bin)"
      echo "  CODEX_ORCHESTRATOR_TAG      upstream tag to patch (default $UPSTREAM_TAG)"
      echo "  CODEX_HOME                  Codex config dir (default ~/.codex)"
      exit 0
      ;;
    *) echo "install.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

case "$MAX_AGENTS" in
  ''|*[!0-9]*) echo "install.sh: --max-agents must be a positive integer" >&2; exit 2 ;;
  0) echo "install.sh: --max-agents must be at least 1" >&2; exit 2 ;;
esac

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- pre-flight
# Everything that can make the run fail is checked up front. Cloning upstream Codex pulls several
# hundred megabytes, so discovering a missing toolchain afterwards wastes a lot of time and disk.
say "Checking prerequisites"

missing=()
command -v git     >/dev/null || missing+=("git")
command -v python3 >/dev/null || missing+=("python3")
if [[ "$SKIP_BUILD" == 0 ]]; then
  command -v cargo >/dev/null || missing+=("cargo")
  command -v rustc >/dev/null || missing+=("rustc")
fi

if (( ${#missing[@]} )); then
  printf '\033[31merror:\033[0m missing required tool(s): %s\n' "${missing[*]}" >&2
  for tool in "${missing[@]}"; do
    case "$tool" in
      cargo|rustc)
        cat >&2 <<'HINT'

  Conductor compiles a patched Codex from source, so it needs a Rust toolchain.
  The build is pinned to the channel in codex-rs/rust-toolchain.toml, so rustup is
  the reliable way to install it:

      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
      # Arch: sudo pacman -S rustup && rustup default stable
      # Debian/Ubuntu: sudo apt install rustup   (or use the curl line above)

  Then restart your shell so ~/.cargo/bin is on PATH and re-run this script.
HINT
        break
        ;;
    esac
  done
  for tool in "${missing[@]}"; do
    [[ "$tool" == "python3" ]] && echo "  python3 is needed to generate the agent role files." >&2
    [[ "$tool" == "git" ]] && echo "  git is needed to fetch and patch the Codex source." >&2
  done
  exit 1
fi

if [[ "$SKIP_BUILD" == 0 ]]; then
  echo "    cargo   : $(cargo --version 2>/dev/null || echo '<unavailable>')"
  echo "    rustc   : $(rustc --version 2>/dev/null || echo '<unavailable>')"
fi
echo "    python3 : $(python3 --version 2>&1)"

# Running the script from a clone that sits inside another clone (the classic result of pasting the
# README's `git clone && cd Conductor` while already inside Conductor) silently builds a second
# several-hundred-megabyte copy of upstream Codex. Catch it before that happens.
parent_dir="$(dirname "$PROJECT_DIR")"
while [[ "$parent_dir" != "/" && "$parent_dir" != "$HOME" && -n "$parent_dir" ]]; do
  if [[ -f "$parent_dir/install.sh" && -d "$parent_dir/patches" ]]; then
    warn "this looks like a Conductor checkout nested inside another one:"
    warn "    outer: $parent_dir"
    warn "    here : $PROJECT_DIR"
    warn "Each copy builds its own ~700MB Codex clone. Consider removing the inner one."
    break
  fi
  parent_dir="$(dirname "$parent_dir")"
done

say "Checking the current Codex installation"
ORIGINAL_CODEX="$(command -v codex || true)"
if [[ -n "$ORIGINAL_CODEX" ]]; then
  echo "    which codex   : $ORIGINAL_CODEX"
  echo "    codex --version: $(codex --version 2>/dev/null || echo '<unavailable>')"
else
  warn "no 'codex' found on PATH; installing ours as the only one"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on PATH. Please add it to your PATH (earlier than the existing codex)!" ;;
esac

if [[ -n "$ORIGINAL_CODEX" && "$ORIGINAL_CODEX" == "$BIN_DIR/codex$EXE" ]]; then
  say "$BIN_DIR/codex$EXE already exists; it will be replaced by this build"
elif [[ -n "$ORIGINAL_CODEX" ]]; then
  first_hit="$(IFS=:; for d in $PATH; do [[ -x "$d/codex$EXE" ]] && { echo "$d"; break; }; done || true)"
  if [[ -n "$first_hit" && "$first_hit" != "$BIN_DIR" ]]; then
    prefix_ok=0
    IFS=: read -ra path_dirs <<<"$PATH"
    for d in "${path_dirs[@]}"; do
      [[ "$d" == "$BIN_DIR" ]] && { prefix_ok=1; break; }
      [[ "$d" == "$first_hit" ]] && break
    done
    [[ "$prefix_ok" == 1 ]] || warn "$BIN_DIR comes after $first_hit on PATH; 'codex' might not resolve to our build."
  fi
fi

# ---------------------------------------------------------------- source tree
BUILT_BIN="$RUST_DIR/target/release/codex$EXE"

# `git commit` refuses to run when the machine has no configured identity, which used to abort the
# install after the clone and leave a staged-but-uncommitted patch behind. Supply a fallback
# identity for our own commit only; the user's global config still wins when it exists.
git_commit_as_installer() {
  local name email
  name="$(git config user.name  || echo "Conductor Installer")"
  email="$(git config user.email || echo "conductor-installer@localhost")"
  git -c "user.name=$name" -c "user.email=$email" commit -q "$@"
}

apply_patch() {
  # Runs inside SOURCE_DIR. Puts the tree on PATCH_BRANCH at UPSTREAM_TAG with the patch committed.
  git checkout -q -B "$PATCH_BRANCH" "$UPSTREAM_TAG"
  git apply --index "$PROJECT_DIR/patches/codex-orchestrator.patch"
  git_commit_as_installer -m "Add /effort and multi-model routing"
}

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  if [[ -e "$SOURCE_DIR" ]]; then
    die "$SOURCE_DIR exists but is not a git checkout; remove it and re-run"
  fi
  say "Cloning Codex repository (this is a few hundred MB)"
  # A blobless clone keeps every ref and tag — update-patched-codex.sh needs them to rebase onto a
  # newer release — while deferring file contents, which cuts the download by roughly two thirds.
  if ! git clone --filter=blob:none "$UPSTREAM_REPO" "$SOURCE_DIR"; then
    rm -rf "$SOURCE_DIR"
    die "failed to clone $UPSTREAM_REPO"
  fi
  say "Applying the /effort patch"
  if ! ( cd "$SOURCE_DIR" && apply_patch ); then
    die "could not apply patches/codex-orchestrator.patch to $UPSTREAM_TAG"
  fi
elif [[ ! -f "$SOURCE_DIR/$PATCH_SENTINEL" ]]; then
  # The clone exists but carries no patch: a previous run died between clone and commit. Repairing
  # here matters, because the old code skipped straight to the build and shipped vanilla Codex.
  say "Found an unpatched Codex checkout; applying the /effort patch"
  ( cd "$SOURCE_DIR" && git fetch --tags --quiet origin || true )
  if ! ( cd "$SOURCE_DIR" && apply_patch ); then
    die "could not apply patches/codex-orchestrator.patch to $UPSTREAM_TAG in $SOURCE_DIR"
  fi
else
  say "Using the existing patched checkout in $SOURCE_DIR"
  # A staged-but-uncommitted patch is what a pre-fix install left behind. It builds correctly, so
  # commit it rather than forcing the user to start over.
  if [[ -n "$(cd "$SOURCE_DIR" && git status --porcelain)" ]]; then
    ( cd "$SOURCE_DIR" && git add -A && git_commit_as_installer -m "Add /effort and multi-model routing" ) \
      && say "committed the previously uncommitted patch in $SOURCE_DIR" \
      || warn "$SOURCE_DIR has uncommitted changes that could not be committed; building them as-is"
  fi
fi

[[ -d "$RUST_DIR" ]] || die "no codex-rs directory in $SOURCE_DIR; the checkout looks broken"

# ---------------------------------------------------------------- build
if [[ "$SKIP_BUILD" == 0 ]]; then
  say "Building the patched Codex (release) — this takes a while on a first run"
  (
    cd "$RUST_DIR"
    CARGO_PROFILE_RELEASE_DEBUG=none \
    CARGO_PROFILE_RELEASE_STRIP=symbols \
    CARGO_NET_GIT_FETCH_WITH_CLI=true \
      cargo build --release -p codex-cli --bin codex
  )
else
  say "Skipping build (--skip-build)"
fi

if [[ ! -x "$BUILT_BIN" ]]; then
  if [[ "$SKIP_BUILD" == 1 ]]; then
    die "no built binary at $BUILT_BIN; re-run without --skip-build to compile it first"
  fi
  die "no built binary at $BUILT_BIN"
fi

# ---------------------------------------------------------------- package layout
say "Assembling the package layout in $PKG_DIR"
VERSION="$("$BUILT_BIN" --version 2>/dev/null | awk '{print $NF}')"
[[ -n "$VERSION" ]] || VERSION="unknown"

# Only metadata for codex-package.json, so fall back rather than failing when rustc is absent
# (which is legitimate under --skip-build).
if command -v rustc >/dev/null; then
  TARGET="$(rustc -vV | awk '/host:/ {print $2}')"
else
  TARGET="$(uname -m)-unknown-$(uname -s | tr '[:upper:]' '[:lower:]')"
fi

find_vendor_dir() {
  local candidates=()
  if [[ -n "$ORIGINAL_CODEX" && "$ORIGINAL_CODEX" != "$BIN_DIR/codex$EXE" ]]; then
    local resolved
    if command -v realpath >/dev/null; then
        resolved="$(realpath "$ORIGINAL_CODEX")"
    else
        resolved="$(cd "$(dirname "$ORIGINAL_CODEX")" && pwd)/$(basename "$ORIGINAL_CODEX")"
    fi
    for d in "$(dirname "$resolved")"/../node_modules/@openai/codex-*/vendor/*; do
      if [[ -d "$d" ]]; then candidates+=("$d"); fi
    done
  fi

  # ${VAR:-} matters: APPDATA and USERPROFILE are unset everywhere except Windows, and under
  # `set -u` a bare expansion aborted this function before it reached any real candidate — so the
  # vendor directory was never found on Linux or macOS.
  for prefix in /usr/lib /usr/local/lib /opt/homebrew/lib ~/.nvm/versions/node/*/lib \
                "${APPDATA:-}/npm" "${USERPROFILE:-}/AppData/Roaming/npm"; do
    [[ "$prefix" == /npm || "$prefix" == "/AppData/Roaming/npm" ]] && continue
    for d in "$prefix"/node_modules/@openai/codex/node_modules/@openai/codex-*/vendor/* \
             "$prefix"/node_modules/@openai/codex-*/vendor/*; do
      if [[ -d "$d" ]]; then candidates+=("$d"); fi
    done
  done

  candidates+=("$CODEX_HOME/packages/standalone/releases")

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate/bin" || -d "$candidate/codex-resources" ]]; then
      (cd "$candidate" && pwd)
      return 0
    fi
  done
  return 1
}

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/bin"
install -m 0755 "$BUILT_BIN" "$PKG_DIR/bin/codex$EXE"

if VENDOR_DIR="$(find_vendor_dir)"; then
  say "Copying bundled helpers from $VENDOR_DIR"
  for dir in codex-resources codex-path; do
    [[ -d "$VENDOR_DIR/$dir" ]] && cp -a "$VENDOR_DIR/$dir" "$PKG_DIR/"
  done
  if [[ -f "$VENDOR_DIR/bin/codex-code-mode-host$EXE" ]]; then
    install -m 0755 "$VENDOR_DIR/bin/codex-code-mode-host$EXE" "$PKG_DIR/bin/codex-code-mode-host$EXE"
  fi
else
  warn "could not find a bundled Codex vendor directory."
  warn "The patched binary will fall back to the system ripgrep/bwrap where possible."
fi

cat >"$PKG_DIR/codex-package.json" <<JSON
{
  "layoutVersion": 1,
  "version": "$VERSION",
  "target": "$TARGET",
  "variant": "codex",
  "entrypoint": "bin/codex$EXE",
  "resourcesDir": "codex-resources",
  "pathDir": "codex-path"
}
JSON

# ---------------------------------------------------------------- link
say "Installing 'codex' to $BIN_DIR"
mkdir -p "$BIN_DIR" "$BACKUP_DIR"
if [[ -e "$BIN_DIR/codex$EXE" && ! -L "$BIN_DIR/codex$EXE" ]]; then
  mv "$BIN_DIR/codex$EXE" "$BACKUP_DIR/codex.$STAMP$EXE"
  warn "moved the pre-existing $BIN_DIR/codex$EXE to $BACKUP_DIR/codex.$STAMP$EXE"
fi
ln -sfn "$PKG_DIR/bin/codex$EXE" "$BIN_DIR/codex$EXE"

if [[ -n "$ORIGINAL_CODEX" && "$ORIGINAL_CODEX" != "$BIN_DIR/codex$EXE" ]]; then
  printf '%s\n' "$ORIGINAL_CODEX" >"$PROJECT_DIR/.original-codex-path"
fi

# Confirm we actually installed the patched build rather than a stock one.
if ! "$PKG_DIR/bin/codex$EXE" --version >/dev/null 2>&1; then
  warn "the installed binary did not respond to --version; check the build output above"
fi

# ---------------------------------------------------------------- orchestrator assets
say "Installing the routing skill"
mkdir -p "$SKILLS_DIR"
rm -rf "$SKILLS_DIR/codex-orchestrator-routing"
cp -a "$PROJECT_DIR/skill/codex-orchestrator-routing" "$SKILLS_DIR/"

say "Discovering models and writing the agent roles"
if [[ -f "$PROJECT_DIR/bin/codex-orchestrator-sync" ]]; then
  # The model cache only exists once Codex has run at least once and signed in, so a failure here
  # is expected on a fresh machine and must not fail the whole install.
  if ! python3 "$PROJECT_DIR/bin/codex-orchestrator-sync" --max-agents="$MAX_AGENTS"; then
    warn "could not generate the agent roles yet."
    warn "Start 'codex' once so it caches your account's model list, then re-run:"
    warn "    $PROJECT_DIR/bin/codex-orchestrator-sync"
  fi
fi

# ---------------------------------------------------------------- auto-update
# A daily systemd user timer runs bin/conductor-autoupdate, which rebases, builds, tests and
# installs new upstream releases on its own. Linux with a systemd user session only.
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
if [[ "$AUTO_UPDATE" == 1 ]] && command -v systemctl >/dev/null \
   && systemctl --user show-environment >/dev/null 2>&1; then
  say "Installing the daily auto-update timer"
  mkdir -p "$UNIT_DIR"
  cat >"$UNIT_DIR/conductor-autoupdate.service" <<UNIT
[Unit]
Description=Rebase, build, test and install the Conductor patched Codex on new upstream releases
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=PATH=$BIN_DIR:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$PROJECT_DIR/bin/conductor-autoupdate
Nice=19
TimeoutStartSec=6h
UNIT
  cat >"$UNIT_DIR/conductor-autoupdate.timer" <<UNIT
[Unit]
Description=Check daily for a new upstream Codex release for Conductor

[Timer]
OnBootSec=15min
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now conductor-autoupdate.timer >/dev/null
elif [[ "$AUTO_UPDATE" == 1 ]]; then
  warn "no systemd user session; run $PROJECT_DIR/bin/conductor-autoupdate yourself (e.g. from cron)"
fi

# ---------------------------------------------------------------- report
say "Done"
echo
echo "  which codex (before): ${ORIGINAL_CODEX:-<none>}"
hash -r 2>/dev/null || true
echo "  which codex (after) : $(command -v codex || echo "$BIN_DIR/codex$EXE")"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    warn "$BIN_DIR is still not on your PATH, so 'codex' will not resolve to this build."
    echo "  bash: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" >&2
    echo "  zsh : echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" >&2
    echo "  fish: fish_add_path -m ~/.local/bin" >&2
    ;;
esac
