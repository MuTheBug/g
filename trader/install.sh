#!/usr/bin/env bash
# One-click installer for the momentum-basket bot on a Linux VPS.
#
#   curl -fsSL <raw-url>/trader/install.sh | bash      # or:
#   bash trader/install.sh
#
# It creates a venv, installs deps, writes a config.env you fill in, and
# installs+starts a systemd service that auto-restarts and survives reboots.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE="momentum-basket-bot"
USER_NAME="$(whoami)"
PY="$(command -v python3 || true)"

echo "==> momentum-basket bot installer"
[ -n "$PY" ] || { echo "python3 not found. Install it first (e.g. apt install python3 python3-venv)"; exit 1; }

# 1) venv + deps
echo "==> creating venv at $DIR/.venv"
"$PY" -m venv "$DIR/.venv"
"$DIR/.venv/bin/pip" -q install --upgrade pip
"$DIR/.venv/bin/pip" -q install -r "$DIR/requirements.txt"
echo "    deps installed."

# 2) config
if [ ! -f "$DIR/config.env" ]; then
  cp "$DIR/config.example.env" "$DIR/config.env"
  chmod 600 "$DIR/config.env"
  echo "==> wrote $DIR/config.env  — EDIT IT NOW with your API + Telegram keys."
else
  echo "==> config.env already exists; leaving it untouched."
fi

# 3) systemd service (falls back to manual run if systemd is absent)
if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
  UNIT="/etc/systemd/system/${SERVICE}.service"
  echo "==> installing systemd unit at $UNIT (needs sudo)"
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=Momentum-basket Binance futures bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER_NAME}
WorkingDirectory=${DIR}
EnvironmentFile=${DIR}/config.env
ExecStart=${DIR}/.venv/bin/python ${DIR}/momentum_basket_bot.py
Restart=always
RestartSec=10
StandardOutput=append:${DIR}/bot.log
StandardError=append:${DIR}/bot.log

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE"
  cat <<EOF

==> Installed. Next steps:
   1. nano ${DIR}/config.env          # paste your keys; keep TESTNET+DRY_RUN=true first
   2. sudo systemctl start ${SERVICE}
   3. journalctl -u ${SERVICE} -f     # or: tail -f ${DIR}/bot.log
   When happy, set BINANCE_TESTNET=false and DRY_RUN=false in config.env, then
   sudo systemctl restart ${SERVICE}
EOF
else
  cat <<EOF

==> systemd not available. Run manually instead:
   1. nano ${DIR}/config.env
   2. set -a; source ${DIR}/config.env; set +a
      nohup ${DIR}/.venv/bin/python ${DIR}/momentum_basket_bot.py > ${DIR}/bot.log 2>&1 &
   tail -f ${DIR}/bot.log
EOF
fi
