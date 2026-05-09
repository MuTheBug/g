package com.apex.trader.presentation.component

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.apex.trader.presentation.theme.ApexBear
import com.apex.trader.presentation.theme.ApexBull
import com.apex.trader.presentation.theme.ApexHighlight
import com.apex.trader.presentation.theme.ApexNeutral
import com.apex.trader.presentation.theme.ApexSurfaceVariant
import com.apex.trader.presentation.theme.ApexTextMuted

@Composable
fun ApexCard(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Box(modifier = Modifier.padding(14.dp)) { content() }
    }
}

@Composable
fun ConfidenceBadge(score: Int, modifier: Modifier = Modifier) {
    val color = when {
        score >= 85 -> ApexBull
        score >= 75 -> ApexHighlight
        score >= 60 -> ApexNeutral
        else -> ApexBear
    }
    Box(
        modifier = modifier
            .background(color.copy(alpha = 0.18f), RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp)
    ) {
        Text(
            text = "$score%",
            color = color,
            style = MaterialTheme.typography.labelLarge
        )
    }
}

@Composable
fun SidePill(side: String, modifier: Modifier = Modifier) {
    val color = if (side.equals("LONG", true) || side == "BUY") ApexBull else ApexBear
    Box(
        modifier = modifier
            .background(color.copy(alpha = 0.18f), RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 4.dp)
    ) {
        Text(text = side, color = color, style = MaterialTheme.typography.labelLarge)
    }
}

@Composable
fun KeyValueRow(label: String, value: String, valueColor: Color = MaterialTheme.colorScheme.onSurface) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = label,
            modifier = Modifier.weight(1f),
            color = ApexTextMuted,
            style = MaterialTheme.typography.bodyMedium
        )
        Text(
            text = value,
            color = valueColor,
            style = MaterialTheme.typography.labelMedium
        )
    }
}

@Composable
fun SectionHeader(title: String) {
    Column {
        Text(
            text = title.uppercase(),
            color = ApexTextMuted,
            style = MaterialTheme.typography.labelSmall
        )
        Spacer(Modifier.padding(top = 4.dp))
    }
}

@Composable
fun Stat(label: String, value: String, color: Color = MaterialTheme.colorScheme.onSurface) {
    Column(
        modifier = Modifier
            .background(ApexSurfaceVariant, RoundedCornerShape(10.dp))
            .padding(horizontal = 10.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.Start,
        verticalArrangement = Arrangement.Center
    ) {
        Text(label, color = ApexTextMuted, style = MaterialTheme.typography.labelSmall, textAlign = TextAlign.Start)
        Text(value, color = color, style = MaterialTheme.typography.titleMedium)
    }
}

@Composable
fun HSpacer(width: androidx.compose.ui.unit.Dp) = Spacer(Modifier.width(width))
