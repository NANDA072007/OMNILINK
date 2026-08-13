import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../crypto/packet_service.dart';
import '../models/message.dart';
import '../repositories/message_repository.dart';
import '../repositories/outbox_repository.dart';
import '../../transport_bridge/transport_adapter.dart';

/// Store-and-Forward Daemon managing background outbox queue retries.
///
/// Listens to physical radio connection events and automatically flushes
/// queued packets whenever a radio link is re-established with a recipient peer.
class OutboxDaemon {
  final TransportAdapter _transportAdapter;
  final OutboxRepository _outboxRepo;
  final MessageRepository _messageRepo;
  final PacketService _packetService;

  late final StreamSubscription<PeerConnectionEvent> _peerSubscription;

  OutboxDaemon({
    required TransportAdapter transportAdapter,
    required OutboxRepository outboxRepo,
    required MessageRepository messageRepo,
    required PacketService packetService,
  })  : _transportAdapter = transportAdapter,
        _outboxRepo = outboxRepo,
        _messageRepo = messageRepo,
        _packetService = packetService {
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
      // Fetch queued packets targeting this peer endpoint / node ID
      final pendingPackets = await _outboxRepo.getPendingPacketsForRecipient(peerId);
      final candidatePackets = pendingPackets.isNotEmpty
          ? pendingPackets
          : await _outboxRepo.getAllPendingPackets();

      for (final envelope in candidatePackets) {
        // Skip if already in deduplication ring buffer (Rule #2: Do not send duplicate packets)
        if (_packetService.isDuplicate(envelope.packetId)) {
          await _outboxRepo.removeFromOutbox(envelope.packetId);
          continue;
        }

        final jsonPayload = envelope.toJson();
        final packetBytes = Uint8List.fromList(utf8.encode(jsonPayload));

        // Attempt transmission over native radio
        final success = await _transportAdapter.sendPacket(peerId, packetBytes);

        if (success) {
          debugPrint(
            'OMNILINK_OUTBOX: Successfully flushed queued packet ${envelope.packetId} to $peerId',
          );
          // Delete from outbox_queue table
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
    } catch (e) {
      debugPrint('OMNILINK_OUTBOX: Error flushing outbox for $peerId: $e');
    }
    return deliveredCount;
  }

  /// Disposes stream subscription.
  void dispose() {
    _peerSubscription.cancel();
  }
}
