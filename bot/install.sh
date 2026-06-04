#!/usr/bin/env bash
# install.sh — set up the DTM-R bot on a fresh Linux VPS (Debian/Ubuntu).
# Creates a venv, installs deps, scaffolds .env, and (optionally) installs a
# systemd service that keeps the bot running and restarts it on failure/boot.
#
#   ./install.sh            # venv + deps + .env scaffold
#   ./install.sh --systemd  # also install & enable the systemd service
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
PY="${PYTHON:-python3}"

echo ">> DTM-R bot install in $HERE"

if ! command -v "$PY" >/dev/null 2>&1; then
  echo ">> installing python3 + venv (needs sudo)"
  sudo apt-get update -y && sudo apt-get install -y python3 python3-venv python3-pip
fi

echo ">> creating virtualenv .venv"
"$PY" -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip >/dev/null
pip install -r requirements.txt

if [ ! -f .env ]; then
  cp .env.example .env
  chmod 600 .env
  echo ">> created .env from template — EDIT IT with your API keys before going live."
else
  echo ">> .env already exists; leaving it untouched."
fi

echo ">> smoke test (offline signing + indicator parity)"
.venv/bin/python selftest_offline.py || { echo "!! offline self-test failed"; exit 1; }

if [ "${1:-}" = "--systemd" ]; then
  SVC=/etc/systemd/system/dtmr-bot.service
  echo ">> installing systemd unit -> $SVC (needs sudo)"
  sudo bash -c "sed -e 's|__WORKDIR__|$HERE|g' -e 's|__USER__|$USER|g' \
      '$HERE/systemd/dtmr-bot.service' > '$SVC'"
  sudo systemctl daemon-reload
  sudo systemctl enable dtmr-bot.service
  echo ">> service installed. Start with:  sudo systemctl start dtmr-bot"
  echo ">> logs:                            journalctl -u dtmr-bot -f"
fi

cat <<EOF

================ NEXT STEPS ================
1) Edit  $HERE/.env  with your Binance Futures API key/secret.
2) Validate signals (no auth):   ./run.sh --selftest
3) Paper-trade first (DEFAULT):  TESTNET=true DRY_RUN=true   ./run.sh --once
4) When confident, set DRY_RUN=false (still TESTNET) to place test orders.
5) Only after a solid testnet run, set TESTNET=false for real money.
   Start with a SMALL balance and watch the first live cycles.
============================================
EOF
