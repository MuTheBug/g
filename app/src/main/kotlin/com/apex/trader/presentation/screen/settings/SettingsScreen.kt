package com.apex.trader.presentation.screen.settings

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.clickable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.apex.trader.presentation.component.ApexCard
import com.apex.trader.presentation.theme.ApexHighlight
import com.apex.trader.presentation.theme.ApexTextMuted

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    onAboutClick: () -> Unit,
    vm: SettingsViewModel = hiltViewModel()
) {
    val s by vm.settings.collectAsStateWithLifecycle()
    val disconnected by vm.disconnected.collectAsStateWithLifecycle()
    val scheduleError by vm.scheduleError.collectAsStateWithLifecycle()
    val runNowMessage by vm.runNowMessage.collectAsStateWithLifecycle()

    LaunchedEffect(disconnected) {
        if (disconnected) onBack()
    }

    // Runtime POST_NOTIFICATIONS permission for Android 13+
    val notificationPermLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        // Callback is delivered on the main thread mid activity-resume. Do nothing
        // here that could throw — the VM dispatches the scheduler call to IO with
        // NonCancellable + try/catch so anything thrown from WorkManager init lands
        // in our error flow instead of bubbling to the activity uncaught.
        try {
            vm.setBackgroundScanEnabled(granted)
        } catch (t: Throwable) {
            android.util.Log.e("ApexTrader", "perm callback failed", t)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            item {
                ApexCard {
                    Column {
                        Text("Scanner", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(8.dp))
                        Text("Symbols per scan: ${s.scanLimit}", color = ApexTextMuted)
                        Slider(
                            value = s.scanLimit.toFloat(),
                            onValueChange = { vm.update { st -> st.copy(scanLimit = it.toInt().coerceIn(10, 200)) } },
                            valueRange = 10f..200f
                        )
                        Text("Min confidence: ${s.minConfidence}%", color = ApexTextMuted)
                        Slider(
                            value = s.minConfidence.toFloat(),
                            onValueChange = { vm.update { st -> st.copy(minConfidence = it.toInt().coerceIn(50, 95)) } },
                            valueRange = 50f..95f
                        )
                    }
                }
            }
            item {
                ApexCard {
                    Column {
                        Text("Default order parameters", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(8.dp))
                        Text("Default leverage: ${s.defaultLeverage}x", color = ApexTextMuted)
                        Slider(
                            value = s.defaultLeverage.toFloat(),
                            onValueChange = { vm.update { st -> st.copy(defaultLeverage = it.toInt().coerceIn(1, 50)) } },
                            valueRange = 1f..50f
                        )
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Isolated margin", modifier = Modifier.weight(1f))
                            Switch(
                                checked = s.isolatedMargin,
                                onCheckedChange = { v -> vm.update { st -> st.copy(isolatedMargin = v) } }
                            )
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Auto-attach SL & TP")
                                Text(
                                    "Place stop-loss and 3 take-profit brackets alongside every entry",
                                    color = ApexTextMuted,
                                    style = MaterialTheme.typography.bodyMedium
                                )
                            }
                            Switch(
                                checked = s.autoAttachSlTp,
                                onCheckedChange = { v -> vm.update { st -> st.copy(autoAttachSlTp = v) } }
                            )
                        }
                    }
                }
            }
            item {
                ApexCard {
                    Column {
                        Text("Background scan", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(8.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Notify on new high-confidence signals", modifier = Modifier.weight(1f))
                            Switch(
                                checked = s.backgroundScanEnabled,
                                onCheckedChange = { v ->
                                    if (v && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                        // Ask for POST_NOTIFICATIONS first; the launcher callback
                                        // persists the toggle once the system dialog returns.
                                        notificationPermLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                                    } else {
                                        vm.update { st -> st.copy(backgroundScanEnabled = v) }
                                    }
                                }
                            )
                        }
                        scheduleError?.let { err ->
                            Text(
                                "⚠ $err",
                                color = MaterialTheme.colorScheme.error,
                                style = MaterialTheme.typography.bodyMedium,
                                modifier = Modifier.padding(top = 6.dp)
                            )
                        }
                        runNowMessage?.let { msg ->
                            Text(
                                msg,
                                color = ApexHighlight,
                                style = MaterialTheme.typography.bodyMedium,
                                modifier = Modifier.padding(top = 6.dp)
                            )
                        }
                        Spacer(Modifier.height(8.dp))
                        androidx.compose.material3.OutlinedButton(
                            onClick = { vm.runScanNow() },
                            modifier = Modifier.fillMaxWidth()
                        ) { Text("Run a scan now") }
                        Text("Interval: ${s.backgroundScanIntervalMin} min", color = ApexTextMuted)
                        Slider(
                            value = s.backgroundScanIntervalMin.toFloat(),
                            onValueChange = { vm.update { st -> st.copy(backgroundScanIntervalMin = it.toInt().coerceIn(5, 120)) } },
                            valueRange = 5f..120f
                        )
                    }
                }
            }
            item {
                ApexCard {
                    Column {
                        Text("Watchlist & exclusions", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(6.dp))
                        var watch by remember(s.watchlist) { mutableStateOf(s.watchlist.joinToString(",")) }
                        OutlinedTextField(
                            value = watch,
                            onValueChange = {
                                watch = it
                                vm.update { st -> st.copy(watchlist = it.split(",").map { x -> x.trim().uppercase() }.filter { x -> x.isNotEmpty() }.toSet()) }
                            },
                            label = { Text("Watchlist (comma-separated)") },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text)
                        )
                        Spacer(Modifier.height(6.dp))
                        var excl by remember(s.excludedSymbols) { mutableStateOf(s.excludedSymbols.joinToString(",")) }
                        OutlinedTextField(
                            value = excl,
                            onValueChange = {
                                excl = it
                                vm.update { st -> st.copy(excludedSymbols = it.split(",").map { x -> x.trim().uppercase() }.filter { x -> x.isNotEmpty() }.toSet()) }
                            },
                            label = { Text("Excluded symbols (comma-separated)") },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true
                        )
                    }
                }
            }
            item {
                ApexCard {
                    Column {
                        Text("Strategy timeframes", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(6.dp))
                        TfPicker("Higher (HTF)", s.htfTimeframe, listOf("1h", "4h", "1d")) { v -> vm.update { it.copy(htfTimeframe = v) } }
                        TfPicker("Mid (MTF)", s.mtfTimeframe, listOf("15m", "30m", "1h", "4h")) { v -> vm.update { it.copy(mtfTimeframe = v) } }
                        TfPicker("Lower (LTF)", s.ltfTimeframe, listOf("1m", "5m", "15m", "30m")) { v -> vm.update { it.copy(ltfTimeframe = v) } }
                    }
                }
            }
            item {
                ApexCard {
                    Column {
                        Text("Security", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(6.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Biometric lock on launch", modifier = Modifier.weight(1f))
                            Switch(
                                checked = s.biometricLockEnabled,
                                onCheckedChange = { v -> vm.update { st -> st.copy(biometricLockEnabled = v) } }
                            )
                        }
                    }
                }
            }
            item {
                ApexCard(modifier = Modifier.clickable { onAboutClick() }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Info, contentDescription = null, tint = ApexHighlight)
                        Spacer(Modifier.padding(end = 12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text("About", style = MaterialTheme.typography.titleMedium)
                            Text(
                                "App version, developer credit, strategy summary",
                                color = ApexTextMuted,
                                style = MaterialTheme.typography.bodyMedium
                            )
                        }
                        Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = null, tint = ApexTextMuted)
                    }
                }
            }
            item {
                Button(
                    onClick = { vm.disconnect() },
                    modifier = Modifier.fillMaxWidth()
                ) { Text("Disconnect & clear API keys") }
            }
            item { Spacer(Modifier.height(8.dp)) }
            item {
                Text(
                    "⚠ This app sends real orders to Binance Futures. Test on Testnet first. Trading derivatives involves substantial risk of loss.",
                    color = ApexHighlight,
                    style = MaterialTheme.typography.bodyMedium
                )
            }
        }
    }
}

@Composable
private fun TfPicker(label: String, current: String, options: List<String>, onChange: (String) -> Unit) {
    Column(modifier = Modifier.padding(vertical = 4.dp)) {
        Text(label, color = ApexTextMuted, style = MaterialTheme.typography.labelSmall)
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            options.forEach { opt ->
                androidx.compose.material3.FilterChip(
                    selected = opt == current,
                    onClick = { onChange(opt) },
                    label = { Text(opt) }
                )
            }
        }
    }
}
