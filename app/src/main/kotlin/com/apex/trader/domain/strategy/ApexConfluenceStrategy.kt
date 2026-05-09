package com.apex.trader.domain.strategy

import com.apex.trader.data.model.Candle
import com.apex.trader.domain.indicator.Indicators
import kotlin.math.abs

/**
 * # Apex Confluence Strategy (ACS)
 *
 * A multi-timeframe, multi-factor confluence strategy designed for high-probability
 * setups on USDT-margined Binance Futures. The strategy filters trades through:
 *
 *  1. **Market regime** (ADX-based): only trades trending markets unless explicit
 *     range-bound counter-trend setups appear at swing extremes.
 *  2. **HTF trend (4H)**: EMA50 vs EMA200 → primary bias.
 *  3. **MTF setup (1H)**: EMA21 vs EMA50 → operating direction.
 *  4. **LTF trigger (15m)**: precise entry conditions across momentum, volume,
 *     volatility, and price action.
 *
 * The LTF trigger is a confluence score across:
 *  - RSI position relative to 50 (and divergence)
 *  - MACD histogram momentum shift
 *  - Bollinger Band squeeze breakout
 *  - Volume surge vs 20-period average
 *  - VWAP positioning
 *  - Stochastic RSI cross out of oversold/overbought
 *  - Engulfing / pin-bar candle patterns
 *  - OBV trend alignment
 *  - Distance from nearest swing (don't chase)
 *
 * Each component contributes a weighted vote. Only signals scoring >= [Config.minConfidence]
 * are surfaced. The trade plan uses ATR-based dynamic SL/TP at fixed R-multiples.
 *
 * The implementation deliberately avoids look-ahead: every series is evaluated at the
 * latest *closed* candle (excluding the still-forming current candle is the caller's
 * responsibility — pass closed candles only).
 */
