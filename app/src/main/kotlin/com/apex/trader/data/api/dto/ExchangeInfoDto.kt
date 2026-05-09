package com.apex.trader.data.api.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class ExchangeInfoDto(
    val symbols: List<SymbolDto> = emptyList(),
    val timezone: String = "UTC",
    val serverTime: Long = 0L
)

@Serializable
data class SymbolDto(
    val symbol: String,
    val pair: String? = null,
    val contractType: String? = null,
    val status: String,
    val baseAsset: String,
    val quoteAsset: String,
    val pricePrecision: Int = 0,
    val quantityPrecision: Int = 0,
    val baseAssetPrecision: Int = 0,
    val quotePrecision: Int = 0,
    val filters: List<SymbolFilterDto> = emptyList(),
    val onboardDate: Long? = null
)

@Serializable
data class SymbolFilterDto(
    val filterType: String,
    val minPrice: String? = null,
    val maxPrice: String? = null,
    val tickSize: String? = null,
    val minQty: String? = null,
    val maxQty: String? = null,
    val stepSize: String? = null,
    val notional: String? = null,
    val minNotional: String? = null,
    @SerialName("limit") val limit: Int? = null
)

@Serializable
data class TickerDto(
    val symbol: String,
    val lastPrice: String,
    val priceChangePercent: String,
    val volume: String,
    val quoteVolume: String,
    val highPrice: String,
    val lowPrice: String,
    val openPrice: String
)

@Serializable
data class OrderBookDto(
    val lastUpdateId: Long = 0L,
    val bids: List<List<String>> = emptyList(),
    val asks: List<List<String>> = emptyList()
)
