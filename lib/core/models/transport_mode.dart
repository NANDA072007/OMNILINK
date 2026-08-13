/// Enum representing active mesh transport operating modes.
enum TransportMode {
  /// Both Bluetooth & Wi-Fi Direct active for maximum throughput.
  highSpeedMesh,

  /// Bluetooth active only; Wi-Fi off. Slower text messaging fallback active.
  bluetoothOnly,

  /// Trusted paired devices radio connection mode.
  trustedPairedDevices,

  /// No active radios available. Local SQLite outbox queueing active.
  offlineQueue,
}

extension TransportModeExtension on TransportMode {
  String get displayName {
    switch (this) {
      case TransportMode.highSpeedMesh:
        return 'High-Speed Mesh (Bluetooth + Wi-Fi)';
      case TransportMode.bluetoothOnly:
        return 'Bluetooth Only Mesh (Wi-Fi Speed Booster Off)';
      case TransportMode.trustedPairedDevices:
        return 'Trusted Paired Devices Link';
      case TransportMode.offlineQueue:
        return 'Offline Queue Mode (Radios Unavailable)';
    }
  }
}
