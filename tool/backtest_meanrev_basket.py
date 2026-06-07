"""High-probability mean-reversion BASKET take-profit (standalone).

Fuses two ideas:
  * the user's basket take-profit  -> close the WHOLE basket the moment its
    combined net PnL reaches +$3;
  * a high-probability ENTRY of my own design -> cross-sectional mean
    reversion: crypto majors over-extend against each other on the hourly
    scale and snap back, so when flat we go LONG the biggest recent losers
    and SHORT the biggest recent winners (dollar-neutral). We only enter when
    the winner/loser dispersion is wide enough to be worth trading.

Capital is FIXED at $60: every leg is sized off that fixed base ($10 isolated
margin x5 = $50 notional), profits are swept out as income (never compounded),
so realized PnL per calendar month is directly comparable across all years.

Touches NO shipped strategy in lib/ — reads only data/*_1h.csv.

Run:  python3 tool/backtest_meanrev_basket.py
"""

from __future__ import annotations
import csv
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"

# ---- fixed account / sizing ----------------------------------------------
CAPITAL          = 60.0          # fixed; never compounds
MARGIN_PER_POS   = 10.0
LEVERAGE         = 5
NOTIONAL_PER_POS = MARGIN_PER_POS * LEVERAGE       # $50
FEE_PER_SIDE     = 0.0004                            # Binance USDT-M taker
LIQ_FRAC         = 1.0 / LEVERAGE                    # -20% wipes a leg

SYMBOLS = ["BTC", "ETH", "BNB", "SOL", "XRP", "ADA", "DOGE", "AVAX", "DOT", "LINK"]


# ---- load & align all symbols onto the shared hourly grid -----------------
def load_aligned():
    per = {}
    for s in SYMBOLS:
        ts, o, h, l, c = [], [], [], [], []
        with (DATA_DIR / f"{s}_USDT_1h.csv").open() as fh:
            r = csv.reader(fh); next(r)
            for row in r:
                ts.append(int(row[0]))
                o.append(float(row[1])); h.append(float(row[2]))
                l.append(float(row[3])); c.append(float(row[4]))
        per[s] = dict(zip(ts, zip(o, h, l, c)))
    common = set(per[SYMBOLS[0]])
    for s in SYMBOLS[1:]:
        common &= set(per[s])
    grid = sorted(common)
    T, S = len(grid), len(SYMBOLS)
    O = np.empty((T, S)); H = np.empty((T, S))
    L = np.empty((T, S)); C = np.empty((T, S))
    for j, s in enumerate(SYMBOLS):
        for i, t in enumerate(grid):
            o, h, l, c = per[s][t]
            O[i, j] = o; H[i, j] = h; L[i, j] = l; C[i, j] = c
    return np.array(grid, dtype=np.int64), O, H, L, C


GRID, O, H, L, C = load_aligned()
T, S = C.shape


