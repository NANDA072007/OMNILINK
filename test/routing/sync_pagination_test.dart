import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilink/core/models/packet_envelope.dart';
import 'package:omnilink/core/protocol/sync_session.dart';
import 'package:omnilink/core/diagnostics/metrics_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MTU-Safe Paginated Anti-Entropy Sync Tests', () {
    late SyncSessionManager manager;

    setUp(() {
      manager = SyncSessionManager();
      MetricsService.instance.clear();
    });

    tearDown(() {
      manager.dispose();
    });

    test('250 packetIds serialize into multiple <=4096-byte pages', () {
      final packetIds = List.generate(250, (i) => 'pkt_long_ident_string_prefix_$i');
      const pageSize = 40;
      final totalPages = (packetIds.length / pageSize).ceil();

      expect(totalPages, equals(7));

      final now = DateTime.now().millisecondsSinceEpoch;
      final pagesEnvelopes = <PacketEnvelope>[];

      for (int i = 0; i < totalPages; i++) {
        final chunk = packetIds.sublist(i * pageSize, ((i + 1) * pageSize).clamp(0, packetIds.length));
        final pageChecksum = SyncSession.computeChecksum(chunk);

        final pagePayload = jsonEncode({
          'sessionId': 'sess_250',
          'pageIndex': i,
          'packetIdChunk': chunk,
          'hasMore': i < totalPages - 1,
          'pageChecksum': pageChecksum,
        });

        final envelope = PacketEnvelope(
          protocolVersion: '0.1',
          packetId: 'sync_page_$i',
          senderId: 'node_a',
          recipientId: 'node_b',
          createdAt: now,
          expiresAt: now + 60000,
          ttl: 1,
          hopCount: 0,
          priority: 0,
          messageType: 'SYNC_PAGE',
          payloadHash: 'hash_$i',
          signature: 'sig_$i',
          encryptedPayload: pagePayload,
        );

        pagesEnvelopes.add(envelope);
        final bytes = utf8.encode(envelope.toJson());
        expect(bytes.length, lessThanOrEqualTo(4096));
      }
    });

    test('1000 packetIds do not crash sync session', () {
      final packetIds = List.generate(1000, (i) => 'packet_$i');
      final session = manager.createSession(
        sessionId: 'sess_1000',
        peerId: 'peer_1000',
        protocolVersion: 1,
        totalEstimatedCount: 1000,
        pageSize: 40,
      );

      const pageSize = 40;
      final totalPages = (packetIds.length / pageSize).ceil();

      for (int i = 0; i < totalPages; i++) {
        final chunk = packetIds.sublist(i * pageSize, ((i + 1) * pageSize).clamp(0, packetIds.length));
        final checksum = SyncSession.computeChecksum(chunk);
        final accepted = manager.handlePage(
          sessionId: 'sess_1000',
          pageIndex: i,
          packetIdChunk: chunk,
          pageChecksum: checksum,
        );
        expect(accepted, isTrue);
      }

      expect(session.isComplete(totalPages), isTrue);
      expect(session.getCombinedPacketIds().length, equals(1000));
    });

    test('Duplicate page is ignored', () {
      manager.createSession(
        sessionId: 'sess_dup',
        peerId: 'peer_dup',
        protocolVersion: 1,
        totalEstimatedCount: 40,
        pageSize: 40,
      );

      final chunk = ['p1', 'p2', 'p3'];
      final checksum = SyncSession.computeChecksum(chunk);

      final firstAccept = manager.handlePage(
        sessionId: 'sess_dup',
        pageIndex: 0,
        packetIdChunk: chunk,
        pageChecksum: checksum,
      );
      expect(firstAccept, isTrue);

      final secondAccept = manager.handlePage(
        sessionId: 'sess_dup',
        pageIndex: 0,
        packetIdChunk: chunk,
        pageChecksum: checksum,
      );
      expect(secondAccept, isFalse);
    });

    test('Missing page prevents session completion', () {
      final session = manager.createSession(
        sessionId: 'sess_missing',
        peerId: 'peer_missing',
        protocolVersion: 1,
        totalEstimatedCount: 80,
        pageSize: 40,
      );

      final chunk0 = ['p1'];
      manager.handlePage(
        sessionId: 'sess_missing',
        pageIndex: 0,
        packetIdChunk: chunk0,
        pageChecksum: SyncSession.computeChecksum(chunk0),
      );

      // Page 1 missing
      expect(session.isComplete(2), isFalse);
    });

    test('Peer disconnect cancels active sync session', () {
      manager.createSession(
        sessionId: 'sess_disc',
        peerId: 'peer_disc',
        protocolVersion: 1,
        totalEstimatedCount: 40,
        pageSize: 40,
      );

      expect(manager.getSession('sess_disc'), isNotNull);

      manager.cancelSessionsForPeer('peer_disc');

      expect(manager.getSession('sess_disc'), isNull);
    });
  });
}
