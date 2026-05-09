package com.apex.trader.presentation.screen.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.apex.trader.data.local.CredentialsStore
import com.apex.trader.data.repository.AppSettings
import com.apex.trader.data.repository.SettingsRepository
import com.apex.trader.service.ScanWorkerScheduler
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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
            val current = settings.value
            val next = transform(current)
            try {
                settingsRepository.update { next }
            } catch (ce: CancellationException) {
                throw ce
            } catch (t: Throwable) {
                Timber.e(t, "settings persist failed")
                _scheduleError.value = "Couldn't save setting: ${t.message}"
                return@launch
            }
            if (next.backgroundScanEnabled != current.backgroundScanEnabled ||
                (next.backgroundScanEnabled && next.backgroundScanIntervalMin != current.backgroundScanIntervalMin)
            ) {
                applySchedule(next.backgroundScanEnabled, next.backgroundScanIntervalMin, current)
            }
        }
    }

    /**
     * Permission-grant entry point: explicitly toggle the background-scan setting and
     * (re)apply the WorkManager schedule. Runs the scheduler bit on Dispatchers.IO so
     * any blocking inside WorkManager's lazy initialization doesn't happen on the main
     * thread, inside [NonCancellable] so a parallel ViewModel-scope cancellation can't
     * tear down a half-finished schedule, and wrapped in try/catch so a thrown
     * IllegalStateException (e.g. WorkManager init issue) lands in our error flow
     * instead of crashing the activity.
     */
    fun setBackgroundScanEnabled(enabled: Boolean) {
        viewModelScope.launch {
            val current = settings.value
            val next = current.copy(backgroundScanEnabled = enabled)
            try {
                settingsRepository.update { next }
            } catch (ce: CancellationException) {
                throw ce
            } catch (t: Throwable) {
                Timber.e(t, "persist backgroundScanEnabled failed")
                _scheduleError.value = "Couldn't save setting: ${t.message}"
                return@launch
            }
            applySchedule(enabled, next.backgroundScanIntervalMin, current)
        }
    }

    private suspend fun applySchedule(
        enabled: Boolean,
        intervalMinutes: Int,
        rollbackTo: AppSettings
    ) {
        try {
            withContext(Dispatchers.IO + NonCancellable) {
                if (enabled) scanScheduler.enable(intervalMinutes)
                else scanScheduler.disable()
            }
        } catch (ce: CancellationException) {
            throw ce
        } catch (t: Throwable) {
            Timber.e(t, "scheduler apply failed (enabled=$enabled)")
            _scheduleError.value = "Couldn't ${if (enabled) "enable" else "disable"} background scan: ${t.message}"
            // Roll the toggle back so the UI matches the actual state.
            runCatching {
                settingsRepository.update { it.copy(backgroundScanEnabled = rollbackTo.backgroundScanEnabled) }
            }.onFailure { Timber.e(it, "rollback failed") }
        }
    }

    /**
     * Trigger a single one-shot scan via WorkManager so the user can verify the
     * background path works end-to-end without waiting for the periodic window.
     */
    fun runScanNow() {
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO + NonCancellable) {
                    scanScheduler.runOnce()
                }
                _runNowMessage.value = "Scan queued — you'll get a notification per signal found."
            } catch (ce: CancellationException) {
                throw ce
            } catch (t: Throwable) {
                Timber.e(t, "manual run-now failed")
                _scheduleError.value = "Couldn't start a scan: ${t.message}"
            }
        }
    }

    fun disconnect() {
        credentialsStore.clear()
        _disconnected.value = true
    }
}
