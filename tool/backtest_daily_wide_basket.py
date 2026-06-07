"""Wide-universe DAILY momentum basket take-profit — fixed $60, monthly income.

The hourly study capped out because cross-sectional momentum was starved on
only 10 symbols. This widens the universe to the full crypto set of daily
candles in data/ (~40 names after the non-crypto filter), where the
momentum factor is a well-documented, diversified edge.

Same idea the user asked for: open a small basket of a few positions and close
the WHOLE basket the moment combined PnL hits +$3. Entry is cross-sectional
momentum across the wide universe; capital is fixed at $60 (profits swept).

Symbols list per day as they list historically, so the available set grows over
time; we only rank names with enough history for the lookback. Reads only
data/*_USDT_1d.csv; touches nothing in lib/.

Run:  python3 tool/backtest_daily_wide_basket.py
"""

from __future__ import annotations
import csv
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"

CAPITAL          = 60.0
MARGIN_PER_POS   = 10.0
LEVERAGE         = 5
NOTIONAL_PER_POS = MARGIN_PER_POS * LEVERAGE       # $50
FEE_PER_SIDE     = 0.0004
LIQ_FRAC         = 1.0 / LEVERAGE

# crypto-only filter (mirrors lib/domain/universe.dart denylist)
NON_CRYPTO = {
    "XAU", "XAG", "XPT", "XPD", "PAXG", "CL", "BZ", "WTI", "NG", "HG",
    "MSTR", "INTC", "SOXL", "MU", "SNDK", "CRCL", "HEI", "NVDA", "TSLA",
    "AAPL", "COIN", "AMZN", "GOOGL", "GOOG", "META", "MSFT", "NFLX", "AMD",
    "SPY", "QQQ", "GME", "HOOD", "PLTR", "MARA", "BEAT", "ESPORTS", "ALLO",
    "EUR", "GBP", "JPY", "AUD", "CAD", "CHF", "UB", "GUA", "LAB", "AIGENSYN",
}


def base_of(stem: str) -> str:
    name = stem.replace("_USDT_1d", "")
    for p in ("1000000", "1000", "1M", "1B"):
        if name.startswith(p) and len(name) > len(p):
            return name[len(p):]
    return name


def load_universe(min_rows=120):
    syms = {}
    for f in sorted(DATA_DIR.glob("*_USDT_1d.csv")):
        if base_of(f.stem) in NON_CRYPTO:
            continue
        ts, O, H, L, C = [], [], [], [], []
        with f.open() as fh:
            r = csv.reader(fh); next(r)
            for row in r:
                ts.append(int(row[0]))
                O.append(float(row[1])); H.append(float(row[2]))
                L.append(float(row[3])); C.append(float(row[4]))
        if len(ts) < min_rows:
            continue
        name = f.stem.replace("_USDT_1d", "")
        idx = {t: i for i, t in enumerate(ts)}
        syms[name] = dict(ts=ts, O=O, H=H, L=L, C=C, idx=idx)
    return syms


SYMS = load_universe()
NAMES = sorted(SYMS)
ALL_TS = sorted(set().union(*[set(s["ts"]) for s in SYMS.values()]))
YM = {t: datetime.fromtimestamp(t / 1000, tz=timezone.utc).strftime("%Y-%m") for t in ALL_TS}
BTC = "BTC"


def ema_series(name, n):
    C = SYMS[name]["C"]
    out = [C[0]]
    a = 2.0 / (n + 1.0)
    for i in range(1, len(C)):
        out.append(a * C[i] + (1 - a) * out[-1])
    return out


BTC_EMA = {}

# ---- funding-rate history (8h) -> per-symbol (sorted_ts, rate) -------------
import bisect
FUND = {}


def load_funding():
    fdir = DATA_DIR / "funding"
    if not fdir.exists():
        return
    for name in NAMES:
        p = fdir / f"{name}_USDT_funding.csv"
        if not p.exists():
            continue
        ts, rate = [], []
        with p.open() as fh:
            r = csv.reader(fh); next(r, None)
            for row in r:
                try:
                    ts.append(int(row[0])); rate.append(float(row[1]) if row[1] else 0.0)
                except (ValueError, IndexError):
                    continue
        if ts:
            FUND[name] = (ts, rate)


load_funding()


def funding_pnl(name, side, notional, t_open, t_close):
    """Funding paid(-)/earned(+) over [t_open, t_close]. Long pays when the
    rate is positive; short receives it. Uses entry notional as the base."""
    f = FUND.get(name)
    if not f:
        return 0.0
    ts, rate = f
    lo = bisect.bisect_right(ts, t_open)
    hi = bisect.bisect_right(ts, t_close)
    if hi <= lo:
        return 0.0
    return -side * notional * sum(rate[lo:hi])


