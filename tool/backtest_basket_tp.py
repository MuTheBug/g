"""Basket take-profit backtest (standalone — touches NO shipped strategy).

Concept requested by the user:
  "Open a few positions and when the TOTAL pnl of the positions is at
   least +$3, close them all."

This is a synchronized *basket* scalp on the hourly klines:

  1. When the book is flat, open a basket of N positions at the next bar's
     open (one per chosen symbol).
  2. Every bar we mark the basket to market. The moment the basket's
     combined NET pnl (all legs, after round-trip fees) reaches the
     take-profit target (+$3), we close every leg at the next bar's open.
  3. Book is flat again -> immediately open the next basket. Repeat.

Sizing mirrors the repo's real-money config so the numbers are comparable
to the other tools/: $10 isolated margin per leg at 5x  ->  $50 notional
per position. Equity starts at $60 (user-supplied). Isolated margin means a
single leg can never lose more than its $10 margin: a ~-20% adverse move
liquidates that leg for -$10 and drops it from the basket; the rest of the
basket keeps running toward the +$3 target.

Run:  python3 tool/backtest_basket_tp.py
"""

from __future__ import annotations
import csv
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"

# ---- account / sizing (mirrors the live config, $60 equity) ---------------
EQUITY_START     = 60.0
MARGIN_PER_POS   = 10.0
LEVERAGE         = 5
NOTIONAL_PER_POS = MARGIN_PER_POS * LEVERAGE        # $50
FEE_PER_SIDE     = 0.0004                            # Binance USDT-M taker

# Liquidation: isolated margin is fully lost at this adverse fraction.
# notional = margin*lev  ->  margin loss happens at 1/lev price move.
LIQ_FRAC = 1.0 / LEVERAGE                            # 0.20  (-20% for a long)

# Fixed priority so the chosen N symbols are deterministic.
SYMBOL_PRIORITY = ["BTC", "ETH", "BNB", "SOL", "XRP",
                   "ADA", "DOGE", "AVAX", "DOT", "LINK"]


def load_symbol(base: str):
    """Return (timestamps[list[int]], bars dict ts->(o,h,l,c))."""
    path = DATA_DIR / f"{base}_USDT_1h.csv"
    ts, bars = [], {}
    with path.open() as fh:
        r = csv.reader(fh)
        next(r)  # header
        for row in r:
            t = int(row[0])
            o, h, l, c = float(row[1]), float(row[2]), float(row[3]), float(row[4])
            ts.append(t)
            bars[t] = (o, h, l, c)
    return ts, bars


def liq_price(side: int, entry: float) -> float:
    return entry * (1 - LIQ_FRAC) if side > 0 else entry * (1 + LIQ_FRAC)


def leg_net_pnl(side, entry, qty, px):
    """Net pnl of closing a leg at px, after round-trip fees, isolated-capped."""
    gross = qty * (px - entry) * side
    fees = FEE_PER_SIDE * (qty * entry + qty * px)
    pnl = gross - fees
    return max(pnl, -MARGIN_PER_POS)


