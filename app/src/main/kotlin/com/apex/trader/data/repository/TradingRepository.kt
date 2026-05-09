package com.apex.trader.data.repository

import com.apex.trader.data.api.BinanceFuturesApi
import com.apex.trader.data.api.dto.AccountInfoDto
import com.apex.trader.data.api.dto.OrderResponseDto
import com.apex.trader.data.api.dto.PositionDto
import com.apex.trader.domain.strategy.SignalSide
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class TradingRepository @Inject constructor(
    private val api: BinanceFuturesApi
) {
    private val cacheLock = Mutex()
    private var symbolRulesCache: Map<String, SymbolRules> = emptyMap()
    private var rulesFetchedAt = 0L
    private val ttlMs = 60 * 60 * 1000L

    suspend fun getAccount(): AccountInfoDto = api.accountInfo()

    suspend fun getOpenPositions(): List<PositionDto> =
        api.positionRisk().filter { it.positionAmt.toDoubleOrNull()?.let { v -> v != 0.0 } == true }

    suspend fun getOpenOrders(symbol: String? = null) = api.openOrders(symbol)

    suspend fun getSymbolRules(symbol: String): SymbolRules? = cacheLock.withLock {
        if (symbolRulesCache.isEmpty() || System.currentTimeMillis() - rulesFetchedAt > ttlMs) {
            val info = api.exchangeInfo()
            symbolRulesCache = info.symbols.associate { it.symbol to SymbolRules.from(it) }
            rulesFetchedAt = System.currentTimeMillis()
        }
        symbolRulesCache[symbol]
    }

    suspend fun setLeverage(symbol: String, leverage: Int) = api.setLeverage(symbol, leverage)

    suspend fun setMarginType(symbol: String, isolated: Boolean) = runCatching {
        api.setMarginType(symbol, if (isolated) "ISOLATED" else "CROSSED")
    }

    /**
     * Places a market entry, then an attached SL (STOP_MARKET) and up to 3 TPs
     * (TAKE_PROFIT_MARKET). All bracket orders use closePosition=true so they liquidate
     * the full remaining position when triggered.
     *
     * Returns the entry order response. The SL/TP order responses are best-effort and
     * any failures are reported via the [onBracketError] callback so the caller can
     * surface them in the UI without aborting the entry.
     */
    suspend fun openMarketWithBrackets(
        symbol: String,
        side: SignalSide,
        quantity: Double,
        stopPrice: Double,
        takeProfits: List<Double>,
        rules: SymbolRules,
        positionSide: String? = null,
        onBracketError: (String) -> Unit = {}
    ): OrderResponseDto {
        val orderSide = if (side == SignalSide.LONG) "BUY" else "SELL"
        val closeSide = if (side == SignalSide.LONG) "SELL" else "BUY"
        val qtyStr = rules.formatQuantity(quantity)

        val entry = api.newOrder(
            symbol = symbol,
            side = orderSide,
            positionSide = positionSide,
            type = "MARKET",
            quantity = qtyStr,
            newClientOrderId = clientOrderId("ENTRY")
        )

        runCatching {
            api.newOrder(
                symbol = symbol,
                side = closeSide,
                positionSide = positionSide,
                type = "STOP_MARKET",
                stopPrice = rules.formatPrice(stopPrice),
                closePosition = true,
                workingType = "MARK_PRICE",
                priceProtect = true,
                newClientOrderId = clientOrderId("SL")
            )
        }.onFailure { onBracketError("Stop-loss attach failed: ${it.message}") }

        takeProfits.forEachIndexed { idx, tp ->
            runCatching {
                api.newOrder(
                    symbol = symbol,
                    side = closeSide,
                    positionSide = positionSide,
                    type = "TAKE_PROFIT_MARKET",
                    stopPrice = rules.formatPrice(tp),
                    closePosition = true,
                    workingType = "MARK_PRICE",
                    priceProtect = true,
                    newClientOrderId = clientOrderId("TP${idx + 1}")
                )
            }.onFailure { onBracketError("TP${idx + 1} attach failed: ${it.message}") }
        }
        return entry
    }

    suspend fun closePosition(
        symbol: String,
        side: SignalSide,
        quantity: Double,
        rules: SymbolRules
    ): OrderResponseDto {
        val closeSide = if (side == SignalSide.LONG) "SELL" else "BUY"
        return api.newOrder(
            symbol = symbol,
            side = closeSide,
            type = "MARKET",
            quantity = rules.formatQuantity(quantity),
            reduceOnly = true,
            newClientOrderId = clientOrderId("CLOSE")
        )
    }

    suspend fun cancelAll(symbol: String) = api.cancelAllOrders(symbol)

    private fun clientOrderId(tag: String): String {
        val ts = System.currentTimeMillis()
        return "APEX-${tag}-${ts}".take(36)
    }
}
