import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:omnilink/core/database/database_service.dart';
import 'package:omnilink/core/routing/models/queued_packet.dart';
import 'package:omnilink/core/routing/routing_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Sent-history retention', () {
    late DatabaseService dbService;
    late RoutingDatabaseService routingDb;

    setUp(() async {
      dbService = DatabaseService.instance;
      routingDb = RoutingDatabaseService.instance;
      await dbService.clearAllTablesForTesting();
    });

    tearDown(() async {
      await dbService.clearAllTablesForTesting();
    });

    test('stores sent payloads for anti-entropy resend', () async {
      final now = DateTime.now();
      await routingDb.insertSentPacket(
        packetId: 'sent_1',
        recipientNodeId: 'node_b',
        payload: '{"packet_id":"sent_1"}',
        sentAtMs: now.millisecondsSinceEpoch,
        expiresAtMs: now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      );

      expect(await routingDb.getSentPacketIds(), contains('sent_1'));

      final payloads = await routingDb.getSentPacketPayloadsByIds(
        ['sent_1', 'missing'],
      );
      expect(payloads['sent_1'], '{"packet_id":"sent_1"}');
      expect(payloads.containsKey('missing'), isFalse);
    });

    test('purges only expired sent history', () async {
      final now = DateTime.now();
      await routingDb.insertSentPacket(
        packetId: 'sent_live',
        recipientNodeId: 'node_b',
        payload: '{"packet_id":"sent_live"}',
        sentAtMs: now.millisecondsSinceEpoch,
        expiresAtMs: now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
      await routingDb.insertSentPacket(
        packetId: 'sent_dead',
        recipientNodeId: 'node_b',
        payload: '{"packet_id":"sent_dead"}',
        sentAtMs: now.millisecondsSinceEpoch,
        expiresAtMs: now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
      );

      final purged = await routingDb.purgeExpiredSentHistory(
        now.millisecondsSinceEpoch,
      );
      expect(purged, 1);

      final ids = await routingDb.getSentPacketIds();
      expect(ids, contains('sent_live'));
      expect(ids.contains('sent_dead'), isFalse);
    });

    test('queued packet lookup returns the payload before acknowledgement', () async {
      final now = DateTime.now();
      final packet = QueuedPacket(
        packetId: 'queued_1',
        senderNodeId: 'local',
        recipientNodeId: 'node_b',
        payload: '{"packet_id":"queued_1"}',
        priority: MessagePriority.normal,
        strategy: RouteStrategy.storeAndForward,
        ttl: 7,
        hopCount: 0,
        createdAt: now,
        nextRetryAt: now,
        status: 'pending',
      );
      await routingDb.insertOrUpdateQueuedPacket(packet);

      final loaded = await routingDb.getQueuedPacketById('queued_1');
      expect(loaded, isNotNull);
      expect(loaded!.payload, packet.payload);
      expect(loaded.recipientNodeId, 'node_b');
    });
  });
}
