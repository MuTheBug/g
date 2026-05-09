package com.apex.trader.data.model

import com.apex.trader.data.api.dto.KlineDto

data class Candle(
    val openTime: Long,
    val open: Double,
    val high: Double,
    val low: Double,
    val close: Double,
    val volume: Double,
    val closeTime: Long,
    val quoteVolume: Double,
    val takerBuyBaseVolume: Double
) {
    val typicalPrice: Double get() = (high + low + close) / 3.0
    val range: Double get() = high - low
    val isBull: Boolean get() = close >= open
    val body: Double get() = kotlin.math.abs(close - open)
    val upperWick: Double get() = high - kotlin.math.max(open, close)
    val lowerWick: Double get() = kotlin.math.min(open, close) - low

    companion object {
        fun fromDto(d: KlineDto) = Candle(
            openTime = d.openTime,
            open = d.open,
            high = d.high,
            low = d.low,
            close = d.close,
            volume = d.volume,
            closeTime = d.closeTime,
            quoteVolume = d.quoteVolume,
            takerBuyBaseVolume = d.takerBuyBaseVolume
        )
    }
}

enum class Timeframe(val code: String, val millis: Long) {
    M1("1m", 60_000L),
    M5("5m", 300_000L),
    M15("15m", 900_000L),
    M30("30m", 1_800_000L),
    H1("1h", 3_600_000L),
    H4("4h", 14_400_000L),
    D1("1d", 86_400_000L);

    companion object {
        fun fromCode(code: String): Timeframe = entries.first { it.code == code }
    }
}
