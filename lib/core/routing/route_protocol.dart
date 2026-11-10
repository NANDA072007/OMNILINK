import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../transport_bridge/transport_adapter.dart';
import '../crypto/crypto_service.dart';
import '../crypto/packet_service.dart';
import '../models/packet_envelope.dart';
import '../models/peer_device.dart';
import '../models/signed_key_bundle.dart';
import '../battery/battery_state_service.dart';
import '../battery/sync_policy_engine.dart';
import '../protocol/sync_session.dart';
import 'models/route_entry.dart';
import 'prophet_engine.dart';
import 'router_engine.dart';
import 'routing_database.dart';
import 'send_queue.dart';

/// Implements the OMNILINK Route Discovery Protocol.
/// Manages periodic ROUTING_TABLE_SYNC, peer connection ROUTE_ADVERTISEMENT,
/// and reactive ROUTE_REQUEST / ROUTE_REPLY discovery queries.
class RouteProtocol {
  final RouterEngine router;
  final TransportAdapter transport;
  final PacketService packetService;
  final RoutingDatabaseService db;
  final CryptoService cryptoService;
  final ProphetEngine prophetEngine;
  final String Function() getMyNodeId;
  final SimpleKeyPair? Function()? getMasterKeyPair;
  final List<PeerDevice> Function() getConnectedPeers;

  Timer? _syncTimer;
  final Map<String, Timer> _handshakeRetryTimers = {};
  final Map<String, int> _handshakeAttempts = {};
  final Map<String, DateTime> _lastHandshakeCompletedAt = {};

  final SignedKeyBundle? Function()? getSignedKeyBundle;

  /// Serialized radio sender. Wired by RouterEngine post-construction to avoid
  /// circular construction. Falls back to direct transport for control packets.
  SendQueueManager? sendQueue;

  /// Sends control bytes with packetId-scoped queueing when available.
  Future<bool> _sendViaQueue(String peerId, Uint8List bytes, {String? packetId}) {
    final q = sendQueue;
    if (q != null) {
      return q.enqueueAndSend(
        packetId: packetId ?? 'ctrl_${DateTime.now().millisecondsSinceEpoch}_$peerId',
        peerId: peerId,
        payloadBytes: bytes,
      );
    }
    return transport.sendPacket(peerId, bytes);
  }

  /// Builds a genuinely signed control envelope. Returns null when the local
  /// identity is not ready yet; callers must not emit unsigned control packets.
  Future<PacketEnvelope?> _buildControlEnvelope({
    required String recipientNodeId,
    required String messageType,
    required String payloadJson,
    required String packetId,
    int ttl = 1,
    int maxHops = 1,
    int priority = 0,
    Duration validity = const Duration(minutes: 5),
  }) async {
    final myNodeId = getMyNodeId();
    final masterKeyPair = getMasterKeyPair?.call();
    if (myNodeId.isEmpty || masterKeyPair == null) {
      debugPrint(
        'OMNILINK_ROUTE: Cannot sign $messageType — local identity is not ready.',
      );
      return null;
    }

    return packetService.createSignedControlEnvelope(
      senderNodeId: myNodeId,
      senderKeyPair: masterKeyPair,
      recipientNodeId: recipientNodeId,
      messageType: messageType,
      payloadJson: payloadJson,
      packetId: packetId,
      ttl: ttl,
      maxHops: maxHops,
      priority: priority,
      validity: validity,
    );
  }

  RouteProtocol({
    required this.router,
    required this.transport,
    required this.packetService,
    required this.db,
    required this.cryptoService,
    required this.prophetEngine,
    required this.getMyNodeId,
    this.getMasterKeyPair,
    this.getSignedKeyBundle,
    required this.getConnectedPeers,
  });

  final BatteryStateService _batteryService = BatteryStateService();
  final SyncPolicyEngine _syncPolicyEngine = SyncPolicyEngine();
  StreamSubscription? _batterySub;
  Duration _currentInterval = const Duration(seconds: 45);
  bool _hasRecentRouteChanges = false;
  bool _hasActiveForegroundChat = false;

