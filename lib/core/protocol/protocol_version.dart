import 'dart:convert';

/// Versioning specification for the OMNILINK wire protocol.
/// Used to detect protocol version drift between meshed devices.
class ProtocolVersion {
  static const int currentVersion = 1;
  static const int minSupportedVersion = 1;

  final int version;

  const ProtocolVersion([this.version = currentVersion]);

  /// Checks if a remote peer's protocol version is compatible with this node.
  bool get isSupported => version >= minSupportedVersion && version <= currentVersion;

  static bool isSupportedVersion(int remoteVersion) {
    return remoteVersion >= minSupportedVersion && remoteVersion <= currentVersion;
  }

  Map<String, dynamic> toMap() {
    return {
      'version': version,
      'min_supported_version': minSupportedVersion,
      'current_version': currentVersion,
    };
  }

  factory ProtocolVersion.fromMap(Map<String, dynamic> map) {
    return ProtocolVersion(
      (map['version'] as num?)?.toInt() ?? currentVersion,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory ProtocolVersion.fromJson(String source) =>
      ProtocolVersion.fromMap(jsonDecode(source) as Map<String, dynamic>);

  @override
  String toString() => 'ProtocolVersion($version, supported: $isSupported)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ProtocolVersion && other.version == version);

  @override
  int get hashCode => version.hashCode;
}