def simulate(lookback, k, tp_target, max_hold, min_spread,
             sl_target=None, direction="revert", leg_stop=None):
    """Cross-sectional basket, fixed-$60 sizing, bracketed by TP/SL.

    lookback   : hours used for the recent-return signal
    k          : legs per side (k long + k short, dollar-neutral)
    tp_target  : basket combined net-PnL target ($)
    max_hold   : force-close a basket after this many hours
    min_spread : only enter when (max ret - min ret) across symbols >= this
    sl_target  : basket stop — close all if combined net PnL <= -sl_target
                 (None disables; this is the bracket that caps the tail)
    direction  : 'revert'   -> long the losers, short the winners
                 'momentum' -> long the winners, short the losers
    """
    # recent return signal: C[i]/C[i-lookback]-1
    ret = np.full((T, S), np.nan)
    ret[lookback:] = C[lookback:] / C[:-lookback] - 1.0

    income = 0.0
    monthly = defaultdict(float)          # 'YYYY-MM' -> realized PnL
    monthly_n = defaultdict(int)
    legs = None
    basket = None
    pending_open = None                    # list of (sym_j, side) or None
    pending_close = None                   # 'tp' / 'timeout' or None
    n_tp = n_to = n_liq = n_stop = 0
    realized_list = []

    for i in range(T):
        # 1) execute pending OPEN at this bar's open
        if pending_open is not None:
            sel = pending_open; pending_open = None
            new = []
            for (j, side) in sel:
                px = O[i, j]
                qty = NOTIONAL_PER_POS / px
                # protective per-leg stop (tighter than liquidation) kills the
                # -$10 tail; falls back to the 20% liquidation if disabled.
                frac = leg_stop if leg_stop is not None else LIQ_FRAC
                prot = px * (1 - frac) if side > 0 else px * (1 + frac)
                new.append([j, side, px, qty, prot, True])
            legs = new
            basket = dict(realized=0.0, opened_i=i, held=0)

        # 2) execute pending CLOSE at this bar's open
        if pending_close is not None:
            reason = pending_close; pending_close = None
            realized = basket["realized"]
            for lg in legs:
                if lg[5]:
                    j, side, entry, qty = lg[0], lg[1], lg[2], lg[3]
                    px = O[i, j]
                    gross = qty * (px - entry) * side
                    fees = FEE_PER_SIDE * (qty * entry + qty * px)
                    realized += max(gross - fees, -MARGIN_PER_POS)
            income += realized
            ym = datetime.fromtimestamp(GRID[i] / 1000, tz=timezone.utc).strftime("%Y-%m")
            monthly[ym] += realized; monthly_n[ym] += 1
            realized_list.append((GRID[i], realized, reason))
            if reason == "tp": n_tp += 1
            elif reason == "stop": n_stop += 1
            else: n_to += 1
            legs = None; basket = None

        # 3) intrabar protective-stop / liquidation of live legs
        if legs is not None:
            for lg in legs:
                if not lg[5]:
                    continue
                j, side, entry, qty, prot = lg[0], lg[1], lg[2], lg[3], lg[4]
                hit = (side > 0 and L[i, j] <= prot) or (side < 0 and H[i, j] >= prot)
                if hit:
                    lg[5] = False
                    gross = qty * (prot - entry) * side
                    fees = FEE_PER_SIDE * (qty * entry + qty * prot)
                    basket["realized"] += max(gross - fees, -MARGIN_PER_POS)
                    n_liq += 1
            if not any(lg[5] for lg in legs):
                income += basket["realized"]
                ym = datetime.fromtimestamp(GRID[i] / 1000, tz=timezone.utc).strftime("%Y-%m")
                monthly[ym] += basket["realized"]; monthly_n[ym] += 1
                realized_list.append((GRID[i], basket["realized"], "liq"))
                legs = None; basket = None

        # 4) TP / timeout check at this bar's close
        if legs is not None and pending_close is None:
            basket["held"] += 1
            total = basket["realized"]
            for lg in legs:
                if lg[5]:
                    j, side, entry, qty = lg[0], lg[1], lg[2], lg[3]
                    px = C[i, j]
                    gross = qty * (px - entry) * side
                    fees = FEE_PER_SIDE * (qty * entry + qty * px)
                    total += max(gross - fees, -MARGIN_PER_POS)
            if total >= tp_target:
                pending_close = "tp"
            elif sl_target is not None and total <= -sl_target:
                pending_close = "stop"
            elif basket["held"] >= max_hold:
                pending_close = "timeout"

        # 5) entry when flat: cross-sectional mean reversion, dispersion-gated
        if legs is None and pending_open is None and i >= lookback:
            r = ret[i]
            if not np.isnan(r).any():
                order = np.argsort(r)                 # ascending: losers first
                spread = r[order[-1]] - r[order[0]]
                if spread >= min_spread and 2 * k <= len(order):
                    losers = order[:k]                # smallest recent return
                    winners = order[-k:]              # largest recent return
                    if direction == "revert":
                        long_set, short_set = losers, winners
                    else:                              # momentum
                        long_set, short_set = winners, losers
                    sel = ([(int(j), 1) for j in long_set]
                           + [(int(j), -1) for j in short_set])
                    pending_open = sel

    return dict(income=income, monthly=dict(monthly), monthly_n=dict(monthly_n),
                n_tp=n_tp, n_to=n_to, n_liq=n_liq, n_stop=n_stop,
                baskets=n_tp + n_to + n_liq + n_stop,
                realized=realized_list,
                params=dict(lookback=lookback, k=k, tp=tp_target,
                            hold=max_hold, min_spread=min_spread,
                            sl=sl_target, dir=direction, leg_stop=leg_stop))


