import 'dart:math';
import '../diagnostics/app_logger.dart';
import '../diagnostics/metrics_service.dart';
import 'battery_state_service.dart';

class NetworkActivityContext {
  final int activePeerCount;
  final int pendingOutboxCount;
  final bool hasRecentRouteChanges;
  final bool hasActiveForegroundChat;

  const NetworkActivityContext({
    required this.activePeerCount,
    required this.pendingOutboxCount,
    required this.hasRecentRouteChanges,
    required this.hasActiveForegroundChat,
  });
}

class SyncPolicyDecision {
  final Duration interval;
  final String reason;
  final bool isSyncPaused;

  const SyncPolicyDecision({
    required this.interval,
    required this.reason,
    this.isSyncPaused = false,
  });
}

/// Adaptive Sync Policy Engine determining periodic routing table sync intervals
/// based on battery status, network activity, and active chat engagement.
class SyncPolicyEngine {
  final Random _random;

  SyncPolicyEngine({Random? random}) : _random = random ?? Random();

  SyncPolicyDecision evaluatePolicy({
    required BatteryState battery,
    required NetworkActivityContext activity,
  }) {
    // 1. Critical Battery (<= 5% & Discharging): Pause non-essential background sync
    if (battery.isCritical && !activity.hasActiveForegroundChat && activity.pendingOutboxCount == 0) {
      const decision = SyncPolicyDecision(
        interval: Duration(seconds: 600),
        reason: 'Critical battery (<= 5%). Paused non-essential background sync.',
        isSyncPaused: true,
      );
      _logDecision(decision);
      return decision;
    }

    // 2. Active Chat / Pending Outbox Boost: 15s interval
    if (activity.hasActiveForegroundChat || activity.pendingOutboxCount > 0) {
      final decision = _applyJitter(
        baseSeconds: 15,
        reason: 'Boosted: Active foreground chat or pending outbox packets (${activity.pendingOutboxCount}).',
      );
      _logDecision(decision);
      return decision;
    }

    // 3. Charging + Active Routing Table Changes: 15s interval
    if (battery.isCharging && activity.hasRecentRouteChanges) {
      final decision = _applyJitter(
        baseSeconds: 15,
        reason: 'Charging with active routing table changes.',
      );
      _logDecision(decision);
      return decision;
    }

    // 4. Charging (Idle): 30s interval
    if (battery.isCharging) {
      final decision = _applyJitter(
        baseSeconds: 30,
        reason: 'Charging (device connected to power source).',
      );
      _logDecision(decision);
      return decision;
    }

    // 5. Low Battery (<= 20%): 300s (5 min) interval
    if (battery.isLow || battery.isLowPowerMode) {
      final decision = _applyJitter(
        baseSeconds: 300,
        reason: 'Low battery (<= 20%) or OS Battery Saver mode active.',
      );
      _logDecision(decision);
      return decision;
    }

    // 6. Normal Battery + Active Peers: 60s interval
    if (activity.activePeerCount > 0) {
      final decision = _applyJitter(
        baseSeconds: 60,
        reason: 'Normal battery (> 20%) with ${activity.activePeerCount} active connected peer(s).',
      );
      _logDecision(decision);
      return decision;
    }

    // 7. Normal Battery + Idle (No connected peers): 120s interval
    final decision = _applyJitter(
      baseSeconds: 120,
      reason: 'Normal battery (> 20%) in idle mesh state.',
    );
    _logDecision(decision);
    return decision;
  }

  SyncPolicyDecision _applyJitter({required int baseSeconds, required String reason}) {
    final jitterPercent = (_random.nextDouble() * 0.20) - 0.10; // -10% to +10%
    final jitteredSeconds = (baseSeconds * (1.0 + jitterPercent)).round().clamp(10, 600);
    return SyncPolicyDecision(
      interval: Duration(seconds: jitteredSeconds),
      reason: '$reason (base: ${baseSeconds}s, jittered: ${jitteredSeconds}s)',
    );
  }

  void _logDecision(SyncPolicyDecision decision) {
    AppLogger.info('Adaptive Sync Policy: ${decision.reason}', domain: LogDomain.battery);
    MetricsService.instance.setGauge('adaptive_sync_interval_seconds', decision.interval.inSeconds.toDouble());
  }
}
