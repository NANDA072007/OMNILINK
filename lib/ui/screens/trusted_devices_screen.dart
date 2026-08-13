import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/peer_device.dart';
import '../../core/providers.dart';
import '../../transport_bridge/android_transport_adapter.dart';
import 'chat_screen.dart';

/// Trusted Devices Screen allowing location-free, Wi-Fi-free direct messaging over Bluetooth RFCOMM stream sockets.
class TrustedDevicesScreen extends ConsumerStatefulWidget {
  const TrustedDevicesScreen({super.key});

  @override
  ConsumerState<TrustedDevicesScreen> createState() => _TrustedDevicesScreenState();
}

class _TrustedDevicesScreenState extends ConsumerState<TrustedDevicesScreen> {
  List<Map<String, dynamic>> _bondedDevices = [];
  bool _isLoading = true;
  bool _isServerRunning = false;
  final Set<String> _connectedMacs = {};

  @override
  void initState() {
    super.initState();
    _loadBondedDevices();
    _startServer();
  }

  Future<void> _startServer() async {
    final adapter = ref.read(transportAdapterProvider);
    if (adapter is AndroidTransportAdapter) {
      final started = await adapter.startRfcommServer();
      if (mounted) {
        setState(() {
          _isServerRunning = started;
        });
      }
    }
  }

  Future<void> _loadBondedDevices() async {
    setState(() => _isLoading = true);
    final adapter = ref.read(transportAdapterProvider);
    if (adapter is AndroidTransportAdapter) {
      final devices = await adapter.getBondedBluetoothDevices();
      if (mounted) {
        setState(() {
          _bondedDevices = devices;
          _isLoading = false;
        });
      }
    } else {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _connectToDevice(String address, String name) async {
    final adapter = ref.read(transportAdapterProvider);
    if (adapter is AndroidTransportAdapter) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connecting to $name ($address)...')),
      );

      final success = await adapter.connectRfcommDevice(address);
      if (!mounted) return;

      if (success) {
        setState(() {
          _connectedMacs.add(address);
        });

        // Save RFCOMM peer to SQLite database
        final peerRepo = ref.read(peerRepositoryProvider);
        final peerDevice = PeerDevice(
          peerId: address,
          friendlyName: name,
          lastSeenAt: DateTime.now(),
          transportType: 'Bluetooth-RFCOMM',
          connectionStatus: PeerConnectionStatus.connected,
        );
        await peerRepo.savePeer(peerDevice);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF00E676),
            content: Text('Connected to $name via RFCOMM! Opening chat...'),
          ),
        );

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              peerId: address,
              peerName: name,
            ),
          ),
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red,
            content: Text('Failed to connect to $name over RFCOMM socket.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trusted Paired Bluetooth Devices'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh Bonded Devices',
            onPressed: _loadBondedDevices,
          ),
        ],
      ),
      body: Column(
        children: [
          // Bluetooth RFCOMM Server Status Bar
          Container(
            color: _isServerRunning
                ? const Color(0xFF00E676).withAlpha(35)
                : Colors.amber.withAlpha(35),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  _isServerRunning
                      ? Icons.bluetooth_searching_rounded
                      : Icons.bluetooth_disabled_rounded,
                  color: _isServerRunning ? const Color(0xFF00E676) : Colors.amber,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isServerRunning
                            ? 'RFCOMM MESH SERVER ACTIVE'
                            : 'RFCOMM SERVER INACTIVE',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: _isServerRunning ? const Color(0xFF00E676) : Colors.amber,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Location-free direct Bluetooth sockets for paired system devices.',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isServerRunning ? Colors.red.shade900 : const Color(0xFF00E676),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    final adapter = ref.read(transportAdapterProvider);
                    if (adapter is AndroidTransportAdapter) {
                      if (_isServerRunning) {
                        await adapter.stopRfcommServer();
                        setState(() => _isServerRunning = false);
                      } else {
                        await _startServer();
                      }
                    }
                  },
                  child: Text(_isServerRunning ? 'Stop' : 'Start'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF00E676)))
                : _bondedDevices.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.bluetooth_disabled_rounded, size: 64, color: Colors.grey.shade700),
                            const SizedBox(height: 16),
                            const Text('No paired Bluetooth devices found.', style: TextStyle(fontSize: 16, color: Colors.grey)),
                            const SizedBox(height: 8),
                            const Text('Pair your devices in Android Bluetooth Settings first.', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _bondedDevices.length,
                        itemBuilder: (context, index) {
                          final dev = _bondedDevices[index];
                          final name = dev['deviceName'] as String? ?? 'Unknown Device';
                          final address = dev['deviceAddress'] as String? ?? '';
                          final isConnected = _connectedMacs.contains(address);

                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: isConnected
                                    ? const Color(0xFF00E676).withAlpha(51)
                                    : const Color(0xFF2C2C2C),
                                child: Icon(
                                  Icons.bluetooth_connected_rounded,
                                  color: isConnected ? const Color(0xFF00E676) : Colors.grey,
                                ),
                              ),
                              title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text('MAC: $address\n${isConnected ? "Connected • RFCOMM Socket" : "Paired Device"}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                              isThreeLine: true,
                              trailing: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: isConnected ? const Color(0xFF00E676) : const Color(0xFF2C2C2C),
                                  foregroundColor: isConnected ? Colors.black : Colors.white,
                                ),
                                icon: Icon(isConnected ? Icons.chat_rounded : Icons.link_rounded, size: 16),
                                label: Text(isConnected ? 'Chat' : 'Connect'),
                                onPressed: () {
                                  if (isConnected) {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ChatScreen(peerId: address, peerName: name),
                                      ),
                                    );
                                  } else {
                                    _connectToDevice(address, name);
                                  }
                                },
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
