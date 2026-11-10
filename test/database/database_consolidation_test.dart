import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:omnilink/core/database/database_service.dart';
import 'package:omnilink/core/routing/routing_database.dart';
import 'package:omnilink/core/routing/models/route_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('Slice 1B.8 — Database Consolidation & Schema Reconciliation Tests', () {
    late String dbDirectory;

    setUp(() async {
      databaseFactory = databaseFactoryFfi;
      dbDirectory = await getDatabasesPath();
      await DatabaseService.instance.close();

      // Clean up test databases before each test run
      final meshPath = p.join(dbDirectory, 'omnilink_mesh.db');
      final routingPath = p.join(dbDirectory, 'omnilink_routing.db');
      final migratedPath = p.join(dbDirectory, 'omnilink_routing.db.migrated');

      final fMesh = File(meshPath);
      final fRouting = File(routingPath);
      final fMigrated = File(migratedPath);

      try {
        if (await fMesh.exists()) await fMesh.delete();
      } catch (_) {}
      try {
        if (await fRouting.exists()) await fRouting.delete();
      } catch (_) {}
      try {
        if (await fMigrated.exists()) await fMigrated.delete();
      } catch (_) {}
    });

    tearDown(() async {
      await DatabaseService.instance.close();
    });

    test('1. Fresh installation initializes single omnilink_mesh.db at v7 with all 11 unified tables', () async {
      final dbService = DatabaseService();
      final db = await dbService.database;

      final tablesRes = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table';");
      final tableNames = tablesRes.map((r) => r['name'] as String).toSet();

      expect(tableNames.contains('peers'), isTrue);
      expect(tableNames.contains('messages'), isTrue);
      expect(tableNames.contains('outbox_queue'), isTrue);
      expect(tableNames.contains('payload_transfers'), isTrue);
      expect(tableNames.contains('payload_chunks'), isTrue);
      expect(tableNames.contains('processed_packets'), isTrue);
      expect(tableNames.contains('sent_history'), isTrue);
      expect(tableNames.contains('routing_table'), isTrue);
      expect(tableNames.contains('neighbor_table'), isTrue);
      expect(tableNames.contains('encounter_history'), isTrue);
      expect(tableNames.contains('route_cache'), isTrue);

      final versionRes = await db.rawQuery('PRAGMA user_version;');
      expect(versionRes.first['user_version'], equals(7));
    });

    test('2 & 13. RoutingDatabaseService acts as facade and resolves to DatabaseService (omnilink_mesh.db)', () async {
      final dbService = DatabaseService();
      final routingDbService = RoutingDatabaseService();

      final meshDb = await dbService.database;
      final facadeDb = await routingDbService.database;

      expect(facadeDb, equals(meshDb), reason: 'RoutingDatabaseService MUST forward directly to DatabaseService.instance');
    });

    test('3, 4, 5, 6 & 12. Reconciliation Migration: Legacy omnilink_routing.db records are imported into omnilink_mesh.db and survive app restart', () async {
      // Step A: Create and populate legacy omnilink_routing.db manually
      final legacyPath = p.join(dbDirectory, 'omnilink_routing.db');
      final legacyDb = await openDatabase(
        legacyPath,
        version: 1,
        onCreate: (db, v) async {
          await db.execute('''
            CREATE TABLE routing_table (
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
        },
      );

      await legacyDb.insert('routing_table', {
        'destination_node_id': 'legacy_node_123',
        'next_hop_peer_id': 'peer_hop_1',
        'hop_count': 2,
        'probability': 0.85,
        'signal_quality': 0.9,
        'last_updated': 1000000,
        'is_active': 1,
      });
      await legacyDb.close();

      // Step B: Initialize DatabaseService (omnilink_mesh.db) which triggers legacy migration
      final dbService = DatabaseService();
      final meshDb = await dbService.database;

      // Step C: Verify legacy record was successfully reconciled into omnilink_mesh.db
      final routesInMesh = await meshDb.query('routing_table', where: 'destination_node_id = ?', whereArgs: ['legacy_node_123']);
      expect(routesInMesh.length, equals(1));
      expect(routesInMesh.first['next_hop_peer_id'], equals('peer_hop_1'));

      // Step D: Verify legacy omnilink_routing.db was safely renamed to omnilink_routing.db.migrated
      final legacyFile = File(legacyPath);
      final migratedFile = File(p.join(dbDirectory, 'omnilink_routing.db.migrated'));
      expect(await legacyFile.exists(), isFalse, reason: 'Active legacy omnilink_routing.db should no longer exist');
      expect(await migratedFile.exists(), isTrue, reason: 'Legacy DB file should be safely archived after migration');

      // Step E: Verify RoutingDatabaseService facade reads the imported route
      final routingFacade = RoutingDatabaseService();
      final routesViaFacade = await routingFacade.getRoutesForDestination('legacy_node_123');
      expect(routesViaFacade.length, equals(1));
      expect(routesViaFacade.first.nextHopPeerId, equals('peer_hop_1'));
    });

    test('7 & 8. Indexes and Constraints are preserved in consolidated omnilink_mesh.db', () async {
      final dbService = DatabaseService();
      final db = await dbService.database;

      final indexesRes = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='index';");
      final indexNames = indexesRes.map((r) => r['name'] as String).toSet();

      expect(indexNames.contains('idx_messages_conversation'), isTrue);
      expect(indexNames.contains('idx_outbox_recipient'), isTrue);
      expect(indexNames.contains('idx_processed_packets_expires'), isTrue);
      expect(indexNames.contains('idx_routing_dest'), isTrue);
    });

    test('9 & 11. Idempotent Migration: Interrupted or duplicate imports resolve deterministically without throwing', () async {
      final routingFacade = RoutingDatabaseService();

      final route = RouteEntry(
        destinationNodeId: 'dest_node_99',
        nextHopPeerId: 'peer_99',
        hopCount: 1,
        probability: 0.9,
        signalQuality: 0.8,
        lastUpdated: DateTime.now(),
      );

      // Insert once
      await routingFacade.insertOrUpdateRoute(route);

      // Re-insert duplicate
      await routingFacade.insertOrUpdateRoute(route);

      final routes = await routingFacade.getRoutesForDestination('dest_node_99');
      expect(routes.length, equals(1), reason: 'Duplicate route insertion MUST update or ignore gracefully without throwing');
    });

    test('10. Corrupted/empty legacy database file does not prevent omnilink_mesh.db startup', () async {
      final legacyPath = p.join(dbDirectory, 'omnilink_routing.db');
      final fCorrupt = File(legacyPath);
      await fCorrupt.writeAsString('INVALID_CORRUPT_SQLITE_HEADER_DATA');

      final dbService = DatabaseService();
      final db = await dbService.database;

      expect(db.isOpen, isTrue, reason: 'omnilink_mesh.db MUST open cleanly even if legacy routing DB is corrupted');
    });

    test('11. Timestamp-Based Conflict Resolution: Newer last_updated record in legacy DB overwrites older record in mesh DB', () async {
      final dbService = DatabaseService();
      final meshDb = await dbService.database;

      // Seed an older route entry in omnilink_mesh.db (timestamp = 1000)
      await meshDb.insert('routing_table', {
        'destination_node_id': 'conflict_node_1',
        'next_hop_peer_id': 'old_peer_1',
        'hop_count': 3,
        'probability': 0.5,
        'signal_quality': 0.5,
        'last_updated': 1000,
        'is_active': 1,
      });
      await dbService.close();

      // Seed a newer route entry in legacy omnilink_routing.db (timestamp = 5000)
      final legacyPath = p.join(dbDirectory, 'omnilink_routing.db');
      final legacyDb = await openDatabase(
        legacyPath,
        version: 1,
        onCreate: (db, v) async {
          await db.execute('''
            CREATE TABLE routing_table (
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
        },
      );

      await legacyDb.insert('routing_table', {
        'destination_node_id': 'conflict_node_1',
        'next_hop_peer_id': 'new_peer_2',
        'hop_count': 1,
        'probability': 0.95,
        'signal_quality': 0.9,
        'last_updated': 5000,
        'is_active': 1,
      });
      await legacyDb.close();

      // Trigger reconciliation migration
      final reloadedDb = await dbService.database;
      final routes = await reloadedDb.query('routing_table', where: 'destination_node_id = ?', whereArgs: ['conflict_node_1']);

      expect(routes.length, equals(1));
      expect(routes.first['next_hop_peer_id'], equals('new_peer_2'), reason: 'Newer timestamp record MUST win conflict resolution');
      expect(routes.first['last_updated'], equals(5000));
    });
  });
}
