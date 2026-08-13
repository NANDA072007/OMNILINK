import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../crypto/packet_service.dart';
import '../models/packet_envelope.dart';
import '../models/peer_device.dart';
import '../../transport_bridge/transport_adapter.dart';

/// Global Multi-Hop Mesh Routing Engine for OMNILINK.
///
/// Implements Blind Flooding relay with Time-To-Live (TTL) hop control,
/// signature preservation, LRU loop prevention, and delivery receipt routing.
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
      'OMNILINK_ROUTER: [t=$tRecv] incoming packet received from senderPeerId=${event.senderPeerId} (${event.payloadBytes.length} bytes)',
    );

    try {
      final jsonString = utf8.decode(event.payloadBytes);
      final envelope = PacketEnvelope.fromJson(jsonString);

      debugPrint(
        'OMNILINK_ROUTER: [t=$tRecv] envelope packetId=${envelope.packetId} type=${envelope.messageType} sender=${envelope.senderId.substring(0, 8)}... recipient=${envelope.recipientId.substring(0, 8)}... ttl=${envelope.ttl} hops=${envelope.hopCount}',
      );

      // 1. Check LRU deduplication cache (Rule #4: Prevent infinite routing loops)
      if (_packetService.isDuplicate(envelope.packetId)) {
        debugPrint('OMNILINK_ROUTER: [t=$tRecv] DROPPING duplicate packet ${envelope.packetId}');
        return;
      }
      _packetService.markProcessed(envelope.packetId);

      // 2. Validate envelope Ed25519 signature
      final isValid = await _packetService.validateEnvelope(envelope);
      if (!isValid) {
        debugPrint('OMNILINK_ROUTER: [t=$tRecv] DROPPING packet ${envelope.packetId}: Invalid signature');
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

      // 4. Inbound Routing Logic (Fix #2)
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
        // Destination is another node -> Multi-hop Blind Flooding Relay
        final forwardEnvelope = envelope.copyWith(
          ttl: envelope.ttl - 1,
          hopCount: envelope.hopCount + 1,
        );

        debugPrint(
          'OMNILINK_ROUTER: [t=$tRecv] RELAYING transit packet ${envelope.packetId} '
          '(target: ${envelope.recipientId.substring(0, 8)}..., new_ttl: ${forwardEnvelope.ttl}, hops: ${forwardEnvelope.hopCount})',
        );

        final jsonPayload = forwardEnvelope.toJson();
        final packetBytes = Uint8List.fromList(utf8.encode(jsonPayload));

        final connectedPeers = _getConnectedPeers();
        int relayCount = 0;
        for (final peer in connectedPeers) {
          // Do not send back to the ingress peer who delivered it to us
          if (peer.peerId != event.senderPeerId &&
              peer.connectionStatus == PeerConnectionStatus.connected) {
            final sent = await _transportAdapter.sendPacket(peer.peerId, packetBytes);
            if (sent) relayCount++;
          }
        }
        debugPrint('OMNILINK_ROUTER: [t=$tRecv] Relayed packet ${envelope.packetId} across $relayCount peer link(s)');
      } else {
        debugPrint('OMNILINK_ROUTER: [t=$tRecv] DROPPED packet ${envelope.packetId}: TTL exhausted (ttl=${envelope.ttl})');
      }
    } catch (e, s) {
      debugPrint('OMNILINK_ROUTER: [t=$tRecv] Exception processing packet: $e\n$s');
    }
  }

  /// Outbound Blind Flooding broadcast helper (Fix #3).
  Future<bool> broadcastEnvelope(PacketEnvelope envelope, {String? targetPeerId}) async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    final jsonPayload = envelope.toJson();
    final packetBytes = Uint8List.fromList(utf8.encode(jsonPayload));

    final connectedPeers = _getConnectedPeers()
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
        .toList();

    if (connectedPeers.isEmpty) {
      debugPrint('OMNILINK_ROUTER: [t=$t0] No connected peers active for outbound broadcast.');
      return false;
    }

    // 1. Direct Link Match
    final directPeerIndex = connectedPeers.indexWhere(
      (p) => p.peerId == targetPeerId || p.nodeId == envelope.recipientId || p.peerId == envelope.recipientId,
    );

    if (directPeerIndex != -1) {
      final target = connectedPeers[directPeerIndex];
      debugPrint('OMNILINK_ROUTER: [t=$t0] Direct link match for target ${target.peerId}. Transmitting directly...');
      return await _transportAdapter.sendPacket(target.peerId, packetBytes);
    }

    // 2. Blind Flooding Multi-Hop Broadcast
    debugPrint(
      'OMNILINK_ROUTER: [t=$t0] Recipient ${envelope.recipientId.substring(0, 8)}... not directly linked. Blind Flooding packet ${envelope.packetId} across ${connectedPeers.length} peer(s)...',
    );
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
