package com.apex.trader.presentation.screen.signal

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.apex.trader.data.model.Candle
import com.apex.trader.data.model.Timeframe
import com.apex.trader.data.repository.MarketRepository
import com.apex.trader.data.repository.SettingsRepository
import com.apex.trader.domain.scanner.MarketScanner
import com.apex.trader.domain.strategy.Signal
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class SignalDetailUiState(
    val loading: Boolean = true,
    val symbol: String = "",
    val candles: List<Candle> = emptyList(),
    val signal: Signal? = null,
    val error: String? = null
)

@HiltViewModel
class SignalDetailViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val marketRepository: MarketRepository,
    private val settingsRepository: SettingsRepository,
    private val scanner: MarketScanner
) : ViewModel() {

    private val symbolArg: String = savedStateHandle.get<String>("symbol").orEmpty()

    private val _ui = MutableStateFlow(SignalDetailUiState(symbol = symbolArg))
    val ui = _ui.asStateFlow()

    init { refresh() }

    fun refresh() {
        _ui.update { it.copy(loading = true, error = null) }
        viewModelScope.launch {
            val r = runCatching {
                val settings = settingsRepository.settings.first()
                val htf = Timeframe.fromCode(settings.htfTimeframe)
                val mtf = Timeframe.fromCode(settings.mtfTimeframe)
                val ltf = Timeframe.fromCode(settings.ltfTimeframe)
                val ltfCandles = marketRepository.getCandles(symbolArg, ltf, 200)
                val signal = scanner.evaluateOne(symbolArg, htf, mtf, ltf)
                ltfCandles to signal
            }
            _ui.update {
                if (r.isSuccess) {
                    val (candles, sig) = r.getOrThrow()
                    it.copy(loading = false, candles = candles, signal = sig)
                } else it.copy(loading = false, error = r.exceptionOrNull()?.message)
            }
        }
    }
}
