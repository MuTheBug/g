#!/usr/bin/env bash
# run.sh — activate the venv and launch the bot. Passes through any args
# (e.g. --once, --selftest). Used directly or by the systemd unit.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
if [ ! -d .venv ]; then
  echo "!! .venv missing — run ./install.sh first" >&2
  exit 1
fi
# shellcheck disable=SC1091
source .venv/bin/activate
exec python run.py "$@"
