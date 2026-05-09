package com.apex.trader.data.repository

import com.apex.trader.data.api.BinanceFuturesApi
import com.apex.trader.data.api.dto.KlineDto
import com.apex.trader.data.api.dto.OrderBookDto
import com.apex.trader.data.api.dto.TickerDto
import com.apex.trader.data.model.Candle
import com.apex.trader.data.model.Timeframe
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class MarketRepository @Inject constructor(
    private val api: BinanceFuturesApi
) {
    /** Returns USDT-margined PERPETUAL trading symbols, alphabetically. */
    suspend fun getActiveUsdtPerpSymbols(): List<String> {
        val info = api.exchangeInfo()
        return info.symbols
            .asSequence()
            .filter { it.status == "TRADING" }
            .filter { it.quoteAsset == "USDT" }
            .filter { (it.contractType ?: "PERPETUAL") == "PERPETUAL" }
            .map { it.symbol }
            .sorted()
            .toList()
    }

    suspend fun get24hTickers(): List<TickerDto> = api.ticker24h()

    suspend fun getCandles(symbol: String, timeframe: Timeframe, limit: Int = 500): List<Candle> {
        val arr: JsonArray = api.klines(symbol, timeframe.code, limit)
        return arr.map { Candle.fromDto(KlineDto.fromJsonArray(it.jsonArray)) }
    }

    suspend fun getOrderBook(symbol: String, limit: Int = 20): OrderBookDto =
        api.orderBook(symbol, limit)

    /** Top-of-book imbalance, +1 = bid heavy, -1 = ask heavy. */
    fun bookImbalance(book: OrderBookDto, depth: Int = 10): Double {
        val bids = book.bids.take(depth).sumOf { it[1].toDouble() }
        val asks = book.asks.take(depth).sumOf { it[1].toDouble() }
        val total = bids + asks
        if (total == 0.0) return 0.0
        return (bids - asks) / total
    }
}
