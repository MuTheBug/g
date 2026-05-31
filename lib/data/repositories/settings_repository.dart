import 'package:shared_preferences/shared_preferences.dart';

/// Persistent app settings — slimmed to ONLY the fields that apply to the
/// single shipped strategy (EMA Stack Trend, daily). Removed: TF pickers
/// (the strategy is hardcoded daily — exposing TFs caused stale saved
/// values to silently override the new defaults), strategy id (one
/// strategy), scanner/auto-trade min-confidence (every EMA-stack signal
/// scores 100), validated-symbols whitelist (sweep feature is gone), and
/// the TP-based SL ratchet (this strategy has no fixed TPs).
class AppSettings {
  const AppSettings({
    this.scanLimit = 50,
    this.defaultLeverage = 5,
    this.isolatedMargin = true,
    this.autoAttachSlTp = true,
    this.backgroundScanEnabled = false,
    // Daily strategy: re-scanning every 60 min is plenty (the bars only
    // close once a day).
    this.backgroundScanIntervalMin = 60,
    this.excludedSymbols = const <String>{},
    this.biometricLockEnabled = true,
    this.autoTradeEnabled = false,
    this.autoTradeMaxOpenPositions = 10,
    // Used for fixed-margin sizing AND as the unit for the slot ramp
    // thresholds (8 x / 15 x margin).
    this.autoTradeMarginUsdt = 10,
    this.riskBasedSizing = true,
    this.autoTradeRiskPct = 1.0,
    this.slotRampEnabled = true,
  });

  final int scanLimit;
  final int defaultLeverage;
  final bool isolatedMargin;
  final bool autoAttachSlTp;
  final bool backgroundScanEnabled;
  final int backgroundScanIntervalMin;
  final Set<String> excludedSymbols;
  final bool biometricLockEnabled;

  final bool autoTradeEnabled;
  final int autoTradeMaxOpenPositions;

  /// Fixed margin per trade (USDT). Used when [riskBasedSizing] is off,
  /// and as the unit for the slot-ramp thresholds (8 x / 15 x).
  final double autoTradeMarginUsdt;

  /// When true, size each trade so a stop-out loses [autoTradeRiskPct] %
  /// of account equity: qty = (riskPct% * equity) / |entry - stopLoss|.
  final bool riskBasedSizing;
  final double autoTradeRiskPct;

  /// Equity-aware slot cap (variant I from the portfolio backtest):
  /// 2 slots until equity > 8 x margin, 3 until 15 x margin, then the
  /// user max. Stops a small account being over-leveraged early.
  final bool slotRampEnabled;

  AppSettings copyWith({
    int? scanLimit,
    int? defaultLeverage,
    bool? isolatedMargin,
    bool? autoAttachSlTp,
    bool? backgroundScanEnabled,
    int? backgroundScanIntervalMin,
    Set<String>? excludedSymbols,
    bool? biometricLockEnabled,
    bool? autoTradeEnabled,
    int? autoTradeMaxOpenPositions,
    double? autoTradeMarginUsdt,
    bool? riskBasedSizing,
    double? autoTradeRiskPct,
    bool? slotRampEnabled,
  }) =>
      AppSettings(
        scanLimit: scanLimit ?? this.scanLimit,
        defaultLeverage: defaultLeverage ?? this.defaultLeverage,
        isolatedMargin: isolatedMargin ?? this.isolatedMargin,
        autoAttachSlTp: autoAttachSlTp ?? this.autoAttachSlTp,
        backgroundScanEnabled: backgroundScanEnabled ?? this.backgroundScanEnabled,
        backgroundScanIntervalMin:
            backgroundScanIntervalMin ?? this.backgroundScanIntervalMin,
        excludedSymbols: excludedSymbols ?? this.excludedSymbols,
        biometricLockEnabled: biometricLockEnabled ?? this.biometricLockEnabled,
        autoTradeEnabled: autoTradeEnabled ?? this.autoTradeEnabled,
        autoTradeMaxOpenPositions:
            autoTradeMaxOpenPositions ?? this.autoTradeMaxOpenPositions,
        autoTradeMarginUsdt: autoTradeMarginUsdt ?? this.autoTradeMarginUsdt,
        riskBasedSizing: riskBasedSizing ?? this.riskBasedSizing,
        autoTradeRiskPct: autoTradeRiskPct ?? this.autoTradeRiskPct,
        slotRampEnabled: slotRampEnabled ?? this.slotRampEnabled,
      );
}

