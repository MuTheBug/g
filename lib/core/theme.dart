import 'package:flutter/material.dart';

class ApexColors {
  ApexColors._();

  // Surfaces
  static const background = Color(0xFF0B0E13);
  static const surface = Color(0xFF131822);
  static const surfaceVariant = Color(0xFF1B2230);
  static const outline = Color(0xFF2A3344);

  // Brand
  static const primary = Color(0xFF7C5CFF);
  static const primaryDim = Color(0xFF5B43D1);
  static const onPrimary = Color(0xFFFFFFFF);

  // Trading
  static const bull = Color(0xFF00C896);
  static const bear = Color(0xFFFF4D6D);
  static const neutral = Color(0xFFB0BAC9);
  static const highlight = Color(0xFFFFC857);

  // Text
  static const text = Color(0xFFE6EAF2);
  static const textMuted = Color(0xFF8A95A8);
}

ThemeData buildApexTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: ApexColors.primary,
    onPrimary: ApexColors.onPrimary,
    primaryContainer: ApexColors.primaryDim,
    onPrimaryContainer: ApexColors.onPrimary,
    secondary: ApexColors.highlight,
    onSecondary: ApexColors.background,
    secondaryContainer: ApexColors.surfaceVariant,
    onSecondaryContainer: ApexColors.text,
    error: ApexColors.bear,
    onError: ApexColors.onPrimary,
    errorContainer: ApexColors.surfaceVariant,
    onErrorContainer: ApexColors.bear,
    surface: ApexColors.surface,
    onSurface: ApexColors.text,
    surfaceContainerHighest: ApexColors.surfaceVariant,
    onSurfaceVariant: ApexColors.textMuted,
    outline: ApexColors.outline,
    outlineVariant: ApexColors.outline,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: ApexColors.text,
    onInverseSurface: ApexColors.background,
    inversePrimary: ApexColors.primaryDim,
    surfaceTint: ApexColors.primary,
  );

  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: ApexColors.background,
    canvasColor: ApexColors.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: ApexColors.background,
      foregroundColor: ApexColors.text,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: ApexColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ApexColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: ApexColors.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: ApexColors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: ApexColors.primary, width: 1.6),
      ),
      labelStyle: const TextStyle(color: ApexColors.textMuted),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: ApexColors.primary,
        foregroundColor: ApexColors.onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ApexColors.text,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        side: const BorderSide(color: ApexColors.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: ApexColors.primary),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? ApexColors.primary : ApexColors.neutral,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? ApexColors.primary.withValues(alpha: 0.4)
            : ApexColors.surfaceVariant,
      ),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: ApexColors.primary,
      inactiveTrackColor: ApexColors.surfaceVariant,
      thumbColor: ApexColors.primary,
      overlayColor: Color(0x337C5CFF),
    ),
    dividerColor: ApexColors.outline,
    dialogTheme: DialogThemeData(
      backgroundColor: ApexColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: ApexColors.text,
      displayColor: ApexColors.text,
    ),
  );
}
