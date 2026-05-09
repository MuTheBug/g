package com.apex.trader.data.api.dto

import kotlinx.serialization.Serializable

@Serializable
data class AccountInfoDto(
    val totalWalletBalance: String,
    val totalUnrealizedProfit: String,
    val totalMarginBalance: String,
    val availableBalance: String,
    val maxWithdrawAmount: String,
    val assets: List<AccountAssetDto> = emptyList(),
    val positions: List<PositionDto> = emptyList()
)

@Serializable
data class AccountAssetDto(
    val asset: String,
    val walletBalance: String,
    val unrealizedProfit: String,
    val marginBalance: String,
    val availableBalance: String
)

@Serializable
data class PositionDto(
    val symbol: String,
    val positionAmt: String,
    val entryPrice: String,
    val markPrice: String? = null,
    val unRealizedProfit: String,
    val liquidationPrice: String? = null,
    val leverage: String,
    val marginType: String? = null,
    val isolatedMargin: String? = null,
    val positionSide: String,
    val updateTime: Long? = null
)

@Serializable
data class OrderResponseDto(
    val orderId: Long,
    val symbol: String,
    val status: String,
    val clientOrderId: String,
    val price: String,
    val avgPrice: String? = null,
    val origQty: String,
    val executedQty: String,
    val cumQuote: String? = null,
    val timeInForce: String? = null,
    val type: String,
    val reduceOnly: Boolean? = null,
    val closePosition: Boolean? = null,
    val side: String,
    val positionSide: String? = null,
    val stopPrice: String? = null,
    val workingType: String? = null,
    val priceProtect: Boolean? = null,
    val origType: String? = null,
    val updateTime: Long? = null
)

@Serializable
data class LeverageResponseDto(
    val leverage: Int,
    val maxNotionalValue: String? = null,
    val symbol: String
)

@Serializable
data class MarginTypeResponseDto(
    val code: Int = 200,
    val msg: String = "success"
)

@Serializable
data class ListenKeyDto(
    val listenKey: String
)
