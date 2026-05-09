package com.apex.trader.data.api

import com.apex.trader.data.api.dto.AccountInfoDto
import com.apex.trader.data.api.dto.ExchangeInfoDto
import com.apex.trader.data.api.dto.LeverageResponseDto
import com.apex.trader.data.api.dto.ListenKeyDto
import com.apex.trader.data.api.dto.MarginTypeResponseDto
import com.apex.trader.data.api.dto.OrderBookDto
import com.apex.trader.data.api.dto.OrderResponseDto
import com.apex.trader.data.api.dto.PositionDto
import com.apex.trader.data.api.dto.TickerDto
import com.apex.trader.data.api.interceptor.SecuredTag
import com.apex.trader.data.api.interceptor.SignedTag
import kotlinx.serialization.json.JsonArray
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Query
import retrofit2.http.Tag

interface BinanceFuturesApi {

    // ---- Public market data ----

    @GET("/fapi/v1/exchangeInfo")
    suspend fun exchangeInfo(): ExchangeInfoDto

    @GET("/fapi/v1/ticker/24hr")
    suspend fun ticker24h(): List<TickerDto>

    @GET("/fapi/v1/ticker/24hr")
    suspend fun ticker24hSymbol(@Query("symbol") symbol: String): TickerDto

    /** Returns klines as raw JSON array; deserialized via [com.apex.trader.data.api.dto.KlineDto.fromJsonArray]. */
    @GET("/fapi/v1/klines")
    suspend fun klines(
        @Query("symbol") symbol: String,
        @Query("interval") interval: String,
        @Query("limit") limit: Int = 500
    ): JsonArray

    @GET("/fapi/v1/depth")
    suspend fun orderBook(
        @Query("symbol") symbol: String,
        @Query("limit") limit: Int = 20
    ): OrderBookDto

    // ---- Account / Trade (signed) ----

    @GET("/fapi/v2/account")
    suspend fun accountInfo(
        @Tag signed: SignedTag = SignedTag,
        @Tag secured: SecuredTag = SecuredTag
    ): AccountInfoDto

    @GET("/fapi/v2/positionRisk")
    suspend fun positionRisk(
        @Query("symbol") symbol: String? = null,
        @Tag signed: SignedTag = SignedTag,
        @Tag secured: SecuredTag = SecuredTag
    ): List<PositionDto>

    @POST("/fapi/v1/leverage")
    suspend fun setLeverage(
        @Query("symbol") symbol: String,
        @Query("leverage") leverage: Int,
        @Tag signed: SignedTag = SignedTag,
        @Tag secured: SecuredTag = SecuredTag
    ): LeverageResponseDto

    @POST("/fapi/v1/marginType")
    suspend fun setMarginType(
        @Query("symbol") symbol: String,
        @Query("marginType") marginType: String, // ISOLATED or CROSSED
        @Tag signed: SignedTag = SignedTag,
        @Tag secured: SecuredTag = SecuredTag
    ): MarginTypeResponseDto

    /**
     * Place an order. `type` is one of MARKET, LIMIT, STOP_MARKET, TAKE_PROFIT_MARKET, STOP, TAKE_PROFIT,
     * TRAILING_STOP_MARKET. For MARKET entry pass quantity; for STOP_MARKET / TAKE_PROFIT_MARKET pass
     * stopPrice and (typically) closePosition=true to close the entire position when triggered.
     */
    @POST("/fapi/v1/order")
    suspend fun newOrder(
        @Query("symbol") symbol: String,
        @Query("side") side: String, // BUY or SELL
        @Query("positionSide") positionSide: String? = null, // LONG / SHORT / BOTH (hedge or one-way)
        @Query("type") type: String,
        @Query("quantity") quantity: String? = null,
        @Query("price") price: String? = null,
        @Query("stopPrice") stopPrice: String? = null,
        @Query("timeInForce") timeInForce: String? = null,
        @Query("reduceOnly") reduceOnly: Boolean? = null,
        @Query("closePosition") closePosition: Boolean? = null,
        @Query("workingType") workingType: String? = null, // MARK_PRICE / CONTRACT_PRICE
        @Query("newClientOrderId") newClientOrderId: String? = null,
        @Query("priceProtect") priceProtect: Boolean? = null,
        @Query("activationPrice") activationPrice: String? = null,
        @Query("callbackRate") callbackRate: String? = null,
        @Tag signed: SignedTag = SignedTag,
        @Tag secured: SecuredTag = SecuredTag
    ): OrderResponseDto

    @DELETE("/fapi/v1/allOpenOrders")
    suspend fun cancelAllOrders(
        @Query("symbol") symbol: String,
        @Tag signed: SignedTag = SignedTag,
        @Tag secured: SecuredTag = SecuredTag
    ): Map<String, String>

    @GET("/fapi/v1/openOrders")
    suspend fun openOrders(
        @Query("symbol") symbol: String? = null,
        @Tag signed: SignedTag = SignedTag,
        @Tag secured: SecuredTag = SecuredTag
    ): List<OrderResponseDto>

    // ---- User stream ----

    @POST("/fapi/v1/listenKey")
    suspend fun startUserStream(
        @Tag signed: SignedTag = SignedTag
    ): ListenKeyDto
}