def simulate(n_positions: int, tp_target: float, mode: str,
             max_hold_bars: int = 0, _cache={}):
    """mode: 'long' (all longs) or 'both' (alternate long/short by leg index).

    max_hold_bars: if > 0, a basket that has not hit the take-profit within
    this many bars is force-closed at the next open ('timeout') so the engine
    can recycle instead of getting stuck holding losers forever.
    """
    symbols = SYMBOL_PRIORITY[:n_positions]
    data = {s: _cache.get(s) or _cache.setdefault(s, load_symbol(s))
            for s in symbols}

    # synchronized grid = timestamps present in EVERY chosen symbol
    common = set(data[symbols[0]][1].keys())
    for s in symbols[1:]:
        common &= set(data[s][1].keys())
    grid = sorted(common)

    equity = EQUITY_START
    legs = None          # list of open-leg dicts, or None when flat
    basket = None        # dict: realized (from liquidated legs), opened_ts
    pending_open = False
    pending_close = None  # None, or reason string ('tp' / 'timeout')

    trades = []          # one record per CLOSED basket
    equity_curve = []
    peak = EQUITY_START
    max_dd = 0.0
    blown = False

    def open_basket(ts):
        nonlocal legs, basket
        new_legs = []
        for i, s in enumerate(symbols):
            o = data[s][1][ts][0]
            side = 1 if (mode == "long" or i % 2 == 0) else -1
            qty = NOTIONAL_PER_POS / o
            new_legs.append(dict(sym=s, side=side, entry=o, qty=qty,
                                 liq=liq_price(side, o), alive=True))
        legs = new_legs
        basket = dict(realized=0.0, opened_ts=ts, n=len(new_legs), held=0)

    for ts in grid:
        # ---- 1) execute a pending basket OPEN at this bar's open ----------
        if pending_open and not blown:
            pending_open = False
            if equity >= n_positions * MARGIN_PER_POS:
                open_basket(ts)

        # ---- 2) execute a pending basket CLOSE at this bar's open ---------
        if pending_close:
            reason = pending_close
            pending_close = None
            realized = basket["realized"]
            for lg in legs:
                if lg["alive"]:
                    px = data[lg["sym"]][1][ts][0]
                    realized += leg_net_pnl(lg["side"], lg["entry"], lg["qty"], px)
            equity += realized
            trades.append(dict(opened=basket["opened_ts"], closed=ts,
                               pnl=realized, n=basket["n"], reason=reason))
            legs, basket = None, None
            if equity < MARGIN_PER_POS:
                blown = True

        # ---- 3) intrabar liquidations for the live basket ----------------
        if legs is not None:
            for lg in legs:
                if not lg["alive"]:
                    continue
                o, h, l, c = data[lg["sym"]][1][ts]
                hit = (lg["side"] > 0 and l <= lg["liq"]) or \
                      (lg["side"] < 0 and h >= lg["liq"])
                if hit:
                    lg["alive"] = False
                    basket["realized"] += -MARGIN_PER_POS   # full margin lost

            alive = [lg for lg in legs if lg["alive"]]
            if not alive:
                # whole basket wiped out by liquidations -> realize, go flat
                equity += basket["realized"]
                trades.append(dict(opened=basket["opened_ts"], closed=ts,
                                   pnl=basket["realized"], n=basket["n"],
                                   reason="liquidated"))
                legs, basket = None, None
                if equity < MARGIN_PER_POS:
                    blown = True

        # ---- 4) take-profit / timeout check at this bar's CLOSE ----------
        if legs is not None and pending_close is None:
            basket["held"] += 1
            total = basket["realized"]
            for lg in legs:
                if lg["alive"]:
                    c = data[lg["sym"]][1][ts][3]
                    total += leg_net_pnl(lg["side"], lg["entry"], lg["qty"], c)
            if total >= tp_target:
                pending_close = "tp"
            elif max_hold_bars and basket["held"] >= max_hold_bars:
                pending_close = "timeout"

        # ---- 5) refill: if flat (and not about to close), queue an open ---
        if legs is None and not pending_open and not blown:
            pending_open = True

        # ---- 6) mark-to-market equity curve at this bar's close ----------
        mtm = equity
        if legs is not None:
            mtm += basket["realized"]
            for lg in legs:
                if lg["alive"]:
                    c = data[lg["sym"]][1][ts][3]
                    mtm += leg_net_pnl(lg["side"], lg["entry"], lg["qty"], c)
        equity_curve.append((ts, mtm))
        peak = max(peak, mtm)
        if peak > 0:
            max_dd = max(max_dd, (peak - mtm) / peak)
        if blown:
            break

    return dict(symbols=symbols, trades=trades, equity_curve=equity_curve,
                final_equity=equity, max_dd=max_dd, blown=blown, grid=grid,
                hold=max_hold_bars)


def summarize(res, n, tp, mode):
    trades = res["trades"]
    eq = res["equity_curve"]
    if not eq:
        return None
    days = (eq[-1][0] - eq[0][0]) / 86_400_000
    tp_baskets = [t for t in trades if t["reason"] == "tp"]
    to_baskets = [t for t in trades if t["reason"] == "timeout"]
    liq_baskets = [t for t in trades if t["reason"] == "liquidated"]
    wins = sum(1 for t in trades if t["pnl"] > 0)
    final = res["final_equity"]
    ret = final / EQUITY_START - 1.0
    cagr = ((final / EQUITY_START) ** (365.0 / days) - 1.0) if days > 0 and final > 0 else -1.0
    avg_basket = sum(t["pnl"] for t in trades) / len(trades) if trades else 0.0
    return dict(n=n, tp=tp, mode=mode, hold=res.get("hold", 0), days=days,
                baskets=len(trades), tp_baskets=len(tp_baskets),
                to_baskets=len(to_baskets), liq_baskets=len(liq_baskets),
                win_rate=wins / len(trades) if trades else 0.0,
                avg_basket=avg_basket, final=final, ret=ret, cagr=cagr,
                max_dd=res["max_dd"], blown=res["blown"], symbols=res["symbols"])


