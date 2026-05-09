package com.apex.trader.domain.indicator

import com.apex.trader.data.model.Candle
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Pure-Kotlin technical indicators. Implementations follow the standard textbook
 * definitions and match the Wilder/J. Welles smoothing where applicable. Inputs are
 * treated as immutable; outputs are aligned 1:1 with the input series (warm-up
 * positions are filled with [Double.NaN] so callers can detect "not enough data").
 */
object Indicators {

    fun sma(values: List<Double>, period: Int): DoubleArray {
        require(period > 0)
        val out = DoubleArray(values.size) { Double.NaN }
        if (values.size < period) return out
        var sum = 0.0
        for (i in values.indices) {
            sum += values[i]
            if (i >= period) sum -= values[i - period]
            if (i >= period - 1) out[i] = sum / period
        }
        return out
    }

    fun ema(values: List<Double>, period: Int): DoubleArray {
        require(period > 0)
        val out = DoubleArray(values.size) { Double.NaN }
        if (values.isEmpty()) return out
        val k = 2.0 / (period + 1.0)
        // Seed EMA with SMA of first `period` values.
        if (values.size < period) return out
        var sum = 0.0
        for (i in 0 until period) sum += values[i]
        var prev = sum / period
        out[period - 1] = prev
        for (i in period until values.size) {
            prev = values[i] * k + prev * (1 - k)
            out[i] = prev
        }
        return out
    }

    /** Wilder's smoothing (RMA) — used by RSI, ATR, ADX. */
    fun rma(values: List<Double>, period: Int): DoubleArray {
        require(period > 0)
        val out = DoubleArray(values.size) { Double.NaN }
        if (values.size < period) return out
        var sum = 0.0
        for (i in 0 until period) sum += values[i]
        var prev = sum / period
        out[period - 1] = prev
        for (i in period until values.size) {
            prev = (prev * (period - 1) + values[i]) / period
            out[i] = prev
        }
        return out
    }

    fun rsi(closes: List<Double>, period: Int = 14): DoubleArray {
        val n = closes.size
        val out = DoubleArray(n) { Double.NaN }
        if (n < period + 1) return out
        val gains = DoubleArray(n)
        val losses = DoubleArray(n)
        for (i in 1 until n) {
            val d = closes[i] - closes[i - 1]
            if (d >= 0) gains[i] = d else losses[i] = -d
        }
        // First averages: simple mean of the first `period` gains/losses.
        var avgGain = 0.0
        var avgLoss = 0.0
        for (i in 1..period) {
            avgGain += gains[i]
            avgLoss += losses[i]
        }
        avgGain /= period
        avgLoss /= period
        out[period] = computeRsi(avgGain, avgLoss)
        for (i in period + 1 until n) {
            avgGain = (avgGain * (period - 1) + gains[i]) / period
            avgLoss = (avgLoss * (period - 1) + losses[i]) / period
            out[i] = computeRsi(avgGain, avgLoss)
        }
        return out
    }

    private fun computeRsi(avgGain: Double, avgLoss: Double): Double {
        if (avgLoss == 0.0) return 100.0
        val rs = avgGain / avgLoss
        return 100.0 - 100.0 / (1.0 + rs)
    }

    data class Macd(val macd: DoubleArray, val signal: DoubleArray, val histogram: DoubleArray)

    fun macd(
        closes: List<Double>,
        fast: Int = 12,
        slow: Int = 26,
        signalPeriod: Int = 9
    ): Macd {
        val emaFast = ema(closes, fast)
        val emaSlow = ema(closes, slow)
        val macd = DoubleArray(closes.size) { Double.NaN }
        for (i in closes.indices) {
            if (!emaFast[i].isNaN() && !emaSlow[i].isNaN()) macd[i] = emaFast[i] - emaSlow[i]
        }
        // Build signal line from MACD values (skip NaN warm-up).
        val firstValid = macd.indexOfFirst { !it.isNaN() }
        val signal = DoubleArray(closes.size) { Double.NaN }
        if (firstValid >= 0 && closes.size - firstValid >= signalPeriod) {
            val sub = macd.copyOfRange(firstValid, macd.size).toList()
            val sig = ema(sub, signalPeriod)
            for (i in sig.indices) signal[firstValid + i] = sig[i]
        }
        val hist = DoubleArray(closes.size) { Double.NaN }
        for (i in closes.indices) {
            if (!macd[i].isNaN() && !signal[i].isNaN()) hist[i] = macd[i] - signal[i]
        }
        return Macd(macd, signal, hist)
    }

    data class Bollinger(val mid: DoubleArray, val upper: DoubleArray, val lower: DoubleArray, val bandwidth: DoubleArray)

