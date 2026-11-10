import 'dart:async';
import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../diagnostics/app_logger.dart';
import 'schema_migrator.dart';

/// Singleton SQLite Database Service managing raw tables, version migrations,
/// WAL concurrency pragmas, and standard CRUD operations for OMNILINK offline mesh persistence.
class DatabaseService {
  static const String _dbName = 'omnilink_mesh.db';
  static const int currentVersion = 6;
  static const int _dbVersion = currentVersion;

  static final DatabaseService instance = DatabaseService._internal();
  static Database? _database;
  static String? overrideDatabasePath;

  DatabaseService._internal();

  factory DatabaseService() => instance;

  static void resetForTesting() {
    _database = null;
  }

  static Future<void> closeAndResetForTesting() async {
    if (_database != null && _database!.isOpen) {
      await _database!.close();
    }
    _database = null;
  }

  /// Wipes all tables atomically in foreign-key-safe order for pristine test isolation.
  Future<void> clearAllTablesForTesting() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('payload_chunks');
      await txn.delete('payload_transfers');
      await txn.delete('processed_packets');
      await txn.delete('messages');
      await txn.delete('outbox_queue');
      await txn.delete('routing_table');
      await txn.delete('neighbor_table');
      await txn.delete('encounter_history');
      await txn.delete('route_cache');
      await txn.delete('peers');
    });
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    final defaultDbName = Platform.environment.containsKey('FLUTTER_TEST')
        ? 'omnilink_mesh_test_$pid.db'
        : _dbName;
    final path = overrideDatabasePath ?? join(await getDatabasesPath(), defaultDbName);

    final db = await openDatabase(
      path,
      version: _dbVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );

    // Reconcile and import legacy omnilink_routing.db if present
    await _migrateLegacyRoutingDatabase(db, dirname(path));

    final elapsed = DateTime.now().millisecondsSinceEpoch - t0;
    AppLogger.info('Opened SQLite app database ($path) in ${elapsed}ms', domain: LogDomain.db);
    return db;
  }

  /// Configures SQLite pragmas for high concurrency WAL journal mode, fast sync, and lock timeout protection.
  Future<void> _onConfigure(Database db) async {
    final stopwatch = Stopwatch()..start();
    try {
      await db.execute('PRAGMA foreign_keys=ON;');
    } catch (e) {
      AppLogger.warn('PRAGMA foreign_keys ignored by SQLite driver: $e', domain: LogDomain.db);
    }
    try {
      await db.rawQuery('PRAGMA journal_mode=WAL;');
    } catch (e) {
      AppLogger.warn('PRAGMA journal_mode ignored by SQLite driver: $e', domain: LogDomain.db);
    }
    try {
      await db.rawQuery('PRAGMA synchronous=NORMAL;');
    } catch (e) {
      AppLogger.warn('PRAGMA synchronous ignored by SQLite driver: $e', domain: LogDomain.db);
    }
    try {
      await db.rawQuery('PRAGMA busy_timeout=5000;');
    } catch (e) {
      AppLogger.warn('PRAGMA busy_timeout ignored by SQLite driver: $e', domain: LogDomain.db);
    }
    try {
      await db.rawQuery('PRAGMA temp_store=MEMORY;');
    } catch (e) {
      AppLogger.warn('PRAGMA temp_store ignored by SQLite driver: $e', domain: LogDomain.db);
    }
    stopwatch.stop();

    try {
      final modeResult = await db.rawQuery('PRAGMA journal_mode;');
      final currentMode = modeResult.isNotEmpty ? modeResult.first['journal_mode'] : 'unknown';
      AppLogger.info(
        'SQLite app DB pragmas applied (journal_mode=$currentMode) in ${stopwatch.elapsedMilliseconds}ms',
        domain: LogDomain.db,
      );
    } catch (_) {}
  }

  /// Creates SQLite database tables on initial launch.
  Future<void> _onCreate(Database db, int version) async {
    AppLogger.info('Creating initial SQLite app database schema (v$version)', domain: LogDomain.db);

    // 1. Peers table
    await db.execute('''
      CREATE TABLE peers (
        node_id TEXT PRIMARY KEY,
        peer_id TEXT,
        static_x25519_public_key TEXT,
        friendly_name TEXT,
        last_seen_at INTEGER,
        rssi INTEGER,
        transport_type TEXT,
        connection_status TEXT
      )
    ''');

    // 2. Messages table
    await db.execute('''
      CREATE TABLE messages (
        message_id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        sender_node_id TEXT NOT NULL,
        recipient_node_id TEXT NOT NULL,
        plaintext_body TEXT,
        state TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // 3. Outbox Queue table for Store-and-Forward offline mesh delivery
    await db.execute('''
      CREATE TABLE IF NOT EXISTS outbox_queue (
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

    // Performance indexes
    await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id);');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_outbox_recipient ON outbox_queue(recipient_node_id);');

    // 4. Payload Transfers table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS payload_transfers (
        payload_id TEXT PRIMARY KEY,
        direction TEXT NOT NULL,
        sender_node_id TEXT NOT NULL,
        recipient_node_id TEXT NOT NULL,
        file_name TEXT NOT NULL,
        payload_type TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        total_size INTEGER NOT NULL,
        total_chunks INTEGER NOT NULL,
        received_chunks INTEGER DEFAULT 0,
        final_sha256 TEXT NOT NULL,
        transfer_state TEXT NOT NULL,
        local_file_path TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    // 5. Payload Chunks table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS payload_chunks (
        payload_id TEXT NOT NULL,
        chunk_index INTEGER NOT NULL,
        chunk_sha256 TEXT NOT NULL,
        chunk_data BLOB,
        received_at INTEGER NOT NULL,
        PRIMARY KEY (payload_id, chunk_index),
        FOREIGN KEY (payload_id) REFERENCES payload_transfers(payload_id) ON DELETE CASCADE
      );
    ''');

    // 6. Processed Packets Replay Table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS processed_packets (
        packet_id TEXT PRIMARY KEY,
        sender_id TEXT NOT NULL,
        first_seen_at INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL
      );
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_processed_packets_expires ON processed_packets(expires_at);');

    // 7. Unified Routing Table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS routing_table (
        destination_node_id TEXT PRIMARY KEY,
        next_hop_peer_id TEXT NOT NULL,
        next_hop_node_id TEXT,
        hop_count INTEGER NOT NULL DEFAULT 1,
        probability REAL NOT NULL DEFAULT 1.0,
        signal_quality REAL NOT NULL DEFAULT 0.5,
        last_updated INTEGER NOT NULL,
        last_successful_delivery INTEGER,
        delivery_attempts INTEGER NOT NULL DEFAULT 0,
        delivery_successes INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1
      );
    ''');

    // 8. Unified Neighbor Table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS neighbor_table (
        peer_id TEXT PRIMARY KEY,
        node_id TEXT,
        friendly_name TEXT NOT NULL,
        rssi INTEGER,
        link_quality REAL NOT NULL DEFAULT 0.5,
        first_seen INTEGER NOT NULL,
        last_seen INTEGER NOT NULL,
        is_connected INTEGER NOT NULL DEFAULT 1,
        packets_sent INTEGER NOT NULL DEFAULT 0,
        packets_received INTEGER NOT NULL DEFAULT 0,
        packets_failed INTEGER NOT NULL DEFAULT 0
      );
    ''');

    // 9. Unified Encounter History Table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS encounter_history (
        node_id TEXT PRIMARY KEY,
        peer_id TEXT NOT NULL,
        predictability REAL NOT NULL DEFAULT 0.75,
        encounter_count INTEGER NOT NULL DEFAULT 1,
        last_encounter INTEGER NOT NULL,
        first_encounter INTEGER NOT NULL,
        avg_duration_seconds REAL NOT NULL DEFAULT 0.0
      );
    ''');

    // 10. Unified Route Cache Table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS route_cache (
        destination_node_id TEXT PRIMARY KEY,
        next_hop_peer_id TEXT NOT NULL,
        path_json TEXT,
        cached_at INTEGER NOT NULL
      );
    ''');

    await db.execute('CREATE INDEX IF NOT EXISTS idx_routing_dest ON routing_table(destination_node_id, probability);');
  }

  /// Incremental database schema migrations.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    final steps = [
      SchemaMigrator(
        fromVersion: 1,
        toVersion: 2,
        migrateStep: (txn) async {
          await txn.execute('CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id);');
          await txn.execute('CREATE INDEX IF NOT EXISTS idx_outbox_recipient ON outbox_queue(recipient_node_id);');
        },
      ),
      SchemaMigrator(
        fromVersion: 2,
        toVersion: 3,
        migrateStep: (txn) async {
          await txn.execute('''
            CREATE TABLE IF NOT EXISTS payload_transfers (
              payload_id TEXT PRIMARY KEY,
              direction TEXT NOT NULL,
              sender_node_id TEXT NOT NULL,
              recipient_node_id TEXT NOT NULL,
              file_name TEXT NOT NULL,
              payload_type TEXT NOT NULL,
              mime_type TEXT NOT NULL,
              total_size INTEGER NOT NULL,
              total_chunks INTEGER NOT NULL,
              received_chunks INTEGER DEFAULT 0,
              final_sha256 TEXT NOT NULL,
              transfer_state TEXT NOT NULL,
              local_file_path TEXT,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            );
          ''');

          await txn.execute('''
            CREATE TABLE IF NOT EXISTS payload_chunks (
              payload_id TEXT NOT NULL,
              chunk_index INTEGER NOT NULL,
              chunk_sha256 TEXT NOT NULL,
              chunk_data BLOB,
              received_at INTEGER NOT NULL,
              PRIMARY KEY (payload_id, chunk_index),
              FOREIGN KEY (payload_id) REFERENCES payload_transfers(payload_id) ON DELETE CASCADE
            );
          ''');
        },
      ),
      SchemaMigrator(
        fromVersion: 3,
        toVersion: 4,
        migrateStep: (txn) async {
          await txn.execute('''
            CREATE TABLE IF NOT EXISTS processed_packets (
              packet_id TEXT PRIMARY KEY,
              sender_id TEXT NOT NULL,
              first_seen_at INTEGER NOT NULL,
              created_at INTEGER NOT NULL,
              expires_at INTEGER NOT NULL
            );
          ''');
          await txn.execute('CREATE INDEX IF NOT EXISTS idx_processed_packets_expires ON processed_packets(expires_at);');
        },
      ),
      SchemaMigrator(
        fromVersion: 4,
        toVersion: 5,
        migrateStep: (txn) async {
          await txn.execute('''
            CREATE TABLE IF NOT EXISTS routing_table (
              destination_node_id TEXT PRIMARY KEY,
              next_hop_peer_id TEXT NOT NULL,
              next_hop_node_id TEXT,
              hop_count INTEGER NOT NULL DEFAULT 1,
              probability REAL NOT NULL DEFAULT 1.0,
              signal_quality REAL NOT NULL DEFAULT 0.5,
              last_updated INTEGER NOT NULL,
              last_successful_delivery INTEGER,
              delivery_attempts INTEGER NOT NULL DEFAULT 0,
              delivery_successes INTEGER NOT NULL DEFAULT 0,
              is_active INTEGER NOT NULL DEFAULT 1
            );
          ''');

          await txn.execute('''
            CREATE TABLE IF NOT EXISTS neighbor_table (
              peer_id TEXT PRIMARY KEY,
              node_id TEXT,
              friendly_name TEXT NOT NULL,
              rssi INTEGER,
              link_quality REAL NOT NULL DEFAULT 0.5,
              first_seen INTEGER NOT NULL,
              last_seen INTEGER NOT NULL,
              is_connected INTEGER NOT NULL DEFAULT 1,
              packets_sent INTEGER NOT NULL DEFAULT 0,
              packets_received INTEGER NOT NULL DEFAULT 0,
              packets_failed INTEGER NOT NULL DEFAULT 0
            );
          ''');

          await txn.execute('''
            CREATE TABLE IF NOT EXISTS encounter_history (
              node_id TEXT PRIMARY KEY,
              peer_id TEXT NOT NULL,
              predictability REAL NOT NULL DEFAULT 0.75,
              encounter_count INTEGER NOT NULL DEFAULT 1,
              last_encounter INTEGER NOT NULL,
              first_encounter INTEGER NOT NULL,
              avg_duration_seconds REAL NOT NULL DEFAULT 0.0
            );
          ''');

          await txn.execute('''
            CREATE TABLE IF NOT EXISTS route_cache (
              destination_node_id TEXT PRIMARY KEY,
              next_hop_peer_id TEXT NOT NULL,
              path_json TEXT,
              cached_at INTEGER NOT NULL
            );
          ''');

          await txn.execute('CREATE INDEX IF NOT EXISTS idx_routing_dest ON routing_table(destination_node_id, probability);');
        },
      ),
      SchemaMigrator(
        fromVersion: 5,
        toVersion: 6,
        migrateStep: (txn) async {
          final tableInfo = await txn.rawQuery('PRAGMA table_info(peers);');
          final hasColumn = tableInfo.any((col) => col['name'] == 'static_x25519_public_key');
          if (!hasColumn) {
            await txn.execute('ALTER TABLE peers ADD COLUMN static_x25519_public_key TEXT;');
          }
        },
      ),
    ];

    await SchemaMigrator.migrate(
      db: db,
      oldVersion: oldVersion,
      newVersion: newVersion,
      dbName: _dbName,
      steps: steps,
    );
  }

  // --------------------------------------------------------------------------
  // GENERIC CRUD HELPER METHODS WITH SLOW QUERY WARNINGS (> 50ms)
  // --------------------------------------------------------------------------

  Future<int> insert(
    String table,
    Map<String, dynamic> data, {
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.replace,
  }) async {
    final stopwatch = Stopwatch()..start();
    final db = await database;
    final result = await db.insert(
      table,
      data,
      conflictAlgorithm: conflictAlgorithm,
    );
    stopwatch.stop();
    if (stopwatch.elapsedMilliseconds > 50) {
      AppLogger.warn('Slow insert on $table (${stopwatch.elapsedMilliseconds}ms)', domain: LogDomain.db);
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> query(
    String table, {
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    int? limit,
  }) async {
    final stopwatch = Stopwatch()..start();
    final db = await database;
    final result = await db.query(
      table,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
    );
    stopwatch.stop();
    if (stopwatch.elapsedMilliseconds > 50) {
      AppLogger.warn('Slow query on $table (${stopwatch.elapsedMilliseconds}ms)', domain: LogDomain.db);
    }
    return result;
  }

  Future<int> update(
    String table,
    Map<String, dynamic> data, {
    required String where,
    required List<dynamic> whereArgs,
  }) async {
    final stopwatch = Stopwatch()..start();
    final db = await database;
    final result = await db.update(
      table,
      data,
      where: where,
      whereArgs: whereArgs,
    );
    stopwatch.stop();
    if (stopwatch.elapsedMilliseconds > 50) {
      AppLogger.warn('Slow update on $table (${stopwatch.elapsedMilliseconds}ms)', domain: LogDomain.db);
    }
    return result;
  }

  Future<int> delete(
    String table, {
    required String where,
    required List<dynamic> whereArgs,
  }) async {
    final stopwatch = Stopwatch()..start();
    final db = await database;
    final result = await db.delete(
      table,
      where: where,
      whereArgs: whereArgs,
    );
    stopwatch.stop();
    if (stopwatch.elapsedMilliseconds > 50) {
      AppLogger.warn('Slow delete on $table (${stopwatch.elapsedMilliseconds}ms)', domain: LogDomain.db);
    }
    return result;
  }

  // --------------------------------------------------------------------------
  // PROCESSED_PACKETS REPLAY TABLE HELPERS
  // --------------------------------------------------------------------------

  /// Checks if packet_id exists in SQLite processed_packets table.
  Future<bool> isPacketProcessed(String packetId) async {
    final db = await database;
    final res = await db.query(
      'processed_packets',
      columns: ['packet_id'],
      where: 'packet_id = ?',
      whereArgs: [packetId],
      limit: 1,
    );
    return res.isNotEmpty;
  }

  /// Atomically claims a packet_id in SQLite processed_packets table.
  /// Throws DatabaseException / returns false if packet_id already exists (ConflictAlgorithm.fail).
  Future<bool> claimPacketProcessed({
    required String packetId,
    required String senderId,
    required int createdAt,
    required int expiresAt,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await database;
    try {
      final id = await db.insert(
        'processed_packets',
        {
          'packet_id': packetId,
          'sender_id': senderId,
          'first_seen_at': now,
          'created_at': createdAt,
          'expires_at': expiresAt,
        },
        conflictAlgorithm: ConflictAlgorithm.fail,
      );
      return id > 0;
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) {
        return false;
      }
      rethrow;
    }
  }

  /// Purges expired processed_packets entries where expires_at < currentTimestampMs.
  Future<int> purgeExpiredProcessedPackets({required int currentTimestampMs}) async {
    final db = await database;
    return await db.delete(
      'processed_packets',
      where: 'expires_at < ?',
      whereArgs: [currentTimestampMs],
    );
  }

  /// One-time reconciliation migration: Imports legacy omnilink_routing.db data into omnilink_mesh.db.
  /// Destination writes execute in a single SQLite transaction.
  /// Migration is idempotent and resumable; file rename occurs ONLY after transaction commits successfully.
  Future<void> _migrateLegacyRoutingDatabase(Database meshDb, String dbPath) async {
    final routingDbPath = join(dbPath, 'omnilink_routing.db');
    final routingDbFile = File(routingDbPath);

    if (!await routingDbFile.exists()) {
      return; // Fresh install or already migrated
    }

    AppLogger.info('Found legacy omnilink_routing.db — starting schema reconciliation migration into omnilink_mesh.db', domain: LogDomain.db);

    try {
      final legacyDb = await openDatabase(routingDbPath, readOnly: true);

      await meshDb.transaction((txn) async {
        // 1. Migrate routing_table with last_updated timestamp resolution
        try {
          final routes = await legacyDb.query('routing_table');
          for (final r in routes) {
            await txn.rawInsert('''
              INSERT INTO routing_table (
                destination_node_id, next_hop_peer_id, next_hop_node_id, hop_count, probability, signal_quality, last_updated, last_successful_delivery, delivery_attempts, delivery_successes, is_active
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(destination_node_id) DO UPDATE SET
                next_hop_peer_id = excluded.next_hop_peer_id,
                next_hop_node_id = excluded.next_hop_node_id,
                hop_count = excluded.hop_count,
                probability = excluded.probability,
                signal_quality = excluded.signal_quality,
                last_updated = excluded.last_updated,
                last_successful_delivery = excluded.last_successful_delivery,
                delivery_attempts = excluded.delivery_attempts,
                delivery_successes = excluded.delivery_successes,
                is_active = excluded.is_active
              WHERE excluded.last_updated > routing_table.last_updated;
            ''', [
              r['destination_node_id'], r['next_hop_peer_id'], r['next_hop_node_id'], r['hop_count'], r['probability'], r['signal_quality'], r['last_updated'], r['last_successful_delivery'], r['delivery_attempts'], r['delivery_successes'], r['is_active']
            ]);
          }
        } catch (e) {
          AppLogger.warn('Routing table legacy import exception: $e', domain: LogDomain.db);
        }

        // 2. Migrate neighbor_table with last_seen timestamp resolution
        try {
          final neighbors = await legacyDb.query('neighbor_table');
          for (final n in neighbors) {
            await txn.rawInsert('''
              INSERT INTO neighbor_table (
                peer_id, node_id, friendly_name, rssi, link_quality, first_seen, last_seen, is_connected, packets_sent, packets_received, packets_failed
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(peer_id) DO UPDATE SET
                node_id = excluded.node_id,
                friendly_name = excluded.friendly_name,
                rssi = excluded.rssi,
                link_quality = excluded.link_quality,
                first_seen = excluded.first_seen,
                last_seen = excluded.last_seen,
                is_connected = excluded.is_connected,
                packets_sent = excluded.packets_sent,
                packets_received = excluded.packets_received,
                packets_failed = excluded.packets_failed
              WHERE excluded.last_seen > neighbor_table.last_seen;
            ''', [
              n['peer_id'], n['node_id'], n['friendly_name'], n['rssi'], n['link_quality'], n['first_seen'], n['last_seen'], n['is_connected'], n['packets_sent'], n['packets_received'], n['packets_failed']
            ]);
          }
        } catch (e) {
          AppLogger.warn('Neighbor table legacy import exception: $e', domain: LogDomain.db);
        }

        // 3. Migrate encounter_history with last_encounter timestamp resolution
        try {
          final encounters = await legacyDb.query('encounter_history');
          for (final e in encounters) {
            await txn.rawInsert('''
              INSERT INTO encounter_history (
                node_id, peer_id, predictability, encounter_count, last_encounter, first_encounter, avg_duration_seconds
              ) VALUES (?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(node_id) DO UPDATE SET
                peer_id = excluded.peer_id,
                predictability = excluded.predictability,
                encounter_count = excluded.encounter_count,
                last_encounter = excluded.last_encounter,
                first_encounter = excluded.first_encounter,
                avg_duration_seconds = excluded.avg_duration_seconds
              WHERE excluded.last_encounter > encounter_history.last_encounter;
            ''', [
              e['node_id'], e['peer_id'], e['predictability'], e['encounter_count'], e['last_encounter'], e['first_encounter'], e['avg_duration_seconds']
            ]);
          }
        } catch (e) {
          AppLogger.warn('Encounter history legacy import exception: $e', domain: LogDomain.db);
        }

        // 4. Migrate route_cache with cached_at timestamp resolution
        try {
          final caches = await legacyDb.query('route_cache');
          for (final c in caches) {
            await txn.rawInsert('''
              INSERT INTO route_cache (
                destination_node_id, next_hop_peer_id, path_json, cached_at
              ) VALUES (?, ?, ?, ?)
              ON CONFLICT(destination_node_id) DO UPDATE SET
                next_hop_peer_id = excluded.next_hop_peer_id,
                path_json = excluded.path_json,
                cached_at = excluded.cached_at
              WHERE excluded.cached_at > route_cache.cached_at;
            ''', [
              c['destination_node_id'], c['next_hop_peer_id'], c['path_json'], c['cached_at']
            ]);
          }
        } catch (e) {
          AppLogger.warn('Route cache legacy import exception: $e', domain: LogDomain.db);
        }
      });

      await legacyDb.close();

      // Rename legacy routing database file ONLY after successful destination commit
      final backupPath = join(dbPath, 'omnilink_routing.db.migrated');
      await routingDbFile.rename(backupPath);
      AppLogger.info('Successfully reconciled legacy omnilink_routing.db into omnilink_mesh.db', domain: LogDomain.db);
    } catch (e) {
      AppLogger.warn('Legacy routing database reconciliation encountered non-fatal error: $e', domain: LogDomain.db);
    }
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
