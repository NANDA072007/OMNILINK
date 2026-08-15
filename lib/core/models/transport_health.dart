enum TransportHealthMode {
  highSpeed,
  degradedTextOnly,
  offlineQueue,
}

/// Granular Transport Health Data Model for OMNILINK.
/// Evaluates Bluetooth congestion (audio devices/headsets) and radio states
/// to select optimal transport degradation policies.
class TransportHealth {
  final bool bluetoothEnabled;
  final bool wifiEnabled;
  final bool locationEnabled;
  final bool audioDeviceConnected;
  final bool headsetConnected;
  final bool canDiscover;
  final bool canHighSpeedTransfer;
  final bool isDegraded;
  final TransportHealthMode recommendedMode;
  final String userMessage;

  const TransportHealth({
    required this.bluetoothEnabled,
    required this.wifiEnabled,
    required this.locationEnabled,
    required this.audioDeviceConnected,
    required this.headsetConnected,
    required this.canDiscover,
    required this.canHighSpeedTransfer,
    required this.isDegraded,
    required this.recommendedMode,
    required this.userMessage,
  });

  factory TransportHealth.fromMap(Map<String, dynamic> map, {required bool locationEnabled}) {
    final btEnabled = map['bluetoothEnabled'] == true;
    final wifiEnabled = map['wifiEnabled'] == true; // or passed from capability
    final audioConnected = map['audioDeviceConnected'] == true;
    final headsetConnected = map['headsetConnected'] == true;
    final canDiscover = map['locationRequiredForScan'] == true ? locationEnabled : true;

    return evaluate(
      bluetoothEnabled: btEnabled,
      wifiEnabled: wifiEnabled,
      locationEnabled: locationEnabled,
      audioDeviceConnected: audioConnected,
      headsetConnected: headsetConnected,
      canDiscover: canDiscover,
    );
  }

  static TransportHealth evaluate({
    required bool bluetoothEnabled,
    required bool wifiEnabled,
    required bool locationEnabled,
    required bool audioDeviceConnected,
    required bool headsetConnected,
    required bool canDiscover,
  }) {
    final bool isDegraded = audioDeviceConnected || (!wifiEnabled && bluetoothEnabled);
    final bool canHighSpeedTransfer = bluetoothEnabled && wifiEnabled;

    TransportHealthMode mode;
    String userMessage;

    if (!bluetoothEnabled) {
      mode = TransportHealthMode.offlineQueue;
      userMessage = 'Bluetooth is required for offline messaging.';
    } else if (bluetoothEnabled && wifiEnabled) {
      mode = TransportHealthMode.highSpeed;
      userMessage = audioDeviceConnected
          ? 'Ready for offline messaging. Bluetooth audio device connected.'
          : 'Ready for high-speed offline messaging.';
    } else if (bluetoothEnabled && !wifiEnabled && audioDeviceConnected) {
      mode = TransportHealthMode.degradedTextOnly;
      userMessage =
          'Bluetooth is busy. Delivery may be slower. Turn on Wi-Fi for better reliability.';
    } else {
      mode = TransportHealthMode.degradedTextOnly;
      userMessage = 'Ready. Turn on Wi-Fi for faster delivery.';
    }

    return TransportHealth(
      bluetoothEnabled: bluetoothEnabled,
      wifiEnabled: wifiEnabled,
      locationEnabled: locationEnabled,
      audioDeviceConnected: audioDeviceConnected,
      headsetConnected: headsetConnected,
      canDiscover: canDiscover,
      canHighSpeedTransfer: canHighSpeedTransfer,
      isDegraded: isDegraded,
      recommendedMode: mode,
      userMessage: userMessage,
    );
  }
}
