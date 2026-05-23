import 'package:shared_preferences/shared_preferences.dart';

enum TradingMode { live, paper }

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
    this.tradingMode = TradingMode.live,
    this.paperStartingBalance = 10000,
    this.validatedSymbols = const <String>{},
    this.validatedSymbolsEnabled = false,
    this.lockInProfits = true,
    this.moveToBeAfterTp1 = true,
    this.moveToTp1AfterTp2 = true,
    this.strategyId = 'pullback',
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

  // Mode + paper account
  final TradingMode tradingMode;
  final double paperStartingBalance;

  // Multi-symbol-backtest-driven whitelist. When [validatedSymbolsEnabled]
  // is true and the set is non-empty, the scanner + auto-trader skip any
  // symbol outside the set.
  final Set<String> validatedSymbols;
  final bool validatedSymbolsEnabled;

  /// Master toggle for the SL ratchet. When off, the stop-manager is a
  /// no-op even if [moveToBeAfterTp1] / [moveToTp1AfterTp2] are on.
  final bool lockInProfits;
  final bool moveToBeAfterTp1;
  final bool moveToTp1AfterTp2;

  /// One of: 'apex' (the original 11-factor confluence) or 'pullback' (the
  /// newer trend-pullback strategy). Default is 'pullback' because ACS has
  /// been bleeding equity on this account.
  final String strategyId;

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
    TradingMode? tradingMode,
    double? paperStartingBalance,
    Set<String>? validatedSymbols,
    bool? validatedSymbolsEnabled,
    bool? lockInProfits,
    bool? moveToBeAfterTp1,
    bool? moveToTp1AfterTp2,
    String? strategyId,
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
        tradingMode: tradingMode ?? this.tradingMode,
        paperStartingBalance: paperStartingBalance ?? this.paperStartingBalance,
        validatedSymbols: validatedSymbols ?? this.validatedSymbols,
        validatedSymbolsEnabled:
            validatedSymbolsEnabled ?? this.validatedSymbolsEnabled,
        lockInProfits: lockInProfits ?? this.lockInProfits,
        moveToBeAfterTp1: moveToBeAfterTp1 ?? this.moveToBeAfterTp1,
        moveToTp1AfterTp2: moveToTp1AfterTp2 ?? this.moveToTp1AfterTp2,
        strategyId: strategyId ?? this.strategyId,
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
  static const _kTradingMode = 'tradingMode';
  static const _kPaperBal = 'paperStartingBalance';
  static const _kValidated = 'validatedSymbols';
  static const _kValidatedOn = 'validatedSymbolsEnabled';
  static const _kLockProfits = 'lockInProfits';
  static const _kBeAfterTp1 = 'moveToBeAfterTp1';
  static const _kTp1AfterTp2 = 'moveToTp1AfterTp2';
  static const _kStrategyId = 'strategyId';

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
        tradingMode: (p.getString(_kTradingMode) ?? 'live') == 'paper'
            ? TradingMode.paper
            : TradingMode.live,
        paperStartingBalance: p.getDouble(_kPaperBal) ?? 10000,
        validatedSymbols: (p.getStringList(_kValidated) ?? const <String>[])
            .toSet(),
        validatedSymbolsEnabled: p.getBool(_kValidatedOn) ?? false,
        lockInProfits: p.getBool(_kLockProfits) ?? true,
        moveToBeAfterTp1: p.getBool(_kBeAfterTp1) ?? true,
        moveToTp1AfterTp2: p.getBool(_kTp1AfterTp2) ?? true,
        strategyId: p.getString(_kStrategyId) ?? 'pullback',
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
        p.setString(_kTradingMode, s.tradingMode == TradingMode.paper ? 'paper' : 'live'),
        p.setDouble(_kPaperBal, s.paperStartingBalance),
        p.setStringList(_kValidated, s.validatedSymbols.toList()),
        p.setBool(_kValidatedOn, s.validatedSymbolsEnabled),
        p.setBool(_kLockProfits, s.lockInProfits),
        p.setBool(_kBeAfterTp1, s.moveToBeAfterTp1),
        p.setBool(_kTp1AfterTp2, s.moveToTp1AfterTp2),
        p.setString(_kStrategyId, s.strategyId),
      ]);
    } catch (_) {/* tolerate disk failure */}
  }
}
