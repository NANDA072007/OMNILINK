import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/peer_device.dart';
import '../../core/providers.dart';
import 'chat_screen.dart';

class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  bool _isDiscovering = false;

  Future<void> _toggleDiscovery() async {
    final adapter = ref.read(transportAdapterProvider);
    if (_isDiscovering) {
      await adapter.stopDiscovery();
      setState(() {
        _isDiscovering = false;
      });
    } else {
      await adapter.startDiscovery();
      setState(() {
        _isDiscovering = true;
      });
    }
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