    fun bollinger(closes: List<Double>, period: Int = 20, stdDev: Double = 2.0): Bollinger {
        val n = closes.size
        val mid = sma(closes, period)
        val upper = DoubleArray(n) { Double.NaN }
        val lower = DoubleArray(n) { Double.NaN }
        val bw = DoubleArray(n) { Double.NaN }
        if (n < period) return Bollinger(mid, upper, lower, bw)
        for (i in period - 1 until n) {
            var sumSq = 0.0
            val mean = mid[i]
            for (j in i - period + 1..i) {
                val diff = closes[j] - mean
                sumSq += diff * diff
            }
            val sd = sqrt(sumSq / period)
            upper[i] = mean + stdDev * sd
            lower[i] = mean - stdDev * sd
            bw[i] = if (mean != 0.0) (upper[i] - lower[i]) / mean else Double.NaN
        }
        return Bollinger(mid, upper, lower, bw)
    }

    /** True Range series (length = candles.size, candles[0] = high - low). */
    fun trueRange(candles: List<Candle>): DoubleArray {
        val n = candles.size
        val out = DoubleArray(n)
        if (n == 0) return out
        out[0] = candles[0].high - candles[0].low
        for (i in 1 until n) {
            val c = candles[i]
            val prevClose = candles[i - 1].close
            out[i] = maxOf(
                c.high - c.low,
                abs(c.high - prevClose),
                abs(c.low - prevClose)
            )
        }
        return out
    }

    fun atr(candles: List<Candle>, period: Int = 14): DoubleArray {
        val tr = trueRange(candles).toList()
        return rma(tr, period)
    }

    data class Adx(val adx: DoubleArray, val plusDi: DoubleArray, val minusDi: DoubleArray)

    fun adx(candles: List<Candle>, period: Int = 14): Adx {
        val n = candles.size
        val out = DoubleArray(n) { Double.NaN }
        val plusDi = DoubleArray(n) { Double.NaN }
        val minusDi = DoubleArray(n) { Double.NaN }
        if (n < period + 1) return Adx(out, plusDi, minusDi)

        val plusDM = DoubleArray(n)
        val minusDM = DoubleArray(n)
        val tr = DoubleArray(n)
        tr[0] = candles[0].high - candles[0].low
        for (i in 1 until n) {
            val up = candles[i].high - candles[i - 1].high
            val dn = candles[i - 1].low - candles[i].low
            plusDM[i] = if (up > dn && up > 0) up else 0.0
            minusDM[i] = if (dn > up && dn > 0) dn else 0.0
            val c = candles[i]; val pc = candles[i - 1].close
            tr[i] = maxOf(c.high - c.low, abs(c.high - pc), abs(c.low - pc))
        }

        val smTr = rma(tr.toList(), period)
        val smPlus = rma(plusDM.toList(), period)
        val smMinus = rma(minusDM.toList(), period)

        val dx = DoubleArray(n) { Double.NaN }
        for (i in candles.indices) {
            val t = smTr[i]
            if (t.isNaN() || t == 0.0) continue
            plusDi[i] = 100.0 * smPlus[i] / t
            minusDi[i] = 100.0 * smMinus[i] / t
            val sum = plusDi[i] + minusDi[i]
            if (sum != 0.0) dx[i] = 100.0 * abs(plusDi[i] - minusDi[i]) / sum
        }
        // ADX is RMA of DX over `period`, only over non-NaN region.
        val firstValid = dx.indexOfFirst { !it.isNaN() }
        if (firstValid < 0 || dx.size - firstValid < period) return Adx(out, plusDi, minusDi)
        val sub = dx.copyOfRange(firstValid, dx.size).toList()
        val ad = rma(sub, period)
        for (i in ad.indices) out[firstValid + i] = ad[i]
        return Adx(out, plusDi, minusDi)
    }

    fun obv(candles: List<Candle>): DoubleArray {
        val n = candles.size
        val out = DoubleArray(n)
        if (n == 0) return out
        out[0] = 0.0
        for (i in 1 until n) {
            val prev = out[i - 1]
            val c = candles[i].close
            val pc = candles[i - 1].close
            out[i] = when {
                c > pc -> prev + candles[i].volume
                c < pc -> prev - candles[i].volume
                else -> prev
            }
        }
        return out
    }

    data class StochRsi(val k: DoubleArray, val d: DoubleArray)

