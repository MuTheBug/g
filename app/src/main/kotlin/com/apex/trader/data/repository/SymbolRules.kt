package com.apex.trader.data.repository

import com.apex.trader.data.api.dto.SymbolDto
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Per-symbol rounding rules derived from the exchangeInfo `filters`. Binance rejects
 * orders that don't conform to tickSize/stepSize, so we always normalize values
 * client-side before placing an order.
 */
data class SymbolRules(
    val symbol: String,
    val tickSize: Double,
    val stepSize: Double,
    val minQty: Double,
    val minNotional: Double,
    val pricePrecision: Int,
    val quantityPrecision: Int
) {
    fun roundPrice(price: Double): Double = roundToTick(price, tickSize)
    fun roundQuantity(qty: Double): Double = roundToTick(qty, stepSize)
    fun formatPrice(price: Double): String = "%.${pricePrecision}f".format(roundPrice(price))
    fun formatQuantity(qty: Double): String = "%.${quantityPrecision}f".format(roundQuantity(qty))

    private fun roundToTick(value: Double, tick: Double): Double {
        if (tick <= 0.0) return value
        return floor(value / tick) * tick
    }

    companion object {
        fun from(dto: SymbolDto): SymbolRules {
            val priceFilter = dto.filters.firstOrNull { it.filterType == "PRICE_FILTER" }
            val lotFilter = dto.filters.firstOrNull { it.filterType == "LOT_SIZE" }
            val notionalFilter = dto.filters.firstOrNull {
                it.filterType == "MIN_NOTIONAL" || it.filterType == "NOTIONAL"
            }
            val tickSize = priceFilter?.tickSize?.toDoubleOrNull() ?: 10.0.pow(-dto.pricePrecision)
            val stepSize = lotFilter?.stepSize?.toDoubleOrNull() ?: 10.0.pow(-dto.quantityPrecision)
            val minQty = lotFilter?.minQty?.toDoubleOrNull() ?: 0.0
            val minNotional = (notionalFilter?.notional ?: notionalFilter?.minNotional)
                ?.toDoubleOrNull() ?: 5.0
            return SymbolRules(
                symbol = dto.symbol,
                tickSize = tickSize,
                stepSize = stepSize,
                minQty = minQty,
                minNotional = minNotional,
                pricePrecision = dto.pricePrecision.takeIf { it >= 0 } ?: tickPrecision(tickSize),
                quantityPrecision = dto.quantityPrecision.takeIf { it >= 0 } ?: tickPrecision(stepSize)
            )
        }

        private fun tickPrecision(tick: Double): Int {
            if (tick <= 0) return 8
            val p = -ln(tick) / ln(10.0)
            return max(0, p.roundToInt())
        }
    }
}
