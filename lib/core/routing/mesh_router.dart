import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../crypto/packet_service.dart';
import '../models/packet_envelope.dart';
import '../models/peer_device.dart';
import '../repositories/outbox_repository.dart';
import '../../transport_bridge/transport_adapter.dart';

/// Global Multi-Hop Epidemic Mesh Router for OMNILINK.
///
/// Implements Delay-Tolerant Networking (DTN) via Anti-Entropy Handshakes
/// (Summary Vector Exchanges) to eliminate radio congestion while ensuring
/// targeted, zero-duplicate payload propagation across offline mesh nodes.
class MeshRouter {
  final TransportAdapter _transportAdapter;
  final PacketService _packetService;
  final OutboxRepository _outboxRepo;
  final List<PeerDevice> Function() _getConnectedPeers;
  final String? Function() _getMyNodeId;

  late final StreamSubscription<IncomingPacketEvent> _incomingSubscription;
  final StreamController<PacketEnvelope> _localInboundController =
      StreamController<PacketEnvelope>.broadcast();

  MeshRouter({
    required TransportAdapter transportAdapter,
    required PacketService packetService,
    required OutboxRepository outboxRepo,
    required List<PeerDevice> Function() getConnectedPeers,
    required String? Function() getMyNodeId,
  })  : _transportAdapter = transportAdapter,
        _packetService = packetService,
        _outboxRepo = outboxRepo,
        _getConnectedPeers = getConnectedPeers,
        _getMyNodeId = getMyNodeId {
    _incomingSubscription =
        _transportAdapter.incomingPackets.listen(_handleIncomingPacket);
  }

  /// Broadcast stream emitting validated envelopes intended for the local device.
  Stream<PacketEnvelope> get localInboundStream =>
      _localInboundController.stream;

  /// Global packet processing pipeline.
  Future<void> _handleIncomingPacket(IncomingPacketEvent event) async {
    final tRecv = DateTime.now().millisecondsSinceEpoch;
    debugPrint(
      'OMNILINK_ROUTER: [t=$tRecv] incoming packet received from senderPeerId=${event.senderPeerId} (${event.payloadBytes.length} bytes)',
    );

    try {
      final jsonString = utf8.decode(event.payloadBytes);
      final envelope = PacketEnvelope.fromJson(jsonString);

      debugPrint(
        'OMNILINK_ROUTER: [t=$tRecv] envelope packetId=${envelope.packetId} type=${envelope.messageType} sender=${envelope.senderId.substring(0, 8)}... recipient=${envelope.recipientId.substring(0, 8)}...',
      );

      // 1. Structural, timestamp, Ed25519 signature validation & atomic replay claim
      try {
        final isValid = await _packetService.validateAndClaimEnvelope(envelope);
        if (!isValid) {
          debugPrint('OMNILINK_ROUTER: [t=$tRecv] DROPPING packet ${envelope.packetId}: Invalid signature');
          return;
        }
      } on PacketValidationException catch (e) {
        debugPrint('OMNILINK_ROUTER: [t=$tRecv] DROPPING packet ${envelope.packetId}: ${e.errorCode} - ${e.message}');
        return;
      }

      final myNodeId = _getMyNodeId();

      // 3. Application-level Ping/Pong handling
      if (envelope.messageType == 'PING') {
        final rtt = tRecv - envelope.createdAt;
        debugPrint('OMNILINK_LATENCY: [t=$tRecv] PING received from ${envelope.senderId} (one-way: ${rtt}ms)');
        _sendPong(envelope.senderId, event.senderPeerId);
        return;
      } else if (envelope.messageType == 'PONG') {
        final rtt = tRecv - envelope.createdAt;
        debugPrint('OMNILINK_LATENCY: [t=$tRecv] PONG received. Ping RTT=$rtt ms');
        return;
      }

      // 4. Anti-Entropy Epidemic Handshake Engine (Steps #2, #3, #4)
      if (envelope.messageType == 'SYNC_HANDSHAKE') {
        await _handleSyncHandshake(envelope, event.senderPeerId);
        return;
      } else if (envelope.messageType == 'SYNC_REQUEST') {
        await _handleSyncRequest(envelope, event.senderPeerId);
        return;
      }

      // 5. Inbound Routing Branch
      final isForMe = myNodeId != null &&
          (envelope.recipientId == myNodeId ||
              myNodeId.startsWith(envelope.recipientId) ||
              envelope.recipientId.startsWith(myNodeId));

      if (isForMe) {
        // Destination matches local device -> Emit to Chat UI listeners
        debugPrint(
          'OMNILINK_ROUTER: [t=$tRecv] ARRIVED AT DESTINATION! Packet ${envelope.packetId} reached node $myNodeId (total hops: ${envelope.hopCount})',
        );
        _localInboundController.add(envelope);
      } else if (envelope.ttl > 1) {
        // Destination is another node -> Store in local outbox for Epidemic DTN forwarding!
        final forwardEnvelope = envelope.copyWith(
          ttl: envelope.ttl - 1,
          hopCount: envelope.hopCount + 1,
        );

        debugPrint(
          'OMNILINK_EPIDEMIC: [t=$tRecv] Storing transit packet ${envelope.packetId} in local outbox queue for future DTN relay (target: ${envelope.recipientId.substring(0, 8)}..., ttl: ${forwardEnvelope.ttl})',
        );
        await _outboxRepo.saveToOutbox(forwardEnvelope);
      } else {
        debugPrint('OMNILINK_ROUTER: [t=$tRecv] DROPPED packet ${envelope.packetId}: TTL exhausted (ttl=${envelope.ttl})');
      }
    } catch (e, s) {
      debugPrint('OMNILINK_ROUTER: [t=$tRecv] Exception processing packet: $e\n$s');
    }
  }

