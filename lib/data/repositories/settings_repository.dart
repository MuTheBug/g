import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  const AppSettings({
    this.scanLimit = 30,
    this.minConfidence = 70,
    this.defaultLeverage = 5,
    this.isolatedMargin = true,
    this.autoAttachSlTp = true,
    this.backgroundScanEnabled = false,
    this.backgroundScanIntervalMin = 15,
    this.excludedSymbols = const <String>{},
    this.watchlist = const <String>{},
    this.biometricLockEnabled = true,
    this.htfTimeframe = '4h',
    this.mtfTimeframe = '1h',
    this.ltfTimeframe = '15m',
    this.autoTradeEnabled = false,
    this.autoTradeMaxOpenPositions = 3,
    this.autoTradeMarginUsdt = 10,
    this.autoTradeMinConfidence = 80,
  });

  final int scanLimit;
  final int minConfidence;
  final int defaultLeverage;
  final bool isolatedMargin;
  final bool autoAttachSlTp;
  final bool backgroundScanEnabled;
  final int backgroundScanIntervalMin;
  final Set<String> excludedSymbols;
  final Set<String> watchlist;
  final bool biometricLockEnabled;
  final String htfTimeframe;
  final String mtfTimeframe;
  final String ltfTimeframe;

  // Auto-trade
  final bool autoTradeEnabled;
  final int autoTradeMaxOpenPositions;
  final double autoTradeMarginUsdt;
  final int autoTradeMinConfidence;

  AppSettings copyWith({
    int? scanLimit,
    int? minConfidence,
    int? defaultLeverage,
    bool? isolatedMargin,
    bool? autoAttachSlTp,
    bool? backgroundScanEnabled,
    int? backgroundScanIntervalMin,
    Set<String>? excludedSymbols,
    Set<String>? watchlist,
    bool? biometricLockEnabled,
    String? htfTimeframe,
    String? mtfTimeframe,
    String? ltfTimeframe,
    bool? autoTradeEnabled,
    int? autoTradeMaxOpenPositions,
    double? autoTradeMarginUsdt,
    int? autoTradeMinConfidence,
  }) =>
      AppSettings(
        scanLimit: scanLimit ?? this.scanLimit,
        minConfidence: minConfidence ?? this.minConfidence,
        defaultLeverage: defaultLeverage ?? this.defaultLeverage,
        isolatedMargin: isolatedMargin ?? this.isolatedMargin,
        autoAttachSlTp: autoAttachSlTp ?? this.autoAttachSlTp,
        backgroundScanEnabled: backgroundScanEnabled ?? this.backgroundScanEnabled,
        backgroundScanIntervalMin: backgroundScanIntervalMin ?? this.backgroundScanIntervalMin,
        excludedSymbols: excludedSymbols ?? this.excludedSymbols,
        watchlist: watchlist ?? this.watchlist,
        biometricLockEnabled: biometricLockEnabled ?? this.biometricLockEnabled,
        htfTimeframe: htfTimeframe ?? this.htfTimeframe,
        mtfTimeframe: mtfTimeframe ?? this.mtfTimeframe,
        ltfTimeframe: ltfTimeframe ?? this.ltfTimeframe,
        autoTradeEnabled: autoTradeEnabled ?? this.autoTradeEnabled,
        autoTradeMaxOpenPositions: autoTradeMaxOpenPositions ?? this.autoTradeMaxOpenPositions,
        autoTradeMarginUsdt: autoTradeMarginUsdt ?? this.autoTradeMarginUsdt,
        autoTradeMinConfidence: autoTradeMinConfidence ?? this.autoTradeMinConfidence,
      );
}

class SettingsRepository {
  SettingsRepository._();
  static final SettingsRepository instance = SettingsRepository._();

  static const _kScanLimit = 'scanLimit';
  static const _kMinConfidence = 'minConfidence';
  static const _kDefaultLeverage = 'defaultLeverage';
  static const _kIsolated = 'isolatedMargin';
  static const _kAutoAttach = 'autoAttachSlTp';
  static const _kBgEnabled = 'backgroundScanEnabled';
  static const _kBgInterval = 'backgroundScanIntervalMin';
  static const _kExcluded = 'excludedSymbols';
  static const _kWatchlist = 'watchlist';
  static const _kBiometric = 'biometricLockEnabled';
  static const _kHtf = 'htfTimeframe';
  static const _kMtf = 'mtfTimeframe';
  static const _kLtf = 'ltfTimeframe';
  static const _kAtEnabled = 'autoTradeEnabled';
  static const _kAtMax = 'autoTradeMaxOpenPositions';
  static const _kAtMargin = 'autoTradeMarginUsdt';
  static const _kAtMinConf = 'autoTradeMinConfidence';

  Future<SharedPreferences> get _prefs async => SharedPreferences.getInstance();

  Future<AppSettings> load() async {
    try {
      final p = await _prefs;
      return AppSettings(
        scanLimit: p.getInt(_kScanLimit) ?? 30,
        minConfidence: p.getInt(_kMinConfidence) ?? 70,
        defaultLeverage: p.getInt(_kDefaultLeverage) ?? 5,
        isolatedMargin: p.getBool(_kIsolated) ?? true,
        autoAttachSlTp: p.getBool(_kAutoAttach) ?? true,
        backgroundScanEnabled: p.getBool(_kBgEnabled) ?? false,
        backgroundScanIntervalMin: p.getInt(_kBgInterval) ?? 15,
        excludedSymbols: (p.getStringList(_kExcluded) ?? const <String>[]).toSet(),
        watchlist: (p.getStringList(_kWatchlist) ?? const <String>[]).toSet(),
        biometricLockEnabled: p.getBool(_kBiometric) ?? true,
        htfTimeframe: p.getString(_kHtf) ?? '4h',
        mtfTimeframe: p.getString(_kMtf) ?? '1h',
        ltfTimeframe: p.getString(_kLtf) ?? '15m',
        autoTradeEnabled: p.getBool(_kAtEnabled) ?? false,
        autoTradeMaxOpenPositions: p.getInt(_kAtMax) ?? 3,
        autoTradeMarginUsdt: p.getDouble(_kAtMargin) ?? 10,
        autoTradeMinConfidence: p.getInt(_kAtMinConf) ?? 80,
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
        p.setInt(_kMinConfidence, s.minConfidence),
        p.setInt(_kDefaultLeverage, s.defaultLeverage),
        p.setBool(_kIsolated, s.isolatedMargin),
        p.setBool(_kAutoAttach, s.autoAttachSlTp),
        p.setBool(_kBgEnabled, s.backgroundScanEnabled),
        p.setInt(_kBgInterval, s.backgroundScanIntervalMin),
        p.setStringList(_kExcluded, s.excludedSymbols.toList()),
        p.setStringList(_kWatchlist, s.watchlist.toList()),
        p.setBool(_kBiometric, s.biometricLockEnabled),
        p.setString(_kHtf, s.htfTimeframe),
        p.setString(_kMtf, s.mtfTimeframe),
        p.setString(_kLtf, s.ltfTimeframe),
        p.setBool(_kAtEnabled, s.autoTradeEnabled),
        p.setInt(_kAtMax, s.autoTradeMaxOpenPositions),
        p.setDouble(_kAtMargin, s.autoTradeMarginUsdt),
        p.setInt(_kAtMinConf, s.autoTradeMinConfidence),
      ]);
    } catch (_) {/* tolerate disk failure */}
  }
}
