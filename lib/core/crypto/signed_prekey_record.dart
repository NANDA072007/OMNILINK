import 'dart:convert';

/// Defines the lifecycle status of a Signed Pre-Key.
enum SignedPreKeyStatus {
  active,
  grace,
  expired,
}

extension SignedPreKeyStatusX on SignedPreKeyStatus {
  String toValueString() => name;

  static SignedPreKeyStatus fromValueString(String val) {
    switch (val.toLowerCase()) {
      case 'active':
        return SignedPreKeyStatus.active;
      case 'grace':
        return SignedPreKeyStatus.grace;
      default:
        return SignedPreKeyStatus.expired;
    }
  }
}

/// Represents the public metadata for a persisted Signed Pre-Key (SPK).
class SignedPreKeyRecord {
  final String id; // Hex public key string used as key identifier
  final String publicKeyHex; // X25519 public key hex
  final int createdAt; // Epoch ms created
  final int expiresAt; // Epoch ms when rotation is due (createdAt + 30 days)
  final int retentionUntil; // Epoch ms when grace period ends (createdAt + 90 days)
  final SignedPreKeyStatus status;

  const SignedPreKeyRecord({
    required this.id,
    required this.publicKeyHex,
    required this.createdAt,
    required this.expiresAt,
    required this.retentionUntil,
    required this.status,
  });

  bool get isExpired => DateTime.now().millisecondsSinceEpoch > retentionUntil;
  bool get needsRotation =>
      DateTime.now().millisecondsSinceEpoch > expiresAt &&
      status == SignedPreKeyStatus.active;

  SignedPreKeyRecord copyWith({
    String? id,
    String? publicKeyHex,
    int? createdAt,
    int? expiresAt,
    int? retentionUntil,
    SignedPreKeyStatus? status,
  }) {
    return SignedPreKeyRecord(
      id: id ?? this.id,
      publicKeyHex: publicKeyHex ?? this.publicKeyHex,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      retentionUntil: retentionUntil ?? this.retentionUntil,
      status: status ?? this.status,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'public_key_hex': publicKeyHex,
      'created_at': createdAt,
      'expires_at': expiresAt,
      'retention_until': retentionUntil,
      'status': status.toValueString(),
    };
  }

  factory SignedPreKeyRecord.fromMap(Map<String, dynamic> map) {
    return SignedPreKeyRecord(
      id: map['id'] as String,
      publicKeyHex: map['public_key_hex'] as String,
      createdAt: map['created_at'] as int,
      expiresAt: map['expires_at'] as int,
      retentionUntil: map['retention_until'] as int,
      status: SignedPreKeyStatusX.fromValueString(map['status'] as String),
    );
  }

  String toJson() => jsonEncode(toMap());

  factory SignedPreKeyRecord.fromJson(String source) =>
      SignedPreKeyRecord.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
