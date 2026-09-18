#!/usr/bin/env bash
# Remove everything install.sh added and restore the original `codex`.
#
# Only our own files are touched: the ~/.local/bin/codex symlink, the generated agent roles, the
# routing skill, and the two clearly marked managed blocks in $CODEX_HOME/config.toml and
# $CODEX_HOME/AGENTS.md. Your own settings, sessions and auth are left alone.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$PROJECT_DIR/pkg"
BACKUP_DIR="$PROJECT_DIR/backup"
BIN_DIR="${CODEX_ORCHESTRATOR_BIN_DIR:-$HOME/.local/bin}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
STAMP="$(date +%Y%m%d-%H%M%S)"

KEEP_SOURCE=1
for arg in "$@"; do
  case "$arg" in
    --purge-source) KEEP_SOURCE=0 ;;
    -h|--help)
      sed -n '2,6p' "${BASH_SOURCE[0]}"
      echo
      echo "Usage: uninstall.sh [--purge-source]"
      echo "  --purge-source  also delete the built binary and package layout (keeps the git clone)"
      exit 0
      ;;
    *) echo "uninstall.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

BEGIN_MARKER='# >>> codex-orchestrator >>>'
END_MARKER='# <<< codex-orchestrator <<<'

strip_block() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -qF "$BEGIN_MARKER" "$file" || return 0
  mkdir -p "$BACKUP_DIR"
  cp -a "$file" "$BACKUP_DIR/$(basename "$file").$STAMP"
  python3 - "$file" "$BEGIN_MARKER" "$END_MARKER" <<'PY'
import re
import sys

path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
cleaned = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", "", text, flags=re.DOTALL)
cleaned = cleaned.rstrip()
with open(path, "w", encoding="utf-8") as handle:
    handle.write(cleaned + "\n" if cleaned else "")
PY
  say "removed the managed block from $file (backup in $BACKUP_DIR)"
}

# ------------------------------------------------------------------ binary
if [[ -L "$BIN_DIR/codex" ]]; then
  target="$(readlink -f "$BIN_DIR/codex" || true)"
  if [[ "$target" == "$PKG_DIR/bin/codex" ]]; then
    rm -f "$BIN_DIR/codex"
    say "removed $BIN_DIR/codex"
  else
    say "left $BIN_DIR/codex alone: it points at $target, not our build"
  fi
elif [[ -e "$BIN_DIR/codex" ]]; then
  say "left $BIN_DIR/codex alone: it is not our symlink"
fi

# Restore any pre-existing binary we moved out of the way during install.
restored="$(ls -1t "$BACKUP_DIR"/codex.* 2>/dev/null | head -1 || true)"
if [[ -n "$restored" && ! -e "$BIN_DIR/codex" ]]; then
  mv "$restored" "$BIN_DIR/codex"
  say "restored $BIN_DIR/codex from $restored"
fi

# ------------------------------------------------------------------ assets
for role in explorer_low verifier_low implementer_medium debugger_high architect_high; do
  if [[ -f "$CODEX_HOME/agents/$role.toml" ]]; then
    rm -f "$CODEX_HOME/agents/$role.toml"
    say "removed $CODEX_HOME/agents/$role.toml"
  fi
done
rmdir "$CODEX_HOME/agents" 2>/dev/null || true

if [[ -d "$CODEX_HOME/skills/codex-orchestrator-routing" ]]; then
  rm -rf "$CODEX_HOME/skills/codex-orchestrator-routing"
  say "removed the routing skill"
fi

strip_block "$CODEX_HOME/config.toml"
strip_block "$CODEX_HOME/AGENTS.md"

if [[ "$KEEP_SOURCE" == 0 ]]; then
  rm -rf "$PKG_DIR" "$PROJECT_DIR/codex/codex-rs/target"
  say "removed the package layout and build artifacts"
fi

# ------------------------------------------------------------------ report
hash -r 2>/dev/null || true
say "Done"
echo
if [[ -f "$PROJECT_DIR/.original-codex-path" ]]; then
  echo "  codex before install : $(cat "$PROJECT_DIR/.original-codex-path")"
fi
echo "  which codex : $(command -v codex || echo '<none on PATH>')"
if command -v codex >/dev/null; then
  echo "  resolves to : $(readlink -f "$(command -v codex)")"
  echo "  version     : $(codex --version 2>/dev/null || echo '<unavailable>')"
fi
echo
echo "  The tier mapping in ${XDG_CONFIG_HOME:-$HOME/.config}/codex-orchestrator/config.toml was"
echo "  left in place; delete that directory if you want it gone too."
