import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../crypto/packet_service.dart';
import '../models/packet_envelope.dart';
import '../models/peer_device.dart';
import '../../transport_bridge/transport_adapter.dart';

/// Global Multi-Hop Mesh Routing Engine for OMNILINK with latency ping/pong and delivery receipts.
class MeshRouter {
  final TransportAdapter _transportAdapter;
  final PacketService _packetService;
  final List<PeerDevice> Function() _getConnectedPeers;
  final String? Function() _getMyNodeId;

  late final StreamSubscription<IncomingPacketEvent> _incomingSubscription;
  final StreamController<PacketEnvelope> _localInboundController =
      StreamController<PacketEnvelope>.broadcast();

  MeshRouter({
    required TransportAdapter transportAdapter,
    required PacketService packetService,
    required List<PeerDevice> Function() getConnectedPeers,
    required String? Function() getMyNodeId,
  })  : _transportAdapter = transportAdapter,
        _packetService = packetService,
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
      'OMNILINK_DART: [t=$tRecv] incoming packet received from senderPeerId=${event.senderPeerId} (${event.payloadBytes.length} bytes)',
    );

    try {
      final jsonString = utf8.decode(event.payloadBytes);
      final envelope = PacketEnvelope.fromJson(jsonString);

      debugPrint(
        'OMNILINK_DART: [t=$tRecv] decoded envelope packetId=${envelope.packetId} type=${envelope.messageType} senderId=${envelope.senderId} recipientId=${envelope.recipientId}',
      );

      // 1. Check LRU deduplication cache (Prevent routing loops)
      if (_packetService.isDuplicate(envelope.packetId)) {
        debugPrint('OMNILINK_DART: [t=$tRecv] dropping duplicate packet ${envelope.packetId}');
        return;
      }
      _packetService.markProcessed(envelope.packetId);

      // 2. Validate envelope signature
      final isValid = await _packetService.validateEnvelope(envelope);
      if (!isValid) {
        debugPrint('OMNILINK_DART: [t=$tRecv] invalid signature for packet ${envelope.packetId}');
        return;
      }

      final myNodeId = _getMyNodeId();

      // 3. Application-level Ping/Pong handling (Fix #7)
      if (envelope.messageType == 'PING') {
        final rtt = tRecv - envelope.createdAt;
        debugPrint('OMNILINK_LATENCY: [t=$tRecv] ping received from ${envelope.senderId} (one-way estimate: ${rtt}ms)');
        _sendPong(envelope.senderId, event.senderPeerId);
        return;
      } else if (envelope.messageType == 'PONG') {
        final rtt = tRecv - envelope.createdAt;
        debugPrint('OMNILINK_LATENCY: [t=$tRecv] ping RTT=$rtt ms from ${envelope.senderId}');
        return;
      }

      // 4. Routing decision branch
      if (myNodeId != null && (envelope.recipientId == myNodeId || envelope.recipientId == event.senderPeerId)) {
        // Destination is local node -> Emit to local inbound stream
        debugPrint('OMNILINK_DART: [t=$tRecv] packet ${envelope.packetId} accepted for local node');
        _localInboundController.add(envelope);
      } else if (envelope.ttl > 1) {
        // Multi-hop relay
        final forwardEnvelope = envelope.copyWith(
          ttl: envelope.ttl - 1,
          hopCount: envelope.hopCount + 1,
        );

        final jsonPayload = forwardEnvelope.toJson();
        final packetBytes = Uint8List.fromList(utf8.encode(jsonPayload));

        final connectedPeers = _getConnectedPeers();
        for (final peer in connectedPeers) {
          if (peer.peerId != event.senderPeerId &&
              peer.connectionStatus == PeerConnectionStatus.connected) {
            await _transportAdapter.sendPacket(peer.peerId, packetBytes);
          }
        }
      } else {
        debugPrint('OMNILINK_DART: [t=$tRecv] dropped packet ${envelope.packetId} due to TTL expiry');
      }
    } catch (e, s) {
      debugPrint('OMNILINK_DART: [t=$tRecv] packet decode exception: $e\n$s');
    }
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
      debugPrint('OMNILINK_LATENCY: [t=$t0] sent PONG to $peerId');
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
      debugPrint('OMNILINK_LATENCY: [t=$t0] sent PING to $peerId ($recipientNodeId)');
    } catch (_) {}
  }

  void dispose() {
    _incomingSubscription.cancel();
    _localInboundController.close();
  }
}