class ApexConfluenceStrategy(
    private val config: Config = Config()
) {

    data class Config(
        val htfEmaFast: Int = 50,
        val htfEmaSlow: Int = 200,
        val mtfEmaFast: Int = 21,
        val mtfEmaSlow: Int = 50,
        val ltfEmaFast: Int = 9,
        val ltfEmaSlow: Int = 21,
        val rsiPeriod: Int = 14,
        val atrPeriod: Int = 14,
        val adxPeriod: Int = 14,
        val bbPeriod: Int = 20,
        val volPeriod: Int = 20,
        val minAdxTrending: Double = 22.0,
        val minVolumeSurge: Double = 1.4,
        val atrSlMult: Double = 1.5,
        val tp1R: Double = 1.5,
        val tp2R: Double = 2.5,
        val tp3R: Double = 4.0,
        val minConfidence: Int = 70
    )

    /**
     * Evaluate the strategy across HTF / MTF / LTF candles. Each list must contain
     * only closed candles in chronological order. Returns null when not enough data
     * or when no high-confidence signal exists.
     */
    fun evaluate(
        symbol: String,
        htf: List<Candle>,
        mtf: List<Candle>,
        ltf: List<Candle>,
        nowMs: Long = System.currentTimeMillis()
    ): Signal? {
        if (htf.size < config.htfEmaSlow + 5) return null
        if (mtf.size < config.mtfEmaSlow + 5) return null
        if (ltf.size < 60) return null

        val htfBias = htfBias(htf) ?: return null
        val mtfBias = mtfBias(mtf) ?: return null
        // Trade only with HTF (primary trend follow). MTF must agree.
        if (htfBias != mtfBias) return null

        val ltfCloses = ltf.map { it.close }
        val rsi = Indicators.rsi(ltfCloses, config.rsiPeriod)
        val macd = Indicators.macd(ltfCloses)
        val bb = Indicators.bollinger(ltfCloses, config.bbPeriod)
        val atr = Indicators.atr(ltf, config.atrPeriod)
        val adx = Indicators.adx(ltf, config.adxPeriod)
        val obv = Indicators.obv(ltf)
        val stochRsi = Indicators.stochRsi(ltfCloses)
        val vwap = Indicators.vwap(ltf)
        val emaFastLtf = Indicators.ema(ltfCloses, config.ltfEmaFast)
        val emaSlowLtf = Indicators.ema(ltfCloses, config.ltfEmaSlow)

        val i = ltf.lastIndex
        val price = ltf[i].close
        val atrNow = atr[i].takeIf { !it.isNaN() } ?: return null
        val adxNow = adx.adx[i].takeIf { !it.isNaN() } ?: return null
        val regime = when {
            adxNow >= config.minAdxTrending && adxNow < 50.0 -> MarketRegime.TRENDING
            adxNow < 18.0 -> MarketRegime.RANGING
            else -> MarketRegime.TRANSITION
        }
        // Only take trending setups (this strategy is trend-follow first).
        if (regime != MarketRegime.TRENDING) return null

        val side = if (htfBias == Trend.UP) SignalSide.LONG else SignalSide.SHORT
        val (support, resistance) = Indicators.nearestSwing(ltf, lookback = 60)

        val volSurge = Indicators.volumeSurge(ltf, config.volPeriod)
        val divergence = Indicators.rsiDivergence(ltfCloses, rsi)

        val reasons = mutableListOf<SignalReason>()

        // 1. EMA stack on LTF agrees with side
        val ltfEmaUp = emaFastLtf[i] > emaSlowLtf[i]
        reasons += SignalReason(
            label = "LTF EMA stack",
            detail = "EMA${config.ltfEmaFast} ${if (ltfEmaUp) ">" else "<"} EMA${config.ltfEmaSlow}",
            weight = 12.0,
            passed = (side == SignalSide.LONG) == ltfEmaUp
        )

        // 2. RSI position
        val rsiNow = rsi[i]
        val rsiOk = if (side == SignalSide.LONG) rsiNow in 45.0..68.0 else rsiNow in 32.0..55.0
        reasons += SignalReason(
            label = "RSI position",
            detail = "RSI ${"%.1f".format(rsiNow)} in entry zone",
            weight = 10.0,
            passed = rsiOk
        )

        // 3. MACD histogram momentum
        val histNow = macd.histogram[i]
        val histPrev = macd.histogram.getOrNull(i - 1) ?: Double.NaN
        val macdMomentum = !histNow.isNaN() && !histPrev.isNaN() &&
            ((side == SignalSide.LONG && histNow > 0 && histNow > histPrev) ||
                (side == SignalSide.SHORT && histNow < 0 && histNow < histPrev))
        reasons += SignalReason(
            label = "MACD momentum",
            detail = "Hist ${"%.4f".format(histNow)} (${if (histNow > histPrev) "rising" else "falling"})",
            weight = 12.0,
            passed = macdMomentum
        )

        // 4. Volume surge
        reasons += SignalReason(
            label = "Volume surge",
            detail = "${"%.2f".format(volSurge)}x avg",
            weight = 10.0,
            passed = volSurge >= config.minVolumeSurge
        )

        // 5. Bollinger band context — inside upper/lower half but not pinning the band
        val midOk = if (side == SignalSide.LONG) {
            !bb.mid[i].isNaN() && price > bb.mid[i] && price < bb.upper[i]
        } else {
            !bb.mid[i].isNaN() && price < bb.mid[i] && price > bb.lower[i]
        }
        reasons += SignalReason(
            label = "BB position",
            detail = "Price in favorable BB half",
            weight = 8.0,
            passed = midOk
        )

        // 6. VWAP confirmation
        val vwapNow = vwap[i]
        val vwapOk = !vwapNow.isNaN() && (
            (side == SignalSide.LONG && price > vwapNow) ||
                (side == SignalSide.SHORT && price < vwapNow)
            )
        reasons += SignalReason(
            label = "VWAP side",
            detail = "${if (price > vwapNow) "above" else "below"} VWAP ${"%.4f".format(vwapNow)}",
            weight = 8.0,
            passed = vwapOk
        )

        // 7. Stoch RSI cross / position
        val kNow = stochRsi.k[i]
        val dNow = stochRsi.d[i]
        val kPrev = stochRsi.k.getOrNull(i - 1) ?: Double.NaN
        val dPrev = stochRsi.d.getOrNull(i - 1) ?: Double.NaN
        val stochOk = !kNow.isNaN() && !dNow.isNaN() && !kPrev.isNaN() && !dPrev.isNaN() && (
            (side == SignalSide.LONG && kPrev <= dPrev && kNow > dNow && kNow < 80) ||
                (side == SignalSide.SHORT && kPrev >= dPrev && kNow < dNow && kNow > 20)
            )
        reasons += SignalReason(
            label = "StochRSI cross",
            detail = "K ${"%.1f".format(kNow)} / D ${"%.1f".format(dNow)}",
            weight = 8.0,
            passed = stochOk
        )

        // 8. RSI divergence (bonus — not required)
        val divOk = (side == SignalSide.LONG && divergence == +1) ||
            (side == SignalSide.SHORT && divergence == -1)
        reasons += SignalReason(
            label = "RSI divergence",
            detail = if (divOk) "${if (divergence > 0) "bullish" else "bearish"} divergence" else "no divergence",
            weight = 10.0,
            passed = divOk
        )

        // 9. OBV trend alignment
        val obvNow = obv[i]
        val obvPrev = obv.getOrNull(i - 5) ?: Double.NaN
        val obvOk = !obvPrev.isNaN() && (
            (side == SignalSide.LONG && obvNow > obvPrev) ||
                (side == SignalSide.SHORT && obvNow < obvPrev)
            )
        reasons += SignalReason(
            label = "OBV alignment",
            detail = if (obvOk) "OBV trending with side" else "OBV opposing",
            weight = 6.0,
            passed = obvOk
        )

        // 10. Candle pattern — bullish/bearish engulfing or strong close
        val patternOk = candleConfirms(ltf, side)
        reasons += SignalReason(
            label = "Candle pattern",
            detail = "Engulf / strong-body confirmation",
            weight = 8.0,
            passed = patternOk
        )

        // 11. Distance from swing — don't chase right into resistance/support
        val distanceOk = when (side) {
            SignalSide.LONG -> resistance == null || (resistance - price) > atrNow
            SignalSide.SHORT -> support == null || (price - support) > atrNow
        }
        reasons += SignalReason(
            label = "Headroom to swing",
            detail = "≥ 1 ATR away from nearest opposing swing",
            weight = 8.0,
            passed = distanceOk
        )

        val confidence = scoreConfidence(reasons)
        if (confidence < config.minConfidence) return null

        val plan = buildPlan(side, price, atrNow)

        return Signal(
            symbol = symbol,
            side = side,
            regime = regime,
            confidence = confidence,
            plan = plan,
            reasons = reasons,
            htfTrendUp = htfBias == Trend.UP,
            mtfTrendUp = mtfBias == Trend.UP,
            createdAt = nowMs,
            price = price,
            volumeSurge = volSurge,
            adx = adxNow,
            rsi = rsiNow
        )
    }

    private fun buildPlan(side: SignalSide, entry: Double, atr: Double): TradePlan {
        val sl = if (side == SignalSide.LONG) entry - config.atrSlMult * atr else entry + config.atrSlMult * atr
        val r = abs(entry - sl)
        val (tp1, tp2, tp3) = if (side == SignalSide.LONG) {
            Triple(entry + config.tp1R * r, entry + config.tp2R * r, entry + config.tp3R * r)
        } else {
            Triple(entry - config.tp1R * r, entry - config.tp2R * r, entry - config.tp3R * r)
        }
        return TradePlan(
            entry = entry,
            stopLoss = sl,
            takeProfit1 = tp1,
            takeProfit2 = tp2,
            takeProfit3 = tp3,
            riskRewardR1 = config.tp1R,
            riskRewardR2 = config.tp2R,
            riskRewardR3 = config.tp3R,
            atr = atr
        )
    }

    private fun scoreConfidence(reasons: List<SignalReason>): Int {
        val totalWeight = reasons.sumOf { it.weight }
        val gained = reasons.filter { it.passed }.sumOf { it.weight }
        if (totalWeight == 0.0) return 0
        return ((gained / totalWeight) * 100.0).toInt().coerceIn(0, 100)
    }

    private enum class Trend { UP, DOWN }

    private fun htfBias(htf: List<Candle>): Trend? {
        val closes = htf.map { it.close }
        val emaFast = Indicators.ema(closes, config.htfEmaFast)
        val emaSlow = Indicators.ema(closes, config.htfEmaSlow)
        val i = htf.lastIndex
        if (emaFast[i].isNaN() || emaSlow[i].isNaN()) return null
        // Require slope alignment to avoid chop on the cross.
        val slopeOk = !emaFast[i - 3].isNaN() && abs(emaFast[i] - emaFast[i - 3]) > 0
        if (!slopeOk) return null
        val trendUp = emaFast[i] > emaSlow[i] && emaFast[i] > emaFast[i - 3]
        val trendDown = emaFast[i] < emaSlow[i] && emaFast[i] < emaFast[i - 3]
        return when {
            trendUp -> Trend.UP
            trendDown -> Trend.DOWN
            else -> null
        }
    }

    private fun mtfBias(mtf: List<Candle>): Trend? {
        val closes = mtf.map { it.close }
        val emaFast = Indicators.ema(closes, config.mtfEmaFast)
        val emaSlow = Indicators.ema(closes, config.mtfEmaSlow)
        val i = mtf.lastIndex
        if (emaFast[i].isNaN() || emaSlow[i].isNaN()) return null
        return when {
            emaFast[i] > emaSlow[i] -> Trend.UP
            emaFast[i] < emaSlow[i] -> Trend.DOWN
            else -> null
        }
    }

    /** Returns true if the latest candle confirms direction with body/wick structure. */
    private fun candleConfirms(ltf: List<Candle>, side: SignalSide): Boolean {
        val n = ltf.size
        if (n < 2) return false
        val curr = ltf[n - 1]
        val prev = ltf[n - 2]
        val bodyDominant = curr.body > curr.range * 0.55
        return when (side) {
            SignalSide.LONG -> {
                val engulf = curr.isBull && !prev.isBull && curr.close >= prev.open && curr.open <= prev.close
                val strongBull = curr.isBull && bodyDominant && curr.lowerWick > curr.body * 0.3
                engulf || strongBull
            }
            SignalSide.SHORT -> {
                val engulf = !curr.isBull && prev.isBull && curr.close <= prev.open && curr.open >= prev.close
                val strongBear = !curr.isBull && bodyDominant && curr.upperWick > curr.body * 0.3
                engulf || strongBear
            }
        }
    }
}
