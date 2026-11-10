import 'package:flutter_test/flutter_test.dart';
import 'package:omnilink/core/diagnostics/metrics_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Peer Link Health Metrics Tests', () {
    late MetricsService service;
    const peerId = 'peer_123';

    setUp(() {
      service = MetricsService.instance;
      service.clear();
    });

    test('success rate calculation returns correct ratio', () {
      service.recordPeerPacketSent(peerId);
      service.recordPeerPacketSent(peerId);
      service.recordPeerPacketSent(peerId);
      service.recordPeerPacketSent(peerId);

      service.recordPeerPacketAcked(peerId, latencyMs: 50);
      service.recordPeerPacketAcked(peerId, latencyMs: 60);

      final metrics = service.getPeerMetrics(peerId);
      expect(metrics.packetsSent, equals(4));
      expect(metrics.packetsAcked, equals(2));
      expect(metrics.successRate, equals(0.5));
    });

    test('latency average uses exponential moving average calculation', () {
      service.recordPeerPacketAcked(peerId, latencyMs: 100);
      expect(service.getPeerMetrics(peerId).averageLatencyMs, equals(100.0));

      service.recordPeerPacketAcked(peerId, latencyMs: 200);
      // EMA: (100 * 0.7) + (200 * 0.3) = 70 + 60 = 130
      expect(service.getPeerMetrics(peerId).averageLatencyMs, closeTo(130.0, 0.1));
    });

    test('idle peer decays quality grade to unknown or poor', () {
      final metrics = PeerLinkMetrics(
        peerId: peerId,
        packetsSent: 0,
        packetsAcked: 0,
        lastSeen: DateTime.now().subtract(const Duration(seconds: 45)),
      );

      expect(metrics.qualityGrade, equals(LinkQualityGrade.unknown));

      final staleMetrics = PeerLinkMetrics(
        peerId: peerId,
        packetsSent: 10,
        packetsAcked: 10,
        averageLatencyMs: 40.0,
        lastSeen: DateTime.now().subtract(const Duration(seconds: 90)),
      );

      expect(staleMetrics.qualityGrade, equals(LinkQualityGrade.poor));
    });

    test('default metrics returned when peer not recorded without crashing', () {
      final metrics = service.getPeerMetrics('unknown_peer');
      expect(metrics.packetsSent, equals(0));
      expect(metrics.packetsAcked, equals(0));
      expect(metrics.successRate, equals(1.0));
      expect(metrics.qualityGrade, equals(LinkQualityGrade.unknown));
    });
  });
}
