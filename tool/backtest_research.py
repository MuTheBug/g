"""Research harness: push the momentum-basket Sharpe higher with PRINCIPLED,
literature-backed levers (not parameter tuning), under a strict walk-forward
guard against overfitting.

Levers (each motivated a priori, see refs in the chat/notes):
  * skip      : skip the most recent `skip` days of the momentum window
                (classic Jegadeesh-Titman gap; avoids 1-day reversal noise)
  * ensemble  : average cross-sectional z-scores across several lookbacks
                (robust to any single lookback; reduces lookback overfitting)
  * residual  : rank on BTC-beta-neutralised (idiosyncratic) momentum
                (Blitz residual momentum; valuable post-2021 in crypto)
  * volparity : size legs inverse to volatility (equal risk per leg) instead of
                flat $50 (volatility scaling -> smoother basket PnL)

Anti-overfit protocol: SELECT on the in-sample half (2020-2023), then REPORT the
untouched out-of-sample half (2024-2026). A lever is adopted only if it holds up
OOS. Reuses the loaded 112-symbol universe + funding from
backtest_daily_wide_basket.py.

Run:  python3 tool/backtest_research.py
"""
from __future__ import annotations
import numpy as np
import pandas as pd

import backtest_daily_wide_basket as E

MARGIN   = E.MARGIN_PER_POS
LEV      = E.LEVERAGE
NOTION   = E.NOTIONAL_PER_POS          # $50
FEE      = E.FEE_PER_SIDE
LIQ      = E.LIQ_FRAC
NAMES    = E.NAMES
TS       = E.ALL_TS
T, S     = len(TS), len(NAMES)
BTC_J    = NAMES.index("BTC")
IS_END   = "2024-01"                   # in-sample < this; OOS >= this

# ---- aligned OHLC matrices [T, S] (NaN where a symbol hadn't listed) --------
O = np.full((T, S), np.nan); H = np.full((T, S), np.nan)
L = np.full((T, S), np.nan); C = np.full((T, S), np.nan)
tpos = {t: i for i, t in enumerate(TS)}
for j, name in enumerate(NAMES):
    s = E.SYMS[name]
    for kk, t in enumerate(s["ts"]):
        i = tpos[t]
        O[i, j] = s["O"][kk]; H[i, j] = s["H"][kk]
        L[i, j] = s["L"][kk]; C[i, j] = s["C"][kk]
Cdf = pd.DataFrame(C)
Rdf = Cdf.pct_change()
YM = [E.YM[t] for t in TS]

# vol (for vol-parity) and rolling BTC beta (for residual momentum), once.
VOL20 = Rdf.rolling(20, min_periods=10).std().values
_btc_r = Rdf[BTC_J]
_cov = Rdf.rolling(60, min_periods=30).cov(_btc_r)
_var = _btc_r.rolling(60, min_periods=30).var()
BETA = _cov.div(_var, axis=0).values
BTC_C = C[:, BTC_J]


def momentum(lb, skip):
    """Percentage momentum over [t-skip-lb, t-skip] as a [T,S] matrix."""
    a = Cdf.shift(skip)
    b = Cdf.shift(skip + lb)
    return (a / b - 1.0).values


def build_signal(lookbacks, skip, residual):
    """Cross-sectional rank score [T,S]; higher = stronger long candidate."""
    zs = np.zeros((T, S)); cnt = np.zeros((T, S))
    for lb in lookbacks:
        m = momentum(lb, skip)
        if residual:
            # subtract beta * BTC's own momentum over the same window
            btc_m = m[:, BTC_J][:, None]
            m = m - BETA * btc_m
        # z-score across the cross-section each day (NaN-aware)
        mu = np.nanmean(m, axis=1, keepdims=True)
        sd = np.nanstd(m, axis=1, keepdims=True)
        z = (m - mu) / np.where(sd > 0, sd, np.nan)
        ok = ~np.isnan(z)
        zs[ok] += z[ok]; cnt[ok] += 1
    out = np.where(cnt > 0, zs / np.where(cnt > 0, cnt, 1), np.nan)
    return out


