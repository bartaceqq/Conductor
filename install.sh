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
  *) die "$BIN_DIR is not on PATH. Add it (earlier than the existing codex) and re-run." ;;
esac

if [[ -n "$ORIGINAL_CODEX" && "$ORIGINAL_CODEX" == "$BIN_DIR/codex" ]]; then
  say "$BIN_DIR/codex already exists; it will be replaced by this build"
elif [[ -n "$ORIGINAL_CODEX" ]]; then
  # Confirm our directory really does win once installed.
  first_hit="$(IFS=:; for d in $PATH; do [[ -x "$d/codex" ]] && { echo "$d"; break; }; done || true)"
  if [[ -n "$first_hit" && "$first_hit" != "$BIN_DIR" ]]; then
    prefix_ok=0
    IFS=: read -ra path_dirs <<<"$PATH"
    for d in "${path_dirs[@]}"; do
      [[ "$d" == "$BIN_DIR" ]] && { prefix_ok=1; break; }
      [[ "$d" == "$first_hit" ]] && break
    done
    [[ "$prefix_ok" == 1 ]] || die "$BIN_DIR comes after $first_hit on PATH; 'codex' would not resolve to our build."
  fi
fi

# ---------------------------------------------------------------- build
BUILT_BIN="$RUST_DIR/target/release/codex"
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
# Codex locates ripgrep, bwrap and the code-mode host relative to its own package directory
# (bin/, codex-resources/, codex-path/ next to codex-package.json). Build that layout so the
# patched binary keeps every bundled helper the official install provides.
say "Assembling the package layout in $PKG_DIR"
VERSION="$("$BUILT_BIN" --version 2>/dev/null | awk '{print $NF}')"
[[ -n "$VERSION" ]] || VERSION="unknown"

find_vendor_dir() {
  local candidates=()
  if [[ -n "$ORIGINAL_CODEX" && "$ORIGINAL_CODEX" != "$BIN_DIR/codex" ]]; then
    local resolved
    resolved="$(readlink -f "$ORIGINAL_CODEX")"
    candidates+=("$(dirname "$resolved")/../node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl")
  fi
  candidates+=(
    "/usr/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl"
    "/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl"
    "$HOME/.codex/packages/standalone/releases"
  )
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
install -m 0755 "$BUILT_BIN" "$PKG_DIR/bin/codex"

if VENDOR_DIR="$(find_vendor_dir)"; then
  say "Copying bundled helpers from $VENDOR_DIR"
  for dir in codex-resources codex-path; do
    [[ -d "$VENDOR_DIR/$dir" ]] && cp -a "$VENDOR_DIR/$dir" "$PKG_DIR/"
  done
  if [[ -f "$VENDOR_DIR/bin/codex-code-mode-host" ]]; then
    install -m 0755 "$VENDOR_DIR/bin/codex-code-mode-host" "$PKG_DIR/bin/codex-code-mode-host"
  fi
else
  warn "could not find a bundled Codex vendor directory."
  warn "The patched binary will fall back to the system ripgrep/bwrap where possible."
fi

cat >"$PKG_DIR/codex-package.json" <<JSON
{
  "layoutVersion": 1,
  "version": "$VERSION",
  "target": "x86_64-unknown-linux-musl",
  "variant": "codex",
  "entrypoint": "bin/codex",
  "resourcesDir": "codex-resources",
  "pathDir": "codex-path"
}
JSON

# ---------------------------------------------------------------- link
say "Installing 'codex' to $BIN_DIR"
mkdir -p "$BIN_DIR" "$BACKUP_DIR"
if [[ -e "$BIN_DIR/codex" && ! -L "$BIN_DIR/codex" ]]; then
  mv "$BIN_DIR/codex" "$BACKUP_DIR/codex.$STAMP"
  warn "moved the pre-existing $BIN_DIR/codex to $BACKUP_DIR/codex.$STAMP"
fi
ln -sfn "$PKG_DIR/bin/codex" "$BIN_DIR/codex"

# Record what 'codex' resolved to before us, so uninstall can report the restored state.
if [[ -n "$ORIGINAL_CODEX" && "$ORIGINAL_CODEX" != "$BIN_DIR/codex" ]]; then
  printf '%s\n' "$ORIGINAL_CODEX" >"$PROJECT_DIR/.original-codex-path"
fi

# ---------------------------------------------------------------- orchestrator assets
say "Installing the routing skill"
mkdir -p "$SKILLS_DIR"
rm -rf "$SKILLS_DIR/codex-orchestrator-routing"
cp -a "$PROJECT_DIR/skill/codex-orchestrator-routing" "$SKILLS_DIR/"

say "Discovering models and writing the agent roles"
"$PROJECT_DIR/bin/codex-orchestrator-sync" --max-agents="$MAX_AGENTS"

# ---------------------------------------------------------------- report
say "Done"
echo
echo "  which codex (before): ${ORIGINAL_CODEX:-<none>}"
hash -r 2>/dev/null || true
echo "  which codex (after) : $(command -v codex)"
echo "  resolves to         : $(readlink -f "$(command -v codex)")"
echo "  version             : $(codex --version 2>/dev/null || echo '<unavailable>')"
echo
echo "  agent roles         : $CODEX_HOME/agents"
echo "  routing skill       : $SKILLS_DIR/codex-orchestrator-routing"
echo "  tier mapping        : ${XDG_CONFIG_HOME:-$HOME/.config}/codex-orchestrator/config.toml"
echo "  backups             : $BACKUP_DIR"
echo
echo "  Try it:  cd ~/your-project && codex   then type /effort"
echo "  Undo  :  $PROJECT_DIR/uninstall.sh"
