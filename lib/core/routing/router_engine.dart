import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../../transport_bridge/transport_adapter.dart';
import '../crypto/crypto_service.dart';
import '../crypto/packet_service.dart';
import '../database/database_service.dart';
import '../models/packet_envelope.dart';
import '../models/peer_device.dart';
import '../repositories/message_repository.dart';
import 'models/neighbor_info.dart';
import 'models/route_entry.dart';
import 'outbox_daemon.dart';
import 'prophet_engine.dart';
import 'route_protocol.dart';
import 'routing_database.dart';
import 'send_queue.dart';

enum RouteStrategy {
  direct,
  distanceVector,
  probabilistic,
  controlledFlood,
  storeAndForward,
}

class RouteDecision {
  final RouteStrategy strategy;
  final String? peerId;        // For single-target strategies
  final List<String>? peerIds; // For flood strategy
  final String reason;         // For logging

  const RouteDecision({
    required this.strategy,
    this.peerId,
    this.peerIds,
    required this.reason,
  });
}

class RoutingEvent {
  final String eventType;  // "forwarded", "dropped", "queued", "delivered", "receipt"
  final String packetId;
  final String strategy;
  final String? peerId;
  final DateTime timestamp;

  const RoutingEvent({
    required this.eventType,
    required this.packetId,
    required this.strategy,
    this.peerId,
    required this.timestamp,
  });
}

/// Central 5-Layer Intelligent Mesh Router Engine for OMNILINK.
/// Intercepts all incoming/outgoing packets, decides next-hop relays, manages outbox queues,
/// and applies PRoPHET DTN delivery predictability.
class RouterEngine {
  final TransportAdapter transport;
  final PacketService packetService;
  final CryptoService cryptoService;
  final RoutingDatabaseService db;
  final String Function() getMyNodeId;
  final List<PeerDevice> Function() getConnectedPeers;
  late final ProphetEngine prophetEngine;
  late final RouteProtocol routeProtocol;
  late final OutboxDaemon outboxDaemon;
  late final SendQueueManager sendQueueManager;

  final Map<String, String> _peerIdToNodeId = {};
  final Map<String, String> _nodeIdToPeerId = {};
  void Function(String peerId, String nodeId)? onPeerNodeIdDiscovered;

  final _localInboundController = StreamController<PacketEnvelope>.broadcast();
  final _routingEventsController = StreamController<RoutingEvent>.broadcast();

  StreamSubscription<IncomingPacketEvent>? _packetSubscription;
  StreamSubscription<PeerConnectionEvent>? _peerSubscription;
  Timer? _maintenanceTimer;

  RouterEngine({
    required this.transport,
    required this.packetService,
    required this.cryptoService,
    required this.db,
    required this.getMyNodeId,
    required this.getConnectedPeers,
  }) {
    prophetEngine = ProphetEngine(db: db);
    routeProtocol = RouteProtocol(
      router: this,
      transport: transport,
      packetService: packetService,
      db: db,
      cryptoService: cryptoService,
      prophetEngine: prophetEngine,
      getMyNodeId: getMyNodeId,
      getConnectedPeers: getConnectedPeers,
    );
    outboxDaemon = OutboxDaemon(
      db: db,
      transport: transport,
      router: this,
      messageRepo: MessageRepository(dbService: DatabaseService.instance),
      getConnectedPeers: getConnectedPeers,
    );
    sendQueueManager = SendQueueManager(transport: transport);
    _init();
  }

