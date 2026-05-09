package com.apex.trader.data.api.dto

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.jsonPrimitive

/**
 * Binance returns klines as a JSON array of arrays:
 * [openTime, open, high, low, close, volume, closeTime, quoteVolume, trades, takerBuyBase, takerBuyQuote, ignore]
 */
data class KlineDto(
    val openTime: Long,
    val open: Double,
    val high: Double,
    val low: Double,
    val close: Double,
    val volume: Double,
    val closeTime: Long,
    val quoteVolume: Double,
    val trades: Long,
    val takerBuyBaseVolume: Double,
    val takerBuyQuoteVolume: Double
) {
    companion object {
        fun fromJsonArray(arr: JsonArray): KlineDto {
            fun s(i: Int): String = (arr[i] as JsonElement).jsonPrimitive.content
            return KlineDto(
                openTime = s(0).toLong(),
                open = s(1).toDouble(),
                high = s(2).toDouble(),
                low = s(3).toDouble(),
                close = s(4).toDouble(),
                volume = s(5).toDouble(),
                closeTime = s(6).toLong(),
                quoteVolume = s(7).toDouble(),
                trades = s(8).toLong(),
                takerBuyBaseVolume = s(9).toDouble(),
                takerBuyQuoteVolume = s(10).toDouble()
            )
        }
    }
}
