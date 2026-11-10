import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:omnilink/core/database/database_service.dart';
import 'package:omnilink/core/routing/models/queued_packet.dart';
import 'package:omnilink/core/routing/routing_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Outbox lease and receipt lifecycle', () {
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

    test('reads never reset in-flight rows and leases gate retries', () async {
      final now = DateTime.now();
      final packet = QueuedPacket(
        packetId: 'lease_pkt_1',
        senderNodeId: 'local',
        recipientNodeId: 'remote',
        payload: '{"packet_id":"lease_pkt_1"}',
        priority: MessagePriority.normal,
        strategy: RouteStrategy.storeAndForward,
        ttl: 7,
        hopCount: 0,
        createdAt: now,
        nextRetryAt: now,
        status: 'pending',
      );
      await routingDb.insertOrUpdateQueuedPacket(packet);

      // A normal read must not mutate state.
      expect((await routingDb.getPendingOutboxPackets()).length, 1);
      expect((await routingDb.getAllQueuedPackets()).single.status, 'pending');

      // Claim for two minutes: status is sending and the lease blocks retries.
      final leaseUntil = now.add(const Duration(minutes: 2));
      await routingDb.claimOutboxPackets([packet.packetId], leaseUntil);
      final claimed = (await routingDb.getAllQueuedPackets()).single;
      expect(claimed.status, 'sending');
      expect(
        claimed.nextRetryAt.isAfter(now.add(const Duration(minutes: 1))),
        isTrue,
      );
      expect(await routingDb.getDueOutboxPackets(now), isEmpty);

      // After the lease expires, a crashed 'sending' row is eligible again.
      expect(
        (await routingDb.getDueOutboxPackets(
          leaseUntil.add(const Duration(seconds: 1)),
        )).single.packetId,
        packet.packetId,
      );

      // Link ACK keeps the row but delays the next attempt for a receipt.
      final graceUntil = now.add(const Duration(seconds: 30));
      await routingDb.markOutboxPacketsAwaitingReceipt(
        [packet.packetId],
        graceUntil,
      );
      final awaiting = (await routingDb.getAllQueuedPackets()).single;
      expect(awaiting.status, 'pending');
      expect(await routingDb.getDueOutboxPackets(now), isEmpty);
      expect(
        (await routingDb.getDueOutboxPackets(
          graceUntil.add(const Duration(seconds: 1)),
        )).single.packetId,
        packet.packetId,
      );

      // The receipt is the only event that deletes the durable copy.
      await routingDb.deleteQueuedPacket(packet.packetId);
      expect(await routingDb.getAllQueuedPackets(), isEmpty);
    });

    test('getPendingOutboxPackets does not destroy an active sending lease', () async {
      final now = DateTime.now();
      await routingDb.insertOrUpdateQueuedPacket(
        QueuedPacket(
          packetId: 'lease_pkt_2',
          senderNodeId: 'local',
          recipientNodeId: 'remote',
          payload: '{"packet_id":"lease_pkt_2"}',
          priority: MessagePriority.normal,
          strategy: RouteStrategy.storeAndForward,
          ttl: 7,
          hopCount: 0,
          createdAt: now,
          nextRetryAt: now,
          status: 'pending',
        ),
      );

      await routingDb.claimOutboxPackets(
        ['lease_pkt_2'],
        now.add(const Duration(minutes: 2)),
      );

      // Repeated summary reads must leave the claim intact.
      await routingDb.getPendingOutboxPackets();
      await routingDb.getPendingOutboxPackets();

      expect((await routingDb.getAllQueuedPackets()).single.status, 'sending');
    });
  });
}
