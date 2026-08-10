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
    required this.friendlyName,
    required this.lastSeenAt,
    this.rssi,
    required this.transportType,
    required this.connectionStatus,
  });

  PeerDevice copyWith({
    String? peerId,
    String? nodeId,
    String? friendlyName,
    DateTime? lastSeenAt,
    int? rssi,
    String? transportType,
    PeerConnectionStatus? connectionStatus,
  }) {
    return PeerDevice(
      peerId: peerId ?? this.peerId,
      nodeId: nodeId ?? this.nodeId,
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
      'friendly_name': friendlyName,
      'last_seen_at': lastSeenAt.millisecondsSinceEpoch,
      'rssi': rssi,
      'transport_type': transportType,
      'connection_status': connectionStatus.toDbString(),
    };
  }

  factory PeerDevice.fromMap(Map<String, dynamic> map) {
    return PeerDevice(
      peerId: (map['peer_id'] ?? map['peerId']) as String,
      nodeId: (map['node_id'] ?? map['nodeId']) as String?,
      friendlyName: (map['friendly_name'] ?? map['friendlyName']) as String? ?? 'Unknown Peer',
      lastSeenAt: DateTime.fromMillisecondsSinceEpoch(
        (map['last_seen_at'] ?? map['lastSeenAt'] ?? DateTime.now().millisecondsSinceEpoch) as int,
      ),
      rssi: map['rssi'] as int?,
      transportType: (map['transport_type'] ?? map['transportType']) as String? ?? 'ANDROID_NEARBY',
      connectionStatus: PeerConnectionStatusX.fromDbString(
        (map['connection_status'] ?? map['connectionStatus'] ?? 'DISCOVERED') as String,
      ),
    );
  }

  String toJson() => jsonEncode(toMap());

  factory PeerDevice.fromJson(String source) =>
      PeerDevice.fromMap(jsonDecode(source) as Map<String, dynamic>);

  @override
  String toString() {
    return 'PeerDevice(peerId: $peerId, name: $friendlyName, status: ${connectionStatus.name})';
  }
}
