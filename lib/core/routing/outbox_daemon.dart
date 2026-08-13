import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/peer_device.dart';
import '../../transport_bridge/transport_adapter.dart';
import 'mesh_router.dart';

/// Store-and-Forward Daemon managing Epidemic Anti-Entropy Summary Vector Exchanges.
///
/// Listens to physical radio connection events and automatically initiates anti-entropy
/// handshakes whenever radio links connect or local outbox messages are queued.
class OutboxDaemon {
  final TransportAdapter _transportAdapter;
  final MeshRouter _meshRouter;
  final List<PeerDevice> Function() _getConnectedPeers;

  late final StreamSubscription<PeerConnectionEvent> _peerSubscription;

  OutboxDaemon({
    required TransportAdapter transportAdapter,
    required MeshRouter meshRouter,
    required List<PeerDevice> Function() getConnectedPeers,
  })  : _transportAdapter = transportAdapter,
        _meshRouter = meshRouter,
        _getConnectedPeers = getConnectedPeers {
    _peerSubscription = _transportAdapter.peerEvents.listen(_handlePeerEvent);
  }

  /// Triggered whenever physical radio connection events occur.
  Future<void> _handlePeerEvent(PeerConnectionEvent event) async {
    if (event.eventType == PeerConnectionEventType.onConnected) {
      debugPrint(
        'OMNILINK_OUTBOX: Peer connected (${event.peerId}). Initiating Anti-Entropy Handshake...',
      );
      await _meshRouter.sendSyncHandshake(event.peerId);
    }
  }

  /// Triggers an Anti-Entropy Summary Vector Sync across all currently connected radio links.
  Future<void> triggerAntiEntropySync() async {
    final connectedPeers = _getConnectedPeers()
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
        .toList();

    debugPrint(
      'OMNILINK_OUTBOX: Triggering Anti-Entropy Sync across ${connectedPeers.length} active peer(s)...',
    );

    for (final peer in connectedPeers) {
      await _meshRouter.sendSyncHandshake(peer.peerId);
    }
  }

  /// Disposes stream subscription.
  void dispose() {
    _peerSubscription.cancel();
  }
}
