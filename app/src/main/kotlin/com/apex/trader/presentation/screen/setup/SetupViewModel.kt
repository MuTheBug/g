package com.apex.trader.presentation.screen.setup

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.apex.trader.data.local.BinanceCredentials
import com.apex.trader.data.local.CredentialsStore
import com.apex.trader.data.repository.TradingRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

data class SetupUiState(
    val saving: Boolean = false,
    val error: String? = null
)

@HiltViewModel
class SetupViewModel @Inject constructor(
    private val credentialsStore: CredentialsStore,
    private val tradingRepository: TradingRepository
) : ViewModel() {

    private val _ui = MutableStateFlow(SetupUiState())
    val ui = _ui.asStateFlow()

    fun save(apiKey: String, apiSecret: String, testnet: Boolean, onSuccess: () -> Unit) {
        if (apiKey.isBlank() || apiSecret.isBlank()) return
        _ui.value = SetupUiState(saving = true)
        // Save first so the auth interceptor can see the key, then probe accountInfo.
        credentialsStore.save(BinanceCredentials(apiKey, apiSecret, testnet))
        viewModelScope.launch {
            val result = runCatching { tradingRepository.getAccount() }
            if (result.isSuccess) {
                _ui.value = SetupUiState(saving = false)
                onSuccess()
            } else {
                credentialsStore.clear()
                _ui.value = SetupUiState(
                    saving = false,
                    error = "Authentication failed: ${result.exceptionOrNull()?.message ?: "unknown"}"
                )
            }
        }
    }
}
