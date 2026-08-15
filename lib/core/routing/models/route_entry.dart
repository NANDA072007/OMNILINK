/// Model representing a Routing Table entry in the OMNILINK mesh network.
class RouteEntry {
  final String destinationNodeId;
  final String nextHopPeerId;
  final String? nextHopNodeId;
  final int hopCount;
  final double probability;
  final double signalQuality;
  final DateTime lastUpdated;
  final DateTime? lastSuccessfulDelivery;
  final int deliveryAttempts;
  final int deliverySuccesses;
  final bool isActive;

  const RouteEntry({
    required this.destinationNodeId,
    required this.nextHopPeerId,
    this.nextHopNodeId,
    this.hopCount = 1,
    this.probability = 1.0,
    this.signalQuality = 0.5,
    required this.lastUpdated,
    this.lastSuccessfulDelivery,
    this.deliveryAttempts = 0,
    this.deliverySuccesses = 0,
    this.isActive = true,
  });

  Map<String, dynamic> toMap() {
    return {
      'destination_node_id': destinationNodeId,
      'next_hop_peer_id': nextHopPeerId,
      'next_hop_node_id': nextHopNodeId,
      'hop_count': hopCount,
      'probability': probability,
      'signal_quality': signalQuality,
      'last_updated': lastUpdated.millisecondsSinceEpoch,
      'last_successful_delivery': lastSuccessfulDelivery?.millisecondsSinceEpoch,
      'delivery_attempts': deliveryAttempts,
      'delivery_successes': deliverySuccesses,
      'is_active': isActive ? 1 : 0,
    };
  }

  factory RouteEntry.fromMap(Map<String, dynamic> map) {
    return RouteEntry(
      destinationNodeId: map['destination_node_id'] as String,
      nextHopPeerId: map['next_hop_peer_id'] as String,
      nextHopNodeId: map['next_hop_node_id'] as String?,
      hopCount: (map['hop_count'] as num?)?.toInt() ?? 1,
      probability: (map['probability'] as num?)?.toDouble() ?? 1.0,
      signalQuality: (map['signal_quality'] as num?)?.toDouble() ?? 0.5,
      lastUpdated: DateTime.fromMillisecondsSinceEpoch(
        (map['last_updated'] as num).toInt(),
      ),
      lastSuccessfulDelivery: map['last_successful_delivery'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (map['last_successful_delivery'] as num).toInt(),
            )
          : null,
      deliveryAttempts: (map['delivery_attempts'] as num?)?.toInt() ?? 0,
      deliverySuccesses: (map['delivery_successes'] as num?)?.toInt() ?? 0,
      isActive: (map['is_active'] as num?)?.toInt() == 1,
    );
  }

  RouteEntry copyWith({
    String? destinationNodeId,
    String? nextHopPeerId,
    String? nextHopNodeId,
    int? hopCount,
    double? probability,
    double? signalQuality,
    DateTime? lastUpdated,
    DateTime? lastSuccessfulDelivery,
    int? deliveryAttempts,
    int? deliverySuccesses,
    bool? isActive,
  }) {
    return RouteEntry(
      destinationNodeId: destinationNodeId ?? this.destinationNodeId,
      nextHopPeerId: nextHopPeerId ?? this.nextHopPeerId,
      nextHopNodeId: nextHopNodeId ?? this.nextHopNodeId,
      hopCount: hopCount ?? this.hopCount,
      probability: probability ?? this.probability,
      signalQuality: signalQuality ?? this.signalQuality,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      lastSuccessfulDelivery:
          lastSuccessfulDelivery ?? this.lastSuccessfulDelivery,
      deliveryAttempts: deliveryAttempts ?? this.deliveryAttempts,
      deliverySuccesses: deliverySuccesses ?? this.deliverySuccesses,
      isActive: isActive ?? this.isActive,
    );
  }
}
