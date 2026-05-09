package com.apex.trader.presentation.screen.positions

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.apex.trader.data.api.dto.AccountInfoDto
import com.apex.trader.data.api.dto.PositionDto
import com.apex.trader.data.repository.TradingRepository
import com.apex.trader.domain.strategy.SignalSide
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import timber.log.Timber
import kotlin.math.abs
import javax.inject.Inject

data class PositionsUiState(
    val loading: Boolean = true,
    val account: AccountInfoDto? = null,
    val positions: List<PositionDto> = emptyList(),
    val error: String? = null,
    val workingSymbol: String? = null
)

@HiltViewModel
class PositionsViewModel @Inject constructor(
    private val tradingRepository: TradingRepository
) : ViewModel() {

    private val _ui = MutableStateFlow(PositionsUiState())
    val ui = _ui.asStateFlow()

    init { refresh() }

    fun refresh() {
        _ui.update { it.copy(loading = true, error = null) }
        viewModelScope.launch {
            try {
                val account = tradingRepository.getAccount()
                val positions = tradingRepository.getOpenPositions()
                _ui.update { it.copy(loading = false, account = account, positions = positions) }
            } catch (ce: CancellationException) {
                throw ce
            } catch (t: Throwable) {
                Timber.e(t, "positions refresh failed")
                _ui.update { it.copy(loading = false, error = t.message ?: t.javaClass.simpleName) }
            }
        }
    }

    fun closePosition(symbol: String, amt: Double) {
        _ui.update { it.copy(workingSymbol = symbol) }
        viewModelScope.launch {
            try {
                val rules = tradingRepository.getSymbolRules(symbol)
                    ?: error("Missing exchange rules for $symbol")
                val side = if (amt > 0) SignalSide.LONG else SignalSide.SHORT
                tradingRepository.cancelAll(symbol)
                tradingRepository.closePosition(symbol, side, abs(amt), rules)
                _ui.update { it.copy(workingSymbol = null) }
                refresh()
            } catch (ce: CancellationException) {
                _ui.update { it.copy(workingSymbol = null) }
                throw ce
            } catch (t: Throwable) {
                Timber.e(t, "close position failed for $symbol")
                _ui.update { it.copy(workingSymbol = null, error = t.message ?: t.javaClass.simpleName) }
            }
        }
    }
}
