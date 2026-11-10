enum DiscoveryStatus {
  initializing,
  checkingReadiness,
  notReady,
  ready,
  startingDiscovery,
  discovering,
  peerFound,
  connecting,
  connected,
  disconnected,
  error,
}

class DiscoveredPeer {
  final String endpointId;
  final String deviceName;
  final String serviceId;
  final DateTime discoveredAt;

  DiscoveredPeer({
    required this.endpointId,
    required this.deviceName,
    this.serviceId = 'org.omnilink.mesh.v1',
    DateTime? discoveredAt,
  }) : discoveredAt = discoveredAt ?? DateTime.now();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredPeer &&
          runtimeType == other.runtimeType &&
          endpointId == other.endpointId;

  @override
  int get hashCode => endpointId.hashCode;
}

class DiscoveryState {
  final DiscoveryStatus status;
  final List<DiscoveredPeer> discoveredPeers;
  final String? connectedPeerId;
  final String? connectedPeerName;
  final int? pingPongRttMs;
  final String? errorMessage;

  const DiscoveryState({
    this.status = DiscoveryStatus.initializing,
    this.discoveredPeers = const [],
    this.connectedPeerId,
    this.connectedPeerName,
    this.pingPongRttMs,
    this.errorMessage,
  });

  DiscoveryState copyWith({
    DiscoveryStatus? status,
    List<DiscoveredPeer>? discoveredPeers,
    String? connectedPeerId,
    String? connectedPeerName,
    int? pingPongRttMs,
    String? errorMessage,
  }) {
    return DiscoveryState(
      status: status ?? this.status,
      discoveredPeers: discoveredPeers ?? this.discoveredPeers,
      connectedPeerId: connectedPeerId ?? this.connectedPeerId,
      connectedPeerName: connectedPeerName ?? this.connectedPeerName,
      pingPongRttMs: pingPongRttMs ?? this.pingPongRttMs,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
