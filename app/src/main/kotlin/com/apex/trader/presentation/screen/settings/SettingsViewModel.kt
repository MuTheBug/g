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

    fun update(transform: (AppSettings) -> AppSettings) {
        viewModelScope.launch {
            settingsRepository.update(transform)
            val s = settings.value
            if (s.backgroundScanEnabled) scanScheduler.enable(s.backgroundScanIntervalMin)
            else scanScheduler.disable()
        }
    }

    fun disconnect() {
        credentialsStore.clear()
        _disconnected.value = true
    }
}
