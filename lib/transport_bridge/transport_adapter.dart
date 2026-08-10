import 'dart:typed_data';

/// Event types emitted asynchronously from native radio transports to Dart (EventChannel).
enum PeerConnectionEventType {
  onPeerFound,
  onPeerLost,
  onConnected,
  onDisconnected,
  onError,
}

/// Asynchronous event payload emitted when native radio detects peer or state change.
class PeerConnectionEvent {
  final PeerConnectionEventType eventType;
  final String peerId;
  final String? friendlyName;
  final int? rssi;
  final String transportType;
  final String? errorCode;
  final String? errorMessage;

  const PeerConnectionEvent({
    required this.eventType,
    required this.peerId,
    this.friendlyName,
    this.rssi,
    this.transportType = 'ANDROID_NEARBY',
    this.errorCode,
    this.errorMessage,
  });

  factory PeerConnectionEvent.fromMap(Map<String, dynamic> map) {
    final typeStr = map['eventType'] as String? ?? 'onError';
    PeerConnectionEventType type;

    switch (typeStr) {
      case 'onPeerFound':
        type = PeerConnectionEventType.onPeerFound;
        break;
      case 'onPeerLost':
        type = PeerConnectionEventType.onPeerLost;
        break;
      case 'onConnected':
        type = PeerConnectionEventType.onConnected;
        break;
      case 'onDisconnected':
        type = PeerConnectionEventType.onDisconnected;
        break;
      case 'onError':
      default:
        type = PeerConnectionEventType.onError;
        break;
    }

    return PeerConnectionEvent(
      eventType: type,
      peerId: map['peerId'] as String? ?? 'unknown_peer',
      friendlyName: map['friendlyName'] as String?,
      rssi: map['rssi'] as int?,
      transportType: map['transportType'] as String? ?? 'ANDROID_NEARBY',
      errorCode: map['errorCode'] as String?,
      errorMessage: map['errorMessage'] as String?,
    );
  }

  @override
  String toString() {
    return 'PeerConnectionEvent(${eventType.name}, peerId: $peerId, name: $friendlyName)';
  }
}

/// Asynchronous event emitted when an incoming raw byte packet arrives from native radio.
class IncomingPacketEvent {
  /// The transient transport ID of the transmitting peer endpoint.
  final String senderPeerId;

  /// Opaque raw binary packet payload bytes received over physical link.
  /// Strict Rule: Native transport layer DOES NOT parse JSON payload contents.
  final Uint8List payloadBytes;

  const IncomingPacketEvent({
    required this.senderPeerId,
    required this.payloadBytes,
  });

  @override
  String toString() {
    return 'IncomingPacketEvent(from: $senderPeerId, bytes: ${payloadBytes.length})';
  }
}

/// Abstract contract exposing physical radio operations to the Core Communication Engine.
/// See docs/03_flutter_architecture.md and docs/07_transport_abstraction.md.
abstract class TransportAdapter {
  /// Initializes native platform channel bindings and event listeners.
  Future<void> initialize();

  /// Begins scanning for nearby peer devices emitting the specified service ID.
  Future<bool> startDiscovery({String serviceId = 'org.omnilink.mesh.v1'});

  /// Stops peer discovery scanning to conserve power.
  Future<bool> stopDiscovery();

  /// Initiates radio transport connection to a discovered peer.
  Future<bool> connectPeer(String peerId);

  /// Terminate active connection with a peer endpoint.
  Future<bool> disconnectPeer(String peerId);

  /// Transmits raw binary/UTF-8 packet bytes to a peer over native radio transport.
  /// Enforces byte-array boundary across platform channels.
  Future<bool> sendPacket(String peerId, Uint8List packetBytes);

  /// Stream emitting peer discovery, connection, and radio lifecycle events.
  Stream<PeerConnectionEvent> get peerEvents;

  /// Stream emitting incoming raw packet byte arrays received from physical radios.
  Stream<IncomingPacketEvent> get incomingPackets;

  /// Checks if a peer endpoint is currently connected.
  Future<bool> isConnected(String peerId);

  /// Disposes platform channel stream subscriptions and releases resources.
  Future<void> dispose();
}