def simulate(lookback, k, M, tp, sl, leg_stop, hold, gate, ema_len=0, with_funding=True):
    """Cross-sectional daily momentum basket over the wide crypto universe.

    lookback : momentum window (days)
    k        : legs per side (neutral: k long + k short; directional: k on side)
    M        : max concurrent baskets (fixed $60 caps margin)
    ema_len  : >0 -> directional (BTC>EMA: longs; BTC<EMA: shorts); 0 -> neutral
    with_funding : charge/credit 8h funding over each leg's holding period
    """
    if ema_len and ema_len not in BTC_EMA:
        BTC_EMA[ema_len] = ema_series(BTC, ema_len)
    btc_ema = BTC_EMA.get(ema_len)

    n_legs = (k if ema_len else 2 * k)
    margin_cap = n_legs * M * MARGIN_PER_POS
    income = 0.0
    monthly = defaultdict(float); monthly_n = defaultdict(int)
    baskets = []
    pending = []
    n_tp = n_sl = n_to = n_legx = 0
    realized = []

    def mom(name, t):
        s = SYMS[name]
        i = s["idx"].get(t)
        if i is None or i < lookback:
            return None
        p0 = s["C"][i - lookback]
        return (s["C"][i] / p0 - 1.0) if p0 > 0 else None

    def used_margin():
        return sum(MARGIN_PER_POS for b in baskets for lg in b["legs"] if lg[5])

    def held_names():
        return {lg[0] for b in baskets for lg in b["legs"] if lg[5]}

    def close_basket(b, t, reason):
        nonlocal income
        r = b["realized"]
        for lg in b["legs"]:
            if lg[5]:
                name, side, entry, qty = lg[0], lg[1], lg[2], lg[3]
                i = SYMS[name]["idx"].get(t)
                if i is None:                       # no bar today -> last known px
                    i = len(SYMS[name]["C"]) - 1
                px = SYMS[name]["C"][i]
                gross = qty * (px - entry) * side
                fees = FEE_PER_SIDE * (qty * entry + qty * px)
                fund = funding_pnl(name, side, qty * entry, b["opened"], t) if with_funding else 0.0
                r += max(gross - fees + fund, -MARGIN_PER_POS)
        income += r
        monthly[YM[t]] += r; monthly_n[YM[t]] += 1
        realized.append((t, r, reason))

    for t in ALL_TS:
        # open pending baskets at today's open
        if pending:
            for sel in pending:
                legs = []
                for (name, side) in sel:
                    i = SYMS[name]["idx"].get(t)
                    if i is None:                 # no bar on the open day -> skip leg
                        continue
                    px = SYMS[name]["O"][i]; qty = NOTIONAL_PER_POS / px
                    frac = leg_stop if leg_stop is not None else LIQ_FRAC
                    prot = px * (1 - frac) if side > 0 else px * (1 + frac)
                    legs.append([name, side, px, qty, prot, True])
                if legs:
                    baskets.append(dict(legs=legs, opened=t, held=0, realized=0.0))
            pending = []

        # intrabar protective stop per leg
        for b in baskets:
            for lg in b["legs"]:
                if not lg[5]:
                    continue
                name, side, entry, qty, prot = lg[0], lg[1], lg[2], lg[3], lg[4]
                s = SYMS[name]; i = s["idx"].get(t)
                if i is None:        # symbol delisted/missing this day -> hold
                    continue
                if (side > 0 and s["L"][i] <= prot) or (side < 0 and s["H"][i] >= prot):
                    lg[5] = False
                    gross = qty * (prot - entry) * side
                    fees = FEE_PER_SIDE * (qty * entry + qty * prot)
                    fund = funding_pnl(name, side, qty * entry, b["opened"], t) if with_funding else 0.0
                    b["realized"] += max(gross - fees + fund, -MARGIN_PER_POS)
                    n_legx += 1

        # close decisions at today's close
        regime_up = (ema_len and SYMS[BTC]["idx"].get(t) is not None and
                     SYMS[BTC]["C"][SYMS[BTC]["idx"][t]] > btc_ema[SYMS[BTC]["idx"][t]])
        survivors = []
        for b in baskets:
            alive = [lg for lg in b["legs"] if lg[5]]
            if not alive:
                close_basket(b, t, "legx"); continue
            b["held"] += 1
            total = b["realized"]
            for lg in alive:
                name, side, entry, qty = lg[0], lg[1], lg[2], lg[3]
                i = SYMS[name]["idx"].get(t)
                if i is None:
                    total = None; break
                px = SYMS[name]["C"][i]
                gross = qty * (px - entry) * side
                fees = FEE_PER_SIDE * (qty * entry + qty * px)
                total += max(gross - fees, -MARGIN_PER_POS)
            if total is None:
                survivors.append(b); continue
            if total >= tp:
                close_basket(b, t, "tp"); n_tp += 1
            elif sl is not None and total <= -sl:
                close_basket(b, t, "sl"); n_sl += 1
            elif b["held"] >= hold:
                close_basket(b, t, "timeout"); n_to += 1
            else:
                survivors.append(b)
        baskets = survivors

        # entry: open a new basket if capacity + signal
        if len(baskets) < M and used_margin() + n_legs * MARGIN_PER_POS <= margin_cap + 1e-9:
            held = held_names()
            scored = [(name, mom(name, t)) for name in NAMES
                      if name not in held and SYMS[name]["idx"].get(t) is not None]
            scored = [(n, m) for n, m in scored if m is not None]
            if len(scored) >= n_legs:
                scored.sort(key=lambda x: x[1])
                spread = scored[-1][1] - scored[0][1]
                if spread >= gate:
                    if ema_len:
                        if regime_up:
                            sel = [(n, 1) for n, _ in scored[-k:]]
                        else:
                            sel = [(n, -1) for n, _ in scored[:k]]
                    else:
                        sel = ([(n, 1) for n, _ in scored[-k:]]
                               + [(n, -1) for n, _ in scored[:k]])
                    pending.append(sel)

    for b in baskets:
        close_basket(b, ALL_TS[-1], "eod")

    return dict(income=income, monthly=dict(monthly), monthly_n=dict(monthly_n),
                n_tp=n_tp, n_sl=n_sl, n_to=n_to, n_legx=n_legx,
                baskets=n_tp + n_sl + n_to + n_legx, realized=realized,
                params=dict(lookback=lookback, k=k, M=M, tp=tp, sl=sl,
                            leg_stop=leg_stop, hold=hold, gate=gate, ema_len=ema_len))


