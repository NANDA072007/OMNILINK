import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';

import '../../transport_bridge/transport_adapter.dart';
import '../models/message.dart';
import '../models/packet_envelope.dart';
import '../models/peer_device.dart';
import '../repositories/message_repository.dart';
import 'models/queued_packet.dart';
import 'router_engine.dart' hide RouteStrategy;
import 'routing_database.dart';

/// Store-and-Forward Daemon managing persistent message outbox queues in SQLite.
/// Guarantees eventual message delivery across mesh disruptions with priority queueing,
/// automatic peer-connection flushes, TTL expiration, and exponential backoff retries.
class OutboxDaemon {
  final RoutingDatabaseService db;
  final TransportAdapter transport;
  final RouterEngine router;
  final MessageRepository messageRepo;
  final List<PeerDevice> Function() getConnectedPeers;

  StreamSubscription<PeerConnectionEvent>? _peerSub;
  Timer? _maintenanceTimer;
  final Set<String> _flushingPeerIds = {};

  OutboxDaemon({
    required this.db,
    required this.transport,
    required this.router,
    required this.messageRepo,
    required this.getConnectedPeers,
  }) {
    start();
  }

  /// Starts listening for peer connection events and sets up periodic maintenance.
  void start() {
    _peerSub?.cancel();
    _peerSub = transport.peerEvents.listen((event) {
      if (event.eventType == PeerConnectionEventType.onConnected) {
        onPeerConnected(event.peerId);
      }
    });

    _maintenanceTimer?.cancel();
    _maintenanceTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      maintenance();
    });

    debugPrint('OMNILINK_OUTBOX: OutboxDaemon started and listening for peer connections.');
  }

  /// Enqueues an encrypted packet envelope into the persistent SQLite Outbox queue.
  Future<void> enqueue(PacketEnvelope envelope) async {
    try {
      final queued = QueuedPacket(
        packetId: envelope.packetId,
        senderNodeId: envelope.senderId,
        recipientNodeId: envelope.recipientId,
        payload: envelope.toJson(),
        priority: MessagePriority.normal,
        strategy: RouteStrategy.storeAndForward,
        ttl: envelope.ttl,
        hopCount: envelope.hopCount,
        createdAt: DateTime.fromMillisecondsSinceEpoch(envelope.createdAt),
        nextRetryAt: DateTime.now(),
        status: 'pending',
      );

      await db.insertOrUpdateQueuedPacket(queued);
      debugPrint('OMNILINK_OUTBOX: queued packet ${envelope.packetId} for recipient ${envelope.recipientId}');
    } catch (e) {
      debugPrint('OMNILINK_OUTBOX: Error enqueueing packet ${envelope.packetId}: $e');
    }
  }

  /// TASK 3: Force immediate outbox flush when learning or confirming a peer's cryptographic nodeId.
  Future<void> onIdentityLearned(String nodeId, String peerId) async {
    try {
      final pendingPackets = await db.getPendingOutboxPackets();
      final matchingPackets = pendingPackets.where((packet) {
        return packet.recipientNodeId == nodeId || packet.recipientNodeId == peerId;
      }).toList();

      debugPrint('OMNILINK_OUTBOX: Identity learned for $nodeId (peerId=$peerId). Flushing ${matchingPackets.length} pending packets immediately.');

      if (matchingPackets.isNotEmpty) {
        await onPeerConnected(peerId);
      }
    } catch (e) {
      debugPrint('OMNILINK_OUTBOX: Error in onIdentityLearned: $e');
    }
  }

  /// Flushes matching outbox packets when a new peer connects.
  Future<void> onPeerConnected(String peerId) async {
    if (_flushingPeerIds.contains(peerId)) return;
    _flushingPeerIds.add(peerId);
    debugPrint('OMNILINK_FIX: Locked outbox flush for peer $peerId');

    try {
      debugPrint('OMNILINK_OUTBOX: Peer connected ($peerId). Processing pending outbox items...');
      final connectedPeers = getConnectedPeers()
          .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
          .toList();

      final peerDevice = connectedPeers.firstWhere(
        (p) => p.peerId == peerId,
        orElse: () => PeerDevice(
          peerId: peerId,
          friendlyName: '',
          lastSeenAt: DateTime.now(),
          transportType: 'ANDROID_NEARBY',
          connectionStatus: PeerConnectionStatus.connected,
        ),
      );

      final peerNodeId = peerDevice.nodeId ?? peerId;
      final pendingPackets = await db.getPendingOutboxPackets();

      // Filter packets for this peer (direct recipient or relay path)
      final relevantPackets = pendingPackets.where((packet) {
        return packet.recipientNodeId == peerNodeId ||
            packet.recipientNodeId == peerId ||
            packet.status == 'pending';
      }).toList();

      // Sort by dynamic urgencyScore (priority weight + age + TTL - retry penalty)
      relevantPackets.sort((a, b) => b.urgencyScore.compareTo(a.urgencyScore));

      debugPrint('OMNILINK_OUTBOX: Found ${relevantPackets.length} candidate packet(s) to transmit to $peerId');

      for (final packet in relevantPackets) {
        final payloadBytes = utf8.encode(packet.payload);

        debugPrint('OMNILINK_FIX: Flushing outbox packet ${packet.packetId} through SendQueueManager for peer $peerId');
        final success = await router.sendQueueManager.enqueueAndSend(
          packetId: packet.packetId,
          peerId: peerId,
          payloadBytes: payloadBytes,
        );

        if (success) {
          await db.deleteQueuedPacket(packet.packetId);
          await messageRepo.updateMessageState(packet.packetId, MessageState.sending);
          debugPrint('OMNILINK_OUTBOX: Transmitted packet ${packet.packetId} to $peerId. Removed from outbox.');
        } else {
          await _retryWithBackoff(packet);
        }
      }
    } catch (e) {
      debugPrint('OMNILINK_OUTBOX: Exception during outbox flush: $e');
    } finally {
      _flushingPeerIds.remove(peerId);
      debugPrint('OMNILINK_FIX: Unlocked outbox flush for peer $peerId');
    }
  }

  /// Schedules a packet retry with exponential backoff: min(2^attempts * 1000, 60000) ms.
  Future<void> _retryWithBackoff(QueuedPacket packet) async {
    final newAttempts = packet.retryCount + 1;
    final delayMs = min(pow(2, newAttempts).toInt() * 1000, 60000);
    final nextRetry = DateTime.now().add(Duration(milliseconds: delayMs));

    final updatedPacket = packet.copyWith(
      retryCount: newAttempts,
      nextRetryAt: nextRetry,
      status: 'pending',
    );

    await db.insertOrUpdateQueuedPacket(updatedPacket);
    debugPrint('OMNILINK_OUTBOX: Scheduled retry #$newAttempts for packet ${packet.packetId} in ${delayMs}ms');

    Timer(Duration(milliseconds: delayMs), () async {
      final envelope = PacketEnvelope.fromJson(packet.payload);
      await router.sendMessage(envelope);
    });
  }

  /// Removes expired packets exceeding TTL time limit or 10 max retry attempts.
  Future<void> _expireOldMessages() async {
    try {
      final now = DateTime.now();
      final allPackets = await db.getAllQueuedPackets();
      int expiredCount = 0;

      for (final packet in allPackets) {
        final envelope = PacketEnvelope.fromJson(packet.payload);
        final isExpiredByTime = envelope.expiresAt < now.millisecondsSinceEpoch;
        final isExceededRetries = packet.retryCount > 10;

        if (isExpiredByTime || isExceededRetries) {
          await db.deleteQueuedPacket(packet.packetId);
          await messageRepo.updateMessageState(packet.packetId, MessageState.failed);
          expiredCount++;
          debugPrint('OMNILINK_OUTBOX: Expired packet ${packet.packetId} (timeExpired=$isExpiredByTime, retries=${packet.retryCount})');
        }
      }

      if (expiredCount > 0) {
        debugPrint('OMNILINK_OUTBOX: Expired $expiredCount old/failed messages from outbox_queue.');
      }
    } catch (e) {
      debugPrint('OMNILINK_OUTBOX: Error expiring old messages: $e');
    }
  }

  /// Periodic maintenance tasks (runs every 30 seconds).
  Future<void> maintenance() async {
    await _expireOldMessages();
    final connectedPeers = getConnectedPeers()
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
        .toList();

    if (connectedPeers.isNotEmpty) {
      for (final peer in connectedPeers) {
        await onPeerConnected(peer.peerId);
      }
    }
  }

  /// Triggers anti-entropy sync across connected peers.
  Future<void> triggerAntiEntropySync() async {
    final connectedPeers = getConnectedPeers()
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
        .toList();

    for (final peer in connectedPeers) {
      await onPeerConnected(peer.peerId);
    }
  }

  /// Schedules degraded retry sequence for low-bandwidth mode.
  Future<bool> scheduleDegradedRetry({
    required Future<bool> Function() attemptSend,
  }) async {
    final retryDelaysSeconds = [2, 5, 10, 30];

    for (final seconds in retryDelaysSeconds) {
      await Future.delayed(Duration(seconds: seconds));
      final success = await attemptSend();
      if (success) return true;
    }
    return false;
  }

  void dispose() {
    _peerSub?.cancel();
    _maintenanceTimer?.cancel();
  }
}
