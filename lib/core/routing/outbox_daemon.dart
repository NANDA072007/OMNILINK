import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:collection/collection.dart';

import '../../transport_bridge/transport_adapter.dart';
import '../diagnostics/app_logger.dart';
import '../diagnostics/metrics_service.dart';
import '../models/message.dart';
import '../models/packet_envelope.dart';
import '../models/peer_device.dart';
import '../repositories/message_repository.dart';
import '../repositories/peer_repository.dart';
import '../database/database_service.dart';
import 'models/queued_packet.dart';
import 'router_engine.dart' hide RouteStrategy;
import 'routing_database.dart';

/// Store-and-Forward Daemon managing persistent message outbox queues in SQLite.
/// Guarantees eventual message delivery across mesh disruptions with priority queueing,
/// atomic batch flushes, idempotent lock flags, and MetricsService telemetry.
class OutboxDaemon {
  final RoutingDatabaseService db;
  final TransportAdapter transport;
  final RouterEngine router;
  final MessageRepository messageRepo;
  final List<PeerDevice> Function() getConnectedPeers;

  Timer? _maintenanceTimer;
  final Set<String> _flushingPeerIds = {};

  /// Time given to an end-to-end delivery receipt to arrive before a
  /// link-acked packet is retried.
  static const Duration receiptGrace = Duration(seconds: 30);

  OutboxDaemon({
    required this.db,
    required this.transport,
    required this.router,
    required this.messageRepo,
    required this.getConnectedPeers,
  }) {
    start();
  }