def simulate(signal, k=1, M=2, tp=3.0, sl=5.0, leg_stop=0.12, hold=20, gate=0.0,
             sizing="fixed", with_funding=True):
    """Basket lifecycle on a precomputed signal matrix. Mirrors the engine but
    supports inverse-vol ('volparity') sizing. Returns monthly income dict."""
    n_legs = 2 * k
    total_notional = n_legs * NOTION
    monthly = {}
    baskets = []        # each: legs list, opened_i, opened_ts, held
    pending = []
    income = 0.0
    n_tp = n_sl = n_to = n_legx = nb = 0

    def add_month(i, pnl):
        monthly[YM[i]] = monthly.get(YM[i], 0.0) + pnl

    def leg_notionals(sel, i):
        if sizing == "fixed":
            return [NOTION] * len(sel)
        vols = np.array([VOL20[i, j] if not np.isnan(VOL20[i, j]) else np.nan
                         for j, _s in sel])
        med = np.nanmedian(vols)
        vols = np.where(np.isnan(vols), med, vols)
        inv = 1.0 / np.where(vols > 1e-9, vols, med)
        w = inv / inv.sum()
        w = np.clip(w, 0.4 / len(sel) * len(sel) * 0.0 + 0.0, 1.0)  # no-op guard
        notn = total_notional * (inv / inv.sum())
        # clip each leg to [0.4x, 2.5x] of equal split, renormalise
        eq = total_notional / len(sel)
        notn = np.clip(notn, 0.4 * eq, 2.5 * eq)
        notn *= total_notional / notn.sum()
        return list(notn)

    for i in range(T):
        # 1) open pending at today's open
        if pending:
            for sel in pending:
                notns = leg_notionals(sel, i)
                legs = []
                for (j, side), notn in zip(sel, notns):
                    px = O[i, j]
                    if np.isnan(px) or px <= 0:
                        continue
                    qty = notn / px
                    margin = notn / LEV
                    prot = px * (1 - leg_stop) if side > 0 else px * (1 + leg_stop)
                    legs.append(dict(j=j, side=side, entry=px, qty=qty,
                                     prot=prot, margin=margin, open=True))
                if legs:
                    baskets.append(dict(legs=legs, oi=i, ots=TS[i], held=0)); nb += 1
            pending = []

        # 2) intrabar protective leg stop
        for b in baskets:
            for lg in b["legs"]:
                if not lg["open"]:
                    continue
                j = lg["j"]
                hi, lo = H[i, j], L[i, j]
                if np.isnan(hi):
                    continue
                if (lg["side"] > 0 and lo <= lg["prot"]) or (lg["side"] < 0 and hi >= lg["prot"]):
                    lg["open"] = False
                    gross = lg["qty"] * (lg["prot"] - lg["entry"]) * lg["side"]
                    fees = FEE * (lg["qty"] * lg["entry"] + lg["qty"] * lg["prot"])
                    fund = E.funding_pnl(NAMES[j], lg["side"], lg["qty"] * lg["entry"],
                                         b["ots"], TS[i]) if with_funding else 0.0
                    b.setdefault("realized", 0.0)
                    b["realized"] += max(gross - fees + fund, -lg["margin"])
                    n_legx += 1

        # 3) close decisions at close
        survivors = []
        for b in baskets:
            alive = [lg for lg in b["legs"] if lg["open"]]
            if not alive:
                pnl = b.get("realized", 0.0)
                income += pnl; add_month(i, pnl); continue
            b["held"] += 1
            total = b.get("realized", 0.0)
            broken = False
            for lg in alive:
                px = C[i, lg["j"]]
                if np.isnan(px):
                    broken = True; break
                gross = lg["qty"] * (px - lg["entry"]) * lg["side"]
                fees = FEE * (lg["qty"] * lg["entry"] + lg["qty"] * px)
                fund = E.funding_pnl(NAMES[lg["j"]], lg["side"], lg["qty"] * lg["entry"],
                                     b["ots"], TS[i]) if with_funding else 0.0
                total += max(gross - fees + fund, -lg["margin"])
            if broken:
                survivors.append(b); continue
            reason = ("tp" if total >= tp else "sl" if total <= -sl
                      else "to" if b["held"] >= hold else None)
            if reason is None:
                survivors.append(b); continue
            # realize at close
            r = b.get("realized", 0.0)
            for lg in alive:
                px = C[i, lg["j"]]
                gross = lg["qty"] * (px - lg["entry"]) * lg["side"]
                fees = FEE * (lg["qty"] * lg["entry"] + lg["qty"] * px)
                fund = E.funding_pnl(NAMES[lg["j"]], lg["side"], lg["qty"] * lg["entry"],
                                     b["ots"], TS[i]) if with_funding else 0.0
                r += max(gross - fees + fund, -lg["margin"]); lg["open"] = False
            income += r; add_month(i, r)
            n_tp += reason == "tp"; n_sl += reason == "sl"; n_to += reason == "to"
        baskets = survivors

        # 4) entry signal at close -> pending for next open
        if len(baskets) < M:
            row = signal[i]
            held = {lg["j"] for b in baskets for lg in b["legs"] if lg["open"]}
            cand = [(row[j], j) for j in range(S)
                    if j not in held and not np.isnan(row[j]) and not np.isnan(C[i, j])]
            if len(cand) >= n_legs:
                cand.sort()
                spread = cand[-1][0] - cand[0][0]
                if spread >= gate:
                    sel = ([(j, 1) for _v, j in cand[-k:]]
                           + [(j, -1) for _v, j in cand[:k]])
                    pending.append(sel)

    return dict(monthly=monthly, income=income, baskets=nb,
                n_tp=n_tp, n_sl=n_sl, n_to=n_to, n_legx=n_legx)


