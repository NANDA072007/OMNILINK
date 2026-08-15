import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'models/encounter_record.dart';
import 'models/neighbor_info.dart';
import 'models/queued_packet.dart';
import 'models/route_entry.dart';

/// SQLite Database Service managing persistence for the OMNILINK Intelligent Routing Engine.
class RoutingDatabaseService {
  static const String _dbName = 'omnilink_routing.db';
  static const int _dbVersion = 1;

  static final RoutingDatabaseService instance = RoutingDatabaseService._internal();
  static Database? _database;

  RoutingDatabaseService._internal();

  factory RoutingDatabaseService() => instance;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
    );
  }

  /// Initial table creation schema for routing structures.
  Future<void> _onCreate(Database db, int version) async {
    // 1. Routing Table
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
      )
    ''');

    // 2. Neighbor Table
    await db.execute('''
      CREATE TABLE neighbor_table (
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
      )
    ''');

    // 3. Encounter History Table
    await db.execute('''
      CREATE TABLE encounter_history (
        node_id TEXT PRIMARY KEY,
        peer_id TEXT NOT NULL,
        predictability REAL NOT NULL DEFAULT 0.75,
        encounter_count INTEGER NOT NULL DEFAULT 1,
        last_encounter INTEGER NOT NULL,
        first_encounter INTEGER NOT NULL,
        avg_duration_seconds REAL NOT NULL DEFAULT 0.0
      )
    ''');

    // 4. Outbox Queue Table
    await db.execute('''
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

    // 5. Route Cache Table
    await db.execute('''
      CREATE TABLE route_cache (
        destination_node_id TEXT PRIMARY KEY,
        next_hop_peer_id TEXT NOT NULL,
        path_json TEXT,
        cached_at INTEGER NOT NULL
      )
    ''');
  }

  // ===========================================================================
  // 1. ROUTING TABLE CRUD & QUERIES
  // ===========================================================================

  Future<void> insertOrUpdateRoute(RouteEntry entry) async {
    final db = await database;
    await db.insert(
      'routing_table',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<RouteEntry>> getAllRoutes() async {
    final db = await database;
    final maps = await db.query('routing_table');
    return maps.map((m) => RouteEntry.fromMap(m)).toList();
  }

  Future<List<RouteEntry>> getRoutesForDestination(String destinationNodeId) async {
    final db = await database;
    final maps = await db.query(
      'routing_table',
      where: 'destination_node_id = ? AND is_active = 1',
      whereArgs: [destinationNodeId],
      orderBy: 'probability DESC, hop_count ASC',
    );
    return maps.map((m) => RouteEntry.fromMap(m)).toList();
  }

  Future<RouteEntry?> getTopProbableRelay(String destinationNodeId) async {
    final routes = await getRoutesForDestination(destinationNodeId);
    return routes.isNotEmpty ? routes.first : null;
  }

  Future<void> deleteRoute(String destinationNodeId) async {
    final db = await database;
    await db.delete(
      'routing_table',
      where: 'destination_node_id = ?',
      whereArgs: [destinationNodeId],
    );
  }

  // ===========================================================================
  // 2. NEIGHBOR TABLE CRUD
  // ===========================================================================

  Future<void> insertOrUpdateNeighbor(NeighborInfo neighbor) async {
    final db = await database;
    await db.insert(
      'neighbor_table',
      neighbor.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<NeighborInfo>> getAllNeighbors() async {
    final db = await database;
    final maps = await db.query('neighbor_table');
    return maps.map((m) => NeighborInfo.fromMap(m)).toList();
  }

  Future<NeighborInfo?> getNeighborByPeerId(String peerId) async {
    final db = await database;
    final maps = await db.query(
      'neighbor_table',
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
    return maps.isNotEmpty ? NeighborInfo.fromMap(maps.first) : null;
  }

  Future<void> deleteNeighbor(String peerId) async {
    final db = await database;
    await db.delete(
      'neighbor_table',
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
  }

  // ===========================================================================
  // 3. ENCOUNTER HISTORY CRUD & PROPHET CALCULATIONS
  // ===========================================================================

  Future<void> insertOrUpdateEncounter(EncounterRecord record) async {
    final db = await database;
    await db.insert(
      'encounter_history',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<EncounterRecord>> getAllEncounters() async {
    final db = await database;
    final maps = await db.query('encounter_history');
    return maps.map((m) => EncounterRecord.fromMap(m)).toList();
  }

  Future<EncounterRecord?> getEncounterByNodeId(String nodeId) async {
    final db = await database;
    final maps = await db.query(
      'encounter_history',
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
    return maps.isNotEmpty ? EncounterRecord.fromMap(maps.first) : null;
  }

  Future<void> recordEncounter(String nodeId, String peerId) async {
    final existing = await getEncounterByNodeId(nodeId);
    final now = DateTime.now();

    if (existing == null) {
      final newRecord = EncounterRecord(
        nodeId: nodeId,
        peerId: peerId,
        predictability: 0.75,
        encounterCount: 1,
        lastEncounter: now,
        firstEncounter: now,
      );
      await insertOrUpdateEncounter(newRecord);
    } else {
      final updated = existing.updatePredictability(now: now);
      await insertOrUpdateEncounter(updated);
    }
  }

  Future<void> decayEncounters() async {
    final db = await database;
    final all = await getAllEncounters();
    final now = DateTime.now();

    final batch = db.batch();
    for (final record in all) {
      final decayed = record.applyDecay(now: now);
      batch.insert(
        'encounter_history',
        decayed.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    debugPrint('OMNILINK_ROUTING_DB: Applied PRoPHET decay to ${all.length} encounter records.');
  }

  Future<void> deleteEncounter(String nodeId) async {
    final db = await database;
    await db.delete(
      'encounter_history',
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
  }

  // ===========================================================================
  // 4. OUTBOX QUEUE CRUD & QUERIES
  // ===========================================================================

  Future<void> insertOrUpdateQueuedPacket(QueuedPacket packet) async {
    final db = await database;
    await db.insert(
      'outbox_queue',
      packet.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<QueuedPacket>> getAllQueuedPackets() async {
    final db = await database;
    final maps = await db.query('outbox_queue');
    return maps.map((m) => QueuedPacket.fromMap(m)).toList();
  }

  Future<List<QueuedPacket>> getPendingOutboxPackets() async {
    final db = await database;
    final maps = await db.query(
      'outbox_queue',
      where: 'status = ?',
      whereArgs: ['pending'],
    );
    final packets = maps.map((m) => QueuedPacket.fromMap(m)).toList();
    // Sort in-memory by urgency score descending
    packets.sort((a, b) => b.urgencyScore.compareTo(a.urgencyScore));
    return packets;
  }

  Future<void> deleteQueuedPacket(String packetId) async {
    final db = await database;
    await db.delete(
      'outbox_queue',
      where: 'packet_id = ?',
      whereArgs: [packetId],
    );
  }

  // ===========================================================================
  // 5. ROUTE CACHE CRUD
  // ===========================================================================

  Future<void> cacheRoute(String destinationNodeId, String nextHopPeerId, List<String>? path) async {
    final db = await database;
    await db.insert(
      'route_cache',
      {
        'destination_node_id': destinationNodeId,
        'next_hop_peer_id': nextHopPeerId,
        'path_json': path?.join(','),
        'cached_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
