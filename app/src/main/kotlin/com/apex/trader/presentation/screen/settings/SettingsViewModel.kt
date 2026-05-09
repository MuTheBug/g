package com.apex.trader.presentation.screen.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.apex.trader.data.local.CredentialsStore
import com.apex.trader.data.repository.AppSettings
import com.apex.trader.data.repository.SettingsRepository
import com.apex.trader.service.ScanWorkerScheduler
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import timber.log.Timber
import javax.inject.Inject

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settingsRepository: SettingsRepository,
    private val credentialsStore: CredentialsStore,
    private val scanScheduler: ScanWorkerScheduler
) : ViewModel() {

    val settings = settingsRepository.settings.stateIn(
        scope = viewModelScope,
        started = SharingStarted.Eagerly,
        initialValue = AppSettings()
    )

    private val _disconnected = MutableStateFlow(false)
    val disconnected = _disconnected.asStateFlow()

    private val _scheduleError = MutableStateFlow<String?>(null)
    val scheduleError = _scheduleError.asStateFlow()

    private val _runNowMessage = MutableStateFlow<String?>(null)
    val runNowMessage = _runNowMessage.asStateFlow()

    fun clearScheduleError() { _scheduleError.value = null }
    fun clearRunNowMessage() { _runNowMessage.value = null }

    fun update(transform: (AppSettings) -> AppSettings) {
        viewModelScope.launch {
            // Compute the next state synchronously from the current snapshot so that
            // scheduling decisions don't race with the DataStore -> StateFlow propagation.
            val current = settings.value
            val next = transform(current)
            settingsRepository.update { next }
            if (next.backgroundScanEnabled != current.backgroundScanEnabled ||
                (next.backgroundScanEnabled && next.backgroundScanIntervalMin != current.backgroundScanIntervalMin)
            ) {
                runCatching {
                    if (next.backgroundScanEnabled) scanScheduler.enable(next.backgroundScanIntervalMin)
                    else scanScheduler.disable()
                }.onFailure {
                    Timber.e(it, "scan scheduler toggle failed")
                    _scheduleError.value = "Couldn't enable background scan: ${it.message}"
                    // Roll back the toggle so UI matches reality.
                    settingsRepository.update { it.copy(backgroundScanEnabled = current.backgroundScanEnabled) }
                }
            }
        }
    }

    /**
     * Trigger a one-shot scan via WorkManager so the user can verify the
     * background path works end-to-end without waiting for the periodic window.
     */
    fun runScanNow() {
        runCatching { scanScheduler.runOnce() }
            .onSuccess {
                _runNowMessage.value = "Scan queued — you'll get a notification per signal found."
            }
            .onFailure {
                Timber.e(it, "manual run-now failed")
                _scheduleError.value = "Couldn't start a scan: ${it.message}"
            }
    }

    fun disconnect() {
        credentialsStore.clear()
        _disconnected.value = true
    }
}
