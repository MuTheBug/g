package com.apex.trader.presentation.screen.positions

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
import com.apex.trader.data.api.dto.PositionDto
import com.apex.trader.presentation.component.ApexCard
import com.apex.trader.presentation.component.KeyValueRow
import com.apex.trader.presentation.component.SidePill
import com.apex.trader.presentation.theme.ApexBear
import com.apex.trader.presentation.theme.ApexBull
import com.apex.trader.presentation.theme.ApexTextMuted

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PositionsScreen(
    onBack: () -> Unit,
    vm: PositionsViewModel = hiltViewModel()
) {
    val ui by vm.ui.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Positions & Account") },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
                },
                actions = {
                    IconButton(onClick = { vm.refresh() }) { Icon(Icons.Default.Refresh, "Refresh") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)
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
            contentPadding = PaddingValues(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            ui.account?.let { acc ->
                item {
                    ApexCard {
                        Column {
                            Text("Account", style = MaterialTheme.typography.titleMedium)
                            Spacer(Modifier.height(6.dp))
                            KeyValueRow("Wallet balance", "${acc.totalWalletBalance} USDT")
                            KeyValueRow("Margin balance", "${acc.totalMarginBalance} USDT")
                            KeyValueRow("Available", "${acc.availableBalance} USDT")
                            KeyValueRow(
                                "Unrealized PnL",
                                "${acc.totalUnrealizedProfit} USDT",
                                valueColor = if ((acc.totalUnrealizedProfit.toDoubleOrNull() ?: 0.0) >= 0) ApexBull else ApexBear
                            )
                        }
                    }
                }
            }
            if (ui.positions.isEmpty()) {
                item {
                    ApexCard {
                        Text("No open positions", color = ApexTextMuted)
                    }
                }
            } else {
                items(ui.positions, key = { it.symbol + it.positionSide }) { pos ->
                    PositionCard(pos, working = ui.workingSymbol == pos.symbol, onClose = {
                        vm.closePosition(pos.symbol, pos.positionAmt.toDoubleOrNull() ?: 0.0)
                    })
                }
            }
            ui.error?.let {
                item {
                    Text("⚠ $it", color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}

@Composable
private fun PositionCard(pos: PositionDto, working: Boolean, onClose: () -> Unit) {
    val amt = pos.positionAmt.toDoubleOrNull() ?: 0.0
    val pnl = pos.pnl.toDoubleOrNull() ?: 0.0
    ApexCard {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(pos.symbol, style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.padding(end = 8.dp))
                SidePill(if (amt >= 0) "LONG" else "SHORT")
                Spacer(Modifier.weight(1f))
                Text(
                    "${pos.leverage}x",
                    color = ApexTextMuted,
                    style = MaterialTheme.typography.labelMedium
                )
            }
            Spacer(Modifier.height(6.dp))
            KeyValueRow("Quantity", "%.6f".format(amt))
            KeyValueRow("Entry", pos.entryPrice)
            pos.markPrice?.let { KeyValueRow("Mark", it) }
            pos.liquidationPrice?.let { KeyValueRow("Liquidation", it, valueColor = ApexBear) }
            KeyValueRow(
                "Unrealized PnL",
                "%.4f USDT".format(pnl),
                valueColor = if (pnl >= 0) ApexBull else ApexBear
            )
            Spacer(Modifier.height(8.dp))
            Button(
                onClick = onClose,
                enabled = !working,
                modifier = Modifier.fillMaxWidth()
            ) { Text(if (working) "Closing…" else "Close at market") }
        }
    }
}
