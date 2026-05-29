"""Portfolio backtest of the daily EMA Stack Trend across a principled
crypto universe — the correct way to judge a trend-follower (capped risk
per trade, many symbols, fat-tail payoff) instead of per-symbol PF.

Universe filter is STRUCTURAL and a-priori (NOT based on who won):
  - crypto only: exclude tokenized stocks / commodities / FX that ride
    the same futures venue (XAU, XAG, PAXG, MSTR, INTC, SOXL, ...).
  - maturity: >= MIN_BARS daily candles so indicators warm up and there's
    a real out-of-sample window.

Shared-equity event sim over the HELD-OUT calendar window (most recent
~25% of BTC's history, same cutoff for all symbols — no look-ahead, and
the strategy has no fitted params so the window choice can't overfit):
  - risk RISK_PCT of current equity per trade; qty = risk / (3*ATR)
    so a catastrophic-stop hit loses ~1 risk unit.
  - <= MAX_CONCURRENT open positions at once (ties broken by higher ADX).
  - entry/exit = the SHIPPED rules (stack + 5-bar persist + ADX>30,
    3*ATR stop, EMA8/21 cross-back exit), long + short.
Fees 0.04%/side. Reports blended return, max DD, trades, win rate.
"""

from __future__ import annotations
import importlib.util, math
from pathlib import Path
import numpy as np, pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
_spec = importlib.util.spec_from_file_location("v2", str(ROOT / "tool" / "backtest_ema_stack_v2.py"))
v2 = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(v2)

# Non-crypto tokenized assets on the futures venue — excluded a priori.
EXCLUDE = {
    "XAU", "XAG", "PAXG", "CL", "BZ",                      # metals / oil
    "MSTR", "INTC", "SOXL", "MU", "SNDK", "CRCL", "HEI",   # tokenized stocks
    "NVDA", "COIN", "AAPL", "TSLA", "GENIUS", "INTL",      # (defensive extras)
}
MIN_BARS = 500          # ~1.4yr of daily history
ADX_MIN = 30.0
CAT_STOP_ATR = 3.0
PERSIST = 5
RISK_PCT = 0.02         # 2% of equity risked per trade
MAX_CONCURRENT = 10
FEE = 0.0004            # per side
HELDOUT_FRAC = 0.75     # calendar cutoff = 75% through BTC's history


def base_of(path): return path.stem.replace("_USDT_1d", "")


def precompute(df):
    """Per-bar arrays + entry flags using the shipped rules."""
    d = v2.prep(df)  # ef? no — v2.prep makes ema8/ema21/ema50/adx/atr
    ema8 = d["ema8"].to_numpy(); ema21 = d["ema21"].to_numpy(); ema50 = d["ema50"].to_numpy()
    adx = d["adx"].to_numpy(); atr = d["atr"].to_numpy()
    o = d["open"].to_numpy(); h = d["high"].to_numpy(); l = d["low"].to_numpy(); c = d["close"].to_numpy()
    n = len(d)
    long_ok = np.zeros(n, bool); short_ok = np.zeros(n, bool)
    ac = 0; bc = 0
    for i in range(n):
        if any(math.isnan(x) for x in (ema8[i], ema21[i], ema50[i], adx[i], atr[i])):
            ac = bc = 0; continue
        ac = ac + 1 if ema8[i] > ema21[i] else 0
        bc = bc + 1 if ema8[i] < ema21[i] else 0
        if ema8[i] > ema21[i] > ema50[i] and ac >= PERSIST and adx[i] > ADX_MIN:
            long_ok[i] = True
        if ema8[i] < ema21[i] < ema50[i] and bc >= PERSIST and adx[i] > ADX_MIN:
            short_ok[i] = True
    return dict(o=o, h=h, l=l, c=c, ema8=ema8, ema21=ema21, adx=adx, atr=atr,
                long_ok=long_ok, short_ok=short_ok)


