import 'transport_mode.dart';

/// Transport capability model reporting granular hardware radio & permission state.
class TransportCapability {
  final bool bluetoothEnabled;
  final bool wifiEnabled;
  final bool locationEnabled;
  final int androidSdkInt;
  final bool nearbyPlayServicesAvailable;
  final bool canDiscoverNewPeers;
  final bool canUseHighBandwidth;
  final bool canUseBluetoothOnlyFallback;
  final List<String> requiredMissing;
  final List<String> optionalBoostersMissing;

  const TransportCapability({
    required this.bluetoothEnabled,
    required this.wifiEnabled,
    required this.locationEnabled,
    required this.androidSdkInt,
    required this.nearbyPlayServicesAvailable,
    required this.canDiscoverNewPeers,
    required this.canUseHighBandwidth,
    required this.canUseBluetoothOnlyFallback,
    required this.requiredMissing,
    required this.optionalBoostersMissing,
  });

  /// Factory constructor parsing raw dictionary map from native Android platform channel.
  factory TransportCapability.fromMap(Map<String, dynamic> map) {
    final bt = map['bluetoothEnabled'] as bool? ?? false;
    final wifi = map['wifiEnabled'] as bool? ?? false;
    final loc = map['locationEnabled'] as bool? ?? false;
    final sdk = map['androidSdkInt'] as int? ?? 33;
    final gms = map['nearbyPlayServicesAvailable'] as bool? ?? true;

    final reqMissing = <String>[];
    if (!bt) reqMissing.add('Bluetooth');

    final optMissing = <String>[];
    if (!wifi) optMissing.add('Wi-Fi Speed Booster');

    // Location is only required on Android 11 (SDK <= 30/31) for discovery
    if (sdk <= 31 && !loc) {
      reqMissing.add('Location (Android 11 requirement)');
    }

    final canDiscover = bt && (sdk > 31 || loc);

    return TransportCapability(
      bluetoothEnabled: bt,
      wifiEnabled: wifi,
      locationEnabled: loc,
      androidSdkInt: sdk,
      nearbyPlayServicesAvailable: gms,
      canDiscoverNewPeers: canDiscover,
      canUseHighBandwidth: wifi,
      canUseBluetoothOnlyFallback: bt,
      requiredMissing: reqMissing,
      optionalBoostersMissing: optMissing,
    );
  }

  /// Determines the active operating transport mode based on available radios.
  TransportMode selectTransportMode() {
    if (bluetoothEnabled && wifiEnabled) {
      return TransportMode.highSpeedMesh;
    } else if (bluetoothEnabled) {
      return TransportMode.bluetoothOnly;
    } else {
      return TransportMode.offlineQueue;
    }
  }
}
