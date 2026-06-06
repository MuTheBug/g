"""Telegram notifications for the live trader.

Configure with env vars APEX_TELEGRAM_TOKEN and APEX_TELEGRAM_CHAT_ID. If either
is missing, the notifier is a silent no-op (the bot still runs and logs).

Create a bot with @BotFather to get the token; get your chat id by messaging the
bot then visiting https://api.telegram.org/bot<token>/getUpdates (look for
"chat":{"id":...}), or message @userinfobot.
"""
import time
import logging
import requests

log = logging.getLogger("notify")


class Telegram:
    def __init__(self, token, chat_id):
        self.token = (token or "").strip()
        self.chat_id = (chat_id or "").strip()
        self.enabled = bool(self.token and self.chat_id)
        self._last = {}   # throttle bookkeeping: key -> last-sent epoch

    def send(self, text, throttle_key=None, throttle_s=0):
        """Send a message. With throttle_key, drops repeats sent within
        throttle_s seconds (used for noisy/error messages)."""
        if not self.enabled:
            return False
        if throttle_key is not None:
            now = time.time()
            if now - self._last.get(throttle_key, 0) < throttle_s:
                return False
            self._last[throttle_key] = now
        try:
            r = requests.post(
                f"https://api.telegram.org/bot{self.token}/sendMessage",
                json={"chat_id": self.chat_id, "text": text,
                      "disable_web_page_preview": True},
                timeout=10)
            if r.status_code != 200:
                log.warning("telegram send failed %s: %s", r.status_code,
                            r.text[:200])
                return False
            return True
        except Exception as e:
            log.warning("telegram error: %s", e)
            return False
