import 'dart:collection';

enum MetricType { counter, gauge, timer }

/// Single metric event snapshot stored in memory ring buffer.
class MetricEvent {
  final String name;
  final MetricType type;
  final double value;
  final DateTime timestamp;

  const MetricEvent({
    required this.name,
    required this.type,
    required this.value,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'type': type.name,
      'value': value,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}

/// Pure-Dart lightweight Metrics Service for tracking system performance counters,
/// transmission timers, and link-health gauges without UI dependencies.
class MetricsService {
  static final MetricsService instance = MetricsService._internal();

  factory MetricsService() => instance;

  MetricsService._internal();

  final Map<String, int> _counters = {};
  final Map<String, double> _gauges = {};
  final Map<String, int> _activeTimers = {};
  final Queue<MetricEvent> _recentEvents = Queue<MetricEvent>();

  static const int maxRingBufferCapacity = 100;

  /// Increments a named counter.
  void increment(String name, [int delta = 1]) {
    _counters[name] = (_counters[name] ?? 0) + delta;
    _recordEvent(name, MetricType.counter, _counters[name]!.toDouble());
  }

  /// Sets a scalar gauge metric value (e.g. RSSI, battery level, packet loss rate).
  void setGauge(String name, double value) {
    _gauges[name] = value;
    _recordEvent(name, MetricType.gauge, value);
  }

  /// Starts a named timer. Returns current timestamp in milliseconds.
  int startTimer(String name) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _activeTimers[name] = now;
    return now;
  }

  /// Stops a named timer and returns duration in milliseconds.
  int stopTimer(String name) {
    final start = _activeTimers.remove(name);
    if (start == null) return 0;
    final duration = DateTime.now().millisecondsSinceEpoch - start;
    _recordEvent(name, MetricType.timer, duration.toDouble());
    return duration;
  }

  /// Returns current snapshot of all counters.
  Map<String, int> getCounters() => Map.unmodifiable(_counters);

  /// Returns current snapshot of all gauges.
  Map<String, double> getGauges() => Map.unmodifiable(_gauges);

  /// Returns recent metric events snapshot from in-memory ring buffer.
  List<MetricEvent> getRecentEvents() => _recentEvents.toList();

  /// Private helper adding metric snapshot to ring buffer.
  void _recordEvent(String name, MetricType type, double value) {
    if (_recentEvents.length >= maxRingBufferCapacity) {
      _recentEvents.removeFirst();
    }
    _recentEvents.add(
      MetricEvent(
        name: name,
        type: type,
        value: value,
        timestamp: DateTime.now(),
      ),
    );
  }

  final Map<String, PeerLinkMetrics> _peerMetricsMap = {};

  void recordPeerPacketSent(String peerId, {int byteCount = 0, String transportType = 'ANDROID_NEARBY'}) {
    final current = _peerMetricsMap[peerId] ?? PeerLinkMetrics(peerId: peerId, lastSeen: DateTime.now(), transportType: transportType);
    _peerMetricsMap[peerId] = PeerLinkMetrics(
      peerId: peerId,
      packetsSent: current.packetsSent + 1,
      packetsAcked: current.packetsAcked,
      packetsFailed: current.packetsFailed,
      retries: current.retries,
      averageLatencyMs: current.averageLatencyMs,
      estimatedThroughputBps: current.estimatedThroughputBps,
      lastSeen: DateTime.now(),
      rssi: current.rssi,
      mtuLimit: current.mtuLimit,
      transportType: transportType,
    );
  }

  void recordPeerPacketAcked(String peerId, {required double latencyMs, int byteCount = 0}) {
    final current = _peerMetricsMap[peerId] ?? PeerLinkMetrics(peerId: peerId, lastSeen: DateTime.now());
    final newAvgLat = current.packetsAcked == 0
        ? latencyMs
        : (current.averageLatencyMs * 0.7) + (latencyMs * 0.3);

    _peerMetricsMap[peerId] = PeerLinkMetrics(
      peerId: peerId,
      packetsSent: current.packetsSent,
      packetsAcked: current.packetsAcked + 1,
      packetsFailed: current.packetsFailed,
      retries: current.retries,
      averageLatencyMs: newAvgLat,
      estimatedThroughputBps: (byteCount > 0 && latencyMs > 0)
          ? (byteCount / (latencyMs / 1000.0))
          : current.estimatedThroughputBps,
      lastSeen: DateTime.now(),
      rssi: current.rssi,
      mtuLimit: current.mtuLimit,
      transportType: current.transportType,
    );
  }

  void recordPeerPacketFailed(String peerId, {int retries = 0}) {
    final current = _peerMetricsMap[peerId] ?? PeerLinkMetrics(peerId: peerId, lastSeen: DateTime.now());
    _peerMetricsMap[peerId] = PeerLinkMetrics(
      peerId: peerId,
      packetsSent: current.packetsSent,
      packetsAcked: current.packetsAcked,
      packetsFailed: current.packetsFailed + 1,
      retries: current.retries + retries,
      averageLatencyMs: current.averageLatencyMs,
      estimatedThroughputBps: current.estimatedThroughputBps,
      lastSeen: DateTime.now(),
      rssi: current.rssi,
      mtuLimit: current.mtuLimit,
      transportType: current.transportType,
    );
  }

  void recordPeerRssi(String peerId, int rssi) {
    final current = _peerMetricsMap[peerId] ?? PeerLinkMetrics(peerId: peerId, lastSeen: DateTime.now());
    _peerMetricsMap[peerId] = PeerLinkMetrics(
      peerId: peerId,
      packetsSent: current.packetsSent,
      packetsAcked: current.packetsAcked,
      packetsFailed: current.packetsFailed,
      retries: current.retries,
      averageLatencyMs: current.averageLatencyMs,
      estimatedThroughputBps: current.estimatedThroughputBps,
      lastSeen: DateTime.now(),
      rssi: rssi,
      mtuLimit: current.mtuLimit,
      transportType: current.transportType,
    );
  }

  PeerLinkMetrics getPeerMetrics(String peerId) {
    return _peerMetricsMap[peerId] ?? PeerLinkMetrics(peerId: peerId, lastSeen: DateTime.now());
  }

  Map<String, PeerLinkMetrics> getAllPeerMetrics() {
    return Map.unmodifiable(_peerMetricsMap);
  }

  /// Resets all metrics.
  void clear() {
    _counters.clear();
    _gauges.clear();
    _activeTimers.clear();
    _recentEvents.clear();
    _peerMetricsMap.clear();
  }
}

enum LinkQualityGrade {
  excellent,
  good,
  fair,
  poor,
  unknown,
}

class PeerLinkMetrics {
  final String peerId;
  final int packetsSent;
  final int packetsAcked;
  final int packetsFailed;
  final int retries;
  final double averageLatencyMs;
  final double estimatedThroughputBps;
  final DateTime lastSeen;
  final int? rssi;
  final int mtuLimit;
  final String transportType;

  const PeerLinkMetrics({
    required this.peerId,
    this.packetsSent = 0,
    this.packetsAcked = 0,
    this.packetsFailed = 0,
    this.retries = 0,
    this.averageLatencyMs = 0.0,
    this.estimatedThroughputBps = 0.0,
    required this.lastSeen,
    this.rssi,
    this.mtuLimit = 4096,
    this.transportType = 'ANDROID_NEARBY',
  });

  double get successRate {
    if (packetsSent == 0) return 1.0;
    return (packetsAcked / packetsSent).clamp(0.0, 1.0);
  }

  LinkQualityGrade get qualityGrade {
    if (packetsSent == 0) return LinkQualityGrade.unknown;
    final idleSeconds = DateTime.now().difference(lastSeen).inSeconds;
    if (idleSeconds > 60) return LinkQualityGrade.poor;

    final rate = successRate;
    final lat = averageLatencyMs;

    if (rate >= 0.95 && lat <= 150) return LinkQualityGrade.excellent;
    if (rate >= 0.80 && lat <= 350) return LinkQualityGrade.good;
    if (rate >= 0.60 && lat <= 700) return LinkQualityGrade.fair;
    return LinkQualityGrade.poor;
  }
}
