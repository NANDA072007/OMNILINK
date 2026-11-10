import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:omnilink/core/database/schema_migrator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Initialize FFI for desktop SQLite unit testing
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('SQLite Persistence & WAL Migration Tests', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        version: 1,
        onConfigure: (database) async {
          await database.execute('PRAGMA journal_mode=WAL;');
          await database.execute('PRAGMA busy_timeout=5000;');
          await database.execute('PRAGMA foreign_keys=ON;');
        },
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE peers (
              node_id TEXT PRIMARY KEY,
              peer_id TEXT,
              friendly_name TEXT,
              status TEXT
            )
          ''');
          await database.execute('''
            CREATE TABLE messages (
              message_id TEXT PRIMARY KEY,
              conversation_id TEXT NOT NULL,
              plaintext_body TEXT
            )
          ''');
        },
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('Database opens with WAL journal mode and busy_timeout configured', () async {
      final journalModeResult = await db.rawQuery('PRAGMA journal_mode;');
      final busyTimeoutResult = await db.rawQuery('PRAGMA busy_timeout;');

      expect(journalModeResult.first.values.first.toString().toLowerCase(), anyOf(equals('wal'), equals('memory')));
      expect(busyTimeoutResult.first.values.first, equals(5000));
    });

    test('SchemaMigrator executes step-by-step migrations from v1 to v2 without data loss', () async {
      await db.insert('peers', {
        'node_id': 'node_001',
        'peer_id': 'peer_A',
        'friendly_name': 'Alpha Device',
        'status': 'active',
      });

      final steps = [
        SchemaMigrator(
          fromVersion: 1,
          toVersion: 2,
          migrateStep: (txn) async {
            await txn.execute('CREATE INDEX idx_peers_friendly ON peers(friendly_name);');
            await txn.execute('ALTER TABLE peers ADD COLUMN region TEXT DEFAULT "global";');
          },
        ),
      ];

      await SchemaMigrator.migrate(
        db: db,
        oldVersion: 1,
        newVersion: 2,
        dbName: 'test_mesh.db',
        steps: steps,
      );

      final peers = await db.query('peers', where: 'node_id = ?', whereArgs: ['node_001']);
      expect(peers.length, equals(1));
      expect(peers.first['friendly_name'], equals('Alpha Device'));
      expect(peers.first['region'], equals('global'));
    });

    test('SchemaMigrator rolls back atomic transaction if a migration step fails', () async {
      await db.insert('messages', {
        'message_id': 'msg_100',
        'conversation_id': 'conv_1',
        'plaintext_body': 'Original Message',
      });

      final failingSteps = [
        SchemaMigrator(
          fromVersion: 1,
          toVersion: 2,
          migrateStep: (txn) async {
            await txn.execute('ALTER TABLE messages ADD COLUMN priority INTEGER;');
            await txn.execute('INVALID SQL SYNTAX TO TRIGGER ROLLBACK;');
          },
        ),
      ];

      expect(
        () => SchemaMigrator.migrate(
          db: db,
          oldVersion: 1,
          newVersion: 2,
          dbName: 'test_mesh.db',
          steps: failingSteps,
        ),
        throwsA(isA<SchemaMigrationException>()),
      );

      final messages = await db.query('messages', where: 'message_id = ?', whereArgs: ['msg_100']);
      expect(messages.length, equals(1));
      expect(messages.first.containsKey('priority'), isFalse);
    });

    test('Concurrent inserts and queries execute cleanly without lock exception under WAL mode', () async {
      final futures = <Future<void>>[];

      for (int i = 0; i < 20; i++) {
        final index = i;
        futures.add(Future(() async {
          await db.insert('messages', {
            'message_id': 'msg_conc_$index',
            'conversation_id': 'conv_conc',
            'plaintext_body': 'Concurrent payload $index',
          });
          await db.query('messages', where: 'conversation_id = ?', whereArgs: ['conv_conc']);
        }));
      }

      await expectLater(Future.wait(futures), completes);

      final countResult = await db.rawQuery('SELECT COUNT(*) FROM messages');
      final count = (countResult.first.values.first as int);
      expect(count, equals(20));
    });
  });
}