  void _init() {
    _packetSubscription = transport.incomingPackets.listen(_handleIncomingPacket);
    _peerSubscription = transport.peerEvents.listen(_handlePeerEvent);
    _maintenanceTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _periodicMaintenance();
    });
    routeProtocol.startPeriodicSync(interval: const Duration(seconds: 45));
    debugPrint('OMNILINK_ROUTER: RouterEngine initialized with RouteProtocol.');
  }

  Stream<PacketEnvelope> get localInboundStream => _localInboundController.stream;
  Stream<RoutingEvent> get routingEvents => _routingEventsController.stream;

  void registerPeerNodeId(String peerId, String nodeId) {
    if (nodeId.isEmpty || peerId.isEmpty) return;
    final isNew = _peerIdToNodeId[peerId] != nodeId;
    _peerIdToNodeId[peerId] = nodeId;
    _nodeIdToPeerId[nodeId] = peerId;

    if (isNew) {
      final shortNodeId = nodeId.length > 8 ? nodeId.substring(0, 8) : nodeId;
      debugPrint('OMNILINK_ROUTER: Registered registry mapping peerId $peerId <-> nodeId $shortNodeId...');
      onPeerNodeIdDiscovered?.call(peerId, nodeId);
      unawaited(outboxDaemon.onIdentityLearned(nodeId, peerId));
    }
  }

  void _emitEvent(String type, String packetId, String strategy, {String? peerId}) {
    _routingEventsController.add(
      RoutingEvent(
        eventType: type,
        packetId: packetId,
        strategy: strategy,
        peerId: peerId,
        timestamp: DateTime.now(),
      ),
    );
  }

  // ===========================================================================
  // 1. INBOUND PACKET INTERCEPTION
  // ===========================================================================

  Future<void> _handleIncomingPacket(IncomingPacketEvent event) async {
    try {
      final jsonStr = utf8.decode(event.payloadBytes);
      final envelope = PacketEnvelope.fromJson(jsonStr);

      // Deduplication check
      if (packetService.isDuplicate(envelope.packetId)) {
        debugPrint('OMNILINK_ROUTER: Dropping duplicate packet ${envelope.packetId}');
        _emitEvent('dropped', envelope.packetId, 'duplicate', peerId: event.senderPeerId);
        return;
      }

      // Mark processed
      packetService.markProcessed(envelope.packetId);

      // TASK 1: Register peerId <-> nodeId mapping in registry & flush outbox
      registerPeerNodeId(event.senderPeerId, envelope.senderId);

      // Record encounter with sender and update PRoPHET probabilities
      await prophetEngine.recordEncounter(envelope.senderId, event.senderPeerId);

      final myNodeId = getMyNodeId();

      // Local Delivery check
      if (envelope.recipientId == myNodeId) {
        debugPrint('OMNILINK_ROUTER: Packet ${envelope.packetId} delivered to local node from ${event.senderPeerId}');
        _localInboundController.add(envelope);
        _emitEvent('delivered', envelope.packetId, 'local', peerId: event.senderPeerId);

        if (envelope.messageType == 'MESSAGE_PAYLOAD') {
          await _sendDeliveryReceipt(envelope);
        } else if (envelope.messageType == 'DELIVERY_RECEIPT') {
          await _handleDeliveryReceipt(envelope);
        } else if (envelope.messageType == 'ROUTING_TABLE_SYNC') {
          await routeProtocol.handleRoutingTableSync(envelope, event.senderPeerId);
        } else if (envelope.messageType == 'ROUTE_ADVERTISEMENT') {
          await routeProtocol.handleRouteAdvertisement(envelope, event.senderPeerId);
        } else if (envelope.messageType == 'ROUTE_REQUEST') {
          await routeProtocol.handleRouteRequest(envelope, event.senderPeerId);
        } else if (envelope.messageType == 'ROUTE_REPLY') {
          await routeProtocol.handleRouteReply(envelope, event.senderPeerId);
        }
        return;
      }

      // Handle non-local control packets
      if (envelope.messageType == 'ROUTING_TABLE_SYNC') {
        await routeProtocol.handleRoutingTableSync(envelope, event.senderPeerId);
        return;
      } else if (envelope.messageType == 'ROUTE_ADVERTISEMENT') {
        await routeProtocol.handleRouteAdvertisement(envelope, event.senderPeerId);
        return;
      } else if (envelope.messageType == 'ROUTE_REQUEST') {
        await routeProtocol.handleRouteRequest(envelope, event.senderPeerId);
        return;
      } else if (envelope.messageType == 'ROUTE_REPLY') {
        await routeProtocol.handleRouteReply(envelope, event.senderPeerId);
        return;
      }

      // Multi-hop forwarding check
      await _forwardPacket(envelope, event.senderPeerId);
    } catch (e) {
      debugPrint('OMNILINK_ROUTER: Error parsing incoming packet: $e');
    }
  }

  // ===========================================================================
  // 2. MULTI-HOP FORWARDING
  // ===========================================================================

  Future<void> _forwardPacket(PacketEnvelope envelope, String ingressPeerId) async {
    if (envelope.ttl <= 1) {
      debugPrint('OMNILINK_ROUTER: Dropped packet ${envelope.packetId} due to TTL exhaustion (ttl=${envelope.ttl})');
      _emitEvent('dropped', envelope.packetId, 'ttl_exhausted', peerId: ingressPeerId);
      return;
    }

    // Mutate TTL & hopCount (Not in canonical Ed25519 signature digest)
    final forwarded = envelope.copyWith(
      ttl: envelope.ttl - 1,
      hopCount: envelope.hopCount + 1,
    );

    final decision = await _selectNextHop(forwarded, ingressPeerId: ingressPeerId);

    if (decision.strategy == RouteStrategy.direct && decision.peerId != null) {
      final success = await transport.sendPacket(decision.peerId!, utf8.encode(forwarded.toJson()));
      if (success) {
        debugPrint('OMNILINK_ROUTER: forwarded packet ${envelope.packetId} to ${decision.peerId} via direct');
        _emitEvent('forwarded', envelope.packetId, 'direct', peerId: decision.peerId);
      }
    } else if (decision.strategy == RouteStrategy.distanceVector && decision.peerId != null) {
      final success = await transport.sendPacket(decision.peerId!, utf8.encode(forwarded.toJson()));
      if (success) {
        debugPrint('OMNILINK_ROUTER: forwarded packet ${envelope.packetId} to ${decision.peerId} via distanceVector');
        _emitEvent('forwarded', envelope.packetId, 'distanceVector', peerId: decision.peerId);
      }
    } else if (decision.strategy == RouteStrategy.probabilistic && decision.peerId != null) {
      final success = await transport.sendPacket(decision.peerId!, utf8.encode(forwarded.toJson()));
      if (success) {
        debugPrint('OMNILINK_ROUTER: forwarded packet ${envelope.packetId} to ${decision.peerId} via probabilistic');
        _emitEvent('forwarded', envelope.packetId, 'probabilistic', peerId: decision.peerId);
      }
    } else if (decision.strategy == RouteStrategy.controlledFlood && decision.peerIds != null) {
      for (final peerId in decision.peerIds!) {
        await transport.sendPacket(peerId, utf8.encode(forwarded.toJson()));
      }
      debugPrint('OMNILINK_ROUTER: forwarded packet ${envelope.packetId} to ${decision.peerIds!.length} peer(s) via controlledFlood');
      _emitEvent('forwarded', envelope.packetId, 'controlledFlood');
    }
  }

  // ===========================================================================
  // 3. 5-LAYER ROUTE SELECTION ENGINE
  // ===========================================================================

  Future<RouteDecision> _selectNextHop(PacketEnvelope envelope, {String? ingressPeerId}) async {
    final connectedPeers = getConnectedPeers()
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
        .toList();

    final candidatePeers = connectedPeers
        .where((p) => p.peerId != ingressPeerId)
        .toList();

    // Layer 1: Direct Link Check (Peer ID <-> Node ID mapped)
    final mappedPeerId = _nodeIdToPeerId[envelope.recipientId];
    final directPeer = connectedPeers.firstWhere(
      (p) => p.peerId == envelope.recipientId ||
             p.nodeId == envelope.recipientId ||
             p.peerId == mappedPeerId,
      orElse: () => PeerDevice(
        peerId: '',
        friendlyName: '',
        lastSeenAt: DateTime.now(),
        transportType: 'ANDROID_NEARBY',
        connectionStatus: PeerConnectionStatus.disconnected,
      ),
    );
    if (directPeer.peerId.isNotEmpty) {
      debugPrint('OMNILINK_ROUTER: Decision for ${envelope.recipientId} -> Direct connection found via peerId ${directPeer.peerId}');
      return RouteDecision(
        strategy: RouteStrategy.direct,
        peerId: directPeer.peerId,
        reason: 'Recipient is directly connected radio link',
      );
    }

    debugPrint('OMNILINK_ROUTER: Decision for ${envelope.recipientId} -> No direct connection. Routing to Outbox.');

    // Layer 2: Distance Vector Routing Table
    final route = await db.getTopProbableRelay(envelope.recipientId);
    if (route != null && route.isActive) {
      final isNextHopConnected = connectedPeers.any((p) => p.peerId == route.nextHopPeerId);
      if (isNextHopConnected && route.nextHopPeerId != ingressPeerId) {
        return RouteDecision(
          strategy: RouteStrategy.distanceVector,
          peerId: route.nextHopPeerId,
          reason: 'Distance vector routing table entry (probability=${route.probability})',
        );
      }
    }

    // Layer 3: PRoPHET Probabilistic (ProphetEngine)
    final neighborInfos = candidatePeers.map((p) => NeighborInfo(
      peerId: p.peerId,
      nodeId: p.nodeId,
      friendlyName: p.friendlyName,
      rssi: p.rssi,
      linkQuality: NeighborInfo.computeLinkQuality(p.rssi),
      firstSeen: p.lastSeenAt,
      lastSeen: p.lastSeenAt,
      isConnected: true,
    )).toList();

    final prophetSelection = await prophetEngine.selectBestRelay(envelope.recipientId, neighborInfos);
    if (prophetSelection.peer != null && prophetSelection.score > 0.15) {
      debugPrint('OMNILINK_PROPHET: Layer 3 selected relay ${prophetSelection.peer!.peerId} with score ${prophetSelection.score.toStringAsFixed(3)}');
      return RouteDecision(
        strategy: RouteStrategy.probabilistic,
        peerId: prophetSelection.peer!.peerId,
        reason: 'PRoPHET probabilistic relay score (${prophetSelection.score.toStringAsFixed(3)}) > 0.15 threshold',
      );
    }

    // Layer 4: Controlled Flood
    if (candidatePeers.isNotEmpty) {
      unawaited(routeProtocol.sendRouteRequest(envelope.recipientId));
      return RouteDecision(
        strategy: RouteStrategy.controlledFlood,
        peerIds: candidatePeers.map((p) => p.peerId).toList(),
        reason: 'Controlled TTL flooding across ${candidatePeers.length} active peers',
      );
    }

    // Layer 5: Store-and-Forward / Outbox Queue
    unawaited(routeProtocol.sendRouteRequest(envelope.recipientId));
    return const RouteDecision(
      strategy: RouteStrategy.storeAndForward,
      reason: 'No active radio paths. Saved to SQLite outbox queue.',
    );
  }

  // ===========================================================================
  // 4. OUTBOUND MESSAGE TRANSMISSION
  // ===========================================================================

  Future<void> sendMessage(PacketEnvelope envelope) async {
    final connectedPeers = getConnectedPeers()
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
        .toList();
    debugPrint('OMNILINK_ROUTER: Checking active connections... found ${connectedPeers.length} peers.');

    final decision = await _selectNextHop(envelope);

    if (decision.strategy != RouteStrategy.storeAndForward) {
      final payloadBytes = utf8.encode(envelope.toJson());
      bool anySent = false;

      if (decision.peerId != null) {
        debugPrint('OMNILINK_ROUTER: Match found. Handing to SendQueue for peerId ${decision.peerId}.');
        anySent = await sendQueueManager.enqueueAndSend(
          packetId: envelope.packetId,
          peerId: decision.peerId!,
          payloadBytes: payloadBytes,
        );
      } else if (decision.peerIds != null) {
        for (final peerId in decision.peerIds!) {
          final sent = await sendQueueManager.enqueueAndSend(
            packetId: envelope.packetId,
            peerId: peerId,
            payloadBytes: payloadBytes,
          );
          if (sent) anySent = true;
        }
      }

      if (anySent) {
        debugPrint('OMNILINK_ROUTER: Transmitted outbound packet ${envelope.packetId} via ${decision.strategy.name}');
        _emitEvent('forwarded', envelope.packetId, decision.strategy.name, peerId: decision.peerId);
        return;
      }
    }

    // Store-and-Forward queueing via OutboxDaemon
    debugPrint('OMNILINK_ROUTER: Saving packet ${envelope.packetId} to SQLite outbox_queue');
    await outboxDaemon.enqueue(envelope);
    _emitEvent('queued', envelope.packetId, 'storeAndForward');
  }

  // ===========================================================================
  // 5. CONTROL PACKETS & LEARNING
  // ===========================================================================

  Future<void> _sendDeliveryReceipt(PacketEnvelope original) async {
    final myNodeId = getMyNodeId();
    final receiptPayload = jsonEncode({
      'originalPacketId': original.packetId,
      'deliveredAt': DateTime.now().millisecondsSinceEpoch,
    });

    final receipt = PacketEnvelope(
      packetId: 'receipt_${original.packetId}',
      senderId: myNodeId,
      recipientId: original.senderId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      expiresAt: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      messageType: 'DELIVERY_RECEIPT',
      payloadHash: original.payloadHash,
      signature: original.signature,
      encryptedPayload: receiptPayload,
    );

    await sendMessage(receipt);
  }

  Future<void> _handleDeliveryReceipt(PacketEnvelope receiptEnvelope) async {
    debugPrint('OMNILINK_ROUTER: Received delivery receipt from ${receiptEnvelope.senderId} for ${receiptEnvelope.packetId}');
    await db.cacheRoute(receiptEnvelope.senderId, receiptEnvelope.senderId, null);
    await db.insertOrUpdateRoute(
      RouteEntry(
        destinationNodeId: receiptEnvelope.senderId,
        nextHopPeerId: receiptEnvelope.senderId,
        lastUpdated: DateTime.now(),
        lastSuccessfulDelivery: DateTime.now(),
        probability: 1.0,
      ),
    );
  }



  // ===========================================================================
  // 6. OUTBOX FLUSH ON PEER CONNECT
  // ===========================================================================

  Future<void> _handlePeerEvent(PeerConnectionEvent event) async {
    if (event.eventType == PeerConnectionEventType.onConnected) {
      await routeProtocol.sendRouteAdvertisement(event.peerId);
      await outboxDaemon.onPeerConnected(event.peerId);
    }
  }

  Future<void> _onPeerConnected(String peerId) async {
    debugPrint('OMNILINK_ROUTER: Peer connected ($peerId). Flushing pending outbox packets...');
    final pending = await db.getPendingOutboxPackets();

    for (final packet in pending) {
      final envelope = PacketEnvelope.fromJson(packet.payload);
      final decision = await _selectNextHop(envelope);

      if (decision.strategy != RouteStrategy.storeAndForward) {
        final bytes = utf8.encode(packet.payload);
        final success = await transport.sendPacket(peerId, bytes);
        if (success) {
          await db.deleteQueuedPacket(packet.packetId);
          debugPrint('OMNILINK_ROUTER: Flushed queued packet ${packet.packetId} to $peerId');
          _emitEvent('forwarded', packet.packetId, 'outbox_flush', peerId: peerId);
        }
      }
    }
  }

  // ===========================================================================
  // 7. PERIODIC MAINTENANCE (30s)
  // ===========================================================================

  Future<void> _periodicMaintenance() async {
    debugPrint('OMNILINK_ROUTER: Running 30s periodic maintenance...');
    await prophetEngine.decayProbabilities();

    final connectedPeers = getConnectedPeers()
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
        .toList();

    for (final peer in connectedPeers) {
      await _onPeerConnected(peer.peerId);
    }
  }

  /// Flushes pending outbox packets destined for targetNodeId when a route is discovered.
  Future<void> flushOutboxForDestination(String destinationNodeId) async {
    debugPrint('OMNILINK_ROUTER: Route discovered for $destinationNodeId. Retrying outbox queue...');
    final pending = await db.getPendingOutboxPackets();
    final targetPackets = pending.where((p) => p.recipientNodeId == destinationNodeId).toList();

    for (final packet in targetPackets) {
      final envelope = PacketEnvelope.fromJson(packet.payload);
      final decision = await _selectNextHop(envelope);

      if (decision.strategy != RouteStrategy.storeAndForward) {
        final bytes = utf8.encode(packet.payload);
        bool anySent = false;

        if (decision.peerId != null) {
          anySent = await transport.sendPacket(decision.peerId!, bytes);
        } else if (decision.peerIds != null) {
          for (final peerId in decision.peerIds!) {
            final sent = await transport.sendPacket(peerId, bytes);
            if (sent) anySent = true;
          }
        }

        if (anySent) {
          await db.deleteQueuedPacket(packet.packetId);
          debugPrint('OMNILINK_ROUTER: Flushed queued packet ${packet.packetId} to $destinationNodeId via ${decision.strategy.name}');
          _emitEvent('forwarded', packet.packetId, 'outbox_flush', peerId: decision.peerId);
        }
      }
    }
  }

  void dispose() {
    outboxDaemon.dispose();
    routeProtocol.dispose();
    _packetSubscription?.cancel();
    _peerSubscription?.cancel();
    _maintenanceTimer?.cancel();
    _localInboundController.close();
    _routingEventsController.close();
  }
}
