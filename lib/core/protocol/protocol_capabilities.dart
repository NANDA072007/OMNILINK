import 'dart:convert';

/// Represents feature capability flags supported by an OMNILINK node.
/// Exchanged during handshake to determine feature negotiation boundaries.
class ProtocolCapabilities {
  final bool supportsSyncPagination;
  final bool supportsLargePayloadChunking;
  final bool supportsLinkHealthMetrics;
  final bool supportsSafetyNumberVerification;

  const ProtocolCapabilities({
    this.supportsSyncPagination = false,
    this.supportsLargePayloadChunking = false,
    this.supportsLinkHealthMetrics = false,
    this.supportsSafetyNumberVerification = false,
  });

  /// Standard baseline capabilities for current release.
  static const ProtocolCapabilities defaultCapabilities = ProtocolCapabilities(
    supportsSyncPagination: true,
    supportsLargePayloadChunking: false,
    supportsLinkHealthMetrics: true,
    supportsSafetyNumberVerification: false,
  );

  Map<String, dynamic> toMap() {
    return {
      'supports_sync_pagination': supportsSyncPagination,
      'supports_large_payload_chunking': supportsLargePayloadChunking,
      'supports_link_health_metrics': supportsLinkHealthMetrics,
      'supports_safety_number_verification': supportsSafetyNumberVerification,
    };
  }

  factory ProtocolCapabilities.fromMap(Map<String, dynamic> map) {
    return ProtocolCapabilities(
      supportsSyncPagination: map['supports_sync_pagination'] == true,
      supportsLargePayloadChunking: map['supports_large_payload_chunking'] == true,
      supportsLinkHealthMetrics: map['supports_link_health_metrics'] == true,
      supportsSafetyNumberVerification: map['supports_safety_number_verification'] == true,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory ProtocolCapabilities.fromJson(String source) =>
      ProtocolCapabilities.fromMap(jsonDecode(source) as Map<String, dynamic>);

  ProtocolCapabilities copyWith({
    bool? supportsSyncPagination,
    bool? supportsLargePayloadChunking,
    bool? supportsLinkHealthMetrics,
    bool? supportsSafetyNumberVerification,
  }) {
    return ProtocolCapabilities(
      supportsSyncPagination: supportsSyncPagination ?? this.supportsSyncPagination,
      supportsLargePayloadChunking: supportsLargePayloadChunking ?? this.supportsLargePayloadChunking,
      supportsLinkHealthMetrics: supportsLinkHealthMetrics ?? this.supportsLinkHealthMetrics,
      supportsSafetyNumberVerification: supportsSafetyNumberVerification ?? this.supportsSafetyNumberVerification,
    );
  }

  @override
  String toString() {
    return 'ProtocolCapabilities(syncPagination: $supportsSyncPagination, chunking: $supportsLargePayloadChunking, linkHealth: $supportsLinkHealthMetrics, safetyNumber: $supportsSafetyNumberVerification)';
  }
}
