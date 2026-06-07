#!/usr/bin/env bash
# One-click installer for the v3 trend bot on a Linux VPS.
#   bash trader/install.sh
# Creates a venv, installs deps, ensures config.env, and installs+starts a
# systemd service that auto-restarts and survives reboots.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE="v3-trend-bot"
USER_NAME="$(whoami)"
PY="$(command -v python3 || true)"

echo "==> v3 trend bot installer"
[ -n "$PY" ] || { echo "python3 not found (apt install python3 python3-venv)"; exit 1; }

# 1) venv + deps
"$PY" -m venv "$DIR/.venv"
"$DIR/.venv/bin/pip" -q install --upgrade pip
"$DIR/.venv/bin/pip" -q install -r "$DIR/requirements.txt"
echo "    deps installed."

# 2) config (credentials come from /root/keys.txt; config.env holds runtime knobs)
if [ ! -f "$DIR/config.env" ]; then
  cp "$DIR/config.example.env" "$DIR/config.env"; chmod 600 "$DIR/config.env"
  echo "==> wrote $DIR/config.env — review it (keep DRY_RUN=true first)."
fi
[ -f /root/keys.txt ] && echo "==> credentials will load from /root/keys.txt" \
  || echo "!! /root/keys.txt not found — put BINANCE_API_KEY/SECRET + TELEGRAM_* there or in config.env"

# 3) systemd service
if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
  UNIT="/etc/systemd/system/${SERVICE}.service"
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=v3 trend Binance futures bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER_NAME}
WorkingDirectory=${DIR}
EnvironmentFile=${DIR}/config.env
ExecStart=${DIR}/.venv/bin/python ${DIR}/v3_trend_bot.py
Restart=always
RestartSec=10
StandardOutput=append:${DIR}/bot.log
StandardError=append:${DIR}/bot.log

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE"
  echo "==> installed. Start: sudo systemctl start ${SERVICE}  ·  logs: tail -f ${DIR}/bot.log"
  echo "    When happy, set DRY_RUN=false in config.env and: sudo systemctl restart ${SERVICE}"
else
  echo "==> systemd absent. Run manually:"
  echo "   set -a; source ${DIR}/config.env; set +a"
  echo "   nohup ${DIR}/.venv/bin/python ${DIR}/v3_trend_bot.py > ${DIR}/bot.log 2>&1 &"
fi
