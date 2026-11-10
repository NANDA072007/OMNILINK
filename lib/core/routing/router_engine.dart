import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../transport_bridge/transport_adapter.dart';
import '../../transport_bridge/android_transport_adapter.dart';
import '../crypto/crypto_service.dart';
import '../crypto/packet_service.dart';
import '../crypto/signed_prekey_manager.dart';
import '../database/database_service.dart';
import '../models/message.dart';
import '../models/packet_envelope.dart';
import '../models/peer_device.dart';
import '../models/signed_key_bundle.dart';
import '../repositories/message_repository.dart';
import '../repositories/peer_repository.dart';
import 'models/neighbor_info.dart';
import 'models/route_entry.dart';
import 'outbox_daemon.dart';
import 'prophet_engine.dart';
import 'route_protocol.dart';
import 'routing_database.dart';
import 'send_queue.dart';
import '../segmentation/transfer_manager.dart';
import '../segmentation/storage_cleanup_daemon.dart';

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
  final SimpleKeyPair? Function()? getMasterKeyPair;
  final SimpleKeyPair? Function()? getStaticX25519KeyPair;
  final SignedKeyBundle? Function()? getSignedKeyBundle;
  final List<PeerDevice> Function() getConnectedPeers;
  final MessageRepository messageRepo;
  late final ProphetEngine prophetEngine;
  late final RouteProtocol routeProtocol;
  late final OutboxDaemon outboxDaemon;
  late final SendQueueManager sendQueueManager;
  late final TransferManager transferManager;

  final Map<String, String> _peerIdToNodeId = {};
  final Map<String, String> _nodeIdToPeerId = {};
  void Function(String peerId, String nodeId, String? staticX25519PublicKeyHex)? onPeerNodeIdDiscovered;

  final _localInboundController = StreamController<PacketEnvelope>.broadcast();
  final _routingEventsController = StreamController<RoutingEvent>.broadcast();

  StreamSubscription<IncomingPacketEvent>? _packetSubscription;
  StreamSubscription<PeerConnectionEvent>? _peerSubscription;
  Timer? _maintenanceTimer;
  bool _isDisposed = false;
  bool get isDisposed => _isDisposed;

  RouterEngine({
    required this.transport,
    required this.packetService,
    required this.cryptoService,
    required this.db,
    required this.getMyNodeId,
    this.getMasterKeyPair,
    this.getStaticX25519KeyPair,
    this.getSignedKeyBundle,
    required this.getConnectedPeers,
    MessageRepository? messageRepo,
  }) : messageRepo = messageRepo ?? MessageRepository(dbService: DatabaseService.instance) {
    prophetEngine = ProphetEngine(db: db);
    routeProtocol = RouteProtocol(
      router: this,
      transport: transport,
      packetService: packetService,
      db: db,
      cryptoService: cryptoService,
      prophetEngine: prophetEngine,
      getMyNodeId: getMyNodeId,
      getMasterKeyPair: getMasterKeyPair,
      getSignedKeyBundle: getSignedKeyBundle,
      getConnectedPeers: getConnectedPeers,
    );
    sendQueueManager = SendQueueManager(transport: transport);
    routeProtocol.sendQueue = sendQueueManager;
    outboxDaemon = OutboxDaemon(
      db: db,
      transport: transport,
      router: this,
      messageRepo: this.messageRepo,
      getConnectedPeers: getConnectedPeers,
    );
    transferManager = TransferManager(
      sendQueueManager: sendQueueManager,
      dbService: DatabaseService.instance,
    );
    storageCleanupDaemon = StorageCleanupDaemon(dbService: DatabaseService.instance);
    _init();
  }

  late final StorageCleanupDaemon storageCleanupDaemon;

  void _init() {
    if (transport is AndroidTransportAdapter) {
      (transport as AndroidTransportAdapter).endpointResolver = getEndpointIdForNodeId;
    }
    sendQueueManager.endpointResolver = getEndpointIdForNodeId;
    _packetSubscription = transport.incomingPackets.listen(_handleIncomingPacket);
    _peerSubscription = transport.peerEvents.listen(_handlePeerEvent);
    _maintenanceTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _periodicMaintenance();
    });
    routeProtocol.startPeriodicSync(interval: const Duration(seconds: 45));
    storageCleanupDaemon.start();
    debugPrint('OMNILINK_ROUTER: RouterEngine initialized with RouteProtocol & StorageCleanupDaemon.');
  }

  /// Resolves a 64-char persistent nodeId to an active Nearby endpointId.
  String? getEndpointIdForNodeId(String nodeId) {
    final ep = _nodeIdToPeerId[nodeId];
    if (ep != null) return ep;
    final connected = getConnectedPeers()
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected);
    for (final p in connected) {
      if (p.nodeId == nodeId && p.peerId.isNotEmpty) {
        return p.peerId;
      }
    }
    return null;
  }

  /// Resolves an active Nearby endpointId to a 64-char persistent nodeId.
  String? getNodeIdForEndpointId(String endpointId) {
    final node = _peerIdToNodeId[endpointId];
    if (node != null) return node;
    final connected = getConnectedPeers();
    for (final p in connected) {
      if (p.peerId == endpointId && p.nodeId != null && p.nodeId!.isNotEmpty) {
        return p.nodeId;
      }
    }
    return null;
  }

  Stream<PacketEnvelope> get localInboundStream => _localInboundController.stream;
  Stream<RoutingEvent> get routingEvents => _routingEventsController.stream;

  void registerPeerNodeId(String peerId, String nodeId, {String? staticX25519PublicKeyHex}) {
    if (nodeId.isEmpty || peerId.isEmpty) return;
    final isNew = _peerIdToNodeId[peerId] != nodeId;
    _peerIdToNodeId[peerId] = nodeId;
    _nodeIdToPeerId[nodeId] = peerId;

    final shortNodeId = nodeId.length > 8 ? nodeId.substring(0, 8) : nodeId;
    if (isNew) {
      debugPrint('OMNILINK_ROUTER: Registered registry mapping peerId $peerId <-> nodeId $shortNodeId (X25519: ${staticX25519PublicKeyHex ?? "none"})');
    }
    onPeerNodeIdDiscovered?.call(peerId, nodeId, staticX25519PublicKeyHex);
    unawaited(messageRepo.migrateConversationId(peerId, nodeId));
    unawaited(outboxDaemon.onIdentityLearned(nodeId, peerId));
    // Push authoritative binding to native Kotlin so nodeId sends resolve on mesh.
    if (transport is AndroidTransportAdapter) {
      unawaited((transport as AndroidTransportAdapter).registerNodeMapping(nodeId, peerId));
    }
  }

  void unregisterPeerNodeId(String peerId) {
    if (peerId.isEmpty) return;
    final nodeId = _peerIdToNodeId.remove(peerId);
    if (nodeId != null) {
      if (_nodeIdToPeerId[nodeId] == peerId) {
        _nodeIdToPeerId.remove(nodeId);
      }
      debugPrint('OMNILINK_ROUTER: Unregistered mapping for disconnected peerId $peerId (nodeId: ${nodeId.length > 8 ? nodeId.substring(0, 8) : nodeId})');
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
    if (_isDisposed) return;
    try {
      final jsonStr = utf8.decode(event.payloadBytes);

      // Guard against non-envelope diagnostic PING/PONG packets
      try {
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map && (decoded['type'] == 'PING' || decoded['type'] == 'PONG')) {
          debugPrint('OMNILINK_ROUTER: Bypassing diagnostic ${decoded['type']} packet from ${event.senderPeerId}');
          return;
        }
      } catch (_) {}

      final envelope = PacketEnvelope.fromJson(jsonStr);

      // Structural check, timestamp check, Ed25519 signature verification, payload hash check & atomic replay claim
      try {
        final isValid = await packetService.validateAndClaimEnvelope(envelope);
        if (!isValid) {
          debugPrint('OMNILINK_ROUTER: Dropping invalid packet ${envelope.packetId}');
          _emitEvent('dropped', envelope.packetId, 'invalid', peerId: event.senderPeerId);
          return;
        }
      } on PacketValidationException catch (e) {
        if (e.errorCode == 'DUPLICATE_PACKET') {
          // Duplicates are expected in an at-least-once mesh. They are not
          // automatically failures: a retried message must re-trigger its
          // receipt, and a retried receipt must finish its outbox cleanup.
          await _handleDuplicatePacket(envelope, event.senderPeerId);
        } else {
          debugPrint('OMNILINK_ROUTER: Dropping invalid packet ${envelope.packetId}: ${e.errorCode} - ${e.message}');
          _emitEvent('dropped', envelope.packetId, e.errorCode, peerId: event.senderPeerId);
        }
        return;
      }

      // TASK 1: Register peerId <-> nodeId mapping in registry & flush outbox
      registerPeerNodeId(event.senderPeerId, envelope.senderId);

      // Record encounter with sender and update PRoPHET probabilities
      await prophetEngine.recordEncounter(envelope.senderId, event.senderPeerId);

      final myNodeId = getMyNodeId();

      // Local Delivery check
      if (envelope.recipientId == myNodeId) {
        debugPrint('OMNILINK_ROUTER: Packet ${envelope.packetId} delivered to local node from ${event.senderPeerId}');
        _emitEvent('delivered', envelope.packetId, 'local', peerId: event.senderPeerId);

        if (envelope.messageType == 'MESSAGE_PAYLOAD') {
          // Persist before notifying observers or acknowledging. A receipt sent
          // before the SQLite commit would let the sender delete its only copy.
          final persisted = await _processInboundMessagePayload(envelope);
          if (persisted) {
            _localInboundController.add(envelope);
            await _sendDeliveryReceipt(envelope);
          }
        } else {
          _localInboundController.add(envelope);

          if (envelope.messageType == 'DELIVERY_RECEIPT') {
            await _handleDeliveryReceipt(envelope);
          } else if (envelope.messageType == 'TRANSFER_OFFER' ||
              envelope.messageType == 'TRANSFER_ACCEPT' ||
              envelope.messageType == 'TRANSFER_REJECT' ||
              envelope.messageType == 'TRANSFER_ABORT' ||
              envelope.messageType == 'CHUNK_PAYLOAD' ||
              envelope.messageType == 'CHUNK_ACK') {
            await transferManager.handleIncomingEnvelope(envelope, event.senderPeerId);
            return;
          } else if (envelope.messageType == 'ROUTING_TABLE_SYNC') {
            await routeProtocol.handleRoutingTableSync(envelope, event.senderPeerId);
          } else if (envelope.messageType == 'ROUTE_ADVERTISEMENT') {
            await routeProtocol.handleRouteAdvertisement(envelope, event.senderPeerId);
          } else if (envelope.messageType == 'ROUTE_REQUEST') {
            await routeProtocol.handleRouteRequest(envelope, event.senderPeerId);
          } else if (envelope.messageType == 'ROUTE_REPLY') {
            await routeProtocol.handleRouteReply(envelope, event.senderPeerId);
          } else if (envelope.messageType == 'SYNC_HANDSHAKE') {
            await routeProtocol.handleSyncHandshake(envelope, event.senderPeerId);
          } else if (envelope.messageType == 'SYNC_REQUEST') {
            await routeProtocol.handleSyncRequest(envelope, event.senderPeerId);
          } else if (envelope.messageType == 'SYNC_SESSION_START') {
            await routeProtocol.handleSyncSessionStart(envelope, event.senderPeerId);
          } else if (envelope.messageType == 'SYNC_PAGE') {
            await routeProtocol.handleSyncPage(envelope, event.senderPeerId);
          } else if (envelope.messageType == 'SYNC_SESSION_END') {
            await routeProtocol.handleSyncSessionEnd(envelope, event.senderPeerId);
          }
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
      } else if (envelope.messageType == 'SYNC_HANDSHAKE') {
        await routeProtocol.handleSyncHandshake(envelope, event.senderPeerId);
        return;
      } else if (envelope.messageType == 'SYNC_REQUEST') {
        await routeProtocol.handleSyncRequest(envelope, event.senderPeerId);
        return;
      } else if (envelope.messageType == 'SYNC_SESSION_START') {
        await routeProtocol.handleSyncSessionStart(envelope, event.senderPeerId);
        return;
      } else if (envelope.messageType == 'SYNC_PAGE') {
        await routeProtocol.handleSyncPage(envelope, event.senderPeerId);
        return;
      } else if (envelope.messageType == 'SYNC_SESSION_END') {
        await routeProtocol.handleSyncSessionEnd(envelope, event.senderPeerId);
        return;
      }

      // Multi-hop forwarding check
      await _forwardPacket(envelope, event.senderPeerId);
    } catch (e) {
      debugPrint('OMNILINK_ROUTER: Error parsing incoming packet: $e');
    } finally {
      // Native holds the payload in its durable spool until this point. ACK
      // even rejected packets so a poison payload cannot loop forever; senders
      // retain their own receipt-driven outbox copy for retries.
      final spoolId = event.spoolId;
      if (spoolId != null && transport is AndroidTransportAdapter) {
        await (transport as AndroidTransportAdapter).acknowledgeInbound(spoolId);
      }
    }
  }

  /// Handles a packet already claimed by the replay cache. Duplicates are
  /// expected under at-least-once delivery and must heal the two situations
  /// that would otherwise strand state forever: a lost receipt, and a crash
  /// between the replay claim and the SQLite commit.
  Future<void> _handleDuplicatePacket(
    PacketEnvelope envelope,
    String senderPeerId,
  ) async {
    final myNodeId = getMyNodeId();

    if (envelope.recipientId == myNodeId &&
        envelope.messageType == 'MESSAGE_PAYLOAD') {
      final persisted = await _processInboundMessagePayload(envelope);
      if (persisted) {
        await _sendDeliveryReceipt(envelope);
      }
      _emitEvent(
        'duplicate_reconciled',
        envelope.packetId,
        'message',
        peerId: senderPeerId,
      );
      return;
    }

    if (envelope.recipientId == myNodeId &&
        envelope.messageType == 'DELIVERY_RECEIPT') {
      await _handleDeliveryReceipt(envelope);
      _emitEvent(
        'duplicate_reconciled',
        envelope.packetId,
        'receipt',
        peerId: senderPeerId,
      );
      return;
    }

    debugPrint('OMNILINK_ROUTER: Dropping duplicate packet ${envelope.packetId}');
    _emitEvent('dropped', envelope.packetId, 'duplicate', peerId: senderPeerId);
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
      final success = await sendQueueManager.enqueueAndSend(
        packetId: envelope.packetId,
        peerId: decision.peerId!,
        payloadBytes: utf8.encode(forwarded.toJson()),
      );
      if (success) {
        debugPrint('OMNILINK_ROUTER: Relaying packet ${envelope.packetId} to ${decision.peerId}');
        _emitEvent('forwarded', envelope.packetId, 'direct', peerId: decision.peerId);
      }
    } else if (decision.strategy == RouteStrategy.distanceVector && decision.peerId != null) {
      final success = await sendQueueManager.enqueueAndSend(
        packetId: envelope.packetId,
        peerId: decision.peerId!,
        payloadBytes: utf8.encode(forwarded.toJson()),
      );
      if (success) {
        debugPrint('OMNILINK_ROUTER: Relaying packet ${envelope.packetId} to ${decision.peerId}');
        _emitEvent('forwarded', envelope.packetId, 'distanceVector', peerId: decision.peerId);
      }
    } else if (decision.strategy == RouteStrategy.probabilistic && decision.peerId != null) {
      final success = await sendQueueManager.enqueueAndSend(
        packetId: envelope.packetId,
        peerId: decision.peerId!,
        payloadBytes: utf8.encode(forwarded.toJson()),
      );
      if (success) {
        debugPrint('OMNILINK_ROUTER: Relaying packet ${envelope.packetId} to ${decision.peerId}');
        _emitEvent('forwarded', envelope.packetId, 'probabilistic', peerId: decision.peerId);
      }
    } else if (decision.strategy == RouteStrategy.controlledFlood && decision.peerIds != null) {
      for (final peerId in decision.peerIds!) {
        debugPrint('OMNILINK_ROUTER: Relaying packet ${envelope.packetId} to $peerId');
        await sendQueueManager.enqueueAndSend(
          packetId: envelope.packetId,
          peerId: peerId,
          payloadBytes: utf8.encode(forwarded.toJson()),
        );
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
      final isNativeConnected = await transport.isConnected(directPeer.peerId);
      if (isNativeConnected) {
        debugPrint('OMNILINK_ROUTER: Decision for ${envelope.recipientId} -> Direct connection verified via peerId ${directPeer.peerId}');
        return RouteDecision(
          strategy: RouteStrategy.direct,
          peerId: directPeer.peerId,
          reason: 'Recipient is directly connected radio link',
        );
      } else {
        debugPrint('OMNILINK_ROUTER: Peer ${directPeer.peerId} not natively connected. Bypassing stale direct link.');
      }
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

  Future<void> sendMessage(
    PacketEnvelope envelope, {
    bool persistToOutbox = true,
  }) async {
    // Outbox-first: the durable copy must exist before any bytes hit a radio.
    // Receipts and other advisory packets are deliberately not persisted here;
    // they are themselves recoverable by retrying the original message.
    if (persistToOutbox) {
      await outboxDaemon.persist(envelope);
    }

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
        if (persistToOutbox) {
          // Link-level success is not end-to-end delivery. Keep the durable
          // row until a verified receipt arrives, but delay the next attempt.
          await outboxDaemon.markAwaitingReceipt(envelope.packetId);
          await messageRepo.updateMessageStateUnlessReceiptReceived(
            envelope.packetId,
            MessageState.delivered,
          );
        }
        return;
      }
    }

    debugPrint('OMNILINK_ROUTER: Packet ${envelope.packetId} remains in SQLite outbox_queue');
    if (persistToOutbox) {
      await messageRepo.updateMessageStateUnlessReceiptReceived(
        envelope.packetId,
        MessageState.queued,
      );
    }
    _emitEvent('queued', envelope.packetId, 'storeAndForward');
  }

  // ===========================================================================
  // 5. CONTROL PACKETS & LEARNING
  // ===========================================================================

  Future<void> _sendDeliveryReceipt(PacketEnvelope original) async {
    final myNodeId = getMyNodeId();
    final masterKeyPair = getMasterKeyPair?.call();
    if (myNodeId.isEmpty || masterKeyPair == null) {
      debugPrint('OMNILINK_ROUTER: Cannot sign delivery receipt — identity not ready.');
      return;
    }

    final receiptPayload = jsonEncode({
      'originalPacketId': original.packetId,
      'deliveredAt': DateTime.now().millisecondsSinceEpoch,
    });

    try {
      // The receipt is its own packet: it must carry its own payload hash and
      // signature. Reusing the original envelope's fields makes it unverifiable.
      final receipt = await packetService.createSignedControlEnvelope(
        senderNodeId: myNodeId,
        senderKeyPair: masterKeyPair,
        recipientNodeId: original.senderId,
        messageType: 'DELIVERY_RECEIPT',
        payloadJson: receiptPayload,
        packetId: 'receipt_${original.packetId}',
        ttl: 4,
        maxHops: 4,
        priority: 2,
        validity: const Duration(hours: 1),
      );

      await sendMessage(receipt, persistToOutbox: false);
    } catch (e) {
      debugPrint('OMNILINK_ROUTER: Failed to send delivery receipt for ${original.packetId}: $e');
    }
  }

  /// Returns true only when the plaintext message is durably persisted.
  Future<bool> _processInboundMessagePayload(PacketEnvelope envelope) async {
    try {
      if (await messageRepo.hasMessage(envelope.packetId)) {
        return true;
      }

      const storage = FlutterSecureStorage();
      final spkManager = SignedPreKeyManager(cryptoService, storage);

      // Load static X25519 keypair for local device: prefer in-memory key, fallback to secure storage
      SimpleKeyPair? recipientStaticKeyPair = getStaticX25519KeyPair?.call();
      if (recipientStaticKeyPair == null) {
        final staticSeedString = await storage.read(key: 'omnilink_static_x25519_seed');
        if (staticSeedString == null || staticSeedString.isEmpty) {
          throw const FormatException('STATIC_KEY_UNAVAILABLE: Static X25519 seed unavailable for inbound decryption.');
        }
        final seed = List<int>.from(staticSeedString.split(',').map(int.parse));
        recipientStaticKeyPair = await cryptoService.restoreX25519KeyPair(seed);
      }

      // The envelope authenticates the sender's Ed25519 identity, but the
      // Dual-ECDH key agreement additionally needs the sender's static X25519
      // public key. Falling back to senderId (an Ed25519 key) guarantees a
      // decryption failure, so resolve the learned peer key explicitly.
      String? senderStaticX25519Hex;
      for (final peer in getConnectedPeers()) {
        if ((peer.nodeId == envelope.senderId ||
                peer.peerId == envelope.senderId) &&
            peer.staticX25519PublicKeyHex != null &&
            peer.staticX25519PublicKeyHex!.isNotEmpty) {
          senderStaticX25519Hex = peer.staticX25519PublicKeyHex;
          break;
        }
      }
      senderStaticX25519Hex ??= (await PeerRepository(
        dbService: DatabaseService.instance,
      ).getPeerByNodeId(envelope.senderId))?.staticX25519PublicKeyHex;

      final decryptedText = await packetService.decryptMessageEnvelope(
        envelope: envelope,
        recipientStaticKeyPair: recipientStaticKeyPair,
        spkManager: spkManager,
        senderStaticX25519PublicKeyHex: senderStaticX25519Hex,
      );

      // Always save under recipient/sender permanent 64-char nodeId as conversationId
      final receivedMessage = Message(
        messageId: envelope.packetId,
        conversationId: envelope.senderId,
        senderNodeId: envelope.senderId,
        recipientNodeId: envelope.recipientId,
        plaintextBody: decryptedText,
        state: MessageState.delivered,
        createdAt: DateTime.fromMillisecondsSinceEpoch(envelope.createdAt),
        updatedAt: DateTime.now(),
      );

      await messageRepo.saveMessage(receivedMessage);
      debugPrint('OMNILINK_ROUTER: Decrypted and saved inbound message ${envelope.packetId} into SQLite conversation ${envelope.senderId}');

      var senderLabel = 'OMNILINK';
      for (final peer in getConnectedPeers()) {
        if (peer.nodeId == envelope.senderId || peer.peerId == envelope.senderId) {
          if (peer.friendlyName.isNotEmpty) senderLabel = peer.friendlyName;
          break;
        }
      }
      if (transport is AndroidTransportAdapter) {
        unawaited(
          (transport as AndroidTransportAdapter).showMessageNotification(
            title: senderLabel,
            body: decryptedText,
            conversationId: envelope.senderId,
          ),
        );
      }

      return true;
    } catch (e) {
      debugPrint('OMNILINK_ROUTER: Error processing inbound message payload: $e');
      return false;
    }
  }

  Future<void> _handleDeliveryReceipt(PacketEnvelope receiptEnvelope) async {
    debugPrint('OMNILINK_ROUTER: Received delivery receipt from ${receiptEnvelope.senderId} for ${receiptEnvelope.packetId}');
    try {
      String originalPacketId = receiptEnvelope.encryptedPayload;
      try {
        final decoded = jsonDecode(receiptEnvelope.encryptedPayload);
        if (decoded is Map && decoded.containsKey('originalPacketId')) {
          originalPacketId = decoded['originalPacketId'].toString();
        }
      } catch (_) {}

      await messageRepo.updateMessageState(originalPacketId, MessageState.receiptReceived);
      // End-to-end confirmation is the only event that proves the receiver
      // committed the message; this is where the sender's durable copy ends.
      await outboxDaemon.acknowledgeDelivery(originalPacketId);
    } catch (e) {
      debugPrint('OMNILINK_ROUTER: Error updating delivery receipt state: $e');
    }

    final nextHopEndpoint = _nodeIdToPeerId[receiptEnvelope.senderId];
    if (nextHopEndpoint != null) {
      await db.cacheRoute(receiptEnvelope.senderId, nextHopEndpoint, null);
      await db.insertOrUpdateRoute(
        RouteEntry(
          destinationNodeId: receiptEnvelope.senderId,
          nextHopPeerId: nextHopEndpoint,
          lastUpdated: DateTime.now(),
          lastSuccessfulDelivery: DateTime.now(),
          probability: 1.0,
        ),
      );
    }
  }

  // ===========================================================================
  // 6. OUTBOX FLUSH ON PEER CONNECT
  // ===========================================================================

  Future<void> _handlePeerEvent(PeerConnectionEvent event) async {
    if (_isDisposed) return;
    if (event.eventType == PeerConnectionEventType.onConnected) {
      await routeProtocol.sendRouteAdvertisement(event.peerId);
      // OutboxDaemon owns anti-entropy + outbox flushing on connect.
      // Calling sendSyncHandshake here too produced two handshakes per link.
      await outboxDaemon.onPeerConnected(event.peerId);
    } else if (event.eventType == PeerConnectionEventType.onDisconnected) {
      unregisterPeerNodeId(event.peerId);
      routeProtocol.onPeerDisconnected(event.peerId);
      outboxDaemon.onPeerDisconnected(event.peerId);
      sendQueueManager.clearQueue(event.peerId);
    }
  }

  Future<void> _onPeerConnected(String peerId) async {
    debugPrint('OMNILINK_ROUTER: Peer connected ($peerId). Delegating outbox flush to OutboxDaemon...');
    // Single flush owner is OutboxDaemon (per-peer locks + backoff). Avoid duplicate direct flush here.
    await outboxDaemon.onPeerConnected(peerId);
  }

  // ===========================================================================
  // 7. PERIODIC MAINTENANCE (30s)
  // ===========================================================================

  Future<void> _periodicMaintenance() async {
    if (_isDisposed) return;
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
    final pending = await db.getAllQueuedPackets();
    final targetPackets = pending.where((p) => p.recipientNodeId == destinationNodeId).toList();

    for (final packet in targetPackets) {
      final envelope = PacketEnvelope.fromJson(packet.payload);
      final decision = await _selectNextHop(envelope);

      if (decision.strategy != RouteStrategy.storeAndForward) {
        final bytes = utf8.encode(packet.payload);
        bool anySent = false;

        if (decision.peerId != null) {
          anySent = await sendQueueManager.enqueueAndSend(
            packetId: packet.packetId,
            peerId: decision.peerId!,
            payloadBytes: bytes,
          );
        } else if (decision.peerIds != null) {
          for (final peerId in decision.peerIds!) {
            final sent = await sendQueueManager.enqueueAndSend(
              packetId: packet.packetId,
              peerId: peerId,
              payloadBytes: bytes,
            );
            if (sent) anySent = true;
          }
        }

        if (anySent) {
          // Keep the durable copy until the destination acknowledges it.
          await outboxDaemon.markAwaitingReceipt(packet.packetId);
          await messageRepo.updateMessageStateUnlessReceiptReceived(
            packet.packetId,
            MessageState.delivered,
          );
          debugPrint('OMNILINK_ROUTER: Flushed queued packet ${packet.packetId} to $destinationNodeId via ${decision.strategy.name}');
          _emitEvent('forwarded', packet.packetId, 'outbox_flush', peerId: decision.peerId);
        }
      }
    }
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    storageCleanupDaemon.stop();
    transferManager.dispose();
    sendQueueManager.dispose();
    outboxDaemon.dispose();
    routeProtocol.dispose();
    _packetSubscription?.cancel();
    _packetSubscription = null;
    _peerSubscription?.cancel();
    _peerSubscription = null;
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    if (!_localInboundController.isClosed) {
      _localInboundController.close();
    }
    if (!_routingEventsController.isClosed) {
      _routingEventsController.close();
    }
  }
}
