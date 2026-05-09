package com.apex.trader.presentation.screen.trade

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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
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
import com.apex.trader.domain.strategy.SignalSide
import com.apex.trader.presentation.component.ApexCard
import com.apex.trader.presentation.component.KeyValueRow
import com.apex.trader.presentation.component.SidePill
import com.apex.trader.presentation.theme.ApexBear
import com.apex.trader.presentation.theme.ApexBull
import com.apex.trader.presentation.theme.ApexHighlight
import com.apex.trader.presentation.theme.ApexTextMuted

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TradeScreen(
    symbol: String,
    onDone: () -> Unit,
    onBack: () -> Unit,
    vm: TradeViewModel = hiltViewModel()
) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    var showConfirm by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Trade $symbol") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background
                )
            )
        }
    ) { padding ->
        if (ui.loading) {
            Box(modifier = Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            return@Scaffold
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            contentPadding = PaddingValues(12.dp)
        ) {
            item { HeaderCard(ui) }
            item { SideSelector(ui, vm) }
            item { MarginCard(ui, vm) }
            item { LeverageCard(ui, vm) }
            item { MarginTypeCard(ui, vm) }
            item { SlTpCard(ui, vm) }
            item { SummaryCard(ui) }
            if (ui.error != null) {
                item {
                    Text(
                        "⚠ ${ui.error}",
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.padding(horizontal = 4.dp)
                    )
                }
            }
            item {
                Button(
                    onClick = { showConfirm = true },
                    enabled = !ui.placing && ui.marginUsdt > 0 && ui.entryPrice > 0,
                    modifier = Modifier.fillMaxWidth()
                ) { Text(if (ui.placing) "Placing…" else "Place market order") }
            }
            item { Spacer(Modifier.height(24.dp)) }
        }

        if (showConfirm) {
            AlertDialog(
                onDismissRequest = { showConfirm = false },
                title = { Text("Confirm ${ui.side.name}") },
                text = {
                    Column {
                        Text("Symbol: ${ui.symbol}")
                        Text("Side: ${ui.side.name}")
                        Text("Margin: ${"%.2f".format(ui.marginUsdt)} USDT")
                        Text("Leverage: ${ui.leverage}x  (${if (ui.isolated) "ISOLATED" else "CROSS"})")
                        Text("Notional: ${"%.2f".format(ui.notional)} USDT")
                        Text("Quantity: ${"%.6f".format(ui.quantity)}")
                        Text("SL: ${"%.6f".format(ui.effectiveSl)}", color = ApexBear)
                        Text("TP1/TP2/TP3: ${"%.4f / %.4f / %.4f".format(ui.effectiveTp1, ui.effectiveTp2, ui.effectiveTp3)}", color = ApexBull)
                        Text("Risk if SL: ${"%.2f".format(ui.riskUsdt)} USDT", color = ApexHighlight)
                    }
                },
                confirmButton = {
                    TextButton(onClick = {
                        showConfirm = false
                        vm.place(onDone)
                    }) { Text("Place order") }
                },
                dismissButton = {
                    TextButton(onClick = { showConfirm = false }) { Text("Cancel") }
                }
            )
        }
    }
}