    fun stochRsi(
        closes: List<Double>,
        rsiPeriod: Int = 14,
        stochPeriod: Int = 14,
        smoothK: Int = 3,
        smoothD: Int = 3
    ): StochRsi {
        val rsiVals = rsi(closes, rsiPeriod)
        val n = closes.size
        val raw = DoubleArray(n) { Double.NaN }
        for (i in stochPeriod - 1 until n) {
            var lo = Double.POSITIVE_INFINITY
            var hi = Double.NEGATIVE_INFINITY
            var allValid = true
            for (j in i - stochPeriod + 1..i) {
                val v = rsiVals[j]
                if (v.isNaN()) { allValid = false; break }
                if (v < lo) lo = v
                if (v > hi) hi = v
            }
            if (allValid && hi != lo) raw[i] = 100.0 * (rsiVals[i] - lo) / (hi - lo)
            else if (allValid) raw[i] = 0.0
        }
        val k = sma(raw.toList().map { if (it.isNaN()) 0.0 else it }, smoothK)
        // Mask warm-up positions
        val firstNaN = raw.indexOfFirst { !it.isNaN() }
        for (i in 0 until firstNaN.coerceAtLeast(0)) k[i] = Double.NaN
        val d = sma(k.toList().map { if (it.isNaN()) 0.0 else it }, smoothD)
        for (i in 0 until firstNaN.coerceAtLeast(0)) d[i] = Double.NaN
        return StochRsi(k, d)
    }

    /** Rolling VWAP over the entire window (commonly used for intraday on a session basis). */
    fun vwap(candles: List<Candle>): DoubleArray {
        val n = candles.size
        val out = DoubleArray(n) { Double.NaN }
        if (n == 0) return out
        var cumPV = 0.0
        var cumV = 0.0
        for (i in 0 until n) {
            cumPV += candles[i].typicalPrice * candles[i].volume
            cumV += candles[i].volume
            if (cumV > 0) out[i] = cumPV / cumV
        }
        return out
    }

    /**
     * Detects bullish/bearish RSI divergence over a recent window.
     *
     * Bullish: price makes a lower low, RSI makes a higher low (between two pivots).
     * Bearish: price makes a higher high, RSI makes a lower high.
     *
     * Returns +1 for bullish divergence, -1 for bearish divergence, 0 otherwise.
     */
    fun rsiDivergence(
        closes: List<Double>,
        rsiSeries: DoubleArray,
        lookback: Int = 30,
        pivotStrength: Int = 3
    ): Int {
        val n = closes.size
        if (n < lookback + pivotStrength * 2) return 0
        val from = (n - lookback).coerceAtLeast(pivotStrength)
        val highs = mutableListOf<Pair<Int, Double>>()
        val lows = mutableListOf<Pair<Int, Double>>()
        for (i in from until n - pivotStrength) {
            var isHigh = true; var isLow = true
            for (k in 1..pivotStrength) {
                if (closes[i] <= closes[i - k] || closes[i] <= closes[i + k]) isHigh = false
                if (closes[i] >= closes[i - k] || closes[i] >= closes[i + k]) isLow = false
            }
            if (isHigh) highs.add(i to closes[i])
            if (isLow) lows.add(i to closes[i])
        }
        if (lows.size >= 2) {
            val (i1, p1) = lows[lows.size - 2]
            val (i2, p2) = lows.last()
            val r1 = rsiSeries.getOrNull(i1); val r2 = rsiSeries.getOrNull(i2)
            if (r1 != null && r2 != null && !r1.isNaN() && !r2.isNaN()) {
                if (p2 < p1 && r2 > r1) return +1
            }
        }
        if (highs.size >= 2) {
            val (i1, p1) = highs[highs.size - 2]
            val (i2, p2) = highs.last()
            val r1 = rsiSeries.getOrNull(i1); val r2 = rsiSeries.getOrNull(i2)
            if (r1 != null && r2 != null && !r1.isNaN() && !r2.isNaN()) {
                if (p2 > p1 && r2 < r1) return -1
            }
        }
        return 0
    }

    /** Most recent pivot-based support / resistance from a window. */
    fun nearestSwing(candles: List<Candle>, lookback: Int = 50): Pair<Double?, Double?> {
        val n = candles.size
        val from = (n - lookback).coerceAtLeast(2)
        var support: Double? = null
        var resistance: Double? = null
        for (i in from until n - 2) {
            val c = candles[i]
            val isSwingLow = c.low < candles[i - 1].low && c.low < candles[i - 2].low &&
                c.low < candles[i + 1].low && c.low < candles[i + 2].low
            val isSwingHigh = c.high > candles[i - 1].high && c.high > candles[i - 2].high &&
                c.high > candles[i + 1].high && c.high > candles[i + 2].high
            if (isSwingLow) support = c.low
            if (isSwingHigh) resistance = c.high
        }
        return support to resistance
    }

    /** Volume surge ratio: latest volume / SMA(volume, period). */
    fun volumeSurge(candles: List<Candle>, period: Int = 20): Double {
        if (candles.size < period + 1) return 1.0
        var sum = 0.0
        for (i in candles.size - period - 1 until candles.size - 1) sum += candles[i].volume
        val avg = sum / period
        if (avg == 0.0) return 1.0
        return candles.last().volume / avg
    }

}
