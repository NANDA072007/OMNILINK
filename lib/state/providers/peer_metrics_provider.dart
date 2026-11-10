import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/diagnostics/metrics_service.dart';

final peerMetricsProvider =
    StateNotifierProvider<PeerMetricsNotifier, Map<String, PeerLinkMetrics>>((ref) {
  return PeerMetricsNotifier();
});

class PeerMetricsNotifier extends StateNotifier<Map<String, PeerLinkMetrics>> {
  Timer? _throttleTimer;

  PeerMetricsNotifier() : super({}) {
    _startThrottledUpdates();
  }

  void _startThrottledUpdates() {
    _throttleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final metricsMap = MetricsService.instance.getAllPeerMetrics();
      if (!mapEquals(state, metricsMap)) {
        state = Map.unmodifiable(metricsMap);
      }
    });
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    super.dispose();
  }
}