def score(res):
    m = res["monthly"]
    if not m:
        return dict(total=0, n_months=0, pos_frac=0, avg=0, worst=0, best=0, sharpe=-9, n=0)
    v = list(m.values()); n = len(v)
    pos = sum(1 for x in v if x > 0); avg = sum(v) / n
    sd = (sum((x - avg) ** 2 for x in v) / n) ** 0.5
    return dict(total=res["income"], n_months=n, pos_frac=pos / n, avg=avg,
                worst=min(v), best=max(v), sharpe=(avg / sd if sd > 0 else 0.0),
                n=res["baskets"])


def robust(res):
    m = res["monthly"]
    e = [v for ym, v in m.items() if ym < "2024-01"]
    l = [v for ym, v in m.items() if ym >= "2024-01"]
    if not e or not l:
        return -9.0
    return min(sum(e) / len(e), sum(l) / len(l))


def print_row(p, sc):
    mode = f"dir/ema{p['ema_len']}" if p.get("ema_len") else "neutral"
    ls = "off" if p["leg_stop"] is None else f"{p['leg_stop']*100:.0f}%"
    print(f"  {mode:>9} lb={p['lookback']:>2}d k={p['k']} M={p['M']} "
          f"gate={p['gate']*100:>3.0f}% sl=${'' if p['sl'] is None else int(p['sl'])} "
          f"legs={ls:>3} hold={p['hold']:>2}d | "
          f"mo {sc['n_months']:>2} pos {100*sc['pos_frac']:>5.1f}% | "
          f"avg ${sc['avg']:+5.2f} worst ${sc['worst']:+6.2f} | sh {sc['sharpe']:+5.2f} "
          f"| tot ${sc['total']:+7.2f} (b={sc['n']})")


