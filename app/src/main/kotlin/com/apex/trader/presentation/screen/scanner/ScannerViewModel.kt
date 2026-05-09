package com.apex.trader.presentation.screen.scanner

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.apex.trader.domain.scanner.MarketScanner
import com.apex.trader.domain.scanner.ScanProgress
import com.apex.trader.domain.strategy.Signal
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class ScannerUiState(
    val scanning: Boolean = false,
    val processed: Int = 0,
    val total: Int = 0,
    val current: String? = null,
    val signals: List<Signal> = emptyList(),
    val lastScanAt: Long? = null,
    val error: String? = null
)

@HiltViewModel
class ScannerViewModel @Inject constructor(
    private val scanner: MarketScanner
) : ViewModel() {

    private val _ui = MutableStateFlow(ScannerUiState())
    val ui = _ui.asStateFlow()

    private var job: Job? = null

    /** Persist the most recent successful signal list across navigations. */
    fun signalFor(symbol: String): Signal? = _ui.value.signals.firstOrNull { it.symbol == symbol }

    fun scan() {
        if (_ui.value.scanning) return
        _ui.update { it.copy(scanning = true, error = null, processed = 0, total = 0) }
        job = viewModelScope.launch {
            val result = runCatching {
                scanner.scan(progress = { p: ScanProgress ->
                    _ui.update {
                        it.copy(
                            processed = p.processed,
                            total = p.total,
                            current = p.current,
                            signals = p.signals
                        )
                    }
                })
            }
            _ui.update {
                if (result.isSuccess) it.copy(
                    scanning = false,
                    signals = result.getOrNull() ?: it.signals,
                    lastScanAt = System.currentTimeMillis()
                ) else it.copy(scanning = false, error = result.exceptionOrNull()?.message)
            }
        }
    }

    fun cancel() {
        job?.cancel()
        _ui.update { it.copy(scanning = false) }
    }

    override fun onCleared() {
        cancel()
        super.onCleared()
    }
}
