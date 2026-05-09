package com.apex.trader.presentation.screen.trade

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.apex.trader.data.model.Timeframe
import com.apex.trader.data.repository.MarketRepository
import com.apex.trader.data.repository.SettingsRepository
import com.apex.trader.data.repository.SymbolRules
import com.apex.trader.data.repository.TradingRepository
import com.apex.trader.domain.scanner.MarketScanner
import com.apex.trader.domain.strategy.Signal
import com.apex.trader.domain.strategy.SignalSide
import com.apex.trader.domain.strategy.TradePlan
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.math.abs
import javax.inject.Inject

data class TradeUiState(
    val loading: Boolean = true,
    val placing: Boolean = false,
    val symbol: String = "",
    val signal: Signal? = null,
    val rules: SymbolRules? = null,
    val availableUsdt: Double = 0.0,
    // user inputs (defaults applied after load)
    val marginUsdt: Double = 0.0,
    val leverage: Int = 5,
    val isolated: Boolean = true,
    val customSl: Double? = null,
    val customTp1: Double? = null,
    val customTp2: Double? = null,
    val customTp3: Double? = null,
    val autoAttachSlTp: Boolean = true,
    val side: SignalSide = SignalSide.LONG,
    val entryPrice: Double = 0.0,
    val resultMessage: String? = null,
    val warnings: List<String> = emptyList(),
    val error: String? = null
) {
    val notional: Double get() = marginUsdt * leverage
    val quantity: Double get() = if (entryPrice > 0) notional / entryPrice else 0.0
    val effectiveSl: Double get() = customSl ?: signal?.plan?.stopLoss ?: 0.0
    val effectiveTp1: Double get() = customTp1 ?: signal?.plan?.takeProfit1 ?: 0.0
    val effectiveTp2: Double get() = customTp2 ?: signal?.plan?.takeProfit2 ?: 0.0
    val effectiveTp3: Double get() = customTp3 ?: signal?.plan?.takeProfit3 ?: 0.0
    val riskUsdt: Double get() = quantity * abs(entryPrice - effectiveSl)
}

@HiltViewModel
class TradeViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val marketRepository: MarketRepository,
    private val tradingRepository: TradingRepository,
    private val settingsRepository: SettingsRepository,
    private val scanner: MarketScanner
) : ViewModel() {

    private val symbolArg: String = savedStateHandle.get<String>("symbol").orEmpty()

    private val _ui = MutableStateFlow(TradeUiState(symbol = symbolArg))
    val ui = _ui.asStateFlow()

    init { load() }

    private fun load() {
        viewModelScope.launch {
            val r = runCatching {
                val settings = settingsRepository.settings.first()
                val rules = tradingRepository.getSymbolRules(symbolArg)
                val account = tradingRepository.getAccount()
                val available = account.availableBalance.toDoubleOrNull() ?: 0.0
                val htf = Timeframe.fromCode(settings.htfTimeframe)
                val mtf = Timeframe.fromCode(settings.mtfTimeframe)
                val ltf = Timeframe.fromCode(settings.ltfTimeframe)
                val signal = scanner.evaluateOne(symbolArg, htf, mtf, ltf)
                val priceFromTicker = marketRepository.get24hTickers()
                    .firstOrNull { it.symbol == symbolArg }
                    ?.lastPrice?.toDoubleOrNull() ?: signal?.price ?: 0.0
                LoadResult(rules, available, signal, priceFromTicker, settings.defaultLeverage, settings.isolatedMargin, settings.autoAttachSlTp)
            }
            _ui.update {
                if (r.isSuccess) {
                    val res = r.getOrThrow()
                    it.copy(
                        loading = false,
                        rules = res.rules,
                        availableUsdt = res.availableUsdt,
                        signal = res.signal,
                        side = res.signal?.side ?: SignalSide.LONG,
                        entryPrice = res.signal?.plan?.entry ?: res.lastPrice,
                        marginUsdt = (res.availableUsdt * 0.05).coerceAtLeast(0.0), // default 5% of free balance
                        leverage = res.defaultLeverage,
                        isolated = res.defaultIsolated,
                        autoAttachSlTp = res.autoAttachSlTp
                    )
                } else it.copy(loading = false, error = r.exceptionOrNull()?.message)
            }
        }
    }

    private data class LoadResult(
        val rules: SymbolRules?,
        val availableUsdt: Double,
        val signal: Signal?,
        val lastPrice: Double,
        val defaultLeverage: Int,
        val defaultIsolated: Boolean,
        val autoAttachSlTp: Boolean
    )

    fun setMargin(v: Double) = _ui.update { it.copy(marginUsdt = v.coerceAtLeast(0.0)) }
    fun setLeverage(v: Int) = _ui.update { it.copy(leverage = v.coerceIn(1, 125)) }
    fun setIsolated(v: Boolean) = _ui.update { it.copy(isolated = v) }
    fun setAutoAttach(v: Boolean) = _ui.update { it.copy(autoAttachSlTp = v) }
    fun setSide(v: SignalSide) = _ui.update { it.copy(side = v) }
    fun setSl(v: Double?) = _ui.update { it.copy(customSl = v) }
    fun setTp1(v: Double?) = _ui.update { it.copy(customTp1 = v) }
    fun setTp2(v: Double?) = _ui.update { it.copy(customTp2 = v) }
    fun setTp3(v: Double?) = _ui.update { it.copy(customTp3 = v) }

    fun place(onSuccess: () -> Unit) {
        val s = _ui.value
        val rules = s.rules ?: return
        if (s.quantity <= 0) {
            _ui.update { it.copy(error = "Quantity must be > 0") }; return
        }
        if (s.quantity * s.entryPrice < rules.minNotional) {
            _ui.update { it.copy(error = "Notional ${s.quantity * s.entryPrice} below min ${rules.minNotional}") }
            return
        }
        if (s.marginUsdt > s.availableUsdt) {
            _ui.update { it.copy(error = "Margin > available balance") }; return
        }
        _ui.update { it.copy(placing = true, error = null, resultMessage = null, warnings = emptyList()) }

        viewModelScope.launch {
            val r = runCatching {
                tradingRepository.setMarginType(s.symbol, s.isolated)
                tradingRepository.setLeverage(s.symbol, s.leverage)
                val warnings = mutableListOf<String>()
                val tps = if (s.autoAttachSlTp) {
                    listOfNotNull(
                        s.effectiveTp1.takeIf { it > 0 },
                        s.effectiveTp2.takeIf { it > 0 },
                        s.effectiveTp3.takeIf { it > 0 }
                    )
                } else emptyList()
                val sl = if (s.autoAttachSlTp) s.effectiveSl else null
                tradingRepository.openMarketWithBrackets(
                    symbol = s.symbol,
                    side = s.side,
                    quantity = s.quantity,
                    stopPrice = sl,
                    takeProfits = tps,
                    rules = rules,
                    onBracketError = { warnings += it }
                ) to warnings
            }
            _ui.update {
                if (r.isSuccess) {
                    val (response, warnings) = r.getOrThrow()
                    it.copy(
                        placing = false,
                        resultMessage = "Filled ${response.executedQty} @ ${response.avgPrice ?: response.price}",
                        warnings = warnings
                    )
                } else it.copy(placing = false, error = r.exceptionOrNull()?.message)
            }
            if (r.isSuccess) onSuccess()
        }
    }
}
