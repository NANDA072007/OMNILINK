import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../crypto/packet_service.dart';
import '../models/packet_envelope.dart';
import '../models/peer_device.dart';
import '../../transport_bridge/transport_adapter.dart';

/// Global Multi-Hop Mesh Routing Engine for OMNILINK.
///
/// Intercepts all physical radio packets, validates cryptographic signatures,
/// routes packets destined for the local node to UI listeners, and forwards
/// transit packets across connected peers with decremented Time-To-Live (TTL).
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

  /// Global packet processing and store-and-forward relay pipeline.
  Future<void> _handleIncomingPacket(IncomingPacketEvent event) async {
    try {
      final jsonString = utf8.decode(event.payloadBytes);
      final envelope = PacketEnvelope.fromJson(jsonString);

      // 1. Check LRU deduplication cache (Rule #3: Prevent routing loops)
      if (_packetService.isDuplicate(envelope.packetId)) return;
      _packetService.markProcessed(envelope.packetId);

      // 2. Validate envelope structural integrity & Ed25519 signature
      final isValid = await _packetService.validateEnvelope(envelope);
      if (!isValid) {
        debugPrint('OMNILINK_ROUTER: Invalid signature for packet ${envelope.packetId}');
        return;
      }

      final myNodeId = _getMyNodeId();

      // 3. Routing decision branch
      if (myNodeId != null && envelope.recipientId == myNodeId) {
        // Destination is local node -> Emit to UI listeners
        debugPrint(
          'OMNILINK_ROUTER: Packet ${envelope.packetId} reached destination $myNodeId',
        );
        _localInboundController.add(envelope);
      } else if (envelope.ttl > 1) {
        // Destination is remote node -> Multi-hop relay (Rule #2: ttl > 1)
        final forwardEnvelope = envelope.copyWith(
          ttl: envelope.ttl - 1,
          hopCount: envelope.hopCount + 1,
        );

        debugPrint(
          'OMNILINK_ROUTER: Forwarding packet ${forwardEnvelope.packetId} '
          '(ttl: ${forwardEnvelope.ttl}, hops: ${forwardEnvelope.hopCount}) '
          'to recipient ${forwardEnvelope.recipientId}',
        );

        final jsonPayload = forwardEnvelope.toJson();
        final packetBytes = Uint8List.fromList(utf8.encode(jsonPayload));

        final connectedPeers = _getConnectedPeers();
        for (final peer in connectedPeers) {
          // Do not send back to the peer who just delivered it to us
          if (peer.peerId != event.senderPeerId &&
              peer.connectionStatus == PeerConnectionStatus.connected) {
            await _transportAdapter.sendPacket(peer.peerId, packetBytes);
          }
        }
      } else {
        debugPrint(
          'OMNILINK_ROUTER: Dropping packet ${envelope.packetId} due to TTL expiry (ttl=${envelope.ttl})',
        );
      }
    } catch (e) {
      // Packet decode or processing error handled silently
    }
  }

  /// Disposes stream subscriptions and releases resources.
  void dispose() {
    _incomingSubscription.cancel();
    _localInboundController.close();
  }
}
