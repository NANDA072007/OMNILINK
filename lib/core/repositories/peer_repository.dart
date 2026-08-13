import '../database/database_service.dart';
import '../models/peer_device.dart';

/// Repository managing persistence and queries for discovered/known mesh peer devices.
class PeerRepository {
  final DatabaseService _dbService;

  PeerRepository({DatabaseService? dbService})
      : _dbService = dbService ?? DatabaseService.instance;

  /// Saves or updates a [PeerDevice] in the local SQLite database.
  Future<void> savePeer(PeerDevice peer) async {
    final data = peer.toMap();
    // Ensure primary key node_id is non-null by falling back to transient peer_id if needed
    data['node_id'] = peer.nodeId ?? peer.peerId;

    await _dbService.insert('peers', data);
  }

  /// Retrieves all persisted peer devices from the database.
  Future<List<PeerDevice>> getAllPeers() async {
    final rows = await _dbService.query(
      'peers',
      orderBy: 'last_seen_at DESC',
    );

    return rows.map((map) => PeerDevice.fromMap(map)).toList();
  }

  /// Finds a specific peer by its hex Ed25519 public key / node ID.
  Future<PeerDevice?> getPeerByNodeId(String nodeId) async {
    final rows = await _dbService.query(
      'peers',
      where: 'node_id = ? OR peer_id = ?',
      whereArgs: [nodeId, nodeId],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return PeerDevice.fromMap(rows.first);
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
