import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/models/transport_capability.dart';
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

    await startForegroundService();
  }

  /// Starts the Android 14+ Foreground Service for continuous background mesh listening.
  Future<bool> startForegroundService() async {
    try {
      final result = await _controlChannel.invokeMethod<bool>('startForegroundService');
      return result ?? false;
    } catch (e) {
      debugPrint('OMNILINK_DART: Exception starting Foreground Service: $e');
      return false;
    }
  }

  /// Fetches granular hardware radio and permission capability map.
  Future<TransportCapability?> getTransportCapability() async {
    try {
      final map = await _controlChannel.invokeMapMethod<String, dynamic>(
        'getTransportCapability',
      );
      if (map == null) return null;
      final cap = TransportCapability.fromMap(map);
      debugPrint(
        'OMNILINK_TRANSPORT: capability bluetooth=${cap.bluetoothEnabled} wifi=${cap.wifiEnabled} location=${cap.locationEnabled} sdk=${cap.androidSdkInt}',
      );
      debugPrint('OMNILINK_TRANSPORT: selected mode=${cap.selectTransportMode().name}');
      return cap;
    } catch (e) {
      debugPrint('OMNILINK_DART: Error fetching TransportCapability: $e');
      return null;
    }
  }

  /// Stops the Android Foreground Service.
  Future<bool> stopForegroundService() async {
    try {
      final result = await _controlChannel.invokeMethod<bool>('stopForegroundService');
      return result ?? false;
    } catch (e) {
      debugPrint('OMNILINK_DART: Exception stopping Foreground Service: $e');
      return false;
    }
  }

  /// Maps incoming native JSON maps to Dart domain events.
  void _handleNativeEvent(dynamic rawEvent) {
    if (rawEvent is! Map) return;

    final map = Map<String, dynamic>.from(rawEvent);

    // Incoming packet events are identified by type == "incomingPacket".
    if (map['type'] == 'incomingPacket') {
      final peerId = map['peerId'] as String? ?? 'unknown_peer';
      final rawPayload = map['bytes'];

      final Uint8List payloadBytes = _coerceToUint8List(rawPayload);

      debugPrint(
        'OMNILINK_DART: Received incomingPacket event from $peerId with '
        '${payloadBytes.length} bytes',
      );

      _incomingPacketController.add(
        IncomingPacketEvent(
          senderPeerId: peerId,
          payloadBytes: payloadBytes,
        ),
      );
      return;
    }

    // Legacy/diagnostic shape: eventType == "onPacketReceived".
    final eventType = map['eventType'] as String?;
    if (eventType == 'onPacketReceived') {
      final senderPeerId =
          (map['senderPeerId'] ?? map['senderId']) as String? ?? 'unknown_peer';
      final rawPayload = map['payloadBytes'];

      final Uint8List payloadBytes = _coerceToUint8List(rawPayload);

      debugPrint(
        'OMNILINK_DART: Received onPacketReceived event from $senderPeerId '
        'with ${payloadBytes.length} bytes',
      );

      _incomingPacketController.add(
        IncomingPacketEvent(
          senderPeerId: senderPeerId,
          payloadBytes: payloadBytes,
        ),
      );
      return;
    }

    final peerEvent = PeerConnectionEvent.fromMap(map);

    if (peerEvent.eventType == PeerConnectionEventType.onConnected) {
      _connectedPeers.add(peerEvent.peerId);
    } else if (peerEvent.eventType == PeerConnectionEventType.onDisconnected) {
      _connectedPeers.remove(peerEvent.peerId);
    }

    _peerEventController.add(peerEvent);
  }

  /// Normalizes native byte payloads into [Uint8List]. Native side sends a
  /// ByteArray which arrives here as a [Uint8List]; defensively also accepts
  /// a generic [List] of ints.
  Uint8List _coerceToUint8List(dynamic rawPayload) {
    if (rawPayload is Uint8List) {
      return rawPayload;
    }
    if (rawPayload is List) {
      return Uint8List.fromList(List<int>.from(rawPayload));
    }
    return Uint8List(0);
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
    debugPrint(
      'OMNILINK_DART: sendPacket called to $peerId with ${packetBytes.length} bytes',
    );
    // 1. Check if peerId is a Bluetooth MAC address (e.g. 00:11:22:33:44:55)
    final isMacAddress = RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(peerId);
    if (isMacAddress) {
      return await sendRfcommPacket(peerId, packetBytes);
    }

    // 2. High-speed Nearby Connections transport
    try {
      final result = await _controlChannel.invokeMethod<bool>(
        'sendPacket',
        {
          'peerId': peerId,
          'payload': packetBytes,
        },
      );
      if (result == true) return true;
    } catch (_) {}

    // 3. Fallback to RFCOMM transmit
    return await sendRfcommPacket(peerId, packetBytes);
  }

  /// Lists bonded system Bluetooth devices.
  Future<List<Map<String, dynamic>>> getBondedBluetoothDevices() async {
    try {
      final rawList = await _controlChannel.invokeListMethod<dynamic>('getBondedBluetoothDevices');
      if (rawList == null) return [];
      return rawList.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      debugPrint('OMNILINK_DART: Error fetching bonded devices: $e');
      return [];
    }
  }

  /// Starts RFCOMM background server socket listener.
  Future<bool> startRfcommServer() async {
    try {
      final result = await _controlChannel.invokeMethod<bool>('startRfcommServer');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Stops RFCOMM background server socket listener.
  Future<bool> stopRfcommServer() async {
    try {
      final result = await _controlChannel.invokeMethod<bool>('stopRfcommServer');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Connects to a bonded Bluetooth device using RFCOMM socket stream.
  Future<bool> connectRfcommDevice(String deviceAddress) async {
    try {
      final result = await _controlChannel.invokeMethod<bool>(
        'connectRfcommDevice',
        {'deviceAddress': deviceAddress},
      );
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Disconnects an active RFCOMM socket stream.
  Future<bool> disconnectRfcommDevice(String deviceAddress) async {
    try {
      final result = await _controlChannel.invokeMethod<bool>(
        'disconnectRfcommDevice',
        {'deviceAddress': deviceAddress},
      );
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Transmits raw packet bytes over RFCOMM stream socket.
  Future<bool> sendRfcommPacket(String deviceAddress, Uint8List payload) async {
    try {
      final result = await _controlChannel.invokeMethod<bool>(
        'sendRfcommPacket',
        {
          'deviceAddress': deviceAddress,
          'payload': payload,
        },
      );
      return result ?? false;
    } catch (e) {
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
