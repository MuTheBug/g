package com.apex.trader.data.repository

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

private val Context.dataStore by preferencesDataStore(name = "apex_settings")

data class AppSettings(
    val scanLimit: Int = 30,
    val minConfidence: Int = 70,
    val defaultLeverage: Int = 5,
    val isolatedMargin: Boolean = true,
    val autoAttachSlTp: Boolean = true,
    val backgroundScanEnabled: Boolean = false,
    val backgroundScanIntervalMin: Int = 15,
    val excludedSymbols: Set<String> = emptySet(),
    val watchlist: Set<String> = emptySet(),
    val biometricLockEnabled: Boolean = true,
    val htfTimeframe: String = "4h",
    val mtfTimeframe: String = "1h",
    val ltfTimeframe: String = "15m"
)

@Singleton
class SettingsRepository @Inject constructor(
    @ApplicationContext private val context: Context
) {
    val settings: Flow<AppSettings> = context.dataStore.data.map { it.toModel() }

    suspend fun update(transform: (AppSettings) -> AppSettings) {
        context.dataStore.edit { prefs ->
            val current = prefs.toModel()
            val next = transform(current)
            prefs[Keys.scanLimit] = next.scanLimit
            prefs[Keys.minConfidence] = next.minConfidence
            prefs[Keys.defaultLeverage] = next.defaultLeverage
            prefs[Keys.isolatedMargin] = next.isolatedMargin
            prefs[Keys.autoAttachSlTp] = next.autoAttachSlTp
            prefs[Keys.backgroundScanEnabled] = next.backgroundScanEnabled
            prefs[Keys.backgroundScanIntervalMin] = next.backgroundScanIntervalMin
            prefs[Keys.excludedSymbols] = next.excludedSymbols.joinToString(",")
            prefs[Keys.watchlist] = next.watchlist.joinToString(",")
            prefs[Keys.biometricLockEnabled] = next.biometricLockEnabled
            prefs[Keys.htfTimeframe] = next.htfTimeframe
            prefs[Keys.mtfTimeframe] = next.mtfTimeframe
            prefs[Keys.ltfTimeframe] = next.ltfTimeframe
        }
    }

    private fun Preferences.toModel() = AppSettings(
        scanLimit = this[Keys.scanLimit] ?: 50,
        minConfidence = this[Keys.minConfidence] ?: 70,
        defaultLeverage = this[Keys.defaultLeverage] ?: 5,
        isolatedMargin = this[Keys.isolatedMargin] ?: true,
        autoAttachSlTp = this[Keys.autoAttachSlTp] ?: true,
        backgroundScanEnabled = this[Keys.backgroundScanEnabled] ?: false,
        backgroundScanIntervalMin = this[Keys.backgroundScanIntervalMin] ?: 15,
        excludedSymbols = (this[Keys.excludedSymbols] ?: "")
            .split(",").map { it.trim() }.filter { it.isNotEmpty() }.toSet(),
        watchlist = (this[Keys.watchlist] ?: "")
            .split(",").map { it.trim() }.filter { it.isNotEmpty() }.toSet(),
        biometricLockEnabled = this[Keys.biometricLockEnabled] ?: true,
        htfTimeframe = this[Keys.htfTimeframe] ?: "4h",
        mtfTimeframe = this[Keys.mtfTimeframe] ?: "1h",
        ltfTimeframe = this[Keys.ltfTimeframe] ?: "15m"
    )

    private object Keys {
        val scanLimit = intPreferencesKey("scan_limit")
        val minConfidence = intPreferencesKey("min_confidence")
        val defaultLeverage = intPreferencesKey("default_leverage")
        val isolatedMargin = booleanPreferencesKey("isolated_margin")
        val autoAttachSlTp = booleanPreferencesKey("auto_attach_sltp")
        val backgroundScanEnabled = booleanPreferencesKey("bg_scan_enabled")
        val backgroundScanIntervalMin = intPreferencesKey("bg_scan_interval_min")
        val excludedSymbols = stringPreferencesKey("excluded_symbols")
        val watchlist = stringPreferencesKey("watchlist")
        val biometricLockEnabled = booleanPreferencesKey("biometric_lock_enabled")
        val htfTimeframe = stringPreferencesKey("htf_tf")
        val mtfTimeframe = stringPreferencesKey("mtf_tf")
        val ltfTimeframe = stringPreferencesKey("ltf_tf")
    }
}
