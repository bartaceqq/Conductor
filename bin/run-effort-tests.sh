#!/usr/bin/env bash
# Run the tests that cover the /effort patch, plus the neighbouring upstream suites it could break.
#
# Kept separate from install.sh so update-patched-codex.sh can gate an upgrade on it.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$PROJECT_DIR/codex/codex-rs"

cd "$RUST_DIR"

# Debug info dominates test-binary size; turn it off so a full run fits on a small disk.
export CARGO_PROFILE_TEST_DEBUG=none
export CARGO_PROFILE_DEV_DEBUG=none
export CARGO_NET_GIT_FETCH_WITH_CLI=true

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

say "cargo fmt --check"
cargo fmt --all -- --check

say "Our /effort tests"
cargo test -p codex-tui --lib -- \
  effort_status \
  effort_command \
  slash_command::tests

say "Neighbouring upstream TUI suites"
cargo test -p codex-tui --lib -- \
  bottom_pane::chat_composer \
  bottom_pane::command_popup \
  chatwidget::tests::slash_commands \
  status::tests

echo
say "All /effort tests passed"