class SettingsRepository {
  SettingsRepository._();
  static final SettingsRepository instance = SettingsRepository._();

  static const _kScanLimit = 'scanLimit';
  static const _kDefaultLeverage = 'defaultLeverage';
  static const _kIsolated = 'isolatedMargin';
  static const _kAutoAttach = 'autoAttachSlTp';
  static const _kBgEnabled = 'backgroundScanEnabled';
  static const _kBgInterval = 'backgroundScanIntervalMin';
  static const _kExcluded = 'excludedSymbols';
  static const _kBiometric = 'biometricLockEnabled';
  static const _kAtEnabled = 'autoTradeEnabled';
  static const _kAtMax = 'autoTradeMaxOpenPositions';
  static const _kAtMargin = 'autoTradeMarginUsdt';
  static const _kAtRiskBased = 'riskBasedSizing';
  static const _kAtRiskPct = 'autoTradeRiskPct';
  static const _kAtSlotRamp = 'slotRampEnabled';

  Future<SharedPreferences> get _prefs async => SharedPreferences.getInstance();

  Future<AppSettings> load() async {
    try {
      final p = await _prefs;
      return AppSettings(
        scanLimit: p.getInt(_kScanLimit) ?? 50,
        defaultLeverage: p.getInt(_kDefaultLeverage) ?? 5,
        isolatedMargin: p.getBool(_kIsolated) ?? true,
        autoAttachSlTp: p.getBool(_kAutoAttach) ?? true,
        backgroundScanEnabled: p.getBool(_kBgEnabled) ?? false,
        backgroundScanIntervalMin: p.getInt(_kBgInterval) ?? 60,
        excludedSymbols:
            (p.getStringList(_kExcluded) ?? const <String>[]).toSet(),
        biometricLockEnabled: p.getBool(_kBiometric) ?? true,
        autoTradeEnabled: p.getBool(_kAtEnabled) ?? false,
        autoTradeMaxOpenPositions: p.getInt(_kAtMax) ?? 10,
        autoTradeMarginUsdt: p.getDouble(_kAtMargin) ?? 10,
        riskBasedSizing: p.getBool(_kAtRiskBased) ?? true,
        autoTradeRiskPct: p.getDouble(_kAtRiskPct) ?? 1.0,
        slotRampEnabled: p.getBool(_kAtSlotRamp) ?? true,
      );
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings s) async {
    try {
      final p = await _prefs;
      await Future.wait<void>([
        p.setInt(_kScanLimit, s.scanLimit),
        p.setInt(_kDefaultLeverage, s.defaultLeverage),
        p.setBool(_kIsolated, s.isolatedMargin),
        p.setBool(_kAutoAttach, s.autoAttachSlTp),
        p.setBool(_kBgEnabled, s.backgroundScanEnabled),
        p.setInt(_kBgInterval, s.backgroundScanIntervalMin),
        p.setStringList(_kExcluded, s.excludedSymbols.toList()),
        p.setBool(_kBiometric, s.biometricLockEnabled),
        p.setBool(_kAtEnabled, s.autoTradeEnabled),
        p.setInt(_kAtMax, s.autoTradeMaxOpenPositions),
        p.setDouble(_kAtMargin, s.autoTradeMarginUsdt),
        p.setBool(_kAtRiskBased, s.riskBasedSizing),
        p.setDouble(_kAtRiskPct, s.autoTradeRiskPct),
        p.setBool(_kAtSlotRamp, s.slotRampEnabled),
      ]);
    } catch (_) {/* tolerate disk failure */}
  }
}
