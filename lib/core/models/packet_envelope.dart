import 'dart:convert';
import 'dart:typed_data';

/// Standard OMNILINK Protocol Envelope (v0.1).
/// Defined in docs/05_protocol_spec.md and spec/packets.md.
class PacketEnvelope {
  final String protocolVersion;
  final String packetId;
  final String senderId;
  final String recipientId;
  final int createdAt;
  final int expiresAt;
  final int ttl;
  final int hopCount;
  final int maxHops;
  final int priority;
  final String messageType;
  final String payloadHash;
  final String signature;
  final String encryptedPayload;

  const PacketEnvelope({
    this.protocolVersion = '0.1',
    required this.packetId,
    required this.senderId,
    required this.recipientId,
    required this.createdAt,
    required this.expiresAt,
    this.ttl = 7,
    this.hopCount = 0,
    this.maxHops = 7,
    this.priority = 1,
    required this.messageType,
    required this.payloadHash,
    required this.signature,
    required this.encryptedPayload,
  });

  /// Constructs the canonical string representation used to compute the Ed25519 signature digest.
  /// Canonical Format: packet_id + sender_id + recipient_id + created_at + payload_hash
  String toCanonicalString() {
    return '$packetId$senderId$recipientId$createdAt$payloadHash';
  }

  /// Converts the canonical string to UTF-8 bytes for cryptographic signing/verification.
  Uint8List toCanonicalBytes() {
    return Uint8List.fromList(utf8.encode(toCanonicalString()));
  }

  Map<String, dynamic> toMap() {
    return {
      'protocol_version': protocolVersion,
      'packet_id': packetId,
      'sender_id': senderId,
      'recipient_id': recipientId,
      'created_at': createdAt,
      'expires_at': expiresAt,
      'ttl': ttl,
      'hop_count': hopCount,
      'max_hops': maxHops,
      'priority': priority,
      'message_type': messageType,
      'payload_hash': payloadHash,
      'signature': signature,
      'encrypted_payload': encryptedPayload,
    };
  }

  factory PacketEnvelope.fromMap(Map<String, dynamic> map) {
    return PacketEnvelope(
      protocolVersion: (map['protocol_version'] ?? '0.1') as String,
      packetId: map['packet_id'] as String,
      senderId: map['sender_id'] as String,
      recipientId: map['recipient_id'] as String,
      createdAt: map['created_at'] as int,
      expiresAt: map['expires_at'] as int,
      ttl: (map['ttl'] ?? 7) as int,
      hopCount: (map['hop_count'] ?? 0) as int,
      maxHops: (map['max_hops'] ?? 7) as int,
      priority: (map['priority'] ?? 1) as int,
      messageType: map['message_type'] as String,
      payloadHash: map['payload_hash'] as String,
      signature: map['signature'] as String,
      encryptedPayload: map['encrypted_payload'] as String,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory PacketEnvelope.fromJson(String source) =>
      PacketEnvelope.fromMap(jsonDecode(source) as Map<String, dynamic>);

  PacketEnvelope copyWith({
    String? protocolVersion,
    String? packetId,
    String? senderId,
    String? recipientId,
    int? createdAt,
    int? expiresAt,
    int? ttl,
    int? hopCount,
    int? maxHops,
    int? priority,
    String? messageType,
    String? payloadHash,
    String? signature,
    String? encryptedPayload,
  }) {
    return PacketEnvelope(
      protocolVersion: protocolVersion ?? this.protocolVersion,
      packetId: packetId ?? this.packetId,
      senderId: senderId ?? this.senderId,
      recipientId: recipientId ?? this.recipientId,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      ttl: ttl ?? this.ttl,
      hopCount: hopCount ?? this.hopCount,
      maxHops: maxHops ?? this.maxHops,
      priority: priority ?? this.priority,
      messageType: messageType ?? this.messageType,
      payloadHash: payloadHash ?? this.payloadHash,
      signature: signature ?? this.signature,
      encryptedPayload: encryptedPayload ?? this.encryptedPayload,
    );
  }

  /// Computes total size in bytes of serialized JSON envelope.
  int get sizeInBytes => utf8.encode(toJson()).length;

  /// Checks if packet size exceeds strict MTU limit of 4,096 bytes.
  bool get exceedsMtuLimit => sizeInBytes > 4096;

  @override
  String toString() {
    return 'PacketEnvelope(id: $packetId, type: $messageType, sender: ${senderId.substring(0, 8)}..., size: ${sizeInBytes}B)';
  }
}
