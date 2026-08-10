import 'dart:async';
import 'package:flutter/services.dart';

import 'transport_adapter.dart';

/// Android Platform Channel implementation of the abstract [TransportAdapter] contract.
/// Bridges Layer 2 (Dart Core Communication Engine) to Layer 3 (Native Kotlin Radio Transport).
///
/// MethodChannel: "omnilink/transport/control" (Outbound commands)
/// EventChannel:  "omnilink/transport/events" (Inbound event stream)
/// See docs/08_platform_channel_design.md and spec/platform_channels.md for details.
class AndroidTransportAdapter implements TransportAdapter {
  static const MethodChannel _controlChannel =
      MethodChannel('omnilink/transport/control');
  static const EventChannel _eventChannel =
      EventChannel('omnilink/transport/events');

  final StreamController<PeerConnectionEvent> _peerEventController =
      StreamController.broadcast();
  final StreamController<IncomingPacketEvent> _incomingPacketController =
      StreamController.broadcast();

  StreamSubscription? _eventSubscription;
  final Set<String> _connectedPeers = {};

  @override
  Future<void> initialize() async {
    if (_eventSubscription != null) return;

    _eventSubscription = _eventChannel
        .receiveBroadcastStream()
        .listen(_handleNativeEvent, onError: _handleNativeError);
  }

  /// Maps incoming native JSON maps to Dart domain events.
  void _handleNativeEvent(dynamic rawEvent) {
    if (rawEvent is! Map) return;

    final map = Map<String, dynamic>.from(rawEvent);
    final eventType = map['eventType'] as String?;

    if (eventType == 'onPacketReceived') {
      final senderPeerId =
          (map['senderPeerId'] ?? map['senderId']) as String? ?? 'unknown_peer';
      final rawPayload = map['payloadBytes'];

      Uint8List payloadBytes;
      if (rawPayload is Uint8List) {
        payloadBytes = rawPayload;
      } else if (rawPayload is List) {
        payloadBytes = Uint8List.fromList(List<int>.from(rawPayload));
      } else {
        payloadBytes = Uint8List(0);
      }

      _incomingPacketController.add(
        IncomingPacketEvent(
          senderPeerId: senderPeerId,
          payloadBytes: payloadBytes,
        ),
      );
    } else {
      final peerEvent = PeerConnectionEvent.fromMap(map);

      if (peerEvent.eventType == PeerConnectionEventType.onConnected) {
        _connectedPeers.add(peerEvent.peerId);
      } else if (peerEvent.eventType == PeerConnectionEventType.onDisconnected) {
        _connectedPeers.remove(peerEvent.peerId);
      }

      _peerEventController.add(peerEvent);
    }
  }

  void _handleNativeError(dynamic error) {
    _peerEventController.add(
      PeerConnectionEvent(
        eventType: PeerConnectionEventType.onError,
        peerId: 'system',
        errorCode: 'EVENT_CHANNEL_ERROR',
        errorMessage: error.toString(),
      ),
    );
  }

  @override
  Stream<PeerConnectionEvent> get peerEvents => _peerEventController.stream;

  @override
  Stream<IncomingPacketEvent> get incomingPackets =>
      _incomingPacketController.stream;

  @override
  Future<bool> startDiscovery({String serviceId = 'org.omnilink.mesh.v1'}) async {
    try {
      final result = await _controlChannel.invokeMethod<bool>(
        'startDiscovery',
        {'serviceId': serviceId},
      );
      return result ?? false;
    } on MissingPluginException catch (e) {
      _handleNativeError('MissingPluginException: ${e.message}');
      return false;
    } on PlatformException catch (e) {
      _handleNativeError('PlatformException: ${e.message}');
      return false;
    } catch (e) {
      _handleNativeError(e.toString());
      return false;
    }
  }

  @override
  Future<bool> stopDiscovery() async {
    try {
      final result = await _controlChannel.invokeMethod<bool>('stopDiscovery');
      return result ?? false;
    } on MissingPluginException catch (e) {
      _handleNativeError('MissingPluginException: ${e.message}');
      return false;
    } on PlatformException catch (e) {
      _handleNativeError('PlatformException: ${e.message}');
      return false;
    } catch (e) {
      _handleNativeError(e.toString());
      return false;
    }
  }

  @override
  Future<bool> connectPeer(String peerId) async {
    try {
      final result = await _controlChannel.invokeMethod<bool>(
        'connectPeer',
        {'peerId': peerId},
      );
      return result ?? false;
    } on MissingPluginException catch (e) {
      _handleNativeError('MissingPluginException: ${e.message}');
      return false;
    } on PlatformException catch (e) {
      _handleNativeError('PlatformException: ${e.message}');
      return false;
    } catch (e) {
      _handleNativeError(e.toString());
      return false;
    }
  }

  @override
  Future<bool> disconnectPeer(String peerId) async {
    try {
      final result = await _controlChannel.invokeMethod<bool>(
        'disconnectPeer',
        {'peerId': peerId},
      );
      _connectedPeers.remove(peerId);
      return result ?? false;
    } on MissingPluginException catch (e) {
      _handleNativeError('MissingPluginException: ${e.message}');
      return false;
    } on PlatformException catch (e) {
      _handleNativeError('PlatformException: ${e.message}');
      return false;
    } catch (e) {
      _handleNativeError(e.toString());
      return false;
    }
  }

  @override
  Future<bool> sendPacket(String peerId, Uint8List packetBytes) async {
    try {
      final result = await _controlChannel.invokeMethod<bool>(
        'sendPacket',
        {
          'peerId': peerId,
          'payload': packetBytes,
        },
      );
      return result ?? false;
    } on MissingPluginException catch (e) {
      _handleNativeError('MissingPluginException: ${e.message}');
      return false;
    } on PlatformException catch (e) {
      _handleNativeError('PlatformException: ${e.message}');
      return false;
    } catch (e) {
      _handleNativeError(e.toString());
      return false;
    }
  }

  @override
  Future<bool> isConnected(String peerId) async {
    if (_connectedPeers.contains(peerId)) return true;

    try {
      final result = await _controlChannel.invokeMethod<bool>(
        'isConnected',
        {'peerId': peerId},
      );
      return result ?? false;
    } catch (e) {
      return _connectedPeers.contains(peerId);
    }
  }

  @override
  Future<void> dispose() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;

    await _peerEventController.close();
    await _incomingPacketController.close();
  }
}
