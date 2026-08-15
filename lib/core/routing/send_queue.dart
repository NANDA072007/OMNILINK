import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../transport_bridge/transport_adapter.dart';

/// Single item queued for transmission over a physical radio link.
class QueuedSendItem {
  final String packetId;
  final String peerId;
  final Uint8List payloadBytes;
  final Completer<bool> completer;

  QueuedSendItem({
    required this.packetId,
    required this.peerId,
    required this.payloadBytes,
    required this.completer,
  });
}

/// Per-Peer Send Queue Manager managing serialized packet transmissions with strict deadlock timeouts.
class SendQueueManager {
  final TransportAdapter transport;
  final Map<String, List<QueuedSendItem>> _queues = {};
  final Map<String, bool> _isTransmitting = {};

  SendQueueManager({required this.transport});

  /// Enqueues a packet payload for a target peer and processes queue with a 3-second timeout lock.
  Future<bool> enqueueAndSend({
    required String packetId,
    required String peerId,
    required Uint8List payloadBytes,
  }) async {
    final completer = Completer<bool>();
    final item = QueuedSendItem(
      packetId: packetId,
      peerId: peerId,
      payloadBytes: payloadBytes,
      completer: completer,
    );

    _queues.putIfAbsent(peerId, () => []).add(item);
    _processQueue(peerId);

    return completer.future;
  }

  void _processQueue(String peerId) {
    if (_isTransmitting[peerId] == true) return;
    final queue = _queues[peerId];
    if (queue == null || queue.isEmpty) {
      _isTransmitting[peerId] = false;
      return;
    }

    _isTransmitting[peerId] = true;
    final item = queue.removeAt(0);

    Timer? timeoutTimer;
    bool completed = false;

    void finishItem(bool success) {
      if (completed) return;
      completed = true;
      timeoutTimer?.cancel();
      _isTransmitting[peerId] = false;

      if (!item.completer.isCompleted) {
        item.completer.complete(success);
      }

      // Trigger next packet in queue immediately
      scheduleMicrotask(() => _processQueue(peerId));
    }

    // TASK 2: Strict 3-second timeout lock to prevent native send deadlock
    timeoutTimer = Timer(const Duration(seconds: 3), () {
      if (!completed) {
        debugPrint('OMNILINK_QUEUE: Timeout waiting for native ACK. Forcing queue forward.');
        finishItem(false);
      }
    });

    debugPrint('OMNILINK_QUEUE: Pushed packet ${item.packetId} to native transport.');
    transport.sendPacket(peerId, item.payloadBytes).then((success) {
      if (success) {
        debugPrint('OMNILINK_NATIVE: Payload transfer SUCCESS for ${item.packetId}');
      }
      finishItem(success);
    }).catchError((e) {
      debugPrint('OMNILINK_QUEUE: Send error for ${item.packetId}: $e');
      finishItem(false);
    });
  }

  /// Clears outbound queues for a disconnected peer.
  void clearQueue(String peerId) {
    final queue = _queues.remove(peerId);
    if (queue != null) {
      for (final item in queue) {
        if (!item.completer.isCompleted) {
          item.completer.complete(false);
        }
      }
    }
    _isTransmitting.remove(peerId);
  }
}
