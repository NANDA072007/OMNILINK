import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:permission_handler/permission_handler.dart';

import '../../core/providers.dart';
import '../../state/models/discovery_state.dart';
import '../../state/models/radio_status_state.dart';
import '../../state/providers/discovery_state_provider.dart';
import '../../state/providers/radio_status_provider.dart';
import 'chat_screen.dart';
import '../../core/models/peer_device.dart';
import '../widgets/discovered_device_card.dart';
import '../widgets/radar_widget.dart';
import '../widgets/readiness_accordion.dart';

class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _controlChannel =
      MethodChannel('omnilink/transport/control');

  bool? _batteryOptimizationExempt;
  bool? _notificationPermissionGranted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(() async {
      await ref.read(radioStatusProvider.notifier).refreshStatus();
      await _refreshBackgroundReadiness();
    });
  }

  Future<void> _refreshBackgroundReadiness() async {
    final adapter = ref.read(androidTransportAdapterProvider);
    final exempt = await adapter.isIgnoringBatteryOptimizations();
    final notificationsGranted = await Permission.notification.isGranted;
    if (!mounted) return;
    setState(() {
      _batteryOptimizationExempt = exempt;
      _notificationPermissionGranted = notificationsGranted;
    });
  }

  Future<void> _requestBatteryExemption() async {
    final adapter = ref.read(androidTransportAdapterProvider);
    await adapter.requestIgnoreBatteryOptimizations();
    await Future.delayed(const Duration(milliseconds: 600));
    await _refreshBackgroundReadiness();
  }

  Future<void> _requestNotificationPermission() async {
    await Permission.notification.request();
    await _refreshBackgroundReadiness();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(radioStatusProvider.notifier).refreshStatus();
      _refreshBackgroundReadiness();
    }
  }

  Future<void> _toggleBluetooth() async {
    final radioState = ref.read(radioStatusProvider);

    if (!radioState.bluetoothPermissionGranted) {
      debugPrint('OMNILINK_UI: Requesting Bluetooth permissions...');
      await [
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
      ].request();
      await ref.read(radioStatusProvider.notifier).refreshStatus();
      return;
    }

    try {
      await _controlChannel.invokeMethod('requestEnableBluetooth');
      await Future.delayed(const Duration(milliseconds: 500));
      await ref.read(radioStatusProvider.notifier).refreshStatus();
    } catch (e) {
      debugPrint('OMNILINK_UI: Error toggling Bluetooth: $e');
    }
  }

  Future<void> _toggleWifi() async {
    final radioState = ref.read(radioStatusProvider);

    if (!radioState.wifiPermissionGranted) {
      debugPrint('OMNILINK_UI: Requesting Nearby Wi-Fi Devices permission...');
      await Permission.nearbyWifiDevices.request();
      await ref.read(radioStatusProvider.notifier).refreshStatus();
      return;
    }

    try {
      await _controlChannel.invokeMethod('requestToggleWifi');
      await Future.delayed(const Duration(milliseconds: 500));
      await ref.read(radioStatusProvider.notifier).refreshStatus();
    } catch (e) {
      debugPrint('OMNILINK_UI: Error toggling Wi-Fi: $e');
    }
  }

  Future<void> _toggleLocation() async {
    final radioState = ref.read(radioStatusProvider);

    if (!radioState.locationPermissionGranted) {
      debugPrint('OMNILINK_UI: Requesting Fine Location permission...');
      await Permission.location.request();
      await ref.read(radioStatusProvider.notifier).refreshStatus();
      return;
    }

    try {
      await _controlChannel.invokeMethod('requestToggleLocation');
      await Future.delayed(const Duration(milliseconds: 500));
      await ref.read(radioStatusProvider.notifier).refreshStatus();
    } catch (e) {
      debugPrint('OMNILINK_UI: Error toggling Location: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final identityState = ref.watch(identityProvider);
    final radioState = ref.watch(radioStatusProvider);
    final discoveryState = ref.watch(discoveryStateProvider);

    final nodeId = identityState.nodeId;
    final truncatedNodeId = (nodeId != null && nodeId.length >= 12)
        ? '${nodeId.substring(0, 6)}...${nodeId.substring(nodeId.length - 6)}'
        : 'OMNI-LOCAL';

    return Scaffold(
      backgroundColor: const Color(0xFF0D0E15),
      body: SafeArea(
        child: Column(
          children: [
            // =================================================================
            // 1. HEADER
            // =================================================================
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'OMNILINK',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2.0,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Nearby connections · $truncatedNodeId',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                      Icons.tune_rounded,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                    onPressed: () {
                      _showSettingsBottomSheet(context, radioState);
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // =================================================================
            // 2. RADAR VISUALIZATION (HERO AREA)
            // =================================================================
            Expanded(
              flex: 5,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    RadarWidget(
                      status: discoveryState.status,
                      peers: discoveryState.discoveredPeers,
                      connectedPeerName: discoveryState.connectedPeerName,
                      rttMs: discoveryState.pingPongRttMs,
                    ),
                    const SizedBox(height: 20),
                    // Compact Status Pill Below Radar
                    _buildStatusPill(radioState, discoveryState),
                  ],
                ),
              ),
            ),

            // =================================================================
            // 3. DISCOVERED PEERS LIST & DOMINANT ACTION BUTTON
            // =================================================================
            Expanded(
              flex: 4,
              child: Column(
                children: [
                  // Discovered Peer Cards Stream
                  if (discoveryState.discoveredPeers.isNotEmpty)
                    Expanded(
                      child: ListView.builder(
                        itemCount: discoveryState.discoveredPeers.length,
                        itemBuilder: (context, index) {
                          final peer = discoveryState.discoveredPeers[index];
                          final isConn = discoveryState.connectedPeerId ==
                              peer.endpointId;
                          final isConnState = discoveryState.status ==
                              DiscoveryStatus.connecting;

                          final activePeers = ref.watch(peerListProvider);
                          final matchingPeer = activePeers.firstWhere(
                            (p) => p.peerId == peer.endpointId || p.nodeId == peer.endpointId,
                            orElse: () => PeerDevice(
                              peerId: peer.endpointId,
                              friendlyName: peer.deviceName,
                              lastSeenAt: DateTime.now(),
                              connectionStatus: PeerConnectionStatus.discovered,
                              transportType: 'ANDROID_NEARBY',
                            ),
                          );
                          final targetChatId = (matchingPeer.nodeId != null && matchingPeer.nodeId!.isNotEmpty)
                              ? matchingPeer.nodeId!
                              : peer.endpointId;
                          final peerName = matchingPeer.friendlyName.isNotEmpty
                              ? matchingPeer.friendlyName
                              : peer.deviceName;

                          return DiscoveredDeviceCard(
                            peer: peer,
                            isConnecting: isConnState && isConn,
                            isConnected: isConn &&
                                discoveryState.status ==
                                    DiscoveryStatus.connected,
                            onConnect: () {
                              ref
                                  .read(discoveryStateProvider.notifier)
                                  .connectPeer(peer.endpointId);
                            },
                            onOpenChat: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ChatScreen(
                                    peerId: targetChatId,
                                    peerName: peerName,
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    )
                  else if (discoveryState.status == DiscoveryStatus.discovering)
                    Expanded(
                      child: Center(
                        child: Text(
                          'Searching for nearby OMNILINK devices...\nKeep discovery active on both phones',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      ),
                    )
                  else
                    const Spacer(),

                  // Readiness Accordion (Non-intrusive diagnostics)
                  ReadinessAccordion(
                    radioState: radioState,
                    onToggleBluetooth: _toggleBluetooth,
                    onToggleWifi: _toggleWifi,
                    onToggleLocation: _toggleLocation,
                  ),

                  const SizedBox(height: 12),

                  // Dominant Single Action Button
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20.0),
                    child: SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton(
                        onPressed: radioState.isReady
                            ? () {
                                ref
                                    .read(discoveryStateProvider.notifier)
                                    .toggleDiscovery();
                              }
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: discoveryState.status ==
                                  DiscoveryStatus.discovering
                              ? const Color(0xFFFF5252)
                              : const Color(0xFF00E676),
                          disabledBackgroundColor: Colors.white10,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        child: Text(
                          discoveryState.status == DiscoveryStatus.discovering
                              ? 'STOP DISCOVERY'
                              : 'START DISCOVERY',
                          style: TextStyle(
                            color: radioState.isReady
                                ? Colors.black
                                : Colors.white38,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusPill(
    RadioStatusState radioState,
    DiscoveryState discoveryState,
  ) {
    final String label;
    final Color color;

    if (discoveryState.status == DiscoveryStatus.connected) {
      final rttText = discoveryState.pingPongRttMs != null
          ? '${discoveryState.pingPongRttMs} ms'
          : 'Measuring...';
      label =
          'CONNECTED · ${discoveryState.connectedPeerName ?? "PEER"} ($rttText)';
      color = const Color(0xFF00E676);
    } else if (discoveryState.status == DiscoveryStatus.connecting) {
      label = 'CONNECTING TO PEER...';
      color = const Color(0xFF29B6F6);
    } else if (discoveryState.status == DiscoveryStatus.discovering) {
      label = 'SEARCHING NEARBY';
      color = const Color(0xFF00E676);
    } else if (!radioState.isReady) {
      label = 'DISCOVERY UNAVAILABLE';
      color = const Color(0xFFFF5252);
    } else {
      label = 'READY TO DISCOVER';
      color = const Color(0xFF00E676);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  void _showSettingsBottomSheet(
      BuildContext context, RadioStatusState radioState) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141622),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'OMNILINK Transport Diagnostics',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.bluetooth, color: Colors.white70),
                title: const Text('Bluetooth Adapter',
                    style: TextStyle(color: Colors.white)),
                subtitle: Text(
                  radioState.bluetoothEnabled ? 'Enabled' : 'Disabled',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: TextButton(
                  onPressed: _toggleBluetooth,
                  child: const Text('Toggle'),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.wifi, color: Colors.white70),
                title: const Text('Wi-Fi High Speed Link',
                    style: TextStyle(color: Colors.white)),
                subtitle: Text(
                  radioState.wifiEnabled ? 'Enabled' : 'Disabled',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: TextButton(
                  onPressed: _toggleWifi,
                  child: const Text('Toggle'),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.battery_saver, color: Colors.white70),
                title: const Text('Background Reliability',
                    style: TextStyle(color: Colors.white)),
                subtitle: Text(
                  _batteryOptimizationExempt == true
                      ? 'Battery optimization exempt'
                      : 'Battery optimization may pause the mesh',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: TextButton(
                  onPressed: _batteryOptimizationExempt == true
                      ? null
                      : _requestBatteryExemption,
                  child: Text(
                    _batteryOptimizationExempt == true ? 'Ready' : 'Allow',
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.notifications_active,
                    color: Colors.white70),
                title: const Text('Message Notifications',
                    style: TextStyle(color: Colors.white)),
                subtitle: Text(
                  _notificationPermissionGranted == true
                      ? 'Enabled'
                      : 'Disabled - incoming messages stay silent',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: TextButton(
                  onPressed: _notificationPermissionGranted == true
                      ? null
                      : _requestNotificationPermission,
                  child: Text(
                    _notificationPermissionGranted == true ? 'Ready' : 'Enable',
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
