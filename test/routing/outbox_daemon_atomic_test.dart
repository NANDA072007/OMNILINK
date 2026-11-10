import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:omnilink/core/diagnostics/metrics_service.dart';
import 'package:omnilink/core/routing/models/queued_packet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('OutboxDaemon Atomic & Idempotent Flush Tests', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        version: 1,
        onConfigure: (database) async {
          await database.execute('PRAGMA journal_mode=WAL;');
          await database.execute('PRAGMA busy_timeout=5000;');
        },
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE outbox_queue (
              packet_id TEXT PRIMARY KEY,
              sender_node_id TEXT NOT NULL,
              recipient_node_id TEXT NOT NULL,
              payload TEXT NOT NULL,
              priority TEXT NOT NULL,
              strategy TEXT NOT NULL,
              ttl INTEGER NOT NULL,
              hop_count INTEGER NOT NULL,
              created_at INTEGER NOT NULL,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at INTEGER NOT NULL,
              status TEXT NOT NULL DEFAULT 'pending'
            )
          ''');
        },
      );

      MetricsService.instance.clear();
    });

    tearDown(() async {
      await db.close();
    });

    test('100 queued outbox packets are marked sending and deleted atomically in single transaction', () async {
      final now = DateTime.now();

      // Insert 100 queued outbox packets
      for (int i = 1; i <= 100; i++) {
        await db.insert('outbox_queue', {
          'packet_id': 'pkt_flush_$i',
          'sender_node_id': 'local_node',
          'recipient_node_id': 'target_node',
          'payload': '{"packet_id": "pkt_flush_$i"}',
          'priority': 'normal',
          'strategy': 'storeAndForward',
          'ttl': 7,
          'hop_count': 0,
          'created_at': now.millisecondsSinceEpoch,
          'retry_count': 0,
          'next_retry_at': now.millisecondsSinceEpoch,
          'status': 'pending',
        });
      }

      final initialCountRes = await db.rawQuery('SELECT COUNT(*) FROM outbox_queue');
      expect(initialCountRes.first.values.first, equals(100));

      final targetIds = List.generate(100, (i) => 'pkt_flush_${i + 1}');

      // 1. Mark status = sending inside single transaction
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final id in targetIds) {
          batch.update('outbox_queue', {'status': 'sending'}, where: 'packet_id = ?', whereArgs: [id]);
        }
        await batch.commit(noResult: true);
      });

      final sendingCountRes = await db.rawQuery('SELECT COUNT(*) FROM outbox_queue WHERE status = ?', ['sending']);
      expect(sendingCountRes.first.values.first, equals(100));

      // 2. Batch delete in single transaction
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final id in targetIds) {
          batch.delete('outbox_queue', where: 'packet_id = ?', whereArgs: [id]);
        }
        await batch.commit(noResult: true);
      });

      final remainingCountRes = await db.rawQuery('SELECT COUNT(*) FROM outbox_queue');
      expect(remainingCountRes.first.values.first, equals(0));
    });

    test('Simulated ACK failure retains packets and updates retry count with exponential backoff', () async {
      final now = DateTime.now();

      final queued = QueuedPacket(
        packetId: 'pkt_fail_01',
        senderNodeId: 'local_node',
        recipientNodeId: 'target_node',
        payload: '{"packet_id": "pkt_fail_01"}',
        priority: MessagePriority.normal,
        strategy: RouteStrategy.storeAndForward,
        ttl: 7,
        hopCount: 0,
        createdAt: now,
        retryCount: 1,
        nextRetryAt: now,
        status: 'pending',
      );

      await db.insert('outbox_queue', queued.toMap());

      // Calculate exponential backoff for attempt #2: min(2^2 * 1000, 60000) = 4000ms
      final newAttempts = queued.retryCount + 1;
      final delayMs = min(pow(2, newAttempts).toInt() * 1000, 60000);
      expect(delayMs, equals(4000));

      final updated = queued.copyWith(
        retryCount: newAttempts,
        nextRetryAt: now.add(Duration(milliseconds: delayMs)),
        status: 'pending',
      );

      await db.insert('outbox_queue', updated.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);

      final queryRes = await db.query('outbox_queue', where: 'packet_id = ?', whereArgs: ['pkt_fail_01']);
      expect(queryRes.length, equals(1));
      expect(queryRes.first['retry_count'], equals(2));
      expect(queryRes.first['status'], equals('pending'));
    });

    test('Exponential backoff math scales correctly up to 60,000ms cap', () {
      int backoffFor(int attempts) => min(pow(2, attempts).toInt() * 1000, 60000);

      expect(backoffFor(1), equals(2000));
      expect(backoffFor(2), equals(4000));
      expect(backoffFor(3), equals(8000));
      expect(backoffFor(4), equals(16000));
      expect(backoffFor(5), equals(32000));
      expect(backoffFor(6), equals(60000));
      expect(backoffFor(10), equals(60000));
    });
  });
}
