package com.apex.trader.presentation.screen.signal

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.apex.trader.domain.strategy.Signal
import com.apex.trader.domain.strategy.SignalReason
import com.apex.trader.domain.strategy.SignalSide
import com.apex.trader.presentation.component.ApexCard
import com.apex.trader.presentation.component.CandleChart
import com.apex.trader.presentation.component.ConfidenceBadge
import com.apex.trader.presentation.component.KeyValueRow
import com.apex.trader.presentation.component.SidePill
import com.apex.trader.presentation.theme.ApexBear
import com.apex.trader.presentation.theme.ApexBull
import com.apex.trader.presentation.theme.ApexHighlight
import com.apex.trader.presentation.theme.ApexTextMuted

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SignalDetailScreen(
    symbol: String,
    onTradeClick: () -> Unit,
    onBack: () -> Unit,
    vm: SignalDetailViewModel = hiltViewModel()
) {
    val ui by vm.ui.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(symbol) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { vm.refresh() }) {
                        Icon(Icons.Default.Refresh, "Refresh")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background
                )
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding),
            verticalArrangement = Arrangement.spacedBy(0.dp)
        ) {
            when {
                ui.loading -> Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
                ui.error != null -> Text(
                    text = "⚠ ${ui.error}",
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(16.dp)
                )
                else -> Content(ui, onTradeClick)
            }
        }
    }
}

@Composable
private fun Content(ui: SignalDetailUiState, onTradeClick: () -> Unit) {
    val sig = ui.signal
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        contentPadding = PaddingValues(12.dp)
    ) {
        item {
            ApexCard {
                Column {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(ui.symbol, style = MaterialTheme.typography.headlineMedium)
                        Spacer(Modifier.padding(end = 8.dp))
                        if (sig != null) SidePill(if (sig.side == SignalSide.LONG) "LONG" else "SHORT")
                        Spacer(Modifier.weight(1f))
                        if (sig != null) ConfidenceBadge(sig.confidence)
                    }
                    if (sig == null) {
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "No active high-confidence setup right now. The chart shows the latest 200 candles for context.",
                            color = ApexTextMuted,
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }
                }
            }
        }

        item {
            ApexCard {
                CandleChart(candles = ui.candles, signal = sig)
            }
        }

        if (sig != null) {
            item {
                ApexCard {
                    Column {
                        Text("Trade plan", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(8.dp))
                        KeyValueRow("Entry", "%.6f".format(sig.plan.entry))
                        KeyValueRow("Stop loss", "%.6f".format(sig.plan.stopLoss), valueColor = ApexBear)
                        KeyValueRow("TP1 (${"%.1f".format(sig.plan.riskRewardR1)}R)", "%.6f".format(sig.plan.takeProfit1), valueColor = ApexBull)
                        KeyValueRow("TP2 (${"%.1f".format(sig.plan.riskRewardR2)}R)", "%.6f".format(sig.plan.takeProfit2), valueColor = ApexBull)
                        KeyValueRow("TP3 (${"%.1f".format(sig.plan.riskRewardR3)}R)", "%.6f".format(sig.plan.takeProfit3), valueColor = ApexBull)
                        KeyValueRow("ATR", "%.6f".format(sig.plan.atr))
                        KeyValueRow("ADX", "%.1f".format(sig.adx))
                        KeyValueRow("RSI", "%.1f".format(sig.rsi))
                        KeyValueRow("Volume surge", "%.2fx".format(sig.volumeSurge))
                    }
                }
            }
            item {
                ApexCard {
                    Column {
                        Text("Why this signal", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(6.dp))
                        sig.reasons.forEach { ReasonRow(it) }
                    }
                }
            }
            item {
                Button(
                    onClick = onTradeClick,
                    modifier = Modifier.fillMaxWidth()
                ) { Text("Open trade") }
            }
        }
    }
}

@Composable
private fun ReasonRow(r: SignalReason) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = if (r.passed) "✓" else "✗",
            color = if (r.passed) ApexBull else ApexBear,
            modifier = Modifier.padding(end = 8.dp),
            style = MaterialTheme.typography.titleMedium
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(r.label, style = MaterialTheme.typography.bodyMedium)
            Text(r.detail, color = ApexTextMuted, style = MaterialTheme.typography.labelSmall)
        }
        Text(
            "+${r.weight.toInt()}",
            color = ApexHighlight,
            style = MaterialTheme.typography.labelMedium
        )
    }
}
