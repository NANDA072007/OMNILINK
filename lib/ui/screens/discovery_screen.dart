import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/models/peer_device.dart';
import '../../core/providers.dart';
import '../../transport_bridge/android_transport_adapter.dart';
import 'chat_screen.dart';

/// Temporary diagnostic data from the native [AndroidTransportAdapter] probe.
class PermDiagnostics {
  final int sdkInt;
  final String versionName;
  final int? versionCode;
  final Map<String, bool> permissionGranted;
  final bool playServicesAvailable;
  final int playServicesStatusCode;
  final bool playServicesUserResolvable;
  final bool? bluetoothEnabled;
  final bool? wifiEnabled;
  final bool? locationEnabled;

  const PermDiagnostics({
    required this.sdkInt,
    required this.versionName,
    this.versionCode,
    required this.permissionGranted,
    required this.playServicesAvailable,
    required this.playServicesStatusCode,
    required this.playServicesUserResolvable,
    this.bluetoothEnabled,
    this.wifiEnabled,
    this.locationEnabled,
  });
}

class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  bool _isDiscovering = false;
  bool _permissionDialogObserved = false;
  PermDiagnostics? _diag;
  String _lastRequestSummary = 'not requested yet';

  static const MethodChannel _controlChannel =
      MethodChannel('omnilink/transport/control');

  @override
  void initState() {
    super.initState();
    _refreshNativeDiagnostics();
  }

  Future<void> _toggleDiscovery() async {
    final adapter = ref.read(transportAdapterProvider);
    if (_isDiscovering) {
      final ok = await adapter.stopDiscovery();
      debugPrint('OMNILINK_PERM: stopDiscovery -> $ok');
      setState(() {
        _isDiscovering = false;
      });
    } else {
      final granted = await _requestPermissionsWithLogs();
      await _refreshNativeDiagnostics();

      if (!granted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_lastRequestSummary),
            action: SnackBarAction(
              label: 'Open Settings',
              onPressed: openAppSettings,
            ),
          ),
        );
        return;
      }
      final ok = await adapter.startDiscovery();
      debugPrint('OMNILINK_PERM: startDiscovery -> $ok');
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Discovery failed to start. Check Bluetooth/Location are ON.',
              ),
            ),
          );
        }
        return;
      }
      setState(() {
        _isDiscovering = true;
      });
    }
  }

  /// Requests Android runtime permissions with per-permission result logging.
  ///
  /// Log tags:
  /// - OMNILINK_PERM: Requesting permissions (entry)
  /// - OMNILINK_PERM: <permission> -> <status>   (per result)
  /// - OMNILINK_PERM: allRequiredPermissionsGranted -> <bool>
  ///
  /// Android version branching matches the docs:
  /// - Android 12+ (API 31): Bluetooth + Location
  /// - Android 11 and below (API < 31): Location only (BT is install-time)
  Future<bool> _requestPermissionsWithLogs() async {
    try {
      debugPrint('OMNILINK_PERM: Requesting permissions');
      final sdkInt = _diag?.sdkInt ?? _readSdkFromPlatformVersion();
      debugPrint('OMNILINK_PERM: detected Android SDK = $sdkInt');

      final permissions = <Permission>[
        if (sdkInt >= 31) ...[
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetoothAdvertise,
        ],
        if (sdkInt >= 33) Permission.nearbyWifiDevices,
        Permission.locationWhenInUse,
      ];

      var allGranted = true;

      for (final permission in permissions) {
        final status = await permission.request();
        debugPrint('OMNILINK_PERM: ${permission.toString()} -> $status');
        if (!status.isGranted && !status.isRestricted) {
          allGranted = false;
        }
      }

      _permissionDialogObserved = allGranted;
      _lastRequestSummary = allGranted
          ? 'All required permissions granted. Starting discovery.'
          : 'Bluetooth and Location permissions are required for offline peer discovery.';
      debugPrint('OMNILINK_PERM: allRequiredPermissionsGranted -> $allGranted');
      return allGranted;
    } catch (e, s) {
      debugPrint('OMNILINK_PERM: EXCEPTION in request flow: $e\n$s');
      _lastRequestSummary = 'Permission request failed: $e';
      return false;
    }
  }

  int _readSdkFromPlatformVersion() {
    try {
      final version = Platform.version;
      final apiMatch = RegExp(r'\(API (\d+)\)').firstMatch(version);
      if (apiMatch != null) return int.parse(apiMatch.group(1)!);
      final parts = version.split('.');
      if (parts.isNotEmpty) return int.tryParse(parts.first) ?? 0;
    } catch (_) {}
    return 0;
  }

  /// Requests the 4 permissions directly, independent of discovery, so we can
  /// test whether the system dialog can appear at all.
  Future<void> _requestPermissionsStandalone() async {
    final granted = await _requestPermissionsWithLogs();
    await _refreshNativeDiagnostics();
    if (!mounted) return;
    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_lastRequestSummary),
          action: SnackBarAction(label: 'Open Settings', onPressed: openAppSettings),
        ),
      );
    }
    setState(() {});
  }

  Future<void> _openAppSettings() async {
    await openAppSettings();
    await _refreshNativeDiagnostics();
    if (mounted) setState(() {});
  }

  Future<void> _refreshNativeDiagnostics() async {
    try {
      final details =
          await _controlChannel.invokeMapMethod<Object?, Object?>(
        'getAndroidPermissionDetails',
      );
      if (details == null) return;
      final granted = <String, bool>{};
      for (final key in details.keys) {
        if (key.toString().endsWith('Granted') && details[key] is bool) {
          granted[key.toString()] = details[key] as bool;
        }
      }
      setState(() {
        _diag = PermDiagnostics(
          sdkInt: (details['sdkInt'] as num?)?.toInt() ?? 0,
          versionName: details['versionName']?.toString() ?? '?',
          versionCode: (details['versionCode'] as num?)?.toInt(),
          permissionGranted: granted,
          playServicesAvailable: details['playServicesAvailable'] as bool? ?? false,
          playServicesStatusCode:
              (details['playServicesStatusCode'] as num?)?.toInt() ?? -1,
          playServicesUserResolvable:
              details['playServicesUserResolvable'] as bool? ?? false,
          bluetoothEnabled: details['bluetoothEnabled'] as bool?,
          wifiEnabled: details['wifiEnabled'] as bool?,
          locationEnabled: details['locationEnabled'] as bool?,
        );
      });
    } on MissingPluginException catch (e) {
      debugPrint('OMNILINK_PERM: native diagnostics probe missing: $e');
    } catch (e) {
      debugPrint('OMNILINK_PERM: native diagnostics probe failed: $e');
    }
  }

  /// [TEMPORARY] Diagnostic card for permission/discovery debugging.
  /// Shows device environment + permission state + direct action buttons.
  /// Remove once discovery is verified on physical hardware.
  Widget _buildDebugCard(dynamic adapter) {
    final diag = _diag;
    final adapterType = adapter.runtimeType.toString();

    String boolLabel(bool? b) => b == null ? '? (no data)' : (b ? 'ON' : 'OFF');

    return Container(
      color: const Color(0xFF202020),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bug_report_rounded,
                  size: 16, color: Colors.orangeAccent),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'DIAGNOSTICS (temporary)',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.orangeAccent,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Text(
                'Adapter: $adapterType',
                style: const TextStyle(fontSize: 10, color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: [
              _diagLine('SDK', diag?.sdkInt.toString() ?? '?'),
              _diagLine('App', diag?.versionName ?? '?'),
              _diagLine('GMS', diag == null ? '?' : (diag.playServicesAvailable ? 'OK' : 'MISSING')),
              _diagLine('BT', boolLabel(diag?.bluetoothEnabled)),
              _diagLine('Wi-Fi', boolLabel(diag?.wifiEnabled)),
              _diagLine('Location', boolLabel(diag?.locationEnabled)),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [
              _permChip('BT_SCAN', diag?.permissionGranted['bluetoothScanGranted']),
              _permChip('BT_CONNECT', diag?.permissionGranted['bluetoothConnectGranted']),
              _permChip('BT_ADVERTISE', diag?.permissionGranted['bluetoothAdvertiseGranted']),
              _permChip('FINE_LOC', diag?.permissionGranted['fineLocationGranted']),
              _permChip('NEARBY_WIFI', diag?.permissionGranted['nearbyWifiDevicesGranted']),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Last request: $_lastRequestSummary',
            style: const TextStyle(fontSize: 10, color: Colors.white54),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.orangeAccent,
                  side: const BorderSide(color: Colors.orangeAccent, width: 1),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                ),
                onPressed: _requestPermissionsStandalone,
                icon: const Icon(Icons.touch_app_rounded, size: 14),
                label: const Text('Request Permissions', style: TextStyle(fontSize: 11)),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.lightBlueAccent,
                  side: const BorderSide(color: Colors.lightBlueAccent, width: 1),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                ),
                onPressed: _openAppSettings,
                icon: const Icon(Icons.settings_rounded, size: 14),
                label: const Text('Open App Settings', style: TextStyle(fontSize: 11)),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Colors.white70, width: 1),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                ),
                onPressed: () {
                  _refreshNativeDiagnostics();
                  setState(() {});
                },
                icon: const Icon(Icons.refresh_rounded, size: 14),
                label: const Text('Refresh', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _diagLine(String label, String value) {
    return Text(
      '$label: $value',
      style: const TextStyle(fontSize: 11, color: Colors.white70),
    );
  }

  Widget _permChip(String label, bool? granted) {
    final color = granted == null
        ? Colors.grey
        : (granted ? const Color(0xFF00E676) : Colors.redAccent);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$label: ${granted == null ? '?' : (granted ? 'granted' : 'denied')}',
        style: TextStyle(fontSize: 9, color: color),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final identityState = ref.watch(identityProvider);
    final peerList = ref.watch(peerListProvider);
    final adapter = ref.watch(transportAdapterProvider);

    final nodeId = identityState.nodeId;
    final truncatedNodeId = (nodeId != null && nodeId.length >= 12)
        ? '${nodeId.substring(0, 6)}...${nodeId.substring(nodeId.length - 6)}'
        : 'Generating Identity...';

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.radar_rounded, color: Color(0xFF00E676)),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('OMNILINK Mesh'),
                if (identityState.isLoading)
                  const Text(
                    'Generating Keypair...',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  )
                else
                  Text(
                    'ID: $truncatedNodeId',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF00E676),
                      fontFamily: 'monospace',
                    ),
                  ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _isDiscovering ? Icons.sensors_rounded : Icons.sensors_off_rounded,
              color: _isDiscovering ? const Color(0xFF00E676) : Colors.grey,
            ),
            tooltip: _isDiscovering ? 'Discovery Active' : 'Discovery Stopped',
            onPressed: _toggleDiscovery,
          ),
        ],
      ),
      body: identityState.isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFF00E676)),
                  SizedBox(height: 16),
                  Text('Generating Master Ed25519 Identity...'),
                ],
              ),
            )
          : Column(
              children: [
                // Status Header Banner
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  color: const Color(0xFF161616),
                  child: Row(
                    children: [
                      Icon(
                        _isDiscovering
                            ? Icons.wifi_tethering_rounded
                            : Icons.wifi_tethering_off_rounded,
                        size: 20,
                        color: _isDiscovering ? const Color(0xFF00E676) : Colors.grey,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _isDiscovering
                              ? 'Scanning physical radios for nearby devices...'
                              : 'Discovery stopped. Tap radar button to scan.',
                          style: TextStyle(
                            fontSize: 13,
                            color: _isDiscovering ? Colors.white : Colors.grey,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _buildDebugCard(adapter),
                Expanded(
                  child: peerList.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.devices_other_rounded,
                                size: 64,
                                color: Colors.grey.shade700,
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'No nearby devices found yet.',
                                style: TextStyle(fontSize: 16, color: Colors.grey),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Tap the floating radar button below to start discovery.',
                                style: TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: peerList.length,
                          itemBuilder: (context, index) {
                            final peer = peerList[index];
                            final isConnected =
                                peer.connectionStatus == PeerConnectionStatus.connected;

                            return Card(
                              margin: const EdgeInsets.only(bottom: 10),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 6,
                                ),
                                leading: CircleAvatar(
                                  backgroundColor: isConnected
                                      ? const Color(0xFF00E676).withAlpha(51)
                                      : const Color(0xFF2C2C2C),
                                  child: Icon(
                                    Icons.phone_android_rounded,
                                    color: isConnected
                                        ? const Color(0xFF00E676)
                                        : Colors.grey,
                                  ),
                                ),
                                title: Text(
                                  peer.friendlyName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(
                                  'ID: ${peer.peerId} • RSSI: ${peer.rssi ?? -50} dBm',
                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                ),
                                trailing: isConnected
                                    ? Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00E676).withAlpha(38),
                                          borderRadius: BorderRadius.circular(16),
                                          border: Border.all(
                                            color: const Color(0xFF00E676),
                                            width: 1,
                                          ),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.circle,
                                              size: 8,
                                              color: Color(0xFF00E676),
                                            ),
                                            SizedBox(width: 6),
                                            Text(
                                              'Connected',
                                              style: TextStyle(
                                                color: Color(0xFF00E676),
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    : ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF00E676),
                                          foregroundColor: Colors.black,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                          ),
                                        ),
                                        onPressed: () {
                                          adapter.connectPeer(peer.peerId);
                                        },
                                        child: const Text('Connect'),
                                      ),
                                onTap: isConnected
                                    ? () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => ChatScreen(
                                              peerId: peer.peerId,
                                              peerName: peer.friendlyName,
                                            ),
                                          ),
                                        );
                                      }
                                    : null,
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF00E676),
        foregroundColor: Colors.black,
        icon: Icon(_isDiscovering ? Icons.stop_rounded : Icons.radar_rounded),
        label: Text(_isDiscovering ? 'Stop Discovery' : 'Start Discovery'),
        onPressed: _toggleDiscovery,
      ),
    );
  }
}
