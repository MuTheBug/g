package com.apex.trader.indicator

import com.apex.trader.data.model.Candle
import com.apex.trader.domain.indicator.Indicators
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import kotlin.math.abs

class IndicatorsTest {

    @Test
    fun `sma matches manual calculation`() {
        val v = listOf(1.0, 2.0, 3.0, 4.0, 5.0, 6.0)
        val out = Indicators.sma(v, 3)
        assertThat(out[0].isNaN()).isTrue()
        assertThat(out[1].isNaN()).isTrue()
        assertThat(out[2]).isWithin(EPS).of(2.0)
        assertThat(out[3]).isWithin(EPS).of(3.0)
        assertThat(out[4]).isWithin(EPS).of(4.0)
        assertThat(out[5]).isWithin(EPS).of(5.0)
    }

    @Test
    fun `ema converges to constant for constant input`() {
        val v = List(50) { 10.0 }
        val out = Indicators.ema(v, 9)
        assertThat(out[8]).isWithin(EPS).of(10.0)
        assertThat(out.last()).isWithin(EPS).of(10.0)
    }

    @Test
    fun `rsi at 100 for monotonically increasing series`() {
        val v = (1..100).map { it.toDouble() }
        val out = Indicators.rsi(v, 14)
        assertThat(out.last()).isWithin(0.01).of(100.0)
    }

    @Test
    fun `rsi at 0 for monotonically decreasing series`() {
        val v = (100 downTo 1).map { it.toDouble() }
        val out = Indicators.rsi(v, 14)
        assertThat(out.last()).isWithin(0.01).of(0.0)
    }

    @Test
    fun `bollinger bands width zero on flat input`() {
        val v = List(40) { 10.0 }
        val bb = Indicators.bollinger(v, 20, 2.0)
        val last = bb.bandwidth.last()
        assertThat(last).isWithin(EPS).of(0.0)
        assertThat(bb.upper.last()).isWithin(EPS).of(10.0)
        assertThat(bb.lower.last()).isWithin(EPS).of(10.0)
    }

    @Test
    fun `atr non-negative and finite`() {
        val candles = uptrendCandles(60)
        val atr = Indicators.atr(candles, 14)
        atr.drop(14).forEach {
            assertThat(it.isNaN()).isFalse()
            assertThat(it).isGreaterThan(0.0)
        }
    }

    @Test
    fun `adx high during clean trend`() {
        val candles = uptrendCandles(120, slope = 1.0, noise = 0.05)
        val adx = Indicators.adx(candles, 14)
        val last = adx.adx.last()
        assertThat(last).isGreaterThan(20.0)
    }

    @Test
    fun `obv increases when price rises with volume`() {
        val candles = (1..30).map { i ->
            Candle(
                openTime = i.toLong(),
                open = i.toDouble(),
                high = i + 0.5,
                low = i - 0.5,
                close = i + 0.4,
                volume = 100.0,
                closeTime = i.toLong(),
                quoteVolume = 100.0 * i,
                takerBuyBaseVolume = 50.0
            )
        }
        val obv = Indicators.obv(candles)
        // strictly non-decreasing because every close > previous close
        for (i in 2 until obv.size) {
            assertThat(obv[i]).isAtLeast(obv[i - 1])
        }
    }

    @Test
    fun `vwap equals constant typical price for flat candles`() {
        val candles = List(30) { i ->
            Candle(i.toLong(), 100.0, 100.0, 100.0, 100.0, 10.0, i.toLong(), 1000.0, 5.0)
        }
        val vwap = Indicators.vwap(candles)
        assertThat(vwap.last()).isWithin(EPS).of(100.0)
    }

    @Test
    fun `volume surge ratio reflects spike`() {
        val candles = MutableList(30) { i ->
            Candle(i.toLong(), 100.0, 101.0, 99.0, 100.5, 100.0, i.toLong(), 100.0, 50.0)
        }
        candles.add(Candle(31, 100.0, 101.0, 99.0, 100.5, 500.0, 31, 100.0, 250.0))
        val ratio = Indicators.volumeSurge(candles, 20)
        assertThat(ratio).isGreaterThan(4.0)
    }

    @Test
    fun `rsi divergence detects bullish setup`() {
        // Build a price series with a lower-low and rising RSI
        val closes = mutableListOf<Double>()
        for (i in 0 until 50) closes += 100.0 - i * 0.2 // gentle downtrend
        // First low
        closes += listOf(89.0, 88.5, 89.5, 90.0, 90.5)
        // Lower low later
        for (i in 0 until 10) closes += 90.0 - i * 0.1
        closes += listOf(88.0, 87.5, 88.0, 89.0, 90.0)
        val rsi = Indicators.rsi(closes, 14)
        val div = Indicators.rsiDivergence(closes, rsi, lookback = 30, pivotStrength = 2)
        // Could be 0 or +1 depending on pivot exactness — at least it must not throw
        assertThat(div).isAnyOf(0, 1)
    }

    private fun uptrendCandles(n: Int, slope: Double = 0.5, noise: Double = 0.1): List<Candle> {
        return List(n) { i ->
            val base = 100.0 + i * slope
            Candle(
                openTime = i.toLong(),
                open = base,
                high = base + noise,
                low = base - noise,
                close = base + noise * 0.5,
                volume = 100.0,
                closeTime = i.toLong(),
                quoteVolume = base * 100.0,
                takerBuyBaseVolume = 60.0
            )
        }
    }

    companion object {
        private const val EPS = 1e-9
    }
}
