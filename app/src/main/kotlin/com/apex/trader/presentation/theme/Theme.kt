package com.apex.trader.presentation.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

private val ApexDarkScheme = darkColorScheme(
    primary = ApexPrimary,
    onPrimary = ApexOnPrimary,
    primaryContainer = ApexPrimaryDim,
    secondary = ApexHighlight,
    background = ApexBackground,
    onBackground = ApexText,
    surface = ApexSurface,
    onSurface = ApexText,
    surfaceVariant = ApexSurfaceVariant,
    onSurfaceVariant = ApexTextMuted,
    outline = ApexOutline,
    error = ApexBear
)

@Composable
fun ApexTheme(
    @Suppress("UNUSED_PARAMETER") darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    // Trading apps default to dark — full dark always.
    MaterialTheme(
        colorScheme = ApexDarkScheme,
        typography = ApexTypography,
        content = content
    )
}
