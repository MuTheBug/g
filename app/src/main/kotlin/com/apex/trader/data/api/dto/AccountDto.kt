package com.apex.trader.data.api.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class AccountInfoDto(
    val totalWalletBalance: String = "0",
    val totalUnrealizedProfit: String = "0",
    val totalMarginBalance: String = "0",
    val availableBalance: String = "0",
    val maxWithdrawAmount: String = "0",
    val assets: List<AccountAssetDto> = emptyList(),
    val positions: List<PositionDto> = emptyList()
)

@Serializable
data class AccountAssetDto(
    val asset: String,
    val walletBalance: String = "0",
    val unrealizedProfit: String = "0",
    val marginBalance: String = "0",
    val availableBalance: String = "0"
)

/**
 * Binance returns position data on two endpoints with subtly different schemas:
 *  - `/fapi/v2/positionRisk` uses `unRealizedProfit` and includes `markPrice` / `liquidationPrice` / `marginType`
 *  - `/fapi/v2/account` embedded `positions[]` uses `unrealizedProfit` (lowercase r) and omits the price/risk fields
 *
 * We accept both spellings as nullable and expose [pnl] as the unified accessor.
 */
@Serializable
data class PositionDto(
    val symbol: String,
    val positionAmt: String = "0",
    val entryPrice: String = "0",
    val markPrice: String? = null,
    @SerialName("unRealizedProfit") val unRealizedProfit: String? = null,
    @SerialName("unrealizedProfit") val unrealizedProfit: String? = null,
    val liquidationPrice: String? = null,
    val leverage: String = "1",
    val marginType: String? = null,
    val isolatedMargin: String? = null,
    val isolated: Boolean? = null,
    val positionSide: String = "BOTH",
    val notional: String? = null,
    val updateTime: Long? = null
) {
    val pnl: String get() = unRealizedProfit ?: unrealizedProfit ?: "0"
}

@Serializable
data class OrderResponseDto(
    val orderId: Long,
    val symbol: String,
    val status: String,
    val clientOrderId: String = "",
    val price: String = "0",
    val avgPrice: String? = null,
    val origQty: String = "0",
    val executedQty: String = "0",
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
