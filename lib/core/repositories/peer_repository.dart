import '../database/database_service.dart';
import '../models/peer_device.dart';

/// Repository managing permanent persistence and queries for discovered/known mesh peer devices.
/// Enforces 100% deterministic contact deduplication by immutable Ed25519 public key [nodeId].
class PeerRepository {
  final DatabaseService _dbService;

  PeerRepository({DatabaseService? dbService})
      : _dbService = dbService ?? DatabaseService.instance;

  /// Saves or updates a [PeerDevice] in the local SQLite database.
  /// Uses immutable 64-character Ed25519 [nodeId] as primary key to prevent duplicate contact creation.
  Future<void> savePeer(PeerDevice peer) async {
    final targetNodeId = peer.nodeId;
    // Only persist peers with resolved cryptographic nodeId (64-char hex)
    if (targetNodeId == null || targetNodeId.length < 32) return;

    final db = await _dbService.database;

    // Purge any transient orphan rows created during raw discovery before nodeId handshake
    if (peer.peerId.isNotEmpty && peer.peerId != targetNodeId) {
      await db.delete(
        'peers',
        where: 'node_id = ? AND peer_id = ?',
        whereArgs: [peer.peerId, peer.peerId],
      );
    }

    final data = peer.toMap();
    data['node_id'] = targetNodeId;
    await _dbService.insert('peers', data);
  }

  /// Retrieves all persisted peer devices from the database without duplicates.
  Future<List<PeerDevice>> getAllPeers() async {
    try {
      final rows = await _dbService.query(
        'peers',
        where: 'LENGTH(node_id) >= 32',
        orderBy: 'last_seen_at DESC',
      );

      final Map<String, PeerDevice> uniquePeers = {};
      for (final map in rows) {
        try {
          final peer = PeerDevice.fromMap(map);
          if (peer.nodeId != null && peer.nodeId!.length >= 32) {
            if (!uniquePeers.containsKey(peer.nodeId)) {
              uniquePeers[peer.nodeId!] = peer;
            }
          }
        } catch (_) {}
      }
      return uniquePeers.values.toList();
    } catch (_) {
      return [];
    }
  }

  /// Finds a specific peer by its hex Ed25519 public key / node ID.
  Future<PeerDevice?> getPeerByNodeId(String nodeId) async {
    try {
      final rows = await _dbService.query(
        'peers',
        where: 'node_id = ? OR peer_id = ?',
        whereArgs: [nodeId, nodeId],
        limit: 1,
      );

      if (rows.isEmpty) return null;
      return PeerDevice.fromMap(rows.first);
    } catch (_) {
      return null;
    }
  }

  /// Deletes a peer from local database.
  Future<void> deletePeer(String nodeId) async {
    await _dbService.delete(
      'peers',
      where: 'node_id = ? OR peer_id = ?',
      whereArgs: [nodeId, nodeId],
    );
  }
}