  /// Starts adaptive periodic sync evaluated dynamically based on battery state and routing activity.
  void startPeriodicSync({Duration? interval}) {
    _syncTimer?.cancel();
    _batterySub?.cancel();

    _batterySub = _batteryService.onBatteryStateChanged.listen((_) {
      _evaluateAndScheduleSync();
    });

    _evaluateAndScheduleSync(overrideInterval: interval);
  }

  void setActiveForegroundChat(bool isActive) {
    _hasActiveForegroundChat = isActive;
    _evaluateAndScheduleSync();
  }

  void notifyRouteTableChanged() {
    _hasRecentRouteChanges = true;
    _evaluateAndScheduleSync();
  }

  Future<void> _evaluateAndScheduleSync({Duration? overrideInterval}) async {
    final connectedPeers = getConnectedPeers()
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
        .toList();

    int pendingOutbox = 0;
    try {
      final packets = await db.getPendingOutboxPackets();
      pendingOutbox = packets.length;
    } catch (_) {}

    final context = NetworkActivityContext(
      activePeerCount: connectedPeers.length,
      pendingOutboxCount: pendingOutbox,
      hasRecentRouteChanges: _hasRecentRouteChanges,
      hasActiveForegroundChat: _hasActiveForegroundChat,
    );

    final decision = _syncPolicyEngine.evaluatePolicy(
      battery: _batteryService.currentState,
      activity: context,
    );

    final targetDuration = overrideInterval ?? decision.interval;

    if (_syncTimer == null || _currentInterval != targetDuration) {
      _currentInterval = targetDuration;
      _syncTimer?.cancel();

      if (!decision.isSyncPaused) {
        _syncTimer = Timer.periodic(targetDuration, (_) {
          broadcastRoutingTable();
          _hasRecentRouteChanges = false;
        });
      }
    }
  }

  /// Stops periodic routing table sync.
  void stopPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _batterySub?.cancel();
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

      final envelope = await _buildControlEnvelope(
        recipientNodeId: 'BROADCAST',
        messageType: 'ROUTING_TABLE_SYNC',
        payloadJson: payloadJson,
        packetId: 'sync_${now}_$myNodeId',
        ttl: 1, // Directly connected peers only
        validity: const Duration(hours: 1),
      );
      if (envelope == null) return;

      final connectedPeers = getConnectedPeers()
          .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
          .toList();

      final bytes = utf8.encode(envelope.toJson());
      for (final peer in connectedPeers) {
        await _sendViaQueue(peer.peerId, bytes, packetId: envelope.packetId);
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

      final vectorMap = <String, double>{};
      for (final item in entriesList) {
        final map = item as Map<String, dynamic>;
        final destId = map['destinationNodeId'] as String;
        final remoteHopCount = (map['hopCount'] as num).toInt();
        final remoteProb = (map['probability'] as num).toDouble();
        vectorMap[destId] = remoteProb;

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

      await prophetEngine.exchangePredictability(fromPeerId, vectorMap);
      debugPrint('OMNILINK_ROUTE: merged $mergedCount routes from peer $fromPeerId');
    } catch (e) {
      debugPrint('OMNILINK_ROUTE: Error merging ROUTING_TABLE_SYNC: $e');
    }
  }

  // ===========================================================================
  // 2. ROUTE_ADVERTISEMENT
  // ===========================================================================

