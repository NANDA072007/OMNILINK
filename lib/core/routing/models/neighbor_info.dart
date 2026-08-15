/// Model representing direct physical radio neighbor devices in OMNILINK.
class NeighborInfo {
  final String peerId;
  final String? nodeId;
  final String friendlyName;
  final int? rssi;
  final double linkQuality;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final bool isConnected;
  final int packetsSent;
  final int packetsReceived;
  final int packetsFailed;

  const NeighborInfo({
    required this.peerId,
    this.nodeId,
    required this.friendlyName,
    this.rssi,
    required this.linkQuality,
    required this.firstSeen,
    required this.lastSeen,
    this.isConnected = true,
    this.packetsSent = 0,
    this.packetsReceived = 0,
    this.packetsFailed = 0,
  });

  /// Computes historical link delivery success rate [0.0 to 1.0].
  double get successRate =>
      packetsSent > 0 ? (packetsReceived / packetsSent).clamp(0.0, 1.0) : 1.0;

  /// Calculates radio link quality score based on Received Signal Strength Indicator (RSSI).
  static double computeLinkQuality(int? rssi) {
    if (rssi == null) return 0.5;
    if (rssi >= -50) return 1.0;
    if (rssi >= -70) return 0.7;
    if (rssi >= -85) return 0.4;
    return 0.1;
  }

  Map<String, dynamic> toMap() {
    return {
      'peer_id': peerId,
      'node_id': nodeId,
      'friendly_name': friendlyName,
      'rssi': rssi,
      'link_quality': linkQuality,
      'first_seen': firstSeen.millisecondsSinceEpoch,
      'last_seen': lastSeen.millisecondsSinceEpoch,
      'is_connected': isConnected ? 1 : 0,
      'packets_sent': packetsSent,
      'packets_received': packetsReceived,
      'packets_failed': packetsFailed,
    };
  }

  factory NeighborInfo.fromMap(Map<String, dynamic> map) {
    return NeighborInfo(
      peerId: map['peer_id'] as String,
      nodeId: map['node_id'] as String?,
      friendlyName: map['friendly_name'] as String? ?? 'Unknown Peer',
      rssi: (map['rssi'] as num?)?.toInt(),
      linkQuality: (map['link_quality'] as num?)?.toDouble() ?? 0.5,
      firstSeen: DateTime.fromMillisecondsSinceEpoch(
        (map['first_seen'] as num).toInt(),
      ),
      lastSeen: DateTime.fromMillisecondsSinceEpoch(
        (map['last_seen'] as num).toInt(),
      ),
      isConnected: (map['is_connected'] as num?)?.toInt() == 1,
      packetsSent: (map['packets_sent'] as num?)?.toInt() ?? 0,
      packetsReceived: (map['packets_received'] as num?)?.toInt() ?? 0,
      packetsFailed: (map['packets_failed'] as num?)?.toInt() ?? 0,
    );
  }

  NeighborInfo copyWith({
    String? peerId,
    String? nodeId,
    String? friendlyName,
    int? rssi,
    double? linkQuality,
    DateTime? firstSeen,
    DateTime? lastSeen,
    bool? isConnected,
    int? packetsSent,
    int? packetsReceived,
    int? packetsFailed,
  }) {
    return NeighborInfo(
      peerId: peerId ?? this.peerId,
      nodeId: nodeId ?? this.nodeId,
      friendlyName: friendlyName ?? this.friendlyName,
      rssi: rssi ?? this.rssi,
      linkQuality: linkQuality ?? this.linkQuality,
      firstSeen: firstSeen ?? this.firstSeen,
      lastSeen: lastSeen ?? this.lastSeen,
      isConnected: isConnected ?? this.isConnected,
      packetsSent: packetsSent ?? this.packetsSent,
      packetsReceived: packetsReceived ?? this.packetsReceived,
      packetsFailed: packetsFailed ?? this.packetsFailed,
    );
  }
}
