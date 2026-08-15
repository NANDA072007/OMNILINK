enum MessagePriority {
  low(weight: 1),
  normal(weight: 2),
  high(weight: 3),
  urgent(weight: 5);

  final int weight;
  const MessagePriority({required this.weight});

  static MessagePriority fromString(String val) {
    return MessagePriority.values.firstWhere(
      (e) => e.name.toLowerCase() == val.toLowerCase(),
      orElse: () => MessagePriority.normal,
    );
  }
}

enum RouteStrategy {
  direct,
  flooding,
  epidemic,
  prophet,
  opportunistic;

  static RouteStrategy fromString(String val) {
    return RouteStrategy.values.firstWhere(
      (e) => e.name.toLowerCase() == val.toLowerCase(),
      orElse: () => RouteStrategy.epidemic,
    );
  }
}

/// Represents an encrypted packet stored in the SQLite outbox queue for routing.
class QueuedPacket {
  final String packetId;
  final String senderNodeId;
  final String recipientNodeId;
  final String payload;
  final MessagePriority priority;
  final RouteStrategy strategy;
  final int ttl;
  final int hopCount;
  final DateTime createdAt;
  final int retryCount;
  final DateTime nextRetryAt;
  final String status; // 'pending', 'in_flight', 'delivered', 'failed', 'expired'

  const QueuedPacket({
    required this.packetId,
    required this.senderNodeId,
    required this.recipientNodeId,
    required this.payload,
    this.priority = MessagePriority.normal,
    this.strategy = RouteStrategy.epidemic,
    this.ttl = 7,
    this.hopCount = 0,
    required this.createdAt,
    this.retryCount = 0,
    required this.nextRetryAt,
    this.status = 'pending',
  });

  /// Dynamic urgency score used by scheduler to prioritize transmission ordering.
  double get urgencyScore {
    final ageInMinutes = DateTime.now().difference(createdAt).inMinutes;
    return (priority.weight * 100.0) +
        (ttl * 10.0) -
        (retryCount * 5.0) +
        ageInMinutes;
  }

  Map<String, dynamic> toMap() {
    return {
      'packet_id': packetId,
      'sender_node_id': senderNodeId,
      'recipient_node_id': recipientNodeId,
      'payload': payload,
      'priority': priority.name,
      'strategy': strategy.name,
      'ttl': ttl,
      'hop_count': hopCount,
      'created_at': createdAt.millisecondsSinceEpoch,
      'retry_count': retryCount,
      'next_retry_at': nextRetryAt.millisecondsSinceEpoch,
      'status': status,
    };
  }

  factory QueuedPacket.fromMap(Map<String, dynamic> map) {
    return QueuedPacket(
      packetId: map['packet_id'] as String,
      senderNodeId: map['sender_node_id'] as String,
      recipientNodeId: map['recipient_node_id'] as String,
      payload: map['payload'] as String,
      priority: MessagePriority.fromString(map['priority'] as String? ?? 'normal'),
      strategy: RouteStrategy.fromString(map['strategy'] as String? ?? 'epidemic'),
      ttl: (map['ttl'] as num?)?.toInt() ?? 7,
      hopCount: (map['hop_count'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as num).toInt(),
      ),
      retryCount: (map['retry_count'] as num?)?.toInt() ?? 0,
      nextRetryAt: DateTime.fromMillisecondsSinceEpoch(
        (map['next_retry_at'] as num).toInt(),
      ),
      status: map['status'] as String? ?? 'pending',
    );
  }

  QueuedPacket copyWith({
    String? packetId,
    String? senderNodeId,
    String? recipientNodeId,
    String? payload,
    MessagePriority? priority,
    RouteStrategy? strategy,
    int? ttl,
    int? hopCount,
    DateTime? createdAt,
    int? retryCount,
    DateTime? nextRetryAt,
    String? status,
  }) {
    return QueuedPacket(
      packetId: packetId ?? this.packetId,
      senderNodeId: senderNodeId ?? this.senderNodeId,
      recipientNodeId: recipientNodeId ?? this.recipientNodeId,
      payload: payload ?? this.payload,
      priority: priority ?? this.priority,
      strategy: strategy ?? this.strategy,
      ttl: ttl ?? this.ttl,
      hopCount: hopCount ?? this.hopCount,
      createdAt: createdAt ?? this.createdAt,
      retryCount: retryCount ?? this.retryCount,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      status: status ?? this.status,
    );
  }
}
