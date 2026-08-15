import 'dart:async';
import 'package:flutter/foundation.dart';

import 'models/encounter_record.dart';
import 'models/neighbor_info.dart';
import 'models/route_entry.dart';
import 'routing_database.dart';

/// Selection result from PRoPHET relay evaluation.
class PeerSelection {
  final NeighborInfo? peer;
  final double score;

  const PeerSelection({
    this.peer,
    required this.score,
  });
}

/// Central PRoPHET (Probabilistic Routing Protocol using History of Encounters and Transitivity) Engine.
/// Manages encounter metrics, time-decay calculations, predictability transitivity exchange,
/// and optimal probabilistic next-hop relay selection.
class ProphetEngine {
  static const double kEncounter = 0.75;    // Boost factor when nodes meet
  static const double gammaDecay = 0.98;    // Hourly decay rate without contact
  static const double pInitial = 0.1;       // Initial predictability for new encounters
  static const double transitivityK = 0.5;  // Transitivity trust multiplier for indirect paths
  static const int maxEncounterRecords = 500;

  final RoutingDatabaseService db;

  ProphetEngine({required this.db});

  /// Called when discovering or connecting to a peer device.
  /// Updates or creates encounter record with formula: P_new = P_old + (1 - P_old) * K_ENCOUNTER
  Future<void> recordEncounter(String nodeId, String peerId, {int? rssi}) async {
    final now = DateTime.now();
    final existing = await db.getEncounterByNodeId(nodeId);

    if (existing == null) {
      final newRecord = EncounterRecord(
        nodeId: nodeId,
        peerId: peerId,
        predictability: pInitial + (1.0 - pInitial) * kEncounter,
        encounterCount: 1,
        lastEncounter: now,
        firstEncounter: now,
      );
      await db.insertOrUpdateEncounter(newRecord);
      debugPrint('OMNILINK_PROPHET: new encounter with $nodeId ($peerId), P=${newRecord.predictability.toStringAsFixed(3)}');
    } else {
      final updated = existing.updatePredictability(now: now, pEncounter: kEncounter);
      await db.insertOrUpdateEncounter(updated);
      debugPrint('OMNILINK_PROPHET: encounter with $nodeId ($peerId), P=${updated.predictability.toStringAsFixed(3)}');
    }

    // Enforce max 500 encounter records limit
    await _enforceRecordCapacity();
  }

  /// Periodically decays probabilities for all known nodes: P_new = P_old * (GAMMA_DECAY ^ hours)
  Future<void> decayProbabilities() async {
    final all = await db.getAllEncounters();
    final now = DateTime.now();
    int activeCount = 0;

    for (final record in all) {
      final decayed = record.applyDecay(now: now, gamma: gammaDecay);
      await db.insertOrUpdateEncounter(decayed);
      if (decayed.predictability >= 0.01) {
        activeCount++;
      }
    }
    debugPrint('OMNILINK_PROPHET: Decayed ${all.length} encounter records. $activeCount active records remain.');
  }

  /// Calculates indirect transitivity predictability for reaching targetNodeId via relayNodeId:
  /// P(local -> relay) * P(relay -> target) * TRANSITIVITY_K
  Future<double> getPredictability(String relayNodeId, String targetNodeId) async {
    if (relayNodeId == targetNodeId) return 1.0;

    final relayEncounter = await db.getEncounterByNodeId(relayNodeId);
    final pRelay = relayEncounter?.predictability ?? 0.0;

    final targetRoutes = await db.getRoutesForDestination(targetNodeId);
    final relayRoute = targetRoutes.firstWhere(
      (r) => r.nextHopPeerId == relayNodeId || r.nextHopNodeId == relayNodeId,
      orElse: () => RouteEntry(
        destinationNodeId: targetNodeId,
        nextHopPeerId: relayNodeId,
        probability: 0.1,
        lastUpdated: DateTime.now(),
      ),
    );

    return (pRelay * relayRoute.probability * transitivityK).clamp(0.0, 1.0);
  }

  /// Evaluates connected peers and selects the optimal PRoPHET relay for a target destination.
  Future<PeerSelection> selectBestRelay(String targetNodeId, List<NeighborInfo> connectedPeers) async {
    NeighborInfo? bestPeer;
    double bestScore = 0.0;

    for (final peer in connectedPeers) {
      if (!peer.isConnected) continue;
      final relayNodeId = peer.nodeId ?? peer.peerId;
      double score = await getPredictability(relayNodeId, targetNodeId);

      // Weight score by physical link quality
      score = (score * peer.linkQuality).clamp(0.0, 1.0);

      if (score > bestScore) {
        bestScore = score;
        bestPeer = peer;
      }
    }

    return PeerSelection(peer: bestPeer, score: bestScore);
  }

  /// Exchanges and updates transitivity predictability vectors from remote peer.
  /// Transitivity: P(A->C) = max(P(A->C), P(A->B) * P(B->C) * TRANSITIVITY_K)
  Future<void> exchangePredictability(String peerNodeId, Map<String, double> peerVector) async {
    final myEncounterWithPeer = await db.getEncounterByNodeId(peerNodeId);
    final pMyToPeer = myEncounterWithPeer?.predictability ?? 0.1;
    int updatedCount = 0;

    for (final entry in peerVector.entries) {
      final targetNodeId = entry.key;
      final peerP = entry.value;

      final transitiveP = (pMyToPeer * peerP * transitivityK).clamp(0.0, 1.0);
      final existingEncounter = await db.getEncounterByNodeId(targetNodeId);
      final existingP = existingEncounter?.predictability ?? 0.0;

      if (transitiveP > existingP) {
        final now = DateTime.now();
        final updatedRecord = (existingEncounter ??
            EncounterRecord(
              nodeId: targetNodeId,
              peerId: peerNodeId,
              predictability: transitiveP,
              lastEncounter: now,
              firstEncounter: now,
            )).copyWith(
          predictability: transitiveP,
          lastEncounter: now,
        );

        await db.insertOrUpdateEncounter(updatedRecord);
        updatedCount++;
      }
    }

    debugPrint('OMNILINK_PROPHET: Exchanged predictability vector with $peerNodeId ($updatedCount transitive routes updated).');
  }

  /// Private helper enforcing max 500 encounter records per node.
  Future<void> _enforceRecordCapacity() async {
    final all = await db.getAllEncounters();
    if (all.length <= maxEncounterRecords) return;

    // Sort by predictability ascending (lowest predictability removed first)
    all.sort((a, b) => a.predictability.compareTo(b.predictability));
    final overflowCount = all.length - maxEncounterRecords;

    for (int i = 0; i < overflowCount; i++) {
      await db.deleteEncounter(all[i].nodeId);
    }

    debugPrint('OMNILINK_PROPHET: Purged $overflowCount lowest predictability encounter records (cap=$maxEncounterRecords).');
  }
}
