package com.apex.trader.data.local

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

data class BinanceCredentials(
    val apiKey: String,
    val apiSecret: String,
    val testnet: Boolean
)

/**
 * Encrypted storage for the user's Binance API key/secret. Uses Android Keystore-backed
 * AES256_GCM via Jetpack Security.
 */
@Singleton
class CredentialsStore @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val prefs: SharedPreferences by lazy {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            FILE_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    private val _state = MutableStateFlow(load())
    val state: StateFlow<BinanceCredentials?> = _state.asStateFlow()

    fun snapshot(): BinanceCredentials? = _state.value

    fun save(creds: BinanceCredentials) {
        prefs.edit()
            .putString(KEY_API_KEY, creds.apiKey)
            .putString(KEY_API_SECRET, creds.apiSecret)
            .putBoolean(KEY_TESTNET, creds.testnet)
            .apply()
        _state.value = creds
    }

    fun clear() {
        prefs.edit().clear().apply()
        _state.value = null
    }

    private fun load(): BinanceCredentials? {
        val key = prefs.getString(KEY_API_KEY, null) ?: return null
        val sec = prefs.getString(KEY_API_SECRET, null) ?: return null
        if (key.isBlank() || sec.isBlank()) return null
        return BinanceCredentials(key, sec, prefs.getBoolean(KEY_TESTNET, false))
    }

    companion object {
        private const val FILE_NAME = "apex_credentials.enc"
        private const val KEY_API_KEY = "api_key"
        private const val KEY_API_SECRET = "api_secret"
        private const val KEY_TESTNET = "testnet"
    }
}
