import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/encounter_record.dart';
import 'models/neighbor_info.dart';
import 'models/queued_packet.dart';
import 'models/route_entry.dart';
import 'routing_database.dart';

/// Database service provider for OMNILINK Intelligent Mesh Routing.
final routingDatabaseProvider = Provider<RoutingDatabaseService>((ref) {
  return RoutingDatabaseService.instance;
});

/// StateNotifier managing dynamic Routing Table entries in memory & SQLite.
class RoutingTableNotifier extends StateNotifier<List<RouteEntry>> {
  final RoutingDatabaseService _db;

  RoutingTableNotifier(this._db) : super([]) {
    loadRoutes();
  }

  Future<void> loadRoutes() async {
    final routes = await _db.getAllRoutes();
    state = routes;
  }

  Future<void> addOrUpdateRoute(RouteEntry route) async {
    await _db.insertOrUpdateRoute(route);
    await loadRoutes();
  }

  Future<void> removeRoute(String destinationNodeId) async {
    await _db.deleteRoute(destinationNodeId);
    await loadRoutes();
  }
}

final routingTableProvider =
    StateNotifierProvider<RoutingTableNotifier, List<RouteEntry>>((ref) {
  final db = ref.watch(routingDatabaseProvider);
  return RoutingTableNotifier(db);
});

/// StateNotifier managing direct radio Neighbors in memory & SQLite.
class NeighborTableNotifier extends StateNotifier<List<NeighborInfo>> {
  final RoutingDatabaseService _db;

  NeighborTableNotifier(this._db) : super([]) {
    loadNeighbors();
  }

  Future<void> loadNeighbors() async {
    final neighbors = await _db.getAllNeighbors();
    state = neighbors;
  }

  Future<void> addOrUpdateNeighbor(NeighborInfo neighbor) async {
    await _db.insertOrUpdateNeighbor(neighbor);
    await loadNeighbors();
  }

  Future<void> removeNeighbor(String peerId) async {
    await _db.deleteNeighbor(peerId);
    await loadNeighbors();
  }
}

final neighborTableProvider =
    StateNotifierProvider<NeighborTableNotifier, List<NeighborInfo>>((ref) {
  final db = ref.watch(routingDatabaseProvider);
  return NeighborTableNotifier(db);
});

/// StateNotifier managing PRoPHET Encounter History records in memory & SQLite.
class EncounterHistoryNotifier extends StateNotifier<List<EncounterRecord>> {
  final RoutingDatabaseService _db;

  EncounterHistoryNotifier(this._db) : super([]) {
    loadEncounters();
  }

  Future<void> loadEncounters() async {
    final records = await _db.getAllEncounters();
    state = records;
  }

  Future<void> recordEncounter(String nodeId, String peerId) async {
    await _db.recordEncounter(nodeId, peerId);
    await loadEncounters();
  }

  Future<void> applyDecay() async {
    await _db.decayEncounters();
    await loadEncounters();
  }
}

final encounterHistoryProvider =
    StateNotifierProvider<EncounterHistoryNotifier, List<EncounterRecord>>((ref) {
  final db = ref.watch(routingDatabaseProvider);
  return EncounterHistoryNotifier(db);
});

/// StateNotifier managing Outbox Queue packets in memory & SQLite.
class OutboxNotifier extends StateNotifier<List<QueuedPacket>> {
  final RoutingDatabaseService _db;

  OutboxNotifier(this._db) : super([]) {
    loadOutboxPackets();
  }

  Future<void> loadOutboxPackets() async {
    final packets = await _db.getPendingOutboxPackets();
    state = packets;
  }

  Future<void> enqueuePacket(QueuedPacket packet) async {
    await _db.insertOrUpdateQueuedPacket(packet);
    await loadOutboxPackets();
  }

  Future<void> removePacket(String packetId) async {
    await _db.deleteQueuedPacket(packetId);
    await loadOutboxPackets();
  }
}

final outboxProvider =
    StateNotifierProvider<OutboxNotifier, List<QueuedPacket>>((ref) {
  final db = ref.watch(routingDatabaseProvider);
  return OutboxNotifier(db);
});