def score(res):
    """Rank configs by monthly-income consistency, not just total."""
    m = res["monthly"]
    if not m:
        return dict(total=0, n_months=0, pos_frac=0, avg=0, worst=0, sharpe=-9)
    vals = list(m.values())
    n = len(vals)
    pos = sum(1 for v in vals if v > 0)
    avg = sum(vals) / n
    sd = (sum((v - avg) ** 2 for v in vals) / n) ** 0.5
    sharpe = (avg / sd) if sd > 0 else 0.0
    return dict(total=res["income"], n_months=n, pos_frac=pos / n, avg=avg,
                worst=min(vals), best=max(vals), sharpe=sharpe,
                baskets=res["baskets"], n_tp=res["n_tp"], n_to=res["n_to"],
                n_liq=res["n_liq"], n_stop=res["n_stop"])


def print_row(p, sc):
    sl = "off" if p.get("sl") is None else f"${p['sl']:.0f}"
    ls = "off" if p.get("leg_stop") is None else f"{p['leg_stop']*100:.0f}%"
    print(f"  {p['dir'][:4]} lb={p['lookback']:>3}h k={p['k']} hold={p['hold']:>4}h "
          f"sl={sl:>4} legstop={ls:>3} | "
          f"mo {sc['n_months']:>2} pos {100*sc['pos_frac']:>5.1f}% | "
          f"avg ${sc['avg']:+5.2f}/mo worst ${sc['worst']:+6.2f} | "
          f"sh {sc['sharpe']:+5.2f} | tot ${sc['total']:+7.2f} "
          f"(b={sc['baskets']},legX={sc['n_liq']})")


