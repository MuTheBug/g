package com.apex.trader.presentation.screen.scanner

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.AccountBalance
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.apex.trader.domain.strategy.Signal
import com.apex.trader.domain.strategy.SignalSide
import com.apex.trader.presentation.component.ApexCard
import com.apex.trader.presentation.component.ConfidenceBadge
import com.apex.trader.presentation.component.SidePill
import com.apex.trader.presentation.theme.ApexBear
import com.apex.trader.presentation.theme.ApexBull
import com.apex.trader.presentation.theme.ApexTextMuted

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScannerScreen(
    onSignalClick: (String) -> Unit,
    onPositionsClick: () -> Unit,
    onSettingsClick: () -> Unit,
    vm: ScannerViewModel = hiltViewModel()
) {
    val ui by vm.ui.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) {
        if (ui.signals.isEmpty() && !ui.scanning) vm.scan()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Apex Scanner") },
                actions = {
                    IconButton(onClick = onPositionsClick) {
                        Icon(Icons.Outlined.AccountBalance, "Positions")
                    }
                    IconButton(onClick = onSettingsClick) {
                        Icon(Icons.Default.Settings, "Settings")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background
                )
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding)
        ) {
            ScanHeader(
                ui = ui,
                onScan = { vm.scan() },
                onCancel = { vm.cancel() }
            )

            if (ui.error != null) {
                Text(
                    text = "⚠ ${ui.error}",
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(horizontal = 16.dp)
                )
            }

            if (ui.signals.isEmpty() && !ui.scanning) {
                EmptyState()
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 8.dp)
                ) {
                    items(ui.signals, key = { it.symbol }) { sig ->
                        SignalCard(sig, onClick = { onSignalClick(sig.symbol) })
                    }
                }
            }
        }
    }
}

@Composable
private fun ScanHeader(
    ui: ScannerUiState,
    onScan: () -> Unit,
    onCancel: () -> Unit
) {
    Column(modifier = Modifier.padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = if (ui.scanning) "Scanning…" else "${ui.signals.size} signals",
                    style = MaterialTheme.typography.titleLarge
                )
                Text(
                    text = if (ui.scanning) "${ui.processed}/${ui.total} symbols • ${ui.current ?: ""}"
                    else if (ui.lastScanAt != null) "Last scan ${formatAgo(ui.lastScanAt)}"
                    else "Tap scan to begin",
                    color = ApexTextMuted,
                    style = MaterialTheme.typography.bodyMedium
                )
            }
            if (ui.scanning) {
                OutlinedButton(onClick = onCancel) { Text("Cancel") }
            } else {
                Button(onClick = onScan) { Text("Scan now") }
            }
        }
        if (ui.scanning && ui.total > 0) {
            Spacer(Modifier.height(8.dp))
            LinearProgressIndicator(
                progress = { ui.processed / ui.total.toFloat() },
                modifier = Modifier.fillMaxWidth().height(4.dp)
            )
        }
    }
}

@Composable
private fun SignalCard(sig: Signal, onClick: () -> Unit) {
    ApexCard(modifier = Modifier.clickable { onClick() }) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(sig.symbol, style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.padding(end = 10.dp))
                SidePill(if (sig.side == SignalSide.LONG) "LONG" else "SHORT")
                Spacer(Modifier.weight(1f))
                ConfidenceBadge(sig.confidence)
            }
            Spacer(Modifier.height(10.dp))
            Row {
                MetricSmall("Entry", "%.4f".format(sig.plan.entry))
                Spacer(Modifier.padding(end = 14.dp))
                MetricSmall(
                    "SL",
                    "%.4f".format(sig.plan.stopLoss),
                    color = ApexBear
                )
                Spacer(Modifier.padding(end = 14.dp))
                MetricSmall(
                    "TP1 / TP3",
                    "%.4f / %.4f".format(sig.plan.takeProfit1, sig.plan.takeProfit3),
                    color = ApexBull
                )
            }
            Spacer(Modifier.height(8.dp))
            Row {
                MetricSmall("ADX", "%.1f".format(sig.adx))
                Spacer(Modifier.padding(end = 14.dp))
                MetricSmall("RSI", "%.1f".format(sig.rsi))
                Spacer(Modifier.padding(end = 14.dp))
                MetricSmall("Vol×", "%.2f".format(sig.volumeSurge))
                Spacer(Modifier.padding(end = 14.dp))
                MetricSmall("Reasons", "${sig.reasonsPassed.size}/${sig.reasons.size}")
            }
        }
    }
}

@Composable
private fun MetricSmall(label: String, value: String, color: androidx.compose.ui.graphics.Color = MaterialTheme.colorScheme.onSurface) {
    Column {
        Text(label, color = ApexTextMuted, style = MaterialTheme.typography.labelSmall)
        Text(value, color = color, style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
private fun EmptyState() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("No high-confidence setups", style = MaterialTheme.typography.titleMedium)
            Text(
                "The market may be ranging — try again later or lower the confidence threshold in Settings.",
                color = ApexTextMuted,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(horizontal = 24.dp)
            )
        }
    }
}

private fun formatAgo(ms: Long): String {
    val sec = (System.currentTimeMillis() - ms) / 1000
    return when {
        sec < 60 -> "${sec}s ago"
        sec < 3600 -> "${sec / 60}m ago"
        else -> "${sec / 3600}h ago"
    }
}
