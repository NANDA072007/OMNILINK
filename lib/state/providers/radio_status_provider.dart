import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../transport_bridge/android_transport_adapter.dart';
import '../models/radio_status_state.dart';

final radioStatusProvider =
    StateNotifierProvider<RadioStatusNotifier, RadioStatusState>((ref) {
  // Reuse the single initialized Android adapter from the core layer.
  final adapter = ref.watch(androidTransportAdapterProvider);
  return RadioStatusNotifier(adapter);
});

class RadioStatusNotifier extends StateNotifier<RadioStatusState> {
  final AndroidTransportAdapter _adapter;
  StreamSubscription? _radioSubscription;

  RadioStatusNotifier(this._adapter) : super(const RadioStatusState()) {
    _init();
  }

  Future<void> _init() async {
    await refreshStatus();

    // Event-driven native BroadcastReceiver listener (0% polling loop)
    _radioSubscription = _adapter.radioStateEvents.listen((detailsMap) {
      debugPrint('OMNILINK_STATE: Received native radio state event: $detailsMap');
      state = RadioStatusState.fromMap(detailsMap);
    }, onError: (err) {
      debugPrint('OMNILINK_STATE: Radio state stream error: $err');
    });
  }

  Future<void> refreshStatus() async {
    try {
      final details = await _adapter.getAndroidPermissionDetails();
      if (details != null) {
        state = RadioStatusState.fromMap(details);
        debugPrint(
          'OMNILINK_STATE: Initial native probe radio readiness: isReady=${state.isReady} bt=${state.bluetoothEnabled} wifi=${state.wifiEnabled} loc=${state.locationEnabled}',
        );
      }
    } catch (e) {
      debugPrint('OMNILINK_STATE: Error probing radio status: $e');
    }
  }

  @override
  void dispose() {
    _radioSubscription?.cancel();
    super.dispose();
  }
}
