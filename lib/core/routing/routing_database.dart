import 'dart:async';
import 'package:sqflite/sqflite.dart';

import '../database/database_service.dart';
import '../diagnostics/app_logger.dart';
import 'models/encounter_record.dart';
import 'models/neighbor_info.dart';
import 'models/queued_packet.dart';
import 'models/route_entry.dart';

/// Compatibility Facade for Routing operations, forwarding to authoritative [DatabaseService] (omnilink_mesh.db).
class RoutingDatabaseService {
  static final RoutingDatabaseService instance = RoutingDatabaseService._internal();

  RoutingDatabaseService._internal();

  factory RoutingDatabaseService() => instance;

  Future<Database> get database async {
    return DatabaseService.instance.database;
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
    AppLogger.info('Applied PRoPHET decay to ${all.length} encounter records.', domain: LogDomain.routing);
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
  // 4. OUTBOX QUEUE CRUD & BATCHED DELETION
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

  Future<QueuedPacket?> getQueuedPacketById(String packetId) async {
    final db = await database;
    final maps = await db.query(
      'outbox_queue',
      where: 'packet_id = ?',
      whereArgs: [packetId],
      limit: 1,
    );
    return maps.isEmpty ? null : QueuedPacket.fromMap(maps.first);
  }

  // ===========================================================================
  // 4b. SENT-HISTORY RETENTION (ANTI-ENTROPY RESEND)
  // ===========================================================================

  /// Stores a delivered packet so a peer can still request it after the
  /// outbox row has been removed by a verified receipt.
  Future<void> insertSentPacket({
    required String packetId,
    required String recipientNodeId,
    required String payload,
    required int sentAtMs,
    required int expiresAtMs,
  }) async {
    final db = await database;
    await db.insert(
      'sent_history',
      {
        'packet_id': packetId,
        'recipient_node_id': recipientNodeId,
        'payload': payload,
        'sent_at': sentAtMs,
        'expires_at': expiresAtMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<String>> getSentPacketIds({
    int limit = 10000,
    int? notExpiredAfter,
  }) async {
    final db = await database;
    final maps = await db.query(
      'sent_history',
      columns: ['packet_id'],
      where: notExpiredAfter != null ? 'expires_at >= ?' : null,
      whereArgs: notExpiredAfter != null ? [notExpiredAfter] : null,
      orderBy: 'sent_at DESC',
      limit: limit,
    );
    return maps.map((m) => m['packet_id'] as String).toList();
  }

  Future<Map<String, String>> getSentPacketPayloadsByIds(
    List<String> packetIds,
  ) async {
    if (packetIds.isEmpty) return const {};
    final db = await database;
    final placeholders = List.filled(packetIds.length, '?').join(',');
    final maps = await db.query(
      'sent_history',
      columns: ['packet_id', 'payload'],
      where: 'packet_id IN ($placeholders)',
      whereArgs: packetIds,
    );
    return {
      for (final row in maps)
        row['packet_id'] as String: row['payload'] as String,
    };
  }

  Future<int> purgeExpiredSentHistory(int currentTimestampMs) async {
    final db = await database;
    return db.delete(
      'sent_history',
      where: 'expires_at < ?',
      whereArgs: [currentTimestampMs],
    );
  }

  Future<List<QueuedPacket>> getPendingOutboxPackets() async {
    final db = await database;
    final maps = await db.query(
      'outbox_queue',
      where: 'status = ? OR status = ?',
      whereArgs: ['pending', 'sending'],
    );
    final packets = maps.map((m) => QueuedPacket.fromMap(m)).toList();
    packets.sort((a, b) => b.urgencyScore.compareTo(a.urgencyScore));
    return packets;
  }

  /// Returns packets whose retry or lease deadline has elapsed.
  ///
  /// This is the only query the flusher uses for transmission. Reading the
  /// outbox must never mutate state; the previous unconditional
  /// `sending -> pending` reset allowed concurrent flushes to double-send.
  Future<List<QueuedPacket>> getDueOutboxPackets(DateTime now) async {
    final db = await database;
    final maps = await db.query(
      'outbox_queue',
      where: "status IN ('pending', 'sending') AND next_retry_at <= ?",
      whereArgs: [now.millisecondsSinceEpoch],
    );
    final packets = maps.map((m) => QueuedPacket.fromMap(m)).toList();
    packets.sort((a, b) => b.urgencyScore.compareTo(a.urgencyScore));
    return packets;
  }

  /// Claims packets for one transmission attempt. `next_retry_at` is reused as
  /// a lease deadline so a crash cannot leave rows stuck in 'sending' forever.
  Future<int> claimOutboxPackets(List<String> ids, DateTime leaseUntil) {
    return _batchUpdateOutbox(
      ids,
      status: 'sending',
      nextRetryAt: leaseUntil,
    );
  }

  /// Marks link-acked packets as awaiting an end-to-end delivery receipt.
  Future<int> markOutboxPacketsAwaitingReceipt(
    List<String> ids,
    DateTime nextRetryAt,
  ) {
    return _batchUpdateOutbox(
      ids,
      status: 'pending',
      nextRetryAt: nextRetryAt,
    );
  }

  Future<int> markOutboxPacketAwaitingReceipt(
    String id,
    DateTime nextRetryAt,
  ) async {
    final db = await database;
    return db.update(
      'outbox_queue',
      {
        'status': 'pending',
        'next_retry_at': nextRetryAt.millisecondsSinceEpoch,
      },
      where: 'packet_id = ?',
      whereArgs: [id],
    );
  }

  Future<int> _batchUpdateOutbox(
    List<String> ids, {
    required String status,
    required DateTime nextRetryAt,
  }) async {
    if (ids.isEmpty) return 0;
    final db = await database;
    return db.transaction((txn) async {
      final batch = txn.batch();
      for (final id in ids) {
        batch.update(
          'outbox_queue',
          {
            'status': status,
            'next_retry_at': nextRetryAt.millisecondsSinceEpoch,
          },
          where: 'packet_id = ?',
          whereArgs: [id],
        );
      }
      final results = await batch.commit();
      return results.length;
    });
  }

  Future<void> deleteQueuedPacket(String packetId) async {
    final db = await database;
    await db.delete(
      'outbox_queue',
      where: 'packet_id = ?',
      whereArgs: [packetId],
    );
  }

  /// Atomic batch deletion of multiple outbox packets inside a single SQLite transaction.
  Future<int> deleteQueuedPacketsByIds(List<String> ids) async {
    if (ids.isEmpty) return 0;
    final db = await database;
    final stopwatch = Stopwatch()..start();

    final count = await db.transaction((txn) async {
      final batch = txn.batch();
      for (final id in ids) {
        batch.delete(
          'outbox_queue',
          where: 'packet_id = ?',
          whereArgs: [id],
        );
      }
      final results = await batch.commit();
      return results.length;
    });

    stopwatch.stop();
    AppLogger.info(
      'Atomic batch deleted ${ids.length} outbox packets in ${stopwatch.elapsedMilliseconds}ms',
      domain: LogDomain.db,
    );
    return count;
  }

  /// Atomic batch status update for multiple outbox packets.
  Future<int> markPacketsStatus(List<String> ids, String status) async {
    if (ids.isEmpty) return 0;
    final db = await database;
    final stopwatch = Stopwatch()..start();

    final count = await db.transaction((txn) async {
      final batch = txn.batch();
      for (final id in ids) {
        batch.update(
          'outbox_queue',
          {'status': status},
          where: 'packet_id = ?',
          whereArgs: [id],
        );
      }
      final results = await batch.commit();
      return results.length;
    });

    stopwatch.stop();
    AppLogger.info(
      'Atomic batch marked ${ids.length} outbox packets status=$status in ${stopwatch.elapsedMilliseconds}ms',
      domain: LogDomain.db,
    );
    return count;
  }

  /// Atomic batch update for multiple queued packets (e.g. exponential backoff updates).
  Future<void> batchUpdateQueuedPackets(List<QueuedPacket> packets) async {
    if (packets.isEmpty) return;
    final db = await database;
    final stopwatch = Stopwatch()..start();

    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final packet in packets) {
        batch.insert(
          'outbox_queue',
          packet.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });

    stopwatch.stop();
    AppLogger.info(
      'Atomic batch updated ${packets.length} outbox packets in ${stopwatch.elapsedMilliseconds}ms',
      domain: LogDomain.db,
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

  Future<void> close() async {
    await DatabaseService.instance.close();
  }
}
