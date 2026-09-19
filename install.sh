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

EXE=""
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
    EXE=".exe"
fi

SKIP_BUILD=0
MAX_AGENTS=4
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --max-agents=*) MAX_AGENTS="${arg#*=}" ;;
    -h|--help)
      sed -n '2,8p' "${BASH_SOURCE[0]}"
      echo
      echo "Usage: install.sh [--skip-build] [--max-agents=N]"
      exit 0
      ;;
    *) echo "install.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- pre-flight
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

# ---------------------------------------------------------------- build
BUILT_BIN="$RUST_DIR/target/release/codex$EXE"

if [[ ! -d "$SOURCE_DIR" || ! -d "$RUST_DIR" ]]; then
  say "Cloning Codex repository and applying patch"
  command -v git >/dev/null || die "git not found"
  git clone https://github.com/openai/codex.git "$SOURCE_DIR"
  (
    cd "$SOURCE_DIR"
    git checkout -b orchestrator/effort-0.155.0 rust-v0.155.0
    git apply "$PROJECT_DIR/patches/codex-orchestrator.patch"
    git add .
    git commit -m "Add /effort and multi-model routing"
  )
fi

if [[ "$SKIP_BUILD" == 0 ]]; then
  command -v cargo >/dev/null || die "cargo not found; install Rust or pass --skip-build"
  say "Building the patched Codex (release)"
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
[[ -x "$BUILT_BIN" ]] || die "no built binary at $BUILT_BIN"

# ---------------------------------------------------------------- package layout
say "Assembling the package layout in $PKG_DIR"
VERSION="$("$BUILT_BIN" --version 2>/dev/null | awk '{print $NF}')"
[[ -n "$VERSION" ]] || VERSION="unknown"
TARGET="$(rustc -vV | awk '/host:/ {print $2}')"

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
  
  for prefix in /usr/lib /usr/local/lib /opt/homebrew/lib ~/.nvm/versions/node/*/lib "$APPDATA/npm" "$USERPROFILE/AppData/Roaming/npm"; do
    for d in "$prefix"/node_modules/@openai/codex/node_modules/@openai/codex-*/vendor/*; do
      if [[ -d "$d" ]]; then candidates+=("$d"); fi
    done
  done
  
  candidates+=("$HOME/.codex/packages/standalone/releases")

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

# ---------------------------------------------------------------- orchestrator assets
say "Installing the routing skill"
mkdir -p "$SKILLS_DIR"
rm -rf "$SKILLS_DIR/codex-orchestrator-routing"
cp -a "$PROJECT_DIR/skill/codex-orchestrator-routing" "$SKILLS_DIR/"

say "Discovering models and writing the agent roles"
if [[ -f "$PROJECT_DIR/bin/codex-orchestrator-sync" ]]; then
    "$PROJECT_DIR/bin/codex-orchestrator-sync" --max-agents="$MAX_AGENTS"
fi

# ---------------------------------------------------------------- report
say "Done"
echo
echo "  which codex (before): ${ORIGINAL_CODEX:-<none>}"
hash -r 2>/dev/null || true
echo "  which codex (after) : $(command -v codex || echo "$BIN_DIR/codex$EXE")"
echo "  version             : $("$BIN_DIR/codex$EXE" --version 2>/dev/null || echo '<unavailable>')"
echo
echo "  Try it:  cd ~/your-project && codex   then type /effort"
echo "  Undo  :  $PROJECT_DIR/uninstall.sh"

