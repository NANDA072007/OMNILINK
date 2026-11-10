import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../transport_bridge/android_transport_adapter.dart';
import '../../transport_bridge/transport_adapter.dart';
import '../diagnostics/metrics_service.dart';

/// Single item queued for transmission over a physical radio link.
class QueuedSendItem {
  final int attemptId;
  final String packetId;
  final String peerId;
  final Uint8List payloadBytes;
  final Completer<bool> completer;
  final DateTime queuedAt;

  QueuedSendItem({
    required this.attemptId,
    required this.packetId,
    required this.peerId,
    required this.payloadBytes,
    required this.completer,
    DateTime? queuedAt,
  }) : queuedAt = queuedAt ?? DateTime.now();
}

/// Per-Peer Send Queue Manager managing serialized packet transmissions with strict deadlock timeouts.
/// Tracks each transmission attempt independently, correlates native transfer updates,
/// prevents late callbacks from completing newer transmissions, and prevents head-of-line blocking.
class SendQueueManager {
  final TransportAdapter transport;
  final Duration timeoutDuration;
  /// Resolves a persistent nodeId to the active transient endpointId so queue keys
  /// match native `payloadTransferUpdate.peerId` (endpointId) and avoid 10s stalls.
  String? Function(String targetId)? endpointResolver;

  int _attemptCounter = 0;
  final Map<String, List<QueuedSendItem>> _queues = {};
  final Map<String, bool> _isTransmitting = {};
  final Map<String, int> _activeAttemptId = {};
  final Map<String, QueuedSendItem> _activeItems = {};
  final Map<String, Timer> _activeTimers = {};
  StreamSubscription? _transferSub;

  SendQueueManager({
    required this.transport,
    this.timeoutDuration = const Duration(seconds: 10),
    Stream<Map<String, dynamic>>? payloadTransferUpdates,
  }) {
    final transferStream = payloadTransferUpdates ??
        (transport is AndroidTransportAdapter
            ? (transport as AndroidTransportAdapter).payloadTransferUpdates
            : null);
    if (transferStream != null) {
      _transferSub = transferStream.listen(_handleNativeTransferUpdate);
    }
  }

  /// Exposes current active attempt ID for test inspection.
  @visibleForTesting
  int? getActiveAttemptId(String peerId) => _activeAttemptId[peerId];

  /// Exposes transmitting state for test inspection.
  @visibleForTesting
  bool isTransmitting(String peerId) => _isTransmitting[peerId] == true;

  /// Exposes queue length for test inspection.
  @visibleForTesting
  int queueDepth(String peerId) => _queues[peerId]?.length ?? 0;

  @visibleForTesting
  void handleNativeTransferUpdateForTesting(Map<String, dynamic> update) =>
      _handleNativeTransferUpdate(update);

  @visibleForTesting
  void failCurrentAttemptForTesting({
    required int attemptId,
    required String peerId,
    required String errorReason,
  }) {
    _finishAttempt(peerId, attemptId, false, reason: errorReason);
  }

  void _handleNativeTransferUpdate(Map<String, dynamic> update) {
    var peerId = update['peerId'] as String?;
    final status = update['status'] as String?;
    if (peerId == null || status == null) return;

    // Native reports transient endpointIds. If we queued under a nodeId, the
    // active entry lives under the resolved endpoint key — check both.
    String? queueKey = peerId;
    if (!_activeItems.containsKey(queueKey)) {
      // Reverse-lookup: find active entry whose original peerId resolves here,
      // or fall back to single-active-entry matching for 1-to-1 links.
      for (final k in _activeItems.keys) {
        final resolved = endpointResolver?.call(k);
        if (resolved == peerId || k == peerId) {
          queueKey = k;
          break;
        }
      }
      // Last resort for single-peer links: correlate by sole active item.
      if (!_activeItems.containsKey(queueKey) && _activeItems.length == 1) {
        queueKey = _activeItems.keys.first;
      }
    }
    if (queueKey == null) return;
    peerId = queueKey;

    final isSuccess = status == 'SUCCESS';
    final currentItem = _activeItems[peerId];
    final currentAttemptId = _activeAttemptId[peerId];

    if (currentItem == null || currentAttemptId == null) {
      debugPrint(
        'OMNILINK_QUEUE: Dropping late or unmatched native transfer update for $peerId: status=$status',
      );
      return;
    }

    final updateAttemptId = (update['attemptId'] as num?)?.toInt();
    if (updateAttemptId != null && updateAttemptId != currentAttemptId) {
      debugPrint(
        'OMNILINK_QUEUE: Dropping late or mismatched attempt update for $peerId '
        '(incoming attempt=$updateAttemptId vs active attempt=$currentAttemptId)',
      );
      return;
    }

    final payloadId = update['payloadId'];
    debugPrint(
      'OMNILINK_QUEUE: Native transfer update correlated for $peerId '
      '(packet=${currentItem.packetId}, attempt=$currentAttemptId, payloadId=$payloadId): status=$status',
    );

    _finishAttempt(peerId, currentAttemptId, isSuccess, reason: 'NATIVE_TRANSFER_$status');
  }

  /// Enqueues a packet payload for a target peer and serializes transmission.
  Future<bool> enqueueAndSend({
    required String packetId,
    required String peerId,
    required Uint8List payloadBytes,
  }) async {
    // Normalize nodeId -> endpointId up front so queue keys match native ACKs.
    final normalizedPeerId = endpointResolver?.call(peerId) ?? peerId;
    final attemptId = ++_attemptCounter;
    final completer = Completer<bool>();
    final item = QueuedSendItem(
      attemptId: attemptId,
      packetId: packetId,
      peerId: normalizedPeerId,
      payloadBytes: payloadBytes,
      completer: completer,
    );

    _queues.putIfAbsent(normalizedPeerId, () => []).add(item);
    _processQueue(normalizedPeerId);

    return completer.future;
  }

