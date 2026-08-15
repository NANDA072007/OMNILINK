import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';

import '../../transport_bridge/transport_adapter.dart';
import '../crypto/crypto_service.dart';
import '../crypto/packet_service.dart';
import '../models/packet_envelope.dart';
import '../models/peer_device.dart';
import 'models/route_entry.dart';
import 'router_engine.dart';
import 'routing_database.dart';

/// Implements the OMNILINK Route Discovery Protocol.
/// Manages periodic ROUTING_TABLE_SYNC, peer connection ROUTE_ADVERTISEMENT,
/// and reactive ROUTE_REQUEST / ROUTE_REPLY discovery queries.
class RouteProtocol {
  final RouterEngine router;
  final TransportAdapter transport;
  final PacketService packetService;
  final RoutingDatabaseService db;
  final CryptoService cryptoService;
  final String Function() getMyNodeId;
  final List<PeerDevice> Function() getConnectedPeers;

  Timer? _syncTimer;

  RouteProtocol({
    required this.router,
    required this.transport,
    required this.packetService,
    required this.db,
    required this.cryptoService,
    required this.getMyNodeId,
    required this.getConnectedPeers,
  });

  /// Starts periodic broadcasting of routing tables (default every 45s).
  void startPeriodicSync({Duration interval = const Duration(seconds: 45)}) {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(interval, (_) => broadcastRoutingTable());
    debugPrint('OMNILINK_ROUTE: RouteProtocol periodic sync started (${interval.inSeconds}s interval).');
  }

  /// Stops periodic routing table sync.
  void stopPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  // ===========================================================================
  // 1. ROUTING_TABLE_SYNC
  // ===========================================================================

  /// Broadcasts top 20 routing table entries to all connected peers.
  Future<void> broadcastRoutingTable() async {
    try {
      final myNodeId = getMyNodeId();
      if (myNodeId.isEmpty) return;

      final routes = await db.getAllRoutes();
      routes.sort((a, b) => b.probability.compareTo(a.probability));
      final topRoutes = routes.take(20).toList();

      final entriesPayload = topRoutes.map((r) => {
        'destinationNodeId': r.destinationNodeId,
        'hopCount': r.hopCount,
        'probability': r.probability,
      }).toList();

      final payloadJson = jsonEncode(entriesPayload);
      final now = DateTime.now().millisecondsSinceEpoch;

      final envelope = PacketEnvelope(
        protocolVersion: '0.1',
        packetId: 'sync_${now}_$myNodeId',
        senderId: myNodeId,
        recipientId: 'BROADCAST',
        createdAt: now,
        expiresAt: now + 3600000,
        ttl: 1, // Directly connected peers only
        hopCount: 0,
        priority: 0, // Lower priority than user messages
        messageType: 'ROUTING_TABLE_SYNC',
        payloadHash: await cryptoService.sha256Hex(Uint8List.fromList(utf8.encode(payloadJson))),
        signature: 'public_metadata',
        encryptedPayload: payloadJson,
      );

      final connectedPeers = getConnectedPeers()
          .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
          .toList();

      final bytes = utf8.encode(envelope.toJson());
      for (final peer in connectedPeers) {
        await transport.sendPacket(peer.peerId, bytes);
      }

      debugPrint('OMNILINK_ROUTE: broadcasting routing table with ${topRoutes.length} entries to ${connectedPeers.length} peer(s)');
    } catch (e) {
      debugPrint('OMNILINK_ROUTE: Error broadcasting routing table: $e');
    }
  }

  /// Handles incoming ROUTING_TABLE_SYNC from a connected peer.
  Future<void> handleRoutingTableSync(PacketEnvelope envelope, String fromPeerId) async {
    try {
      final entriesList = jsonDecode(envelope.encryptedPayload) as List<dynamic>;
      int mergedCount = 0;

      for (final item in entriesList) {
        final map = item as Map<String, dynamic>;
        final destId = map['destinationNodeId'] as String;
        final remoteHopCount = (map['hopCount'] as num).toInt();
        final remoteProb = (map['probability'] as num).toDouble();

        if (destId == getMyNodeId()) continue;

        final newHopCount = remoteHopCount + 1;
        final existingRoutes = await db.getRoutesForDestination(destId);
        final existingRoute = existingRoutes.isNotEmpty ? existingRoutes.first : null;

        if (existingRoute == null || newHopCount < existingRoute.hopCount) {
          await db.insertOrUpdateRoute(
            RouteEntry(
              destinationNodeId: destId,
              nextHopPeerId: fromPeerId,
              hopCount: newHopCount,
              probability: (remoteProb * 0.9).clamp(0.0, 1.0),
              lastUpdated: DateTime.now(),
              isActive: true,
            ),
          );
          mergedCount++;
        }
      }

      debugPrint('OMNILINK_ROUTE: merged $mergedCount routes from peer $fromPeerId');
    } catch (e) {
      debugPrint('OMNILINK_ROUTE: Error merging ROUTING_TABLE_SYNC: $e');
    }
  }

