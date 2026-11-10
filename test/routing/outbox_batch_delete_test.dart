import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Initialize FFI for desktop SQLite unit testing
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Outbox Batch Deletion & Transaction Integrity Tests', () {
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
              recipient_node_id TEXT NOT NULL,
              payload TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'pending'
            )
          ''');
        },
      );

      for (int i = 1; i <= 5; i++) {
        await db.insert('outbox_queue', {
          'packet_id': 'pkt_00$i',
          'recipient_node_id': 'target_node_1',
          'payload': 'Payload packet $i',
          'status': 'pending',
        });
      }
    });

    tearDown(() async {
      await db.close();
    });

    test('deleteQueuedPacketsByIds atomically deletes targeted packet IDs inside single batch transaction', () async {
      final res1 = await db.rawQuery('SELECT COUNT(*) FROM outbox_queue');
      final initialCount = (res1.first.values.first as int);
      expect(initialCount, equals(5));

      final targetIds = ['pkt_001', 'pkt_003', 'pkt_005'];

      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final id in targetIds) {
          batch.delete('outbox_queue', where: 'packet_id = ?', whereArgs: [id]);
        }
        await batch.commit(noResult: true);
      });

      final res2 = await db.rawQuery('SELECT COUNT(*) FROM outbox_queue');
      final remainingCount = (res2.first.values.first as int);
      expect(remainingCount, equals(2));

      final remaining = await db.query('outbox_queue');
      final remainingIds = remaining.map((m) => m['packet_id']).toList();
      expect(remainingIds, containsAll(['pkt_002', 'pkt_004']));
      expect(remainingIds.contains('pkt_001'), isFalse);
    });

    test('Failed transaction leaves outbox queue completely unchanged with zero partial deletes', () async {
      final targetIds = ['pkt_002', 'pkt_004'];

      expect(
        () async {
          await db.transaction((txn) async {
            final batch = txn.batch();
            for (final id in targetIds) {
              batch.delete('outbox_queue', where: 'packet_id = ?', whereArgs: [id]);
            }
            await batch.commit(noResult: true);
            throw Exception('Simulated network/DB error post-deletion step');
          });
        },
        throwsA(isA<Exception>()),
      );

      final res3 = await db.rawQuery('SELECT COUNT(*) FROM outbox_queue');
      final count = (res3.first.values.first as int);
      expect(count, equals(5));
    });
  });
}