  void _processQueue(String peerId) {
    if (_isTransmitting[peerId] == true) return;
    final queue = _queues[peerId];
    if (queue == null || queue.isEmpty) {
      _isTransmitting[peerId] = false;
      _activeAttemptId.remove(peerId);
      _activeItems.remove(peerId);
      return;
    }

    _isTransmitting[peerId] = true;
    final item = queue.removeAt(0);
    _activeAttemptId[peerId] = item.attemptId;
    _activeItems[peerId] = item;

    final attemptId = item.attemptId;
    MetricsService.instance.recordPeerPacketSent(peerId, byteCount: item.payloadBytes.length);

    // Timeout protection: force queue forward if native ACK does not arrive
    final timer = Timer(timeoutDuration, () {
      debugPrint(
        'OMNILINK_QUEUE: Timeout waiting for native ACK for packet ${item.packetId} '
        '(attempt $attemptId, peer $peerId). Forcing queue forward.',
      );
      _finishAttempt(peerId, attemptId, false, reason: 'TIMEOUT');
    });
    _activeTimers[peerId] = timer;

    debugPrint('OMNILINK_QUEUE: Pushed packet ${item.packetId} (attempt $attemptId) to native transport for $peerId.');
    transport.sendPacket(peerId, item.payloadBytes).then((submitted) {
      if (!submitted) {
        debugPrint('OMNILINK_QUEUE: Immediate submission failure for packet ${item.packetId} (attempt $attemptId).');
        _finishAttempt(peerId, attemptId, false, reason: 'SUBMISSION_FAILED');
      } else {
        debugPrint('OMNILINK_NATIVE: Payload send initiated for ${item.packetId} (attempt $attemptId)');
        if (transport is! AndroidTransportAdapter && _transferSub == null) {
          // For Mock/Fake transports without native async event channels, complete immediately upon sendPacket success.
          _finishAttempt(peerId, attemptId, true, reason: 'SYNCHRONOUS_TRANSPORT_COMPLETED');
        }
      }
    }).catchError((e) {
      debugPrint('OMNILINK_QUEUE: Send error for ${item.packetId} (attempt $attemptId): $e');
      _finishAttempt(peerId, attemptId, false, reason: 'EXCEPTION');
    });
  }

  void _finishAttempt(String peerId, int attemptId, bool success, {required String reason}) {
    // Strictly verify that this finish call belongs to the currently active attempt
    if (_activeAttemptId[peerId] != attemptId) {
      debugPrint('OMNILINK_QUEUE: Ignoring outdated/mismatched finishAttempt for peer $peerId (attempt=$attemptId vs active=${_activeAttemptId[peerId]}).');
      return;
    }

    _activeTimers.remove(peerId)?.cancel();
    final item = _activeItems.remove(peerId);
    _activeAttemptId.remove(peerId);
    _isTransmitting[peerId] = false;

    if (item != null) {
      if (success) {
        final latencyMs =
            DateTime.now().difference(item.queuedAt).inMilliseconds.toDouble();
        MetricsService.instance.recordPeerPacketAcked(
          peerId,
          latencyMs: latencyMs,
          byteCount: item.payloadBytes.length,
        );
      } else {
        MetricsService.instance.recordPeerPacketFailed(peerId);
      }

      if (!item.completer.isCompleted) {
        item.completer.complete(success);
      }
    }

    // Advance queue for this peer immediately to prevent head-of-line blocking
    scheduleMicrotask(() => _processQueue(peerId));
  }

  /// Clears outbound queues and aborts in-flight transmission for a disconnected peer.
  /// Handles both raw peerId (endpointId) and mapped nodeId to prevent queue leaks.
  void clearQueue(String peerId) {
    final keysToClear = <String>{peerId};
    final normalized = endpointResolver?.call(peerId);
    if (normalized != null && normalized.isNotEmpty) {
      keysToClear.add(normalized);
    }
    // Also reverse-lookup any key whose endpointResolver maps to peerId
    for (final activeKey in _activeItems.keys) {
      if (endpointResolver?.call(activeKey) == peerId) {
        keysToClear.add(activeKey);
      }
    }
    for (final queuedKey in _queues.keys) {
      if (endpointResolver?.call(queuedKey) == peerId) {
        keysToClear.add(queuedKey);
      }
    }

    for (final key in keysToClear) {
      _activeTimers.remove(key)?.cancel();
      final activeItem = _activeItems.remove(key);
      _activeAttemptId.remove(key);
      _isTransmitting[key] = false;

      if (activeItem != null && !activeItem.completer.isCompleted) {
        activeItem.completer.complete(false);
      }

      final queue = _queues.remove(key);
      if (queue != null) {
        for (final item in queue) {
          if (!item.completer.isCompleted) {
            item.completer.complete(false);
          }
        }
      }
    }
    debugPrint('OMNILINK_QUEUE: Cleared send queues for $keysToClear');
  }

  void dispose() {
    _transferSub?.cancel();
    for (final timer in _activeTimers.values) {
      timer.cancel();
    }
    _activeTimers.clear();
    _activeItems.clear();
    _activeAttemptId.clear();
    _queues.clear();
    _isTransmitting.clear();
  }
}
