#!/usr/bin/env bash
set -euo pipefail
grep -q '"Save Changes"' src/settings_screen.c
! grep -q '"Sav Changes"' src/settings_screen.c
grep -q '"Cancel"' src/settings_screen.c