def run_window(syms, pc, dmap, start, end, cap, risk):
    all_dates = sorted({d for df in syms.values() for d in df["date"].tolist()
                        if start <= d <= end})
    equity = 10000.0; peak = equity; maxdd = 0.0
    open_pos = {}; trades = []
    for day in all_dates:
        for b in list(open_pos.keys()):
            i = dmap[b].get(day)
            if i is None: continue
            p = pc[b]; pos = open_pos[b]
            stop = pos["entry"] - CAT_STOP_ATR * pos["atr_e"] if pos["side"] == 1 \
                else pos["entry"] + CAT_STOP_ATR * pos["atr_e"]
            exit_px = None
            if pos["side"] == 1:
                if p["l"][i] <= stop: exit_px = stop
                elif p["ema8"][i] < p["ema21"][i]: exit_px = p["c"][i]
            else:
                if p["h"][i] >= stop: exit_px = stop
                elif p["ema8"][i] > p["ema21"][i]: exit_px = p["c"][i]
            if exit_px is not None:
                gross = pos["side"] * (exit_px - pos["entry"]) * pos["qty"]
                fees = FEE * pos["qty"] * (pos["entry"] + exit_px)
                equity += gross - fees; trades.append(gross - fees)
                del open_pos[b]
        if len(open_pos) < cap:
            cands = []
            for b, p in pc.items():
                if b in open_pos: continue
                i = dmap[b].get(day)
                if i is None: continue
                if p["long_ok"][i] or p["short_ok"][i]:
                    cands.append((p["adx"][i], b, 1 if p["long_ok"][i] else -1, i))
            cands.sort(reverse=True)
            for _adx, b, side, i in cands:
                if len(open_pos) >= cap: break
                p = pc[b]; atr_e = p["atr"][i]; entry = p["c"][i]
                if atr_e <= 0: continue
                qty = (risk * equity) / (CAT_STOP_ATR * atr_e)
                open_pos[b] = dict(side=side, entry=entry, atr_e=atr_e, qty=qty)
        peak = max(peak, equity)
        if peak > 0: maxdd = max(maxdd, (peak - equity) / peak)
    for b, pos in open_pos.items():
        px = pc[b]["c"][len(syms[b]) - 1]
        equity += pos["side"] * (px - pos["entry"]) * pos["qty"]
        trades.append(0.0)
    wins = sum(1 for t in trades if t > 0)
    gw = sum(t for t in trades if t > 0); gl = -sum(t for t in trades if t < 0)
    pf = gw / gl if gl > 0 else float("inf")
    return dict(ret=(equity / 10000 - 1) * 100, dd=maxdd * 100, n=len(trades),
                wr=100 * wins / max(1, len(trades)), pf=pf)


def main():
    files = sorted(DATA_DIR.glob("*_USDT_1d.csv"))
    syms = {}; excluded_class = []; excluded_short = []
    for f in files:
        b = base_of(f)
        if b in EXCLUDE: excluded_class.append(b); continue
        df = pd.read_csv(f)
        if len(df) < MIN_BARS: excluded_short.append(b); continue
        df["date"] = pd.to_datetime(df["timestamp"], unit="ms", utc=True).dt.normalize()
        syms[b] = df.reset_index(drop=True)
    if "BTC" not in syms:
        print("need BTC for the calendar cutoff"); return

    pc = {}; dmap = {}
    for b, df in syms.items():
        pc[b] = precompute(df)
        dmap[b] = {d: i for i, d in enumerate(df["date"].tolist())}

    bd = syms["BTC"]["date"].tolist()
    d0, d50, d75, d100 = bd[0], bd[len(bd) // 2], bd[int(len(bd) * .75)], bd[-1]
    print(f"Universe: {len(syms)} crypto symbols "
          f"(excluded {len(excluded_class)} tokenized TradFi, {len(excluded_short)} too-short).")
    print(f"  tokenized TradFi excluded: {', '.join(sorted(excluded_class))}\n")

    # Robustness matrix: two out-of-sample windows x a few risk/cap settings.
    windows = [("held-out  2024-11+", d75, d100),
               ("earlier   2023-05+", d50, d75),
               ("full      2020-05+", d0, d100)]
    settings = [(10, 0.02), (5, 0.02), (15, 0.02), (10, 0.01)]
    print(f'{"window":<20} {"cap":>3} {"risk":>5} {"return%":>9} {"maxDD%":>7} '
          f'{"trades":>7} {"win%":>6} {"PF":>6}')
    for wname, ws, we in windows:
        for cap, risk in settings:
            r = run_window(syms, pc, dmap, ws, we, cap, risk)
            print(f'{wname:<20} {cap:>3} {risk*100:>4.0f}% {r["ret"]:+9.1f} '
                  f'{r["dd"]:7.1f} {r["n"]:>7} {r["wr"]:6.0f} {r["pf"]:6.2f}')
        print()


if __name__ == "__main__":
    main()