def main():
    print(f"Mean-reversion basket TP | FIXED ${CAPITAL:.0f}, ${MARGIN_PER_POS:.0f}/leg x{LEVERAGE} "
          f"(=${NOTIONAL_PER_POS:.0f}), fee {FEE_PER_SIDE*100:.2f}%/side")
    span_days = (GRID[-1] - GRID[0]) / 86_400_000
    print(f"Universe {S} symbols, {T} hourly bars (~{span_days/365:.1f} yr), "
          f"TP=+$3, profits swept (non-compounding)\n")

    grid_lb   = [3, 6, 12, 24]
    grid_k    = [1, 2, 3]
    grid_hold = [48, 168]
    grid_sl   = [3.0, 5.0, None]           # basket stop ($)
    grid_legs = [0.08, 0.12, None]         # per-leg protective stop (fraction)
    grid_dir  = ["momentum", "revert"]
    TP = 3.0

    print("=== Tuning sweep (ranked by monthly Sharpe) ===")
    runs = []
    for d in grid_dir:
        for lb in grid_lb:
            for k in grid_k:
                for hold in grid_hold:
                    for sl in grid_sl:
                        for ls in grid_legs:
                            res = simulate(lb, k, TP, hold, 0.0, sl_target=sl,
                                           direction=d, leg_stop=ls)
                            runs.append((res, score(res)))
    runs.sort(key=lambda rs: rs[1]["sharpe"], reverse=True)
    for res, sc in runs[:14]:
        print_row(res["params"], sc)

    # Deterministic HEADLINE config (top of the leaderboard, hard-coded so the
    # artifacts are reproducible and not silently re-picked by sweep noise).
    HEADLINE = dict(lookback=3, k=2, hold=168, sl=5.0, leg_stop=0.12,
                    direction="momentum")
    best_res = simulate(HEADLINE["lookback"], HEADLINE["k"], TP,
                        HEADLINE["hold"], 0.0, sl_target=HEADLINE["sl"],
                        direction=HEADLINE["direction"], leg_stop=HEADLINE["leg_stop"])
    best_sc = score(best_res)
    bp = best_res["params"]
    print(f"\n=== HEADLINE: {bp['dir']} lb={bp['lookback']}h k={bp['k']} "
          f"hold={bp['hold']}h sl=${int(bp['sl'])} legstop={int(bp['leg_stop']*100)}% "
          f"(TP=$3) ===")
    print_row(bp, best_sc)

    # out-of-sample sanity: does it hold up in BOTH halves of the history?
    m = best_res["monthly"]
    early = [v for ym, v in m.items() if ym < "2024-01"]
    late = [v for ym, v in m.items() if ym >= "2024-01"]
    for label, seg in (("2022-2023", early), ("2024-2026", late)):
        if seg:
            pos = sum(1 for v in seg if v > 0)
            print(f"    OOS {label}: total ${sum(seg):+7.2f} | "
                  f"avg ${sum(seg)/len(seg):+5.2f}/mo | "
                  f"green {pos}/{len(seg)} ({100*pos/len(seg):.0f}%)")

    # monthly income table (year x month) for the best config
    monthly = best_res["monthly"]
    years = sorted({ym[:4] for ym in monthly})
    months = [f"{m:02d}" for m in range(1, 13)]
    print(f"\n  Monthly income (USD) — fixed ${CAPITAL:.0f} capital:")
    header = "  year |" + "".join(f"{m:>7}" for m in months) + "  |   TOTAL"
    print(header); print("  " + "-" * (len(header) - 2))
    for y in years:
        row = f"  {y} |"
        ytot = 0.0
        for m in months:
            v = monthly.get(f"{y}-{m}")
            if v is None:
                row += f"{'·':>7}"
            else:
                row += f"{v:>7.1f}"; ytot += v
        print(row + f"  | {ytot:>7.1f}")
    allv = list(monthly.values())
    print(f"\n  total income ${sum(allv):+.2f} over {len(allv)} months "
          f"| avg ${sum(allv)/len(allv):+.2f}/mo "
          f"| positive months {sum(1 for v in allv if v>0)}/{len(allv)} "
          f"({100*sum(1 for v in allv if v>0)/len(allv):.0f}%)")
    print(f"  best ${max(allv):+.2f}  worst ${min(allv):+.2f}  "
          f"| baskets {best_sc['baskets']} "
          f"(tp {best_res['n_tp']}/stop {best_res['n_stop']}/"
          f"timeout {best_res['n_to']}/liq {best_res['n_liq']})")

    # write artifacts
    out_m = ROOT / "tool" / "meanrev_basket_monthly.csv"
    with out_m.open("w", newline="") as fh:
        w = csv.writer(fh); w.writerow(["month", "income", "n_baskets"])
        for ym in sorted(monthly):
            w.writerow([ym, f"{monthly[ym]:.4f}", best_res["monthly_n"][ym]])
    out_t = ROOT / "tool" / "meanrev_basket_trades.csv"
    with out_t.open("w", newline="") as fh:
        w = csv.writer(fh); w.writerow(["closed_ts", "pnl", "reason"])
        for ts, pnl, reason in best_res["realized"]:
            w.writerow([ts, f"{pnl:.4f}", reason])
    print(f"\n  wrote {out_m.relative_to(ROOT)} and {out_t.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