  /// Initiates an Anti-Entropy Summary Vector Exchange with a newly connected peer endpoint.
  Future<void> sendSyncHandshake(String peerId) async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    final myNodeId = _getMyNodeId();
    if (myNodeId == null) return;

    try {
      final knownIdsSet = await _outboxRepo.getAllKnownPacketIds();
      final summaryVectorJson = jsonEncode({'known_ids': knownIdsSet.toList()});

      final envelope = PacketEnvelope(
        packetId: 'sync_hs_$t0',
        senderId: myNodeId,
        recipientId: peerId,
        createdAt: t0,
        expiresAt: t0 + 60000,
        messageType: 'SYNC_HANDSHAKE',
        payloadHash: 'sync_hs',
        signature: 'sync_hs',
        encryptedPayload: summaryVectorJson,
      );

      final jsonPayload = envelope.toJson();
      final packetBytes = Uint8List.fromList(utf8.encode(jsonPayload));
      await _transportAdapter.sendPacket(peerId, packetBytes);
      debugPrint('OMNILINK_EPIDEMIC: [t=$t0] Sent SYNC_HANDSHAKE to $peerId (Summary Vector size: ${knownIdsSet.length} known IDs)');
    } catch (e) {
      debugPrint('OMNILINK_EPIDEMIC: Failed to send SYNC_HANDSHAKE to $peerId: $e');
    }
  }

  /// Handles incoming SYNC_HANDSHAKE by comparing Summary Vectors and requesting missing packets.
  Future<void> _handleSyncHandshake(PacketEnvelope envelope, String senderPeerId) async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    final myNodeId = _getMyNodeId();
    if (myNodeId == null) return;

    try {
      final summaryMap = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
      final remoteKnownIds = Set<String>.from(summaryMap['known_ids'] as List? ?? []);

      final localKnownIds = await _outboxRepo.getAllKnownPacketIds();

      // Find packets that the remote peer possesses but this local node is MISSING
      final missingForMe = remoteKnownIds.difference(localKnownIds);

      debugPrint(
        'OMNILINK_EPIDEMIC: [t=$t0] Evaluated SYNC_HANDSHAKE from ${envelope.senderId}: '
        'Remote has ${remoteKnownIds.length} IDs, Local has ${localKnownIds.length} IDs. Missing for me: ${missingForMe.length}',
      );

      if (missingForMe.isNotEmpty) {
        final requestPayloadJson = jsonEncode({'requested_ids': missingForMe.toList()});

        final reqEnvelope = PacketEnvelope(
          packetId: 'sync_req_$t0',
          senderId: myNodeId,
          recipientId: envelope.senderId,
          createdAt: t0,
          expiresAt: t0 + 60000,
          messageType: 'SYNC_REQUEST',
          payloadHash: 'sync_req',
          signature: 'sync_req',
          encryptedPayload: requestPayloadJson,
        );

        final jsonPayload = reqEnvelope.toJson();
        final packetBytes = Uint8List.fromList(utf8.encode(jsonPayload));
        await _transportAdapter.sendPacket(senderPeerId, packetBytes);
        debugPrint('OMNILINK_EPIDEMIC: [t=$t0] Sent SYNC_REQUEST for ${missingForMe.length} missing packet(s) to $senderPeerId');
      }
    } catch (e) {
      debugPrint('OMNILINK_EPIDEMIC: Error handling SYNC_HANDSHAKE: $e');
    }
  }

  /// Handles incoming SYNC_REQUEST by transmitting requested target payloads.
  Future<void> _handleSyncRequest(PacketEnvelope envelope, String senderPeerId) async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    try {
      final reqMap = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
      final requestedIds = List<String>.from(reqMap['requested_ids'] as List? ?? []);

      debugPrint('OMNILINK_EPIDEMIC: [t=$t0] Received SYNC_REQUEST from $senderPeerId for ${requestedIds.length} packet(s)');

      for (final requestedId in requestedIds) {
        final targetEnvelope = await _outboxRepo.getEnvelopeByPacketId(requestedId);
        if (targetEnvelope != null) {
          final jsonPayload = targetEnvelope.toJson();
          final packetBytes = Uint8List.fromList(utf8.encode(jsonPayload));
          final sent = await _transportAdapter.sendPacket(senderPeerId, packetBytes);
          if (sent) {
            debugPrint('OMNILINK_EPIDEMIC: [t=$t0] Transmitted targeted payload $requestedId to $senderPeerId');
          }
        }
      }
    } catch (e) {
      debugPrint('OMNILINK_EPIDEMIC: Error handling SYNC_REQUEST: $e');
    }
  }

  /// Outbound Targeted Broadcast Helper.
  Future<bool> broadcastEnvelope(PacketEnvelope envelope, {String? targetPeerId}) async {
    final jsonPayload = envelope.toJson();
    final packetBytes = Uint8List.fromList(utf8.encode(jsonPayload));

    final connectedPeers = _getConnectedPeers()
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
        .toList();

    if (connectedPeers.isEmpty) {
      return false;
    }

    var sentAny = false;
    for (final peer in connectedPeers) {
      final success = await _transportAdapter.sendPacket(peer.peerId, packetBytes);
      if (success) sentAny = true;
    }
    return sentAny;
  }

  /// Sends a PONG response back to the ping originator.
  Future<void> _sendPong(String recipientNodeId, String peerId) async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    final myNodeId = _getMyNodeId();
    if (myNodeId == null) return;

    try {
      final envelope = PacketEnvelope(
        packetId: 'pong_$t0',
        senderId: myNodeId,
        recipientId: recipientNodeId,
        createdAt: t0,
        expiresAt: t0 + 60000,
        messageType: 'PONG',
        payloadHash: 'pong',
        signature: 'pong',
        encryptedPayload: 'pong',
      );

      final jsonPayload = envelope.toJson();
      final packetBytes = Uint8List.fromList(utf8.encode(jsonPayload));
      await _transportAdapter.sendPacket(peerId, packetBytes);
      debugPrint('OMNILINK_LATENCY: [t=$t0] Sent PONG to $peerId');
    } catch (_) {}
  }

  /// Sends an application-level PING packet to verify bidirectional channel usability.
  Future<void> sendPing(String recipientNodeId, String peerId) async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    final myNodeId = _getMyNodeId();
    if (myNodeId == null) return;

    try {
      final envelope = PacketEnvelope(
        packetId: 'ping_$t0',
        senderId: myNodeId,
        recipientId: recipientNodeId,
        createdAt: t0,
        expiresAt: t0 + 60000,
        messageType: 'PING',
        payloadHash: 'ping',
        signature: 'ping',
        encryptedPayload: 'ping',
      );

      final jsonPayload = envelope.toJson();
      final packetBytes = Uint8List.fromList(utf8.encode(jsonPayload));
      await _transportAdapter.sendPacket(peerId, packetBytes);
      debugPrint('OMNILINK_LATENCY: [t=$t0] Sent PING to $peerId ($recipientNodeId)');
    } catch (_) {}
  }

  void dispose() {
    _incomingSubscription.cancel();
    _localInboundController.close();
  }
}
