import 'dart:async';
import 'package:flutter/services.dart';
import '../diagnostics/app_logger.dart';
import '../diagnostics/metrics_service.dart';

enum BatteryChargingStatus {
  charging,
  discharging,
  full,
  unknown,
}

class BatteryState {
  final int levelPercent;
  final BatteryChargingStatus chargingStatus;
  final bool isLowPowerMode;

  const BatteryState({
    required this.levelPercent,
    required this.chargingStatus,
    required this.isLowPowerMode,
  });

  bool get isCharging =>
      chargingStatus == BatteryChargingStatus.charging ||
      chargingStatus == BatteryChargingStatus.full;

  bool get isCritical => levelPercent <= 5 && !isCharging;
  bool get isLow => levelPercent <= 20 && !isCharging;

  static const BatteryState defaultNormal = BatteryState(
    levelPercent: 80,
    chargingStatus: BatteryChargingStatus.discharging,
    isLowPowerMode: false,
  );

  @override
  String toString() =>
      'BatteryState(level: $levelPercent%, status: ${chargingStatus.name}, lowPower: $isLowPowerMode)';
}

/// Service providing platform battery level, charging status, and low power mode status.
class BatteryStateService {
  static const MethodChannel _channel = MethodChannel('org.omnilink.mesh/battery');
  final _stateController = StreamController<BatteryState>.broadcast();

  BatteryState _currentState = BatteryState.defaultNormal;
  Timer? _pollingTimer;

  BatteryState get currentState => _currentState;
  Stream<BatteryState> get onBatteryStateChanged => _stateController.stream;

  BatteryStateService() {
    _init();
  }

  void _init() {
    refreshBatteryState();
    _pollingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      refreshBatteryState();
    });
  }

  Future<BatteryState> refreshBatteryState() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('getBatteryState');
      if (map != null) {
        final level = (map['level'] as num?)?.toInt() ?? 80;
        final isCharging = map['isCharging'] == true;
        final isLowPower = map['isLowPowerMode'] == true;

        final status = isCharging
            ? BatteryChargingStatus.charging
            : BatteryChargingStatus.discharging;

        final newState = BatteryState(
          levelPercent: level,
          chargingStatus: status,
          isLowPowerMode: isLowPower,
        );

        if (newState.levelPercent != _currentState.levelPercent ||
            newState.chargingStatus != _currentState.chargingStatus ||
            newState.isLowPowerMode != _currentState.isLowPowerMode) {
          AppLogger.info('Battery state updated: $newState', domain: LogDomain.battery);
          MetricsService.instance.setGauge('battery_level_percent', level.toDouble());
          _currentState = newState;
          _stateController.add(newState);
        }
      }
    } catch (_) {
      // Fallback if platform method channel is unavailable
    }
    return _currentState;
  }

  void updateStateForTesting(BatteryState state) {
    _currentState = state;
    _stateController.add(state);
  }

  void dispose() {
    _pollingTimer?.cancel();
    _stateController.close();
  }
}
