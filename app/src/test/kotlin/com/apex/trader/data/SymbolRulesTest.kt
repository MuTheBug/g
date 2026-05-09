package com.apex.trader.data

import com.apex.trader.data.api.dto.SymbolDto
import com.apex.trader.data.api.dto.SymbolFilterDto
import com.apex.trader.data.repository.SymbolRules
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class SymbolRulesTest {

    @Test
    fun `rounds to tick and step`() {
        val dto = SymbolDto(
            symbol = "BTCUSDT",
            status = "TRADING",
            baseAsset = "BTC",
            quoteAsset = "USDT",
            pricePrecision = 2,
            quantityPrecision = 3,
            filters = listOf(
                SymbolFilterDto("PRICE_FILTER", tickSize = "0.10"),
                SymbolFilterDto("LOT_SIZE", stepSize = "0.001", minQty = "0.001"),
                SymbolFilterDto("MIN_NOTIONAL", notional = "5")
            )
        )
        val rules = SymbolRules.from(dto)
        assertThat(rules.formatPrice(50000.1234)).isEqualTo("50000.10")
        assertThat(rules.formatQuantity(0.1239)).isEqualTo("0.123")
        assertThat(rules.minNotional).isEqualTo(5.0)
    }
}
