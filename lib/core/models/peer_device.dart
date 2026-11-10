import 'dart:convert';

/// Represents the physical connection lifecycle of a nearby device radio link.
enum PeerConnectionStatus {
  discovered,
  connecting,
  connected,
  disconnected,
}

extension PeerConnectionStatusX on PeerConnectionStatus {
  String toDbString() {
    switch (this) {
      case PeerConnectionStatus.discovered:
        return 'DISCOVERED';
      case PeerConnectionStatus.connecting:
        return 'CONNECTING';
      case PeerConnectionStatus.connected:
        return 'CONNECTED';
      case PeerConnectionStatus.disconnected:
        return 'DISCONNECTED';
    }
  }

  static PeerConnectionStatus fromDbString(String value) {
    switch (value.toUpperCase()) {
      case 'DISCOVERED':
        return PeerConnectionStatus.discovered;
      case 'CONNECTING':
        return PeerConnectionStatus.connecting;
      case 'CONNECTED':
        return PeerConnectionStatus.connected;
      case 'DISCONNECTED':
        return PeerConnectionStatus.disconnected;
      default:
        return PeerConnectionStatus.disconnected;
    }
  }
}

/// Discovered nearby peer device on the physical radio layer.
class PeerDevice {
  /// Transport-assigned transient endpoint identifier (e.g., Nearby endpointId "9A8B").
  final String peerId;

  /// Hex-encoded Ed25519 Public Key of the peer (64 chars) once identified via IDENTITY_EXCHANGE.
  final String? nodeId;

  /// Hex-encoded X25519 Static Public Encryption Key (64 chars) verified via SignedKeyBundle.
  final String? staticX25519PublicKeyHex;

  /// User-chosen human readable nickname.
  final String friendlyName;

  /// Timestamp when peer was last detected or heard from.
  final DateTime lastSeenAt;

  /// Received Signal Strength Indicator (dBm), if available from native transport.
  final int? rssi;

  /// Underlying transport technology ID (e.g., "ANDROID_NEARBY").
  final String transportType;

  /// Connection state with local device.
  final PeerConnectionStatus connectionStatus;

  const PeerDevice({
    required this.peerId,
    this.nodeId,
    this.staticX25519PublicKeyHex,
    required this.friendlyName,
    required this.lastSeenAt,
    this.rssi,
    required this.transportType,
    required this.connectionStatus,
  });

  PeerDevice copyWith({
    String? peerId,
    String? nodeId,
    String? staticX25519PublicKeyHex,
    String? friendlyName,
    DateTime? lastSeenAt,
    int? rssi,
    String? transportType,
    PeerConnectionStatus? connectionStatus,
  }) {
    return PeerDevice(
      peerId: peerId ?? this.peerId,
      nodeId: nodeId ?? this.nodeId,
      staticX25519PublicKeyHex: staticX25519PublicKeyHex ?? this.staticX25519PublicKeyHex,
      friendlyName: friendlyName ?? this.friendlyName,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      rssi: rssi ?? this.rssi,
      transportType: transportType ?? this.transportType,
      connectionStatus: connectionStatus ?? this.connectionStatus,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'peer_id': peerId,
      'node_id': nodeId,
      'static_x25519_public_key': staticX25519PublicKeyHex,
      'friendly_name': friendlyName,
      'last_seen_at': lastSeenAt.millisecondsSinceEpoch,
      'rssi': rssi,
      'transport_type': transportType,
      'connection_status': connectionStatus.toDbString(),
    };
  }

  factory PeerDevice.fromMap(Map<String, dynamic> map) {
    final rawPeerId = map['peer_id'] ?? map['peerId'] ?? map['node_id'] ?? map['nodeId'];
    final rawNodeId = map['node_id'] ?? map['nodeId'];

    final peerId = (rawPeerId is String && rawPeerId.isNotEmpty)
        ? rawPeerId
        : ((rawNodeId is String && rawNodeId.isNotEmpty) ? rawNodeId : 'unknown_peer');

    final nodeId = (rawNodeId is String && rawNodeId.isNotEmpty) ? rawNodeId : null;
    final staticX25519 = (map['static_x25519_public_key'] ?? map['staticX25519PublicKeyHex'])?.toString();

    final rawLastSeen = map['last_seen_at'] ?? map['lastSeenAt'];
    final lastSeenMs = (rawLastSeen is int)
        ? rawLastSeen
        : (rawLastSeen is num ? rawLastSeen.toInt() : DateTime.now().millisecondsSinceEpoch);

    final rawRssi = map['rssi'];
    final rssi = (rawRssi is int) ? rawRssi : (rawRssi is num ? rawRssi.toInt() : null);

    return PeerDevice(
      peerId: peerId,
      nodeId: nodeId,
      staticX25519PublicKeyHex: (staticX25519 != null && staticX25519.isNotEmpty) ? staticX25519 : null,
      friendlyName: (map['friendly_name'] ?? map['friendlyName'])?.toString() ?? 'Unknown Peer',
      lastSeenAt: DateTime.fromMillisecondsSinceEpoch(lastSeenMs),
      rssi: rssi,
      transportType: (map['transport_type'] ?? map['transportType'])?.toString() ?? 'ANDROID_NEARBY',
      connectionStatus: PeerConnectionStatusX.fromDbString(
        (map['connection_status'] ?? map['connectionStatus'] ?? 'DISCOVERED').toString(),
      ),
    );
  }

  String toJson() => jsonEncode(toMap());

  factory PeerDevice.fromJson(String source) =>
      PeerDevice.fromMap(jsonDecode(source) as Map<String, dynamic>);

  @override
  String toString() {
    return 'PeerDevice(peerId: $peerId, nodeId: $nodeId, x25519: $staticX25519PublicKeyHex, name: $friendlyName, status: ${connectionStatus.name})';
  }
}