  /// Sends ROUTE_ADVERTISEMENT when connecting to a new peer with bounded backoff and liveness verification.
  Future<void> sendRouteAdvertisement(
    String connectedPeerId, {
    bool isReply = false,
    int attempt = 1,
  }) async {
    try {
      // 1. Peer Liveness check: Is this peer currently connected?
      final isConnected = getConnectedPeers().any(
        (p) => (p.peerId == connectedPeerId || p.nodeId == connectedPeerId) &&
               p.connectionStatus == PeerConnectionStatus.connected,
      );
      if (!isConnected) {
        debugPrint('OMNILINK_ROUTE: Aborting route advertisement to $connectedPeerId — peer is not connected.');
        _cancelHandshakeRetry(connectedPeerId);
        return;
      }

      final myNodeId = getMyNodeId();
      final masterKeyPair = getMasterKeyPair?.call();
      final hasBundleProvider = getSignedKeyBundle != null;
      final signedKeyBundle = getSignedKeyBundle?.call();

      // If key bundle provider is registered but bundle is not yet ready, treat as pending
      final isBundlePending = hasBundleProvider && signedKeyBundle == null;

      // 2. Bounded backoff retry if cryptographic identity is still initializing
      if (myNodeId.isEmpty || masterKeyPair == null || isBundlePending) {
        const maxAttempts = 5;
        if (attempt > maxAttempts) {
          debugPrint('OMNILINK_ROUTE: Exceeded $maxAttempts handshake retry attempts for $connectedPeerId. Aborting.');
          _cancelHandshakeRetry(connectedPeerId);
          return;
        }

        final delayMs = 300 * (1 << (attempt - 1));
        debugPrint(
          'OMNILINK_ROUTE: Keys initializing (nodeId: ${myNodeId.isNotEmpty}, masterKey: ${masterKeyPair != null}, bundlePending: $isBundlePending). '
          'Retrying advertisement for $connectedPeerId in ${delayMs}ms (attempt $attempt/$maxAttempts)...',
        );

        _handshakeRetryTimers[connectedPeerId]?.cancel();
        _handshakeRetryTimers[connectedPeerId] = Timer(Duration(milliseconds: delayMs), () {
          sendRouteAdvertisement(connectedPeerId, isReply: isReply, attempt: attempt + 1);
        });
        return;
      }

      _cancelHandshakeRetry(connectedPeerId);

      // 3. Ping-Pong Storm Suppression: avoid reciprocal loop if handshake completed within 3s
      final lastCompleted = _lastHandshakeCompletedAt[connectedPeerId];
      if (isReply && lastCompleted != null && DateTime.now().difference(lastCompleted).inSeconds < 3) {
        debugPrint('OMNILINK_ROUTE: Suppressing redundant reciprocal route advertisement for $connectedPeerId.');
        return;
      }

      final connectedPeers = getConnectedPeers()
          .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
          .map((p) => p.nodeId ?? p.peerId)
          .toList();

      final payloadMap = {
        'nodeId': myNodeId,
        'directNodes': connectedPeers,
        if (signedKeyBundle != null) 'signedKeyBundle': signedKeyBundle.toMap(),
        if (isReply) 'isReply': true,
      };

      final payloadJson = jsonEncode(payloadMap);

      final envelope = await packetService.createEnvelope(
        senderNodeId: myNodeId,
        recipientNodeId: connectedPeerId,
        messageType: 'ROUTE_ADVERTISEMENT',
        encryptedPayloadBase64: payloadJson,
        senderKeyPair: masterKeyPair,
        ttl: 1,
        priority: 0,
      );

      final bytes = utf8.encode(envelope.toJson());
      await _sendViaQueue(connectedPeerId, bytes, packetId: envelope.packetId);

      _lastHandshakeCompletedAt[connectedPeerId] = DateTime.now();
      debugPrint('OMNILINK_ROUTE: [KEY_BUNDLE] sent signed route advertisement (bundle attached: ${signedKeyBundle != null}, isReply: $isReply) to $connectedPeerId');
    } catch (e) {
      debugPrint('OMNILINK_ROUTE: Error sending route advertisement: $e');
    }
  }

  void _cancelHandshakeRetry(String peerId) {
    _handshakeRetryTimers.remove(peerId)?.cancel();
    _handshakeAttempts.remove(peerId);
  }

