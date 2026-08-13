import 'dart:async';

import 'package:flutter/foundation.dart';

import '../crypto/packet_service.dart';
import '../models/message.dart';
import '../repositories/message_repository.dart';
import '../repositories/outbox_repository.dart';

import '../../transport_bridge/transport_adapter.dart';
import 'mesh_router.dart';

/// Store-and-Forward Daemon managing background outbox queue retries.
///
/// Listens to physical radio connection events and automatically flushes
/// queued packets whenever a radio link is re-established with any peer node.
class OutboxDaemon {
  final TransportAdapter _transportAdapter;
  final OutboxRepository _outboxRepo;
  final MessageRepository _messageRepo;
  final PacketService _packetService;
  final MeshRouter _meshRouter;

  late final StreamSubscription<PeerConnectionEvent> _peerSubscription;

  OutboxDaemon({
    required TransportAdapter transportAdapter,
    required OutboxRepository outboxRepo,
    required MessageRepository messageRepo,
    required PacketService packetService,
    required MeshRouter meshRouter,
  })  : _transportAdapter = transportAdapter,
        _outboxRepo = outboxRepo,
        _messageRepo = messageRepo,
        _packetService = packetService,
        _meshRouter = meshRouter {
    _peerSubscription = _transportAdapter.peerEvents.listen(_handlePeerEvent);
  }

  /// Triggered whenever physical radio connection events occur.
  Future<void> _handlePeerEvent(PeerConnectionEvent event) async {
    if (event.eventType == PeerConnectionEventType.onConnected) {
      debugPrint(
        'OMNILINK_OUTBOX: Peer connected (${event.peerId}). Flushing pending outbox packets...',
      );
      await flushOutboxForPeer(event.peerId);
    }
  }

  /// Flushes pending outbox envelopes targeting a specific peer endpoint or node ID.
  Future<int> flushOutboxForPeer(String peerId) async {
    int deliveredCount = 0;
    try {
      final candidatePackets = await _outboxRepo.getAllPendingPackets();
      if (candidatePackets.isEmpty) return 0;

      debugPrint('OMNILINK_OUTBOX: Found ${candidatePackets.length} pending packet(s) in outbox_queue to flush via $peerId');

      for (final envelope in candidatePackets) {
        // Skip if already in deduplication ring buffer (Prevent duplicate sends)
        if (_packetService.isDuplicate(envelope.packetId)) {
          await _outboxRepo.removeFromOutbox(envelope.packetId);
          continue;
        }

        // Transmit envelope via MeshRouter (Direct or Blind Flooding relay)
        final success = await _meshRouter.broadcastEnvelope(envelope, targetPeerId: peerId);

        if (success) {
          debugPrint(
            'OMNILINK_OUTBOX: Successfully flushed queued packet ${envelope.packetId} to/via $peerId',
          );
          // Remove from outbox_queue table
          await _outboxRepo.removeFromOutbox(envelope.packetId);
          // Update SQLite message state to delivered
          await _messageRepo.updateMessageState(
            envelope.packetId,
            MessageState.delivered,
          );
          deliveredCount++;
        } else {
          await _outboxRepo.incrementAttemptCount(envelope.packetId);
        }
      }
    } catch (e, s) {
      debugPrint('OMNILINK_OUTBOX: Error flushing outbox for $peerId: $e\n$s');
    }
    return deliveredCount;
  }

  /// Disposes stream subscription.
  void dispose() {
    _peerSubscription.cancel();
  }
}