  /// Starts periodic maintenance. Peer connect/disconnect orchestration is
  /// owned by RouterEngine so each link is flushed exactly once per event.
  void start() {
    _maintenanceTimer?.cancel();
    _maintenanceTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      maintenance();
    });

    AppLogger.info('OutboxDaemon started; peer lifecycle is owned by RouterEngine.', domain: LogDomain.routing);
  }

  /// Persists an encrypted packet envelope, then attempts an immediate flush.
  Future<void> enqueue(PacketEnvelope envelope) async {
    await persist(envelope);
    unawaited(flushAll());
  }

  /// Durably writes the envelope without attempting transmission.
  /// Used by the outbox-first send path so the row exists before radio I/O.
  Future<void> persist(PacketEnvelope envelope) async {
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
      AppLogger.info('Persisted packet ${envelope.packetId} for recipient ${envelope.recipientId}', domain: LogDomain.routing);
    } catch (e, s) {
      AppLogger.error('Error persisting packet ${envelope.packetId}', domain: LogDomain.routing, error: e, stackTrace: s);
    }
  }

  /// Removes the durable copy after a verified end-to-end delivery receipt.
  Future<void> acknowledgeDelivery(String packetId) async {
    try {
      await db.deleteQueuedPacket(packetId);
      AppLogger.info('End-to-end receipt confirmed for $packetId; outbox copy removed.', domain: LogDomain.routing);
    } catch (e, s) {
      AppLogger.error('Error acknowledging delivered packet $packetId', domain: LogDomain.routing, error: e, stackTrace: s);
    }
  }

  /// Keeps a link-acked packet in the outbox but delays its next attempt to
  /// give the receiver's delivery receipt time to arrive.
  Future<void> markAwaitingReceipt(String packetId) async {
    try {
      await db.markOutboxPacketAwaitingReceipt(
        packetId,
        DateTime.now().add(receiptGrace),
      );
    } catch (e, s) {
      AppLogger.error('Error marking packet $packetId awaiting receipt', domain: LogDomain.routing, error: e, stackTrace: s);
    }
  }

  void onPeerDisconnected(String peerId) {
    _flushingPeerIds.remove(peerId);
  }

  /// Triggers immediate flush scan for all currently connected peer links.
  Future<void> flushAll() async {
    final connectedPeers = getConnectedPeers()
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
        .toList();

    for (final peer in connectedPeers) {
      await _flushPeerOutbox(peer.peerId, peer.nodeId);
    }
  }

  /// Force immediate outbox flush when learning or confirming a peer's cryptographic nodeId & static X25519 key.
  Future<void> onIdentityLearned(String nodeId, String peerId) async {
    try {
      _flushingPeerIds.remove(peerId); // Release any stale connection lock
      AppLogger.info('Identity learned for $nodeId (peerId=$peerId). Flushing outbox immediately.', domain: LogDomain.routing);
      await messageRepo.migrateConversationId(peerId, nodeId);
      await _processQueuedPlaintextMessages(peerId, nodeId);
      await _flushPeerOutbox(peerId, nodeId);
    } catch (e, s) {
      AppLogger.error('Error in onIdentityLearned for peer $peerId', domain: LogDomain.routing, error: e, stackTrace: s);
    }
  }

  /// Encrypts and transmits any queued plaintext messages once remote X25519 static key is available.
  Future<void> _processQueuedPlaintextMessages(String peerId, String? peerNodeId) async {
    try {
      final connectedPeers = getConnectedPeers();
      final peer = connectedPeers.firstWhereOrNull(
        (p) => p.peerId == peerId || (peerNodeId != null && p.nodeId == peerNodeId),
      );

      String? staticX25519 = peer?.staticX25519PublicKeyHex;
      final targetNodeId = peer?.nodeId ?? peerNodeId;

      if ((staticX25519 == null || staticX25519.isEmpty) && targetNodeId != null && targetNodeId.isNotEmpty) {
        final dbPeer = await PeerRepository(dbService: DatabaseService.instance).getPeerByNodeId(targetNodeId);
        staticX25519 = dbPeer?.staticX25519PublicKeyHex;
      }

      if (staticX25519 == null || staticX25519.isEmpty || targetNodeId == null || targetNodeId.isEmpty) {
        return;
      }

      final queuedMessages = await messageRepo.getMessagesForConversation(targetNodeId);
      final pendingPlaintext = queuedMessages.where((m) => m.state == MessageState.queued).toList();

      if (pendingPlaintext.isEmpty) return;

      final myNodeId = router.getMyNodeId();
      final masterKeyPair = router.getMasterKeyPair?.call();

      if (myNodeId.isEmpty || masterKeyPair == null) return;

      // Access static X25519 key directly from in-memory identity state (zero disk Keystore reads)
      final staticKeyPair = router.getStaticX25519KeyPair?.call();
      if (staticKeyPair == null) {
        AppLogger.warn(
          'Deferred processing queued plaintext messages for $targetNodeId: staticX25519KeyPair not yet initialized in memory.',
          domain: LogDomain.routing,
        );
        return;
      }

      for (final msg in pendingPlaintext) {
        if (msg.plaintextBody == null || msg.plaintextBody!.isEmpty) continue;

        // Atomic reservation: prevent concurrent flushes or send taps from double-encrypting
        await messageRepo.updateMessageState(msg.messageId, MessageState.sending);

        try {
          final envelope = await router.packetService.createEncryptedMessageEnvelope(
            senderNodeId: myNodeId,
            senderKeyPair: masterKeyPair,
            senderStaticX25519KeyPair: staticKeyPair,
            recipientNodeId: targetNodeId,
            recipientStaticX25519PublicKeyHex: staticX25519,
            plaintextBody: msg.plaintextBody!,
            packetId: msg.messageId,
          );

          await router.sendMessage(envelope);
          AppLogger.info('Encrypted and transmitted queued plaintext message ${msg.messageId} to $targetNodeId', domain: LogDomain.routing);
        } catch (err, st) {
          // Revert to queued on transmission failure so it can be retried on next connect
          await messageRepo.updateMessageState(msg.messageId, MessageState.queued);
          AppLogger.error('Failed to encrypt/send queued message ${msg.messageId}', domain: LogDomain.routing, error: err, stackTrace: st);
        }
      }
    } catch (e, s) {
      AppLogger.error('Error processing queued plaintext messages for peer $peerId', domain: LogDomain.routing, error: e, stackTrace: s);
    }
  }

  /// Flushes matching outbox packets when a new peer connects.
  Future<void> onPeerConnected(String peerId) async {
    final connectedPeers = getConnectedPeers()
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
        .toList();

    final peerDevice = connectedPeers.firstWhereOrNull((p) => p.peerId == peerId);
    final peerNodeId = peerDevice?.nodeId;

    if (peerNodeId != null && peerNodeId.isNotEmpty) {
      await messageRepo.migrateConversationId(peerId, peerNodeId);
    }
    await _processQueuedPlaintextMessages(peerId, peerNodeId);
    await _flushPeerOutbox(peerId, peerNodeId);
  }

  /// Receipt-driven outbox flush for one peer link.
  ///
  /// A successful radio send only moves the row to "awaiting receipt"; the row
  /// is removed exclusively by [acknowledgeDelivery]. This is what makes a
  /// receiver crash or a lost receipt safe: the sender still has the packet.
  Future<void> _flushPeerOutbox(String peerId, String? peerNodeId) async {
    if (_flushingPeerIds.contains(peerId)) {
      AppLogger.info('Bypassing duplicate concurrent flush for peer $peerId', domain: LogDomain.routing);
      return;
    }

    _flushingPeerIds.add(peerId);

    final metrics = MetricsService.instance;
    metrics.startTimer('outbox_flush_duration');

    try {
      // Anti-entropy handshake: exchange summary vectors for missed packets.
      unawaited(router.routeProtocol.sendSyncHandshake(peerId));

      final pendingPackets = await db.getDueOutboxPackets(DateTime.now());
      metrics.setGauge('outbox_pending_count', pendingPackets.length.toDouble());

      if (pendingPackets.isEmpty) return;

      // Filter packets for this peer (direct recipient, peerId/nodeId match, or valid mesh relay TTL)
      final relevantPackets = pendingPackets.where((packet) {
        final isDirect = packet.recipientNodeId == peerNodeId ||
            packet.recipientNodeId == peerId ||
            (peerNodeId != null && packet.recipientNodeId.contains(peerNodeId)) ||
            (peerNodeId != null && peerNodeId.contains(packet.recipientNodeId));
        return isDirect || packet.ttl > 0;
      }).toList();

      if (relevantPackets.isEmpty) return;

      relevantPackets.sort((a, b) => b.urgencyScore.compareTo(a.urgencyScore));

      AppLogger.info('Found ${relevantPackets.length} due packet(s) for $peerId ($peerNodeId)', domain: LogDomain.routing);

      // Claim with a lease. If this process dies mid-flush, the rows become
      // eligible again after the lease instead of staying 'sending' forever.
      final candidateIds = relevantPackets.map((p) => p.packetId).toList();
      final leaseUntil = DateTime.now().add(const Duration(minutes: 2));
      await db.claimOutboxPackets(candidateIds, leaseUntil);

      final awaitingReceiptIds = <String>[];
      final failedPacketsToUpdate = <QueuedPacket>[];

      for (final packet in relevantPackets) {
        final payloadBytes = utf8.encode(packet.payload);

        final success = await router.sendQueueManager.enqueueAndSend(
          packetId: packet.packetId,
          peerId: peerId,
          payloadBytes: payloadBytes,
        );

        if (success) {
          awaitingReceiptIds.add(packet.packetId);
          await messageRepo.updateMessageStateUnlessReceiptReceived(
            packet.packetId,
            MessageState.delivered,
          );
        } else {
          final newAttempts = packet.retryCount + 1;
          final delayMs = min(pow(2, newAttempts).toInt() * 1000, 60000);
          failedPacketsToUpdate.add(
            packet.copyWith(
              retryCount: newAttempts,
              nextRetryAt: DateTime.now().add(Duration(milliseconds: delayMs)),
              status: 'pending',
            ),
          );
          await messageRepo.updateMessageStateUnlessReceiptReceived(
            packet.packetId,
            MessageState.queued,
          );
        }
      }

      if (awaitingReceiptIds.isNotEmpty) {
        final count = await db.markOutboxPacketsAwaitingReceipt(
          awaitingReceiptIds,
          DateTime.now().add(receiptGrace),
        );
        metrics.increment('outbox_packets_awaiting_receipt', count);
        AppLogger.info('$count packet(s) link-acked for $peerId; awaiting end-to-end receipts.', domain: LogDomain.routing);
      }

      if (failedPacketsToUpdate.isNotEmpty) {
        await db.batchUpdateQueuedPackets(failedPacketsToUpdate);
        metrics.increment('outbox_packets_failed', failedPacketsToUpdate.length);
        AppLogger.warn('Batch updated ${failedPacketsToUpdate.length} failed packets with exponential backoff', domain: LogDomain.routing);
      }
    } catch (e, s) {
      AppLogger.error('Exception during outbox flush for peer $peerId', domain: LogDomain.routing, error: e, stackTrace: s);
    } finally {
      metrics.stopTimer('outbox_flush_duration');
      _flushingPeerIds.remove(peerId);
    }
  }

  /// Removes expired packets exceeding TTL time limit or 10 max retry attempts in a single batch transaction.
  Future<void> _expireOldMessages() async {
    try {
      final now = DateTime.now();
      final allPackets = await db.getAllQueuedPackets();
      final expiredIds = <String>[];

      for (final packet in allPackets) {
        final envelope = PacketEnvelope.fromJson(packet.payload);
        // Store-and-forward messages may legitimately retry many times while
        // the recipient is offline. Only the envelope expiry ends their life.
        if (envelope.expiresAt < now.millisecondsSinceEpoch) {
          expiredIds.add(packet.packetId);
          await messageRepo.updateMessageState(packet.packetId, MessageState.expired);
        }
      }

      if (expiredIds.isNotEmpty) {
        final count = await db.deleteQueuedPacketsByIds(expiredIds);
        AppLogger.info('Batch expired $count old/failed packets from outbox queue', domain: LogDomain.routing);
      }
    } catch (e, s) {
      AppLogger.error('Error expiring old messages', domain: LogDomain.routing, error: e, stackTrace: s);
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
    _maintenanceTimer?.cancel();
  }
}