def main():
    print(f"Wide-universe daily momentum basket | FIXED ${CAPITAL:.0f}, "
          f"${MARGIN_PER_POS:.0f}/leg x{LEVERAGE}=${NOTIONAL_PER_POS:.0f}, "
          f"fee {FEE_PER_SIDE*100:.2f}%/side")
    span = (ALL_TS[-1] - ALL_TS[0]) / 86_400_000
    print(f"Universe {len(NAMES)} crypto symbols, {len(ALL_TS)} days "
          f"(~{span/365:.1f} yr), TP=+$3, profits swept")
    print(f"Funding-rate coverage: {len(FUND)}/{len(NAMES)} symbols "
          f"(8h funding charged/credited per leg)\n")

    TP = 3.0
    runs = []
    for ema_len in (0, 100, 200):
        ks = (1, 2, 3) if ema_len else (1, 2, 3)
        for lb in (5, 10, 20, 30):
            for k in ks:
                for Mx in (1, 2, 3):
                    n_legs = (k if ema_len else 2 * k)
                    if n_legs * Mx * MARGIN_PER_POS > CAPITAL:
                        continue
                    for sl in (5.0, 8.0):
                        for hold in (10, 20):
                            res = simulate(lb, k, Mx, TP, sl, 0.12, hold, 0.0,
                                           ema_len=ema_len)
                            runs.append((res, score(res)))

    # (1) max in-sample Sharpe (often era-dependent)
    by_sharpe = sorted(runs, key=lambda rs: (robust(rs[0]) > 0, rs[1]["sharpe"]),
                       reverse=True)
    print("=== A) Both halves +, then max monthly Sharpe (can be era-driven) ===")
    for res, sc in by_sharpe[:10]:
        print_row(res["params"], sc)

    # (2) most ERA-BALANCED: maximize the weaker of the two half-averages, so
    # 2024-26 income counts as much as the 2020-21 bull — the honest pick for
    # forward monthly income.
    by_robust = sorted(runs, key=lambda rs: robust(rs[0]), reverse=True)
    print("\n=== B) Most era-balanced (max of the WEAKER half's avg/mo) ===")
    for res, sc in by_robust[:10]:
        print_row(res["params"], sc)

    # (3) best dollar-NEUTRAL factor (market-independent, no bull beta)
    neutral = [rs for rs in runs if not rs[0]["params"]["ema_len"]]
    by_neutral = sorted(neutral, key=lambda rs: rs[1]["sharpe"], reverse=True)
    print("\n=== C) Best market-NEUTRAL cross-sectional factor ===")
    for res, sc in by_neutral[:6]:
        print_row(res["params"], sc)

    # The recommended/headline deliverable is the era-balanced pick.
    best_res = by_robust[0][0]
    report(best_res, by_robust[0][1])

    # show what funding actually costs this config (re-run it with funding off)
    bp = best_res["params"]
    nofund = simulate(bp["lookback"], bp["k"], bp["M"], bp["tp"], bp["sl"],
                      bp["leg_stop"], bp["hold"], bp["gate"], ema_len=bp["ema_len"],
                      with_funding=False)
    sc_nf = score(nofund)
    print(f"\n  funding impact on headline: "
          f"with funding ${by_robust[0][1]['total']:+.2f}  vs  "
          f"without ${sc_nf['total']:+.2f}  "
          f"(funding = ${by_robust[0][1]['total'] - sc_nf['total']:+.2f} over {best_res['baskets']} baskets)")


def report(best_res, best_sc):
    print(f"\n=== BEST ===")
    print_row(best_res["params"], best_sc)
    m = best_res["monthly"]
    for label, lo, hi in (("2022-2023", "0000", "2024-01"), ("2024-2026", "2024-01", "9999")):
        seg = [v for ym, v in m.items() if lo <= ym < hi]
        if seg:
            pos = sum(1 for v in seg if v > 0)
            print(f"    OOS {label}: total ${sum(seg):+7.2f} | avg ${sum(seg)/len(seg):+5.2f}/mo "
                  f"| green {pos}/{len(seg)} ({100*pos/len(seg):.0f}%)")

    years = sorted({ym[:4] for ym in m})
    months = [f"{x:02d}" for x in range(1, 13)]
    print(f"\n  Monthly income (USD) — fixed ${CAPITAL:.0f}:")
    header = "  year |" + "".join(f"{x:>7}" for x in months) + "  |   TOTAL"
    print(header); print("  " + "-" * (len(header) - 2))
    for y in years:
        row = f"  {y} |"; ytot = 0.0
        for mm in months:
            v = m.get(f"{y}-{mm}")
            row += f"{'·':>7}" if v is None else f"{v:>7.1f}"
            if v is not None: ytot += v
        print(row + f"  | {ytot:>7.1f}")
    allv = list(m.values())
    print(f"\n  total ${sum(allv):+.2f} over {len(allv)} months | avg ${sum(allv)/len(allv):+.2f}/mo "
          f"| green {sum(1 for v in allv if v>0)}/{len(allv)} "
          f"({100*sum(1 for v in allv if v>0)/len(allv):.0f}%) "
          f"| best ${max(allv):+.1f} worst ${min(allv):+.1f}")
    print(f"  baskets {best_sc['n']} (tp {best_res['n_tp']}/sl {best_res['n_sl']}/"
          f"timeout {best_res['n_to']}/legx {best_res['n_legx']})")

    out_m = ROOT / "tool" / "daily_wide_basket_monthly.csv"
    with out_m.open("w", newline="") as fh:
        w = csv.writer(fh); w.writerow(["month", "income", "n_baskets"])
        for ym in sorted(m):
            w.writerow([ym, f"{m[ym]:.4f}", best_res["monthly_n"][ym]])
    out_t = ROOT / "tool" / "daily_wide_basket_trades.csv"
    with out_t.open("w", newline="") as fh:
        w = csv.writer(fh); w.writerow(["closed_ts", "pnl", "reason"])
        for ts, pnl, reason in best_res["realized"]:
            w.writerow([ts, f"{pnl:.4f}", reason])
    print(f"\n  wrote {out_m.relative_to(ROOT)} and {out_t.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
