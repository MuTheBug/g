import 'package:apex_trader/data/models/symbol_rules.dart';
import 'package:apex_trader/domain/bracket_math.dart';
import 'package:apex_trader/domain/strategy.dart';
import 'package:flutter_test/flutter_test.dart';

SymbolRules _rules({double tick = 0.01, int pp = 2}) => SymbolRules(
      symbol: 'TESTUSDT',
      tickSize: tick,
      stepSize: 0.001,
      minQty: 0.001,
      minNotional: 5,
      pricePrecision: pp,
      quantityPrecision: 3,
    );

void main() {
  group('reanchorStop preserves risk distance on the fill side', () {
    test('long: stop sits one risk-distance below the fill', () {
      final s = BracketMath.reanchorStop(
        side: SignalSide.long,
        referencePrice: 100,
        stopPrice: 95, // 5 below the signal entry
        fillPrice: 104, // filled higher than the signal close
      );
      expect(s, closeTo(99, 1e-9)); // 104 - 5
      expect(s, lessThan(104)); // strictly below the fill
    });

    test('short: stop sits one risk-distance above the fill', () {
      final s = BracketMath.reanchorStop(
        side: SignalSide.short,
        referencePrice: 100,
        stopPrice: 105, // 5 above the signal entry
        fillPrice: 96, // filled lower than the signal close
      );
      expect(s, closeTo(101, 1e-9)); // 96 + 5
      expect(s, greaterThan(96)); // strictly above the fill
    });

    test('unusable inputs return null', () {
      expect(
        BracketMath.reanchorStop(
            side: SignalSide.long,
            referencePrice: 0,
            stopPrice: 95,
            fillPrice: 100),
        isNull,
      );
    });
  });

  group('reanchorTp preserves target distance on the fill side', () {
    test('long target stays above the fill', () {
      final tp = BracketMath.reanchorTp(
        side: SignalSide.long,
        referencePrice: 100,
        tp: 103,
        fillPrice: 104,
      );
      expect(tp, closeTo(107, 1e-9)); // 104 + 3
    });

    test('short target stays below the fill', () {
      final tp = BracketMath.reanchorTp(
        side: SignalSide.short,
        referencePrice: 100,
        tp: 97,
        fillPrice: 96,
      );
      expect(tp, closeTo(93, 1e-9)); // 96 - 3
    });
  });

  group('safeTriggerOnSide keeps stops off the wrong side of mark', () {
    final rules = _rules();

    test('long SL already below mark is left (floored to tick)', () {
      final s = BracketMath.safeTriggerOnSide(
        side: SignalSide.long,
        isStopLoss: true,
        mark: 100,
        desired: 95,
        rules: rules,
      );
      expect(s, isNotNull);
      expect(s!, lessThan(100));
      expect(s, closeTo(95, 1e-9));
    });

    test('long SL above mark (the bug) is clamped strictly below mark', () {
      final s = BracketMath.safeTriggerOnSide(
        side: SignalSide.long,
        isStopLoss: true,
        mark: 100,
        desired: 101, // would trigger immediately
        rules: rules,
      );
      expect(s, isNotNull);
      expect(s!, lessThan(100),
          reason: 'a long SL must sit below mark or it triggers instantly');
    });

    test('short SL below mark (the bug) is clamped strictly above mark', () {
      final s = BracketMath.safeTriggerOnSide(
        side: SignalSide.short,
        isStopLoss: true,
        mark: 100,
        desired: 99, // would trigger immediately
        rules: rules,
      );
      expect(s, isNotNull);
      expect(s!, greaterThan(100),
          reason: 'a short SL must sit above mark or it triggers instantly');
    });

    test('invariant holds across a sweep of desired prices', () {
      const mark = 100.0;
      for (var d = 90; d <= 110; d++) {
        final long = BracketMath.safeTriggerOnSide(
          side: SignalSide.long,
          isStopLoss: true,
          mark: mark,
          desired: d.toDouble(),
          rules: rules,
        );
        final short = BracketMath.safeTriggerOnSide(
          side: SignalSide.short,
          isStopLoss: true,
          mark: mark,
          desired: d.toDouble(),
          rules: rules,
        );
        expect(long!, lessThan(mark), reason: 'long SL @ desired=$d');
        expect(short!, greaterThan(mark), reason: 'short SL @ desired=$d');
      }
    });

    test('result is aligned to the symbol tick size', () {
      final coarse = _rules(tick: 0.5, pp: 1);
      final s = BracketMath.safeTriggerOnSide(
        side: SignalSide.long,
        isStopLoss: true,
        mark: 100,
        desired: 101,
        rules: coarse,
      );
      // floor to a 0.5 grid → integer or .5
      final twice = (s! * 2);
      expect((twice - twice.roundToDouble()).abs(), lessThan(1e-6));
    });

    test('mark unknown (0) leaves the desired level rounded, never null', () {
      final s = BracketMath.safeTriggerOnSide(
        side: SignalSide.long,
        isStopLoss: true,
        mark: 0,
        desired: 95,
        rules: rules,
      );
      expect(s, closeTo(95, 1e-9));
    });
  });

  group('take-profit side rules', () {
    test('long TP must be above mark, short TP below', () {
      expect(BracketMath.stopMustBeBelow(SignalSide.long, false), isFalse);
      expect(BracketMath.stopMustBeBelow(SignalSide.short, false), isTrue);
    });

    test('long SL must be below mark, short SL above', () {
      expect(BracketMath.stopMustBeBelow(SignalSide.long, true), isTrue);
      expect(BracketMath.stopMustBeBelow(SignalSide.short, true), isFalse);
    });
  });
}