  // ===========================================================================
  // 2. ROUTE_ADVERTISEMENT
  // ===========================================================================

  /// Sends ROUTE_ADVERTISEMENT when connecting to a new peer.
  Future<void> sendRouteAdvertisement(String connectedPeerId) async {
    try {
      final myNodeId = getMyNodeId();
      if (myNodeId.isEmpty) return;

      final connectedPeers = getConnectedPeers()
          .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
          .map((p) => p.nodeId ?? p.peerId)
          .toList();

      final payloadMap = {
        'nodeId': myNodeId,
        'directNodes': connectedPeers,
      };

      final payloadJson = jsonEncode(payloadMap);
      final now = DateTime.now().millisecondsSinceEpoch;

      final envelope = PacketEnvelope(
        protocolVersion: '0.1',
        packetId: 'adv_${now}_$myNodeId',
        senderId: myNodeId,
        recipientId: connectedPeerId,
        createdAt: now,
        expiresAt: now + 3600000,
        ttl: 1,
        hopCount: 0,
        priority: 0,
        messageType: 'ROUTE_ADVERTISEMENT',
        payloadHash: await cryptoService.sha256Hex(Uint8List.fromList(utf8.encode(payloadJson))),
        signature: 'public_metadata',
        encryptedPayload: payloadJson,
      );

      final bytes = utf8.encode(envelope.toJson());
      await transport.sendPacket(connectedPeerId, bytes);

      debugPrint('OMNILINK_ROUTE: sent route advertisement to $connectedPeerId');
    } catch (e) {
      debugPrint('OMNILINK_ROUTE: Error sending route advertisement: $e');
    }
  }

  /// Handles incoming ROUTE_ADVERTISEMENT from a newly connected peer.
  Future<void> handleRouteAdvertisement(PacketEnvelope envelope, String fromPeerId) async {
    try {
      final map = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
      final senderNodeId = map['nodeId'] as String;
      final directNodes = (map['directNodes'] as List<dynamic>).cast<String>();

      int learnedCount = 0;

      // Add route to sender (1 hop, prob 1.0)
      if (senderNodeId != getMyNodeId()) {
        await db.insertOrUpdateRoute(
          RouteEntry(
            destinationNodeId: senderNodeId,
            nextHopPeerId: fromPeerId,
            hopCount: 1,
            probability: 1.0,
            lastUpdated: DateTime.now(),
            isActive: true,
          ),
        );
        learnedCount++;
      }

      // Add routes to directly connected nodes of sender (2 hops, prob 0.9)
      for (final directNode in directNodes) {
        if (directNode == getMyNodeId()) continue;
        await db.insertOrUpdateRoute(
          RouteEntry(
            destinationNodeId: directNode,
            nextHopPeerId: fromPeerId,
            hopCount: 2,
            probability: 0.9,
            lastUpdated: DateTime.now(),
            isActive: true,
          ),
        );
        learnedCount++;
      }

      debugPrint('OMNILINK_ROUTE: learned $learnedCount new routes from advertisement by $fromPeerId');
    } catch (e) {
      debugPrint('OMNILINK_ROUTE: Error handling ROUTE_ADVERTISEMENT: $e');
    }
  }

  // ===========================================================================
  // 3. ROUTE_REQUEST & ROUTE_REPLY
  // ===========================================================================

