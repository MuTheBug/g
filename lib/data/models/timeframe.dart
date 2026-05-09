enum Timeframe {
  m1('1m', 60 * 1000),
  m5('5m', 5 * 60 * 1000),
  m15('15m', 15 * 60 * 1000),
  m30('30m', 30 * 60 * 1000),
  h1('1h', 60 * 60 * 1000),
  h4('4h', 4 * 60 * 60 * 1000),
  d1('1d', 24 * 60 * 60 * 1000);

  const Timeframe(this.code, this.millis);
  final String code;
  final int millis;

  static Timeframe fromCode(String code) =>
      Timeframe.values.firstWhere((t) => t.code == code, orElse: () => Timeframe.m15);
}
