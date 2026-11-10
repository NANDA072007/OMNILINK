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
  final StreamController<Map<String, dynamic>> _payloadTransferController =
      StreamController.broadcast();
  final StreamController<Map<String, dynamic>> _radioStateController =
      StreamController.broadcast();

  StreamSubscription? _eventSubscription;
  final Set<String> _connectedPeers = {};
  int _lastProcessedSequenceNumber = 0;
  bool _isResuming = false;

  Stream<Map<String, dynamic>> get payloadTransferUpdates =>
      _payloadTransferController.stream;

  Stream<Map<String, dynamic>> get radioStateEvents =>
      _radioStateController.stream;

  @override
  Future<void> initialize() async {
    if (_eventSubscription != null) return;

    _eventSubscription = _eventChannel
        .receiveBroadcastStream()
        .listen(_handleNativeEvent, onError: _handleNativeError);

    // Start the durable mesh service and pull a snapshot + sequence replay.
    // This covers cold start, engine restart, and process-alive/engine-gone.
    unawaited(resumeFromBackground());
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

  /// Wrapper to start background mesh service.
  Future<bool> startBackgroundMesh() async {
    return await startForegroundService();
  }

  /// Wrapper to stop background mesh service.
  Future<bool> stopBackgroundMesh() async {
    return await stopForegroundService();
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
      return cap;
    } catch (e) {
      debugPrint('OMNILINK_DART: Error fetching TransportCapability: $e');
      return null;
    }
  }

  /// Fetches granular Android runtime permission status (including API 33+ NEARBY_WIFI_DEVICES).
  Future<Map<String, dynamic>?> getDetailedPermissionStatus() async {
    try {
      final map = await _controlChannel.invokeMapMethod<String, dynamic>(
        'getDetailedPermissionStatus',
      );
      return map;
    } catch (e) {
      debugPrint('OMNILINK_DART: Error fetching detailed permission status: $e');
      return null;
    }
  }

  /// Fetches complete native permission & hardware radio details map.
  Future<Map<String, dynamic>?> getAndroidPermissionDetails() async {
    try {
      final map = await _controlChannel.invokeMapMethod<String, dynamic>(
        'getAndroidPermissionDetails',
      );
      return map;
    } catch (e) {
      debugPrint('OMNILINK_DART: Error fetching android permission details: $e');
      return null;
    }
  }

  /// Fetches Bluetooth usage and profile connection state (A2DP / Headset audio).
  Future<Map<String, dynamic>?> getBluetoothUsageState() async {
    try {
      final map = await _controlChannel.invokeMapMethod<String, dynamic>(
        'getBluetoothUsageState',
      );
      return map;
    } catch (e) {
      debugPrint('OMNILINK_DART: Error fetching Bluetooth usage state: $e');
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
  @visibleForTesting
  void handleNativeEventForTesting(dynamic rawEvent) => _handleNativeEvent(rawEvent);

  void _handleNativeEvent(dynamic rawEvent) {
    if (rawEvent is! Map) return;

    final map = Map<String, dynamic>.from(rawEvent);

    // Sequence-based deduplication
    final seq = (map['sequenceNumber'] as num?)?.toInt();
    if (seq != null) {
      if (seq <= _lastProcessedSequenceNumber) {
        debugPrint('OMNILINK_DART: Dropping duplicate replayed event seq=$seq (lastProcessed=$_lastProcessedSequenceNumber)');
        return;
      }
      _lastProcessedSequenceNumber = seq;
    }

    // Process SNAPSHOT state event. Diff against the previous set so a Flutter
    // engine restart re-learns live links and flushes the outbox.
    if (map['type'] == 'SNAPSHOT') {
      final peers = (map['connectedPeers'] as List?)?.cast<String>() ?? [];
      final previous = Set<String>.from(_connectedPeers);
      _connectedPeers
        ..clear()
        ..addAll(peers);

      for (final peerId in _connectedPeers.difference(previous)) {
        _peerEventController.add(
          PeerConnectionEvent(
            eventType: PeerConnectionEventType.onConnected,
            peerId: peerId,
            transportType: 'ANDROID_NEARBY',
          ),
        );
      }
      for (final peerId in previous.difference(_connectedPeers)) {
        _peerEventController.add(
          PeerConnectionEvent(
            eventType: PeerConnectionEventType.onDisconnected,
            peerId: peerId,
            transportType: 'ANDROID_NEARBY',
          ),
        );
      }

      debugPrint('OMNILINK_DART: Received transport snapshot. Connected peers: $_connectedPeers');
      return;
    }

    // Process RADIO_STATE_CHANGED event from native Kotlin BroadcastReceiver
    if (map['type'] == 'RADIO_STATE_CHANGED') {
      final details = map['details'] as Map?;
      if (details != null) {
        _radioStateController.add(Map<String, dynamic>.from(details));
      }
      return;
    }

    // Process BUFFER_OVERFLOW marker event
    if (map['type'] == 'BUFFER_OVERFLOW') {
      final droppedCount = map['droppedCount'] ?? 0;
      debugPrint('OMNILINK_DART: WARNING: Native event buffer overflow detected! Dropped $droppedCount events.');
      return;
    }

    // Native payload transfer updates from Kotlin (SUCCESS/FAILURE)
    if (map['type'] == 'payloadTransferUpdate' ||
        map['eventType'] == 'onPayloadTransferUpdate') {
      debugPrint(
        'OMNILINK_DART: Received payloadTransferUpdate for ${map['peerId']}: ${map['status']}',
      );
      _payloadTransferController.add(map);
      return;
    }

    // Incoming packet events are identified by type == "incomingPacket".
    if (map['type'] == 'incomingPacket') {
      final peerId = map['peerId'] as String? ?? 'unknown_peer';
      final rawPayload = map['bytes'];
      final spoolId = (map['spoolId'] as num?)?.toInt();

      final Uint8List payloadBytes = _coerceToUint8List(rawPayload);

      debugPrint(
        'OMNILINK_DART: Received incomingPacket event from $peerId with '
        '${payloadBytes.length} bytes (spoolId=$spoolId)',
      );

      _incomingPacketController.add(
        IncomingPacketEvent(
          senderPeerId: peerId,
          payloadBytes: payloadBytes,
          spoolId: spoolId,
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
      final spoolId = (map['spoolId'] as num?)?.toInt();

      final Uint8List payloadBytes = _coerceToUint8List(rawPayload);

      debugPrint(
        'OMNILINK_DART: Received onPacketReceived event from $senderPeerId '
        'with ${payloadBytes.length} bytes (spoolId=$spoolId)',
      );

      _incomingPacketController.add(
        IncomingPacketEvent(
          senderPeerId: senderPeerId,
          payloadBytes: payloadBytes,
          spoolId: spoolId,
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
      await startBackgroundMesh();
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

  /// Authoritative endpoint resolver provided by Layer 2 RouterEngine.
  String? Function(String targetId)? endpointResolver;

  /// Pushes a persistent nodeId <-> transient endpointId binding to native Kotlin
  /// so `sendPacket`/`isConnected`/`disconnectPeer` accept nodeIds on multi-peer meshes.
  Future<bool> registerNodeMapping(String nodeId, String endpointId) async {
    try {
      final result = await _controlChannel.invokeMethod<bool>(
        'registerNodeMapping',
        {'nodeId': nodeId, 'endpointId': endpointId},
      );
      return result ?? false;
    } catch (e) {
      debugPrint('OMNILINK_DART: registerNodeMapping failed: $e');
      return false;
    }
  }

  /// Acknowledges a native durable-spool row after the packet is accepted.
  Future<void> acknowledgeInbound(int spoolId) async {
    try {
      await _controlChannel.invokeMethod<bool>(
        'acknowledgeInboundPacket',
        {'spoolId': spoolId},
      );
    } catch (e) {
      debugPrint('OMNILINK_DART: acknowledgeInbound($spoolId) failed: $e');
    }
  }

  Future<bool> ensureMeshActive() async {
    try {
      return await _controlChannel.invokeMethod<bool>('ensureMeshActive') ?? false;
    } catch (e) {
      debugPrint('OMNILINK_DART: ensureMeshActive failed: $e');
      return false;
    }
  }

  Future<bool> setAutoReconnect(bool enabled) async {
    try {
      return await _controlChannel.invokeMethod<bool>(
            'setAutoReconnect',
            {'enabled': enabled},
          ) ??
          false;
    } catch (e) {
      debugPrint('OMNILINK_DART: setAutoReconnect failed: $e');
      return false;
    }
  }

  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _controlChannel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (e) {
      debugPrint('OMNILINK_DART: isIgnoringBatteryOptimizations failed: $e');
      return false;
    }
  }

  Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      return await _controlChannel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimizations',
          ) ??
          false;
    } catch (e) {
      debugPrint('OMNILINK_DART: requestIgnoreBatteryOptimizations failed: $e');
      return false;
    }
  }

  Future<bool> showMessageNotification({
    required String title,
    required String body,
    required String conversationId,
  }) async {
    try {
      return await _controlChannel.invokeMethod<bool>(
            'showMessageNotification',
            {
              'title': title,
              'body': body,
              'conversationId': conversationId,
            },
          ) ??
          false;
    } catch (e) {
      debugPrint('OMNILINK_DART: showMessageNotification failed: $e');
      return false;
    }
  }

  /// Re-synchronizes with the native layer after the app returns to foreground
  /// or after the Flutter engine was restarted with the Android process alive.
  Future<void> resumeFromBackground() async {
    if (_isResuming) return;
    _isResuming = true;
    try {
      await startForegroundService();

      final snapshot = await _controlChannel.invokeMapMethod<String, dynamic>(
        'requestTransportSnapshot',
      );
      if (snapshot != null) {
        _handleNativeEvent(snapshot);
      }

      await _controlChannel.invokeMethod<int>(
        'resumeFromSequence',
        {'lastSequence': _lastProcessedSequenceNumber},
      );

      await ensureMeshActive();
    } catch (e) {
      debugPrint('OMNILINK_DART: resumeFromBackground failed: $e');
    } finally {
      _isResuming = false;
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

    // Resolve target endpoint ID explicitly if peerId is a cryptographic nodeId
    String targetEndpointId = peerId;
    if (!_connectedPeers.contains(peerId)) {
      final resolved = endpointResolver?.call(peerId);
      if (resolved != null && _connectedPeers.contains(resolved)) {
        targetEndpointId = resolved;
      } else {
        debugPrint(
          'OMNILINK_DART: sendPacket rejected - target $peerId is not in connectedPeers '
          '($_connectedPeers) and could not be resolved to an active endpoint.',
        );
        return false;
      }
    }

    // 2. High-speed Nearby Connections transport
    try {
      final result = await _controlChannel.invokeMethod<bool>(
        'sendPacket',
        {
          'peerId': targetEndpointId,
          'payload': packetBytes,
        },
      );
      if (result == true) return true;
    } catch (_) {}

    return false;
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
    await _payloadTransferController.close();
    await _radioStateController.close();
  }
}
