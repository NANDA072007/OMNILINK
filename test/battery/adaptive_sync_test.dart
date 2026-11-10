import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilink/core/battery/battery_state_service.dart';
import 'package:omnilink/core/battery/sync_policy_engine.dart';
import 'package:omnilink/core/diagnostics/metrics_service.dart';

class DeterministicRandom implements Random {
  @override
  double nextDouble() => 0.5; // Always 0.5 -> 0.0% jitter for deterministic test comparisons

  @override
  bool nextBool() => true;

  @override
  int nextInt(int max) => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Adaptive Periodic Sync Policy Engine Tests', () {
    late SyncPolicyEngine engine;

    setUp(() {
      engine = SyncPolicyEngine(random: DeterministicRandom());
      MetricsService.instance.clear();
    });

    test('charging + active route changes yields 15s interval', () {
      const battery = BatteryState(
        levelPercent: 50,
        chargingStatus: BatteryChargingStatus.charging,
        isLowPowerMode: false,
      );

      const activity = NetworkActivityContext(
        activePeerCount: 1,
        pendingOutboxCount: 0,
        hasRecentRouteChanges: true,
        hasActiveForegroundChat: false,
      );

      final decision = engine.evaluatePolicy(battery: battery, activity: activity);
      expect(decision.interval.inSeconds, equals(15));
      expect(decision.isSyncPaused, isFalse);
    });

    test('normal battery + active peers yields 60s interval', () {
      const battery = BatteryState(
        levelPercent: 80,
        chargingStatus: BatteryChargingStatus.discharging,
        isLowPowerMode: false,
      );

      const activity = NetworkActivityContext(
        activePeerCount: 2,
        pendingOutboxCount: 0,
        hasRecentRouteChanges: false,
        hasActiveForegroundChat: false,
      );

      final decision = engine.evaluatePolicy(battery: battery, activity: activity);
      expect(decision.interval.inSeconds, equals(60));
    });

    test('low battery (<= 20%) yields 300s interval', () {
      const battery = BatteryState(
        levelPercent: 15,
        chargingStatus: BatteryChargingStatus.discharging,
        isLowPowerMode: false,
      );

      const activity = NetworkActivityContext(
        activePeerCount: 1,
        pendingOutboxCount: 0,
        hasRecentRouteChanges: false,
        hasActiveForegroundChat: false,
      );

      final decision = engine.evaluatePolicy(battery: battery, activity: activity);
      expect(decision.interval.inSeconds, equals(300));
    });

    test('idle + normal battery yields 120s reduced frequency interval', () {
      const battery = BatteryState(
        levelPercent: 75,
        chargingStatus: BatteryChargingStatus.discharging,
        isLowPowerMode: false,
      );

      const activity = NetworkActivityContext(
        activePeerCount: 0,
        pendingOutboxCount: 0,
        hasRecentRouteChanges: false,
        hasActiveForegroundChat: false,
      );

      final decision = engine.evaluatePolicy(battery: battery, activity: activity);
      expect(decision.interval.inSeconds, equals(120));
    });

    test('active peer chat or outbox pending boosts interval to 15s', () {
      const battery = BatteryState(
        levelPercent: 10,
        chargingStatus: BatteryChargingStatus.discharging,
        isLowPowerMode: false,
      );

      const activity = NetworkActivityContext(
        activePeerCount: 1,
        pendingOutboxCount: 3,
        hasRecentRouteChanges: false,
        hasActiveForegroundChat: true,
      );

      final decision = engine.evaluatePolicy(battery: battery, activity: activity);
      expect(decision.interval.inSeconds, equals(15));
    });

    test('critical battery (<= 5%) without active chat pauses non-essential sync', () {
      const battery = BatteryState(
        levelPercent: 3,
        chargingStatus: BatteryChargingStatus.discharging,
        isLowPowerMode: true,
      );

      const activity = NetworkActivityContext(
        activePeerCount: 0,
        pendingOutboxCount: 0,
        hasRecentRouteChanges: false,
        hasActiveForegroundChat: false,
      );

      final decision = engine.evaluatePolicy(battery: battery, activity: activity);
      expect(decision.isSyncPaused, isTrue);
    });
  });
}