  /// Handles incoming ROUTE_ADVERTISEMENT from a newly connected peer.
  Future<void> handleRouteAdvertisement(PacketEnvelope envelope, String fromPeerId) async {
    try {
      final map = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
      final senderNodeId = map['nodeId'] as String;
      final directNodes = (map['directNodes'] as List<dynamic>).cast<String>();
      final isReply = map['isReply'] == true;

      String? verifiedStaticX25519PublicKeyHex;
      if (map.containsKey('signedKeyBundle') && map['signedKeyBundle'] != null) {
        try {
          final bundleMap = Map<String, dynamic>.from(map['signedKeyBundle'] as Map);
          final bundle = SignedKeyBundle.fromMap(bundleMap);

          final isValid = await cryptoService.verifySignedKeyBundle(bundle);
          if (isValid && bundle.identityPublicKeyHex == senderNodeId) {
            verifiedStaticX25519PublicKeyHex = bundle.staticX25519PublicKeyHex;
            debugPrint('OMNILINK_ROUTE: [KEY_BUNDLE] verified authentic staticX25519 key for $senderNodeId: $verifiedStaticX25519PublicKeyHex');
          } else {
            debugPrint('OMNILINK_ROUTE: [KEY_BUNDLE] rejected invalid or mismatched signature for $senderNodeId');
          }
        } catch (e) {
          debugPrint('OMNILINK_ROUTE: [KEY_BUNDLE] error parsing or verifying bundle: $e');
        }
      }

      int learnedCount = 0;

      // Add route to sender (1 hop, prob 1.0) & register identity mapping instantly
      if (senderNodeId != getMyNodeId()) {
        router.registerPeerNodeId(
          fromPeerId,
          senderNodeId,
          staticX25519PublicKeyHex: verifiedStaticX25519PublicKeyHex,
        );
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
        _lastHandshakeCompletedAt[fromPeerId] = DateTime.now();

        // Reciprocate with our own ROUTE_ADVERTISEMENT if this was an initial advertisement
        if (!isReply) {
          unawaited(sendRouteAdvertisement(fromPeerId, isReply: true));
        }
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

      debugPrint('OMNILINK_ROUTE: learned $learnedCount new routes from advertisement by $fromPeerId (x25519: ${verifiedStaticX25519PublicKeyHex != null})');
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

      final envelope = await _buildControlEnvelope(
        recipientNodeId: 'BROADCAST',
        messageType: 'ROUTE_REQUEST',
        payloadJson: payloadJson,
        packetId: 'req_${now}_${targetNodeId.substring(0, min(8, targetNodeId.length))}',
        ttl: 4,
        maxHops: 4,
        validity: const Duration(seconds: 30),
      );
      if (envelope == null) return;

      final connectedPeers = getConnectedPeers()
          .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
          .toList();

      final bytes = utf8.encode(envelope.toJson());
      for (final peer in connectedPeers) {
        await _sendViaQueue(peer.peerId, bytes, packetId: envelope.packetId);
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

        final replyEnvelope = await _buildControlEnvelope(
          recipientNodeId: envelope.senderId,
          messageType: 'ROUTE_REPLY',
          payloadJson: replyJson,
          packetId: 'rpl_${now}_$targetNodeId',
          ttl: 4,
          maxHops: 4,
          validity: const Duration(minutes: 1),
        );
        if (replyEnvelope == null) return;

        final bytes = utf8.encode(replyEnvelope.toJson());
        await _sendViaQueue(fromPeerId, bytes, packetId: replyEnvelope.packetId);

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

  // ===========================================================================
  // 4. ANTI-ENTROPY HANDSHAKE (PAGINATED & MTU-SAFE)
  // ===========================================================================

  final SyncSessionManager _syncSessionManager = SyncSessionManager();

  /// Sends a paginated anti-entropy sync session or bounded legacy SYNC_HANDSHAKE payload.
  Future<void> sendSyncHandshake(String targetPeerId, {bool supportsPagination = true}) async {
    try {
      final myNodeId = getMyNodeId();
      if (myNodeId.isEmpty) return;

      final pendingOutbox = await db.getPendingOutboxPackets();
      final outboxPacketIds = pendingOutbox.map((p) => p.packetId).toList();
      final processedIds = packetService.getProcessedPacketIds();

      final allHeldIds = {...outboxPacketIds, ...processedIds}.toList();
      final now = DateTime.now().millisecondsSinceEpoch;

      if (!supportsPagination) {
        // Fallback for legacy peers: Send bounded handshake (top 40 IDs max to fit in 4096 MTU)
        final boundedIds = allHeldIds.take(40).toList();
        final payloadJson = jsonEncode({
          'senderNodeId': myNodeId,
          'heldPacketIds': boundedIds,
          'protocolVersion': 1,
        });

        final envelope = await _buildControlEnvelope(
          recipientNodeId: targetPeerId,
          messageType: 'SYNC_HANDSHAKE',
          payloadJson: payloadJson,
          packetId: 'handshake_${now}_$myNodeId',
          validity: const Duration(minutes: 5),
        );
        if (envelope == null) return;

        final bytes = utf8.encode(envelope.toJson());
        if (bytes.length <= 4096) {
          await _sendViaQueue(targetPeerId, bytes, packetId: envelope.packetId);
        }
        return;
      }

      // Paginated Session Transmission
      final sessionId = 'sess_${now}_$myNodeId';
      const int targetChunkSize = 40; // ~40 packet IDs per chunk fits comfortably within 4096-byte MTU

      // 1. Send SYNC_SESSION_START
      final startPayload = jsonEncode({
        'sessionId': sessionId,
        'protocolVersion': 1,
        'totalEstimatedCount': allHeldIds.length,
        'pageSize': targetChunkSize,
        'checksumAlgorithm': 'sha256',
      });

      final startEnvelope = await _buildControlEnvelope(
        recipientNodeId: targetPeerId,
        messageType: 'SYNC_SESSION_START',
        payloadJson: startPayload,
        packetId: 'sync_start_${now}_$myNodeId',
        validity: const Duration(minutes: 5),
      );
      if (startEnvelope == null) return;

      await _sendViaQueue(targetPeerId, utf8.encode(startEnvelope.toJson()), packetId: startEnvelope.packetId);

      // 2. Transmit SYNC_PAGE chunks with a cursor + dynamic MTU reduction.
      // The cursor (rather than pageIdx * chunkSize) guarantees that shrinking a
      // page for MTU never skips the remaining packet IDs.
      int pageIdx = 0;
      int cursor = 0;
      do {
        var take = targetChunkSize;
        List<String> chunk = const [];
        PacketEnvelope? pageEnvelope;

        while (true) {
          final endIdx = min(cursor + take, allHeldIds.length);
          chunk = allHeldIds.sublist(cursor, endIdx);
          final pageChecksum = SyncSession.computeChecksum(chunk);
          final pagePayload = jsonEncode({
            'sessionId': sessionId,
            'pageIndex': pageIdx,
            'packetIdChunk': chunk,
            'hasMore': endIdx < allHeldIds.length,
            'pageChecksum': pageChecksum,
          });

          try {
            pageEnvelope = await _buildControlEnvelope(
              recipientNodeId: targetPeerId,
              messageType: 'SYNC_PAGE',
              payloadJson: pagePayload,
              packetId: 'sync_page_${now}_${pageIdx}_$myNodeId',
              validity: const Duration(minutes: 5),
            );
            break;
          } on PacketValidationException catch (e) {
            if (e.errorCode != 'INVALID_PACKET_SIZE' || take <= 1) rethrow;
            take = take ~/ 2;
          }
        }

        if (pageEnvelope == null) return;

        await _sendViaQueue(
          targetPeerId,
          utf8.encode(pageEnvelope.toJson()),
          packetId: pageEnvelope.packetId,
        );

        cursor += chunk.length;
        pageIdx++;
      } while (cursor < allHeldIds.length);

      final totalPages = pageIdx;

      // 3. Send SYNC_SESSION_END
      final finalChecksum = SyncSession.computeChecksum(allHeldIds);
      final endPayload = jsonEncode({
        'sessionId': sessionId,
        'totalPageCount': totalPages,
        'finalChecksum': finalChecksum,
        'completionStatus': 'COMPLETED',
      });

      final endEnvelope = await _buildControlEnvelope(
        recipientNodeId: targetPeerId,
        messageType: 'SYNC_SESSION_END',
        payloadJson: endPayload,
        packetId: 'sync_end_${now}_$myNodeId',
        validity: const Duration(minutes: 5),
      );
      if (endEnvelope == null) return;

      await _sendViaQueue(targetPeerId, utf8.encode(endEnvelope.toJson()), packetId: endEnvelope.packetId);
      debugPrint('OMNILINK_SYNC: Transmitted paginated sync session $sessionId ($totalPages pages) to $targetPeerId');
    } catch (e) {
      debugPrint('OMNILINK_SYNC: Error sending paginated SYNC_HANDSHAKE: $e');
    }
  }

  /// Handles incoming SYNC_SESSION_START.
  Future<void> handleSyncSessionStart(PacketEnvelope envelope, String fromPeerId) async {
    try {
      final map = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
      final sessionId = map['sessionId'] as String;
      final totalEstimatedCount = (map['totalEstimatedCount'] as num).toInt();
      final pageSize = (map['pageSize'] as num).toInt();
      final protocolVersion = (map['protocolVersion'] as num).toInt();

      _syncSessionManager.createSession(
        sessionId: sessionId,
        peerId: fromPeerId,
        protocolVersion: protocolVersion,
        totalEstimatedCount: totalEstimatedCount,
        pageSize: pageSize,
      );
      debugPrint('OMNILINK_SYNC: Started inbound sync session $sessionId from $fromPeerId');
    } catch (e) {
      debugPrint('OMNILINK_SYNC: Error handling SYNC_SESSION_START: $e');
    }
  }

  /// Handles incoming SYNC_PAGE.
  Future<void> handleSyncPage(PacketEnvelope envelope, String fromPeerId) async {
    try {
      final map = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
      final sessionId = map['sessionId'] as String;
      final pageIndex = (map['pageIndex'] as num).toInt();
      final chunk = (map['packetIdChunk'] as List<dynamic>).cast<String>();
      final pageChecksum = map['pageChecksum'] as String;

      final accepted = _syncSessionManager.handlePage(
        sessionId: sessionId,
        pageIndex: pageIndex,
        packetIdChunk: chunk,
        pageChecksum: pageChecksum,
      );

      if (accepted) {
        debugPrint('OMNILINK_SYNC: Accepted page $pageIndex for session $sessionId from $fromPeerId');
      }
    } catch (e) {
      debugPrint('OMNILINK_SYNC: Error handling SYNC_PAGE: $e');
    }
  }

  /// Handles incoming SYNC_SESSION_END and triggers SYNC_REQUEST for missing packet IDs.
  Future<void> handleSyncSessionEnd(PacketEnvelope envelope, String fromPeerId) async {
    try {
      final map = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
      final sessionId = map['sessionId'] as String;
      final totalPageCount = (map['totalPageCount'] as num).toInt();
      final expectedFinalChecksum = map['finalChecksum'] as String;

      final session = _syncSessionManager.getSession(sessionId);
      if (session == null || !session.isComplete(totalPageCount)) {
        debugPrint('OMNILINK_SYNC: Sync session $sessionId incomplete on end event');
        return;
      }

      final combinedRemoteIds = session.getCombinedPacketIds();
      final computedFinalChecksum = SyncSession.computeChecksum(combinedRemoteIds);

      if (computedFinalChecksum != expectedFinalChecksum) {
        debugPrint('OMNILINK_SYNC: Sync session $sessionId final checksum mismatch');
        return;
      }

      // Find missing packet IDs locally
      final pendingOutbox = await db.getPendingOutboxPackets();
      final localOutboxIds = pendingOutbox.map((p) => p.packetId).toSet();
      final localProcessedIds = packetService.getProcessedPacketIds().toSet();

      final missingPacketIds = <String>[];
      for (final remoteId in combinedRemoteIds) {
        if (!localOutboxIds.contains(remoteId) && !localProcessedIds.contains(remoteId)) {
          missingPacketIds.add(remoteId);
        }
      }

      _syncSessionManager.completeSession(sessionId);
      debugPrint('OMNILINK_SYNC: Completed sync session $sessionId. Remote holds ${combinedRemoteIds.length}, missing ${missingPacketIds.length}');

      if (missingPacketIds.isNotEmpty) {
        await sendSyncRequest(fromPeerId, missingPacketIds);
      }
    } catch (e) {
      debugPrint('OMNILINK_SYNC: Error handling SYNC_SESSION_END: $e');
    }
  }

  /// Handles incoming SYNC_HANDSHAKE from a peer, compares packet IDs, and sends SYNC_REQUEST for missing ones.
  Future<void> handleSyncHandshake(PacketEnvelope envelope, String fromPeerId) async {
    try {
      final map = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
      final remoteHeldIds = (map['heldPacketIds'] as List<dynamic>).cast<String>();

      final pendingOutbox = await db.getPendingOutboxPackets();
      final localOutboxIds = pendingOutbox.map((p) => p.packetId).toSet();
      final localProcessedIds = packetService.getProcessedPacketIds().toSet();

      final missingPacketIds = <String>[];
      for (final remoteId in remoteHeldIds) {
        if (!localOutboxIds.contains(remoteId) && !localProcessedIds.contains(remoteId)) {
          missingPacketIds.add(remoteId);
        }
      }

      debugPrint('OMNILINK_SYNC: Evaluated SYNC_HANDSHAKE from $fromPeerId: remote holds ${remoteHeldIds.length}, we are missing ${missingPacketIds.length}');

      if (missingPacketIds.isNotEmpty) {
        await sendSyncRequest(fromPeerId, missingPacketIds);
      }
    } catch (e) {
      debugPrint('OMNILINK_SYNC: Error handling SYNC_HANDSHAKE: $e');
    }
  }

  /// Sends a SYNC_REQUEST containing ONLY missing packet IDs to target peer.
  Future<void> sendSyncRequest(String targetPeerId, List<String> missingPacketIds) async {
    try {
      final myNodeId = getMyNodeId();
      if (myNodeId.isEmpty) return;

      final payloadJson = jsonEncode({
        'senderNodeId': myNodeId,
        'requestedPacketIds': missingPacketIds,
      });
      final now = DateTime.now().millisecondsSinceEpoch;

      final envelope = await _buildControlEnvelope(
        recipientNodeId: targetPeerId,
        messageType: 'SYNC_REQUEST',
        payloadJson: payloadJson,
        packetId: 'syncreq_${now}_$myNodeId',
        validity: const Duration(minutes: 5),
      );
      if (envelope == null) return;

      final bytes = utf8.encode(envelope.toJson());
      await _sendViaQueue(targetPeerId, bytes, packetId: envelope.packetId);

      debugPrint('OMNILINK_SYNC: Sent SYNC_REQUEST for ${missingPacketIds.length} missing packet(s) to $targetPeerId');
    } catch (e) {
      debugPrint('OMNILINK_SYNC: Error sending SYNC_REQUEST: $e');
    }
  }

  /// Handles incoming SYNC_REQUEST from a peer, fetches requested envelopes from SQLite outbox, and transmits them.
  Future<void> handleSyncRequest(PacketEnvelope envelope, String fromPeerId) async {
    try {
      final map = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
      final requestedIds = (map['requestedPacketIds'] as List<dynamic>).cast<String>().toSet();

      final pendingOutbox = await db.getPendingOutboxPackets();
      final matchingEnvelopes = pendingOutbox.where((p) => requestedIds.contains(p.packetId)).toList();

      debugPrint('OMNILINK_SYNC: Received SYNC_REQUEST from $fromPeerId for ${requestedIds.length} packet(s). Found ${matchingEnvelopes.length} in outbox.');

      for (final outboxPacket in matchingEnvelopes) {
        final bytes = utf8.encode(outboxPacket.payload);
        await _sendViaQueue(fromPeerId, bytes, packetId: outboxPacket.packetId);
        debugPrint('OMNILINK_SYNC: Transmitted missing requested packet ${outboxPacket.packetId} to $fromPeerId');
      }
    } catch (e) {
      debugPrint('OMNILINK_SYNC: Error handling SYNC_REQUEST: $e');
    }
  }

  void onPeerDisconnected(String peerId) {
    _cancelHandshakeRetry(peerId);
    _lastHandshakeCompletedAt.remove(peerId);
    _syncSessionManager.cancelSessionsForPeer(peerId);
  }

  void dispose() {
    stopPeriodicSync();
    for (final timer in _handshakeRetryTimers.values) {
      timer.cancel();
    }
    _handshakeRetryTimers.clear();
    _handshakeAttempts.clear();
    _lastHandshakeCompletedAt.clear();
    _batterySub?.cancel();
    _syncSessionManager.dispose();
  }
}
