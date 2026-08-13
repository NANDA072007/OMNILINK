import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/peer_device.dart';
import '../../core/providers.dart';
import 'chat_screen.dart';
import 'discovery_screen.dart';
import 'trusted_devices_screen.dart';

/// Contacts & Conversations Screen allowing offline and multi-hop messaging.
///
/// Decouples UI thread navigation from direct radio link state: users can tap
/// any contact (online or offline) to view history and queue encrypted messages.
class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  List<PeerDevice> _savedPeers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadContactsFromDb();
  }

  Future<void> _loadContactsFromDb() async {
    final peerRepo = ref.read(peerRepositoryProvider);
    final peers = await peerRepo.getAllPeers();
    if (mounted) {
      setState(() {
        _savedPeers = peers;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final identityState = ref.watch(identityProvider);
    final activePeerList = ref.watch(peerListProvider);

    final nodeId = identityState.nodeId;
    final truncatedNodeId = (nodeId != null && nodeId.length >= 12)
        ? '${nodeId.substring(0, 6)}...${nodeId.substring(nodeId.length - 6)}'
        : 'Generating Identity...';

    // Merge saved database peers with active live discovered peers
    final Map<String, PeerDevice> mergedContacts = {};

    for (final saved in _savedPeers) {
      mergedContacts[saved.peerId] = saved;
    }

    for (final active in activePeerList) {
      mergedContacts[active.peerId] = active;
    }

    final contactsList = mergedContacts.values.toList();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.forum_rounded, color: Color(0xFF00E676)),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('OMNILINK Contacts'),
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
            icon: const Icon(Icons.bluetooth_connected_rounded, color: Color(0xFF00E676)),
            tooltip: 'Trusted Paired Devices',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TrustedDevicesScreen()),
              ).then((_) => _loadContactsFromDb());
            },
          ),
          IconButton(
            icon: const Icon(Icons.radar_rounded, color: Color(0xFF00E676)),
            tooltip: 'Radar Discovery Scanner',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DiscoveryScreen()),
              ).then((_) => _loadContactsFromDb());
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh Contacts',
            onPressed: _loadContactsFromDb,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF00E676)),
            )
          : contactsList.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.person_off_rounded,
                        size: 64,
                        color: Colors.grey.shade700,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'No contacts found in mesh network.',
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Tap the radar scanner button above to discover nearby peers.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00E676),
                          foregroundColor: Colors.black,
                        ),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const DiscoveryScreen()),
                          ).then((_) => _loadContactsFromDb());
                        },
                        icon: const Icon(Icons.radar_rounded),
                        label: const Text('Open Radar Scanner'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  color: const Color(0xFF00E676),
                  onRefresh: _loadContactsFromDb,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: contactsList.length,
                    itemBuilder: (context, index) {
                      final peer = contactsList[index];

                      // Check if peer is directly connected right now
                      final isDirectlyConnected = activePeerList.any(
                        (p) =>
                            p.peerId == peer.peerId &&
                            p.connectionStatus == PeerConnectionStatus.connected,
                      );

                      final statusColor = isDirectlyConnected
                          ? const Color(0xFF00E676) // Green: Directly connected
                          : Colors.amber; // Yellow: Offline / Multi-hop mesh

                      final statusText = isDirectlyConnected
                          ? 'Online • Direct Radio Link'
                          : 'Offline • Store & Forward Mesh';

                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          leading: Stack(
                            children: [
                              CircleAvatar(
                                backgroundColor: isDirectlyConnected
                                    ? const Color(0xFF00E676).withAlpha(51)
                                    : const Color(0xFF2C2C2C),
                                child: Icon(
                                  Icons.person_rounded,
                                  color: isDirectlyConnected
                                      ? const Color(0xFF00E676)
                                      : Colors.grey,
                                ),
                              ),
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: statusColor,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Theme.of(context).cardColor,
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          title: Text(
                            peer.friendlyName,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            'ID: ${peer.peerId}\n$statusText',
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          isThreeLine: true,
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            color: Colors.grey,
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatScreen(
                                  peerId: peer.peerId,
                                  peerName: peer.friendlyName,
                                ),
                              ),
                            ).then((_) => _loadContactsFromDb());
                          },
                        ),
                      );
                    },
                  ),
                ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF00E676),
        foregroundColor: Colors.black,
        icon: const Icon(Icons.radar_rounded),
        label: const Text('Radar Scan'),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const DiscoveryScreen()),
          ).then((_) => _loadContactsFromDb());
        },
      ),
    );
  }
}
