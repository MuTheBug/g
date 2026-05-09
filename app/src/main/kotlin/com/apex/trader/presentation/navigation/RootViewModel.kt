package com.apex.trader.presentation.navigation

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.apex.trader.data.local.CredentialsStore
import com.apex.trader.data.repository.SettingsRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import javax.inject.Inject

@HiltViewModel
class RootViewModel @Inject constructor(
    val credentialsStore: CredentialsStore,
    settingsRepository: SettingsRepository
) : ViewModel() {

    /** Whether biometric lock should gate the app on launch. */
    val biometricLockEnabled = settingsRepository.settings
        .map { it.biometricLockEnabled }
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.Eagerly,
            // Default to false until DataStore loads — avoids flashing the lock screen
            // for an unconfigured user during cold start.
            initialValue = false
        )
}