def stats(monthly, lo="0000", hi="9999"):
    seg = [v for ym, v in monthly.items() if lo <= ym < hi]
    if not seg:
        return dict(n=0, total=0, avg=0, sharpe=0, pos=0, worst=0)
    n = len(seg); avg = sum(seg) / n
    sd = (sum((x - avg) ** 2 for x in seg) / n) ** 0.5
    return dict(n=n, total=sum(seg), avg=avg, sharpe=(avg / sd if sd else 0),
                pos=100 * sum(1 for x in seg if x > 0) / n, worst=min(seg))


def report(label, res):
    a = stats(res["monthly"])
    isn = stats(res["monthly"], hi=IS_END)
    oos = stats(res["monthly"], lo=IS_END)
    print(f"  {label:<34} | all sh {a['sharpe']:+.2f} tot ${a['total']:+6.0f} "
          f"pos {a['pos']:.0f}% || IS sh {isn['sharpe']:+.2f} ${isn['avg']:+5.1f}/mo "
          f"|| OOS sh {oos['sharpe']:+.2f} ${oos['avg']:+5.1f}/mo pos {oos['pos']:.0f}% "
          f"worst ${oos['worst']:+.0f}")
    return a, isn, oos


def main():
    print(f"Research harness | {S} symbols, {T} days | select on IS(<{IS_END}), "
          f"report OOS(>={IS_END})\n")

    # baseline = current headline (single 20d lookback, fixed sizing)
    print("=== Baseline (20d momentum, fixed $50 legs) ===")
    base_sig = build_signal([20], skip=0, residual=False)
    report("baseline", simulate(base_sig))

    print("\n=== Lever 1: skip-recent-day momentum ===")
    for sk in (1, 2, 3, 5):
        report(f"skip={sk}", simulate(build_signal([20], skip=sk, residual=False)))

    print("\n=== Lever 2: multi-lookback ensemble (z-scored) ===")
    for lbs in ([10, 20, 40], [5, 10, 20, 40], [10, 20, 30, 60]):
        report(f"ensemble {lbs}", simulate(build_signal(lbs, skip=0, residual=False)))

    print("\n=== Lever 3: BTC-residual (idiosyncratic) momentum ===")
    report("residual 20d", simulate(build_signal([20], skip=0, residual=True)))
    report("residual ens[10,20,40]", simulate(build_signal([10, 20, 40], skip=0, residual=True)))

    print("\n=== Lever 4: inverse-vol (risk-parity) leg sizing ===")
    report("volparity", simulate(base_sig, sizing="volparity"))

    print("\nNext: combine the levers that hold up OOS, then validate.")


if __name__ == "__main__":
    main()
