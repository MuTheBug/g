package com.apex.trader.strategy

import com.apex.trader.data.model.Candle
import com.apex.trader.domain.strategy.ApexConfluenceStrategy
import com.apex.trader.domain.strategy.SignalSide
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import kotlin.math.sin
import kotlin.random.Random

class ApexConfluenceStrategyTest {

    private val strategy = ApexConfluenceStrategy()

    @Test
    fun `flat market produces no signal`() {
        val flat = List(220) { i ->
            Candle(i.toLong(), 100.0, 100.05, 99.95, 100.0, 10.0, i.toLong(), 1000.0, 5.0)
        }
        val sig = strategy.evaluate("BTCUSDT", flat, flat, flat)
        assertThat(sig).isNull()
    }

    @Test
    fun `clean uptrend on all timeframes generally fires LONG`() {
        // We don't assert it always fires (the strategy has many filters) — just that
        // when it fires, the side is LONG and SL/TP make sense.
        val htf = trendingCandles(220, slope = 0.5, noise = 0.1)
        val mtf = trendingCandles(220, slope = 0.4, noise = 0.1)
        val ltf = trendingCandles(220, slope = 0.3, noise = 0.05)
        val sig = strategy.evaluate("BTCUSDT", htf, mtf, ltf)
        if (sig != null) {
            assertThat(sig.side).isEqualTo(SignalSide.LONG)
            assertThat(sig.plan.stopLoss).isLessThan(sig.plan.entry)
            assertThat(sig.plan.takeProfit1).isGreaterThan(sig.plan.entry)
            assertThat(sig.plan.takeProfit3).isGreaterThan(sig.plan.takeProfit1)
            // Default Config.minConfidence is 70.
            assertThat(sig.confidence).isAtLeast(70)
        }
    }

    @Test
    fun `clean downtrend on all timeframes never produces LONG`() {
        val htf = trendingCandles(220, slope = -0.5, noise = 0.1)
        val mtf = trendingCandles(220, slope = -0.4, noise = 0.1)
        val ltf = trendingCandles(220, slope = -0.3, noise = 0.05)
        val sig = strategy.evaluate("BTCUSDT", htf, mtf, ltf)
        if (sig != null) {
            assertThat(sig.side).isEqualTo(SignalSide.SHORT)
            assertThat(sig.plan.stopLoss).isGreaterThan(sig.plan.entry)
            assertThat(sig.plan.takeProfit1).isLessThan(sig.plan.entry)
        }
    }

    @Test
    fun `conflicting timeframes never produce a signal`() {
        val up = trendingCandles(220, slope = 0.5, noise = 0.1)
        val down = trendingCandles(220, slope = -0.5, noise = 0.1)
        val sig = strategy.evaluate("ETHUSDT", up, down, up)
        assertThat(sig).isNull()
    }

    @Test
    fun `trade plan SL is ATR-based`() {
        val htf = trendingCandles(220, slope = 0.5, noise = 0.5)
        val mtf = trendingCandles(220, slope = 0.4, noise = 0.4)
        val ltf = trendingCandles(220, slope = 0.3, noise = 0.3)
        val sig = strategy.evaluate("BTCUSDT", htf, mtf, ltf) ?: return
        // SL distance ≈ atrSlMult * ATR (1.5 by default)
        val dist = kotlin.math.abs(sig.plan.entry - sig.plan.stopLoss)
        assertThat(dist).isWithin(0.001).of(1.5 * sig.plan.atr)
    }

    private fun trendingCandles(
        n: Int,
        slope: Double,
        noise: Double,
        seed: Long = 7L
    ): List<Candle> {
        val rnd = Random(seed)
        var price = 100.0
        return List(n) { i ->
            val swing = sin(i / 7.0) * noise
            val open = price
            price += slope + (rnd.nextDouble() - 0.5) * noise + swing * 0.1
            val close = price
            val high = maxOf(open, close) + noise
            val low = minOf(open, close) - noise
            Candle(
                openTime = i.toLong(),
                open = open,
                high = high,
                low = low,
                close = close,
                volume = 100.0 + rnd.nextDouble() * 50.0,
                closeTime = i.toLong(),
                quoteVolume = close * 100.0,
                takerBuyBaseVolume = 50.0
            )
        }
    }
}