  /// Broadcasts ROUTE_REQUEST query for a path to targetNodeId when no route exists.
  Future<void> sendRouteRequest(String targetNodeId) async {
    try {
      final myNodeId = getMyNodeId();
      if (myNodeId.isEmpty) return;

      final payloadMap = {'targetNodeId': targetNodeId};
      final payloadJson = jsonEncode(payloadMap);
      final now = DateTime.now().millisecondsSinceEpoch;

      final envelope = PacketEnvelope(
        protocolVersion: '0.1',
        packetId: 'req_${now}_${targetNodeId.substring(0, min(8, targetNodeId.length))}',
        senderId: myNodeId,
        recipientId: 'BROADCAST',
        createdAt: now,
        expiresAt: now + 30000,
        ttl: 4,
        hopCount: 0,
        priority: 0,
        messageType: 'ROUTE_REQUEST',
        payloadHash: await cryptoService.sha256Hex(Uint8List.fromList(utf8.encode(payloadJson))),
        signature: 'public_metadata',
        encryptedPayload: payloadJson,
      );

      final connectedPeers = getConnectedPeers()
          .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
          .toList();

      final bytes = utf8.encode(envelope.toJson());
      for (final peer in connectedPeers) {
        await transport.sendPacket(peer.peerId, bytes);
      }

      debugPrint('OMNILINK_ROUTE: broadcasted ROUTE_REQUEST for target $targetNodeId to ${connectedPeers.length} peer(s)');
    } catch (e) {
      debugPrint('OMNILINK_ROUTE: Error broadcasting ROUTE_REQUEST: $e');
    }
  }

  /// Handles incoming ROUTE_REQUEST from a peer.
  Future<void> handleRouteRequest(PacketEnvelope envelope, String fromPeerId) async {
    try {
      final map = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
      final targetNodeId = map['targetNodeId'] as String;
      final myNodeId = getMyNodeId();

      RouteEntry? validRoute;

      if (targetNodeId == myNodeId) {
        validRoute = RouteEntry(
          destinationNodeId: myNodeId,
          nextHopPeerId: fromPeerId,
          hopCount: 0,
          probability: 1.0,
          lastUpdated: DateTime.now(),
        );
      } else {
        final routes = await db.getRoutesForDestination(targetNodeId);
        if (routes.isNotEmpty && routes.first.isActive && envelope.ttl > 2) {
          validRoute = routes.first;
        }
      }

      if (validRoute != null) {
        final replyPayload = {
          'targetNodeId': targetNodeId,
          'hopCount': validRoute.hopCount,
          'probability': validRoute.probability,
        };
        final replyJson = jsonEncode(replyPayload);
        final now = DateTime.now().millisecondsSinceEpoch;

        final replyEnvelope = PacketEnvelope(
          protocolVersion: '0.1',
          packetId: 'rpl_${now}_$targetNodeId',
          senderId: myNodeId,
          recipientId: envelope.senderId,
          createdAt: now,
          expiresAt: now + 60000,
          ttl: 4,
          hopCount: 0,
          priority: 0,
          messageType: 'ROUTE_REPLY',
          payloadHash: await cryptoService.sha256Hex(Uint8List.fromList(utf8.encode(replyJson))),
          signature: 'public_metadata',
          encryptedPayload: replyJson,
        );

        final bytes = utf8.encode(replyEnvelope.toJson());
        await transport.sendPacket(fromPeerId, bytes);

        debugPrint('OMNILINK_ROUTE: replied to ROUTE_REQUEST for $targetNodeId to $fromPeerId');
      }
    } catch (e) {
      debugPrint('OMNILINK_ROUTE: Error handling ROUTE_REQUEST: $e');
    }
  }

  /// Handles incoming ROUTE_REPLY confirming a discovered route.
  Future<void> handleRouteReply(PacketEnvelope envelope, String fromPeerId) async {
    try {
      final map = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
      final targetNodeId = map['targetNodeId'] as String;
      final remoteHopCount = (map['hopCount'] as num).toInt();
      final remoteProb = (map['probability'] as num).toDouble();

      await db.insertOrUpdateRoute(
        RouteEntry(
          destinationNodeId: targetNodeId,
          nextHopPeerId: fromPeerId,
          hopCount: remoteHopCount + 1,
          probability: remoteProb,
          lastUpdated: DateTime.now(),
          isActive: true,
        ),
      );

      debugPrint('OMNILINK_ROUTE: discovered route to $targetNodeId via $fromPeerId');

      // Retry/flush any queued outbox messages waiting for this targetNodeId
      await router.flushOutboxForDestination(targetNodeId);
    } catch (e) {
      debugPrint('OMNILINK_ROUTE: Error handling ROUTE_REPLY: $e');
    }
  }

  void dispose() {
    stopPeriodicSync();
  }
}