def print_row(s):
    tag = "BLOWN " if s["blown"] else ""
    hold = f"{s['hold']:>4}h" if s["hold"] else "  off"
    print(f"  N={s['n']} {s['mode']:<4} TP=${s['tp']:.0f} hold={hold} | "
          f"baskets {s['baskets']:>5} "
          f"(tp {s['tp_baskets']:>5}/to {s['to_baskets']:>4}/liq {s['liq_baskets']:>3}) | "
          f"win {100*s['win_rate']:>5.1f}% | "
          f"final ${s['final']:>8.2f} ({s['ret']*100:+8.1f}%) | "
          f"CAGR {s['cagr']*100:+7.1f}% | maxDD {s['max_dd']*100:4.1f}% {tag}")


def main():
    print(f"Basket take-profit backtest  |  ${EQUITY_START:.0f} equity, "
          f"${MARGIN_PER_POS:.0f}/leg x{LEVERAGE} (=${NOTIONAL_PER_POS:.0f} notional), "
          f"fee {FEE_PER_SIDE*100:.2f}%/side\n"
          f"Hourly klines, synchronized baskets, TP closes the WHOLE basket.\n")

    # ---- A) literal strategy: no stop, hold until +$3 or liquidation -----
    print("=== A) Literal: TP=+$3, NO time-stop (hold until +$3 or liq) ===")
    for mode in ("long", "both"):
        for n in (3, 5):
            print_row(summarize(simulate(n, 3.0, mode), n, 3.0, mode))

    # ---- B) add a time-stop so stuck baskets recycle ---------------------
    print("\n=== B) TP=+$3 WITH time-stop (cut basket after H hours) ===")
    best = None
    for mode in ("long", "both"):
        for n in (3, 5):
            for hold in (24, 72, 168, 336):   # 1d, 3d, 1wk, 2wk
                res = simulate(n, 3.0, mode, max_hold_bars=hold)
                s = summarize(res, n, 3.0, mode)
                print_row(s)
            print()

    # pick the best non-blown config across the time-stop grid
    for mode in ("long", "both"):
        for n in (3, 5):
            for hold in (24, 72, 168, 336):
                res = simulate(n, 3.0, mode, max_hold_bars=hold)
                s = summarize(res, n, 3.0, mode)
                if (not s["blown"]) and (best is None or s["final"] > best[1]["final"]):
                    best = (res, s)

    if best is not None:
        bn, bmode, bhold = best[1]["n"], best[1]["mode"], best[1]["hold"]
        print(f"=== TP sensitivity (best: N={bn}, {bmode}, hold={bhold}h) ===")
        for tp in (2.0, 3.0, 5.0, 10.0):
            res = simulate(bn, tp, bmode, max_hold_bars=bhold)
            print_row(summarize(res, bn, tp, bmode))

        # write artifacts for the headline (best) config at the +$3 target
        res = simulate(bn, 3.0, bmode, max_hold_bars=bhold)
        s = summarize(res, bn, 3.0, bmode)
        eq_path = ROOT / "tool" / "basket_tp_equity.csv"
        with eq_path.open("w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["timestamp", "equity"])
            for t, v in res["equity_curve"]:
                w.writerow([t, f"{v:.4f}"])
        tr_path = ROOT / "tool" / "basket_tp_trades.csv"
        with tr_path.open("w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["opened", "closed", "n_legs", "pnl", "reason"])
            for t in res["trades"]:
                w.writerow([t["opened"], t["closed"], t["n"],
                            f"{t['pnl']:.4f}", t["reason"]])
        print(f"\nHeadline config: N={bn} {bmode} TP=$3 hold={bhold}h "
              f"on [{', '.join(s['symbols'])}] over ~{s['days']/365:.1f} yr")
        print(f"  wrote {eq_path.relative_to(ROOT)} and "
              f"{tr_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