@Composable
private fun HeaderCard(ui: TradeUiState) {
    ApexCard {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(ui.symbol, style = MaterialTheme.typography.headlineMedium)
                Spacer(Modifier.padding(end = 8.dp))
                SidePill(if (ui.side == SignalSide.LONG) "LONG" else "SHORT")
                Spacer(Modifier.weight(1f))
                Text(
                    "Mark ${"%.6f".format(ui.entryPrice)}",
                    color = ApexTextMuted,
                    style = MaterialTheme.typography.labelMedium
                )
            }
            if (ui.signal != null) {
                Spacer(Modifier.height(6.dp))
                Text(
                    "Signal confidence ${ui.signal!!.confidence}% • ${ui.signal!!.reasonsPassed.size}/${ui.signal!!.reasons.size} reasons",
                    color = ApexHighlight,
                    style = MaterialTheme.typography.bodyMedium
                )
            } else {
                Spacer(Modifier.height(6.dp))
                Text(
                    "No active signal — manual trade",
                    color = ApexTextMuted,
                    style = MaterialTheme.typography.bodyMedium
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SideSelector(ui: TradeUiState, vm: TradeViewModel) {
    ApexCard {
        Column {
            Text("Side", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(6.dp))
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                SegmentedButton(
                    selected = ui.side == SignalSide.LONG,
                    onClick = { vm.setSide(SignalSide.LONG) },
                    shape = SegmentedButtonDefaults.itemShape(0, 2)
                ) { Text("LONG", color = ApexBull) }
                SegmentedButton(
                    selected = ui.side == SignalSide.SHORT,
                    onClick = { vm.setSide(SignalSide.SHORT) },
                    shape = SegmentedButtonDefaults.itemShape(1, 2)
                ) { Text("SHORT", color = ApexBear) }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MarginCard(ui: TradeUiState, vm: TradeViewModel) {
    ApexCard {
        Column {
            Row {
                Text("Margin (USDT)", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                Text("Available ${"%.2f".format(ui.availableUsdt)}", color = ApexTextMuted, style = MaterialTheme.typography.labelMedium)
            }
            Spacer(Modifier.height(6.dp))
            var text by remember(ui.marginUsdt) { mutableStateOf("%.2f".format(ui.marginUsdt)) }
            OutlinedTextField(
                value = text,
                onValueChange = {
                    text = it
                    it.toDoubleOrNull()?.let { v -> vm.setMargin(v) }
                },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(8.dp))
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf(0.05, 0.10, 0.25, 0.50, 1.0).forEach { pct ->
                    FilterChip(
                        selected = false,
                        onClick = {
                            val v = ui.availableUsdt * pct
                            text = "%.2f".format(v)
                            vm.setMargin(v)
                        },
                        label = { Text("${(pct * 100).toInt()}%") },
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(8.dp)
                    )
                }
            }
        }
    }
}

@Composable
private fun LeverageCard(ui: TradeUiState, vm: TradeViewModel) {
    ApexCard {
        Column {
            Row {
                Text("Leverage", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                Text("${ui.leverage}x", color = ApexHighlight, style = MaterialTheme.typography.titleMedium)
            }
            Slider(
                value = ui.leverage.toFloat(),
                onValueChange = { vm.setLeverage(it.toInt()) },
                valueRange = 1f..50f,
                steps = 48
            )
            Text(
                "Higher leverage = lower margin requirement but proportionally higher liquidation risk.",
                color = ApexTextMuted,
                style = MaterialTheme.typography.bodyMedium
            )
        }
    }
}

@Composable
private fun MarginTypeCard(ui: TradeUiState, vm: TradeViewModel) {
    ApexCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text("Isolated margin", style = MaterialTheme.typography.titleMedium)
                Text(
                    if (ui.isolated) "Limits loss to position margin"
                    else "Cross — uses entire futures balance",
                    color = ApexTextMuted,
                    style = MaterialTheme.typography.bodyMedium
                )
            }
            Switch(checked = ui.isolated, onCheckedChange = vm::setIsolated)
        }
    }
}

@Composable
private fun SlTpCard(ui: TradeUiState, vm: TradeViewModel) {
    ApexCard {
        Column {
            Text("Stop loss & take profits", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(6.dp))
            PriceField("Stop loss", ui.effectiveSl, vm::setSl, ApexBear)
            PriceField("Take profit 1", ui.effectiveTp1, vm::setTp1, ApexBull)
            PriceField("Take profit 2", ui.effectiveTp2, vm::setTp2, ApexBull)
            PriceField("Take profit 3", ui.effectiveTp3, vm::setTp3, ApexBull)
        }
    }
}

@Composable
private fun PriceField(
    label: String,
    value: Double,
    onChange: (Double?) -> Unit,
    color: androidx.compose.ui.graphics.Color
) {
    var text by remember(value) { mutableStateOf("%.6f".format(value)) }
    OutlinedTextField(
        value = text,
        onValueChange = {
            text = it
            onChange(it.toDoubleOrNull())
        },
        label = { Text(label, color = color) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)
    )
}

@Composable
private fun SummaryCard(ui: TradeUiState) {
    ApexCard {
        Column {
            Text("Order summary", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(6.dp))
            KeyValueRow("Notional", "%.2f USDT".format(ui.notional))
            KeyValueRow("Quantity", "%.6f".format(ui.quantity))
            KeyValueRow("Entry (mark)", "%.6f".format(ui.entryPrice))
            KeyValueRow("Risk if SL", "%.2f USDT".format(ui.riskUsdt), valueColor = ApexBear)
            ui.rules?.let {
                KeyValueRow("Tick / step", "${it.tickSize} / ${it.stepSize}")
                KeyValueRow("Min notional", "${it.minNotional}")
            }
        }
    }
}
