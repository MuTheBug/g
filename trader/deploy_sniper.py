#!/usr/bin/env python3
"""
SAFE DEPLOYMENT for the Washout Sniper production bot.

Usage:  .venv/bin/python deploy_sniper.py <candidate.py> [--skip-parity]

Sequence (aborts loudly at the first failure, Telegram-alerting each abort):
  0. VERIFY     candidate compiles; strategy-parity test vs the research backtest
                (research/verify_sniper_parity.py <candidate>) unless --skip-parity.
  1. POSITION CHECK   broker API must report ZERO open positions AND zero resting
                orders from the bot — otherwise ABORT (never hot-swap mid-trade).
  2. BACKUP     copy the active script to backup/old_strategy_backup_<TIMESTAMP>.py.
  3. HOT-SWAP   atomically replace the production script with the candidate.
  4. RESTART    systemctl restart, then poll until the service is active and the
                startup line appears in the log; on failure, AUTO-ROLLBACK to the
                backup and restart again.
"""
from __future__ import annotations
import os
import py_compile
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

TRADER = os.path.dirname(os.path.abspath(__file__))
LIVE = os.path.join(TRADER, "washout_sniper_bot.py")
BACKUP_DIR = os.path.join(TRADER, "backup")
SERVICE = "washout-sniper-bot"
LOG = os.path.join(TRADER, "sniper.log")
PARITY = "/root/ttt/binance-futures-klines/research/verify_sniper_parity.py"
PARITY_CWD = "/root/ttt/binance-futures-klines/research"

sys.path.insert(0, TRADER)
import washout_sniper_bot as live_mod          # reuse client + telegram of the live code


def log(msg):
    print(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')}  [deploy] {msg}",
          flush=True)


def alert(msg):
    log(msg)
    try:
        live_mod.tg(f"🛠 <b>deploy</b>: {msg}")
    except Exception:
        pass


def abort(msg):
    alert(f"❌ ABORTED — {msg}")
    sys.exit(1)


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: deploy_sniper.py <candidate.py> [--skip-parity]")
    candidate = os.path.abspath(sys.argv[1])
    skip_parity = "--skip-parity" in sys.argv
    if not os.path.exists(candidate):
        abort(f"candidate not found: {candidate}")
    if os.path.samefile(candidate, LIVE):
        abort("candidate IS the live file; stage a copy instead")

    # ---- 0. verify candidate ----
    try:
        py_compile.compile(candidate, doraise=True)
        log("compile check: OK")
    except py_compile.PyCompileError as e:
        abort(f"candidate does not compile: {e}")
    if skip_parity:
        log("parity check: SKIPPED by flag")
    else:
        # research env python (has pyarrow for the parquet matrices), not the bot venv
        r = subprocess.run(["python3", PARITY, candidate],
                           cwd=PARITY_CWD, capture_output=True, text=True, timeout=1800)
        tail = (r.stdout or "").strip().splitlines()[-1:] or ["(no output)"]
        if r.returncode != 0:
            abort(f"strategy parity FAILED: {tail[0]}")
        log(f"parity check: OK ({tail[0]})")

    # ---- 1. position check ----
    bx = live_mod.Binance(live_mod.API_KEY, live_mod.API_SECRET, live_mod.HOST)
    try:
        open_pos = [p["symbol"] for p in bx.positions()
                    if float(p.get("positionAmt") or 0) != 0]
        open_orders = bx._get("/fapi/v1/openOrders", {}, signed=True)
    except Exception as e:
        abort(f"broker API check failed: {e}")
    if open_pos:
        abort(f"OPEN POSITIONS exist: {', '.join(open_pos)} — deploy after they close "
              f"(or /flatten first)")
    if open_orders:
        abort(f"{len(open_orders)} resting order(s) on the book — deploy after they "
              f"clear (entry bids expire within 5 minutes)")
    log("position check: ZERO open positions, zero resting orders")

    # ---- 2. backup ----
    os.makedirs(BACKUP_DIR, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = os.path.join(BACKUP_DIR, f"old_strategy_backup_{ts}.py")
    shutil.copy2(LIVE, backup)
    log(f"backup: {backup}")

    # ---- 3. hot-swap (atomic) ----
    tmp = LIVE + ".deploy_tmp"
    shutil.copy2(candidate, tmp)
    os.replace(tmp, LIVE)
    log(f"hot-swap: {os.path.basename(candidate)} -> {os.path.basename(LIVE)}")

    # ---- 4. restart + health check (rollback on failure) ----
    log_size = os.path.getsize(LOG) if os.path.exists(LOG) else 0
    subprocess.run(["systemctl", "restart", SERVICE], check=False)
    deadline = time.time() + 180
    healthy = False
    while time.time() < deadline:
        time.sleep(5)
        state = subprocess.run(["systemctl", "is-active", SERVICE],
                               capture_output=True, text=True).stdout.strip()
        if state != "active":
            continue
        try:
            with open(LOG) as f:
                f.seek(log_size)
                new = f.read()
            if "warmup done" in new and "Traceback" not in new:
                healthy = True
                break
            if "Traceback" in new:
                break
        except OSError:
            pass
    if healthy:
        alert(f"✅ deployed {os.path.basename(candidate)} — service active, warmup OK. "
              f"Backup: {os.path.basename(backup)}")
        log("SUCCESS")
        return
    # rollback
    alert("⚠️ health check FAILED after swap — rolling back to backup")
    shutil.copy2(backup, LIVE)
    subprocess.run(["systemctl", "restart", SERVICE], check=False)
    time.sleep(8)
    state = subprocess.run(["systemctl", "is-active", SERVICE],
                           capture_output=True, text=True).stdout.strip()
    abort(f"deploy failed; rolled back to {os.path.basename(backup)} "
          f"(service now: {state})")


if __name__ == "__main__":
    main()
