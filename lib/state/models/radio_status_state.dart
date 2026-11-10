enum RadioCapabilityStatus {
  unknown,
  checking,
  ready,
  disabled,
  permissionRequired,
  unsupported,
  error,
}

/// Structured hardware, service, and permission readiness state for OMNILINK.
class RadioStatusState {
  final RadioCapabilityStatus bluetoothStatus;
  final RadioCapabilityStatus wifiStatus;
  final RadioCapabilityStatus locationStatus;
  final bool bluetoothSupported;
  final bool bluetoothEnabled;
  final bool wifiSupported;
  final bool wifiEnabled;
  final bool locationSupported;
  final bool locationServiceEnabled;
  final bool bluetoothPermissionGranted;
  final bool wifiPermissionGranted;
  final bool locationPermissionGranted;

  const RadioStatusState({
    this.bluetoothStatus = RadioCapabilityStatus.unknown,
    this.wifiStatus = RadioCapabilityStatus.unknown,
    this.locationStatus = RadioCapabilityStatus.unknown,
    this.bluetoothSupported = true,
    this.bluetoothEnabled = false,
    this.wifiSupported = true,
    this.wifiEnabled = false,
    this.locationSupported = true,
    this.locationServiceEnabled = false,
    this.bluetoothPermissionGranted = false,
    this.wifiPermissionGranted = false,
    this.locationPermissionGranted = false,
  });

  bool get isReady =>
      bluetoothStatus == RadioCapabilityStatus.ready &&
      bluetoothPermissionGranted;

  bool get locationEnabled => locationServiceEnabled;

  factory RadioStatusState.fromMap(Map<String, dynamic> map) {
    final sdkInt = (map['sdkInt'] as num?)?.toInt() ?? 34;

    // 1. Bluetooth State Evaluation
    final btConnect = map['bluetoothConnectGranted'] == true;
    final btScan = map['bluetoothScanGranted'] == true;
    final btPerm = sdkInt < 31 || (btConnect && btScan);
    final btSupp = map['bluetoothSupported'] == true;
    final btEnabled = map['bluetoothEnabled'] == true;

    final RadioCapabilityStatus btStatus;
    if (!btSupp) {
      btStatus = RadioCapabilityStatus.unsupported;
    } else if (!btPerm) {
      btStatus = RadioCapabilityStatus.permissionRequired;
    } else if (!btEnabled) {
      btStatus = RadioCapabilityStatus.disabled;
    } else {
      btStatus = RadioCapabilityStatus.ready;
    }

    // 2. Wi-Fi State Evaluation
    final wifiNearby = map['nearbyWifiDevicesGranted'] == true;
    final wifiPerm = sdkInt < 33 || wifiNearby;
    final wifiSupp = map['wifiSupported'] == true;
    final wifiEnabled = map['wifiEnabled'] == true;

    final RadioCapabilityStatus wifiStatus;
    if (!wifiSupp) {
      wifiStatus = RadioCapabilityStatus.unsupported;
    } else if (!wifiPerm) {
      wifiStatus = RadioCapabilityStatus.permissionRequired;
    } else if (!wifiEnabled) {
      wifiStatus = RadioCapabilityStatus.disabled;
    } else {
      wifiStatus = RadioCapabilityStatus.ready;
    }

    // 3. Location State Evaluation
    final fineLoc = map['fineLocationGranted'] == true;
    final locSupp = map['locationSupported'] == true;
    final locServiceEnabled = map['locationServiceEnabled'] == true ||
        map['locationEnabled'] == true;

    final RadioCapabilityStatus locStatus;
    if (!locSupp) {
      locStatus = RadioCapabilityStatus.unsupported;
    } else if (!fineLoc) {
      locStatus = RadioCapabilityStatus.permissionRequired;
    } else if (!locServiceEnabled) {
      locStatus = RadioCapabilityStatus.disabled;
    } else {
      locStatus = RadioCapabilityStatus.ready;
    }

    return RadioStatusState(
      bluetoothStatus: btStatus,
      wifiStatus: wifiStatus,
      locationStatus: locStatus,
      bluetoothSupported: btSupp,
      bluetoothEnabled: btEnabled,
      wifiSupported: wifiSupp,
      wifiEnabled: wifiEnabled,
      locationSupported: locSupp,
      locationServiceEnabled: locServiceEnabled,
      bluetoothPermissionGranted: btPerm,
      wifiPermissionGranted: wifiPerm,
      locationPermissionGranted: fineLoc,
    );
  }
}
