import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../transport_bridge/android_transport_adapter.dart';
import '../../transport_bridge/transport_adapter.dart';
import '../models/discovery_state.dart';
import 'radio_status_provider.dart';

final discoveryStateProvider =
    StateNotifierProvider<DiscoveryStateNotifier, DiscoveryState>((ref) {
  final adapter = ref.watch(androidTransportAdapterProvider);
  final radioStatus = ref.watch(radioStatusProvider);
  return DiscoveryStateNotifier(adapter, radioStatus.isReady);
});

class DiscoveryStateNotifier extends StateNotifier<DiscoveryState> {
  final AndroidTransportAdapter _adapter;
  StreamSubscription? _peerEventSubscription;
  StreamSubscription? _packetSubscription;

  DiscoveryStateNotifier(this._adapter, bool isRadioReady)
      : super(DiscoveryState(
          status: isRadioReady
              ? DiscoveryStatus.ready
              : DiscoveryStatus.notReady,
        )) {
    _init();
  }

  void updateRadioReadiness(bool isRadioReady) {
    if (state.status == DiscoveryStatus.discovering ||
        state.status == DiscoveryStatus.connected ||
        state.status == DiscoveryStatus.connecting) {
      return;
    }
    state = state.copyWith(
      status:
          isRadioReady ? DiscoveryStatus.ready : DiscoveryStatus.notReady,
    );
  }

  Future<void> _init() async {
    await _adapter.initialize();

    // Listen for peer connection events (onPeerFound, onPeerLost, onConnected, onDisconnected)
    _peerEventSubscription = _adapter.peerEvents.listen(_handlePeerEvent);

    // Listen for incoming packet events (PING / PONG protocol)
    _packetSubscription = _adapter.incomingPackets.listen(_handleIncomingPacket);
  }

  Future<bool> toggleDiscovery() async {
    if (state.status == DiscoveryStatus.discovering) {
      return await stopDiscovery();
    } else {
      return await startDiscovery();
    }
  }

  Future<bool> startDiscovery() async {
    try {
      state = state.copyWith(status: DiscoveryStatus.startingDiscovery);
      debugPrint('OMNILINK_DISCOVERY: Starting offline discovery engine...');
      final success = await _adapter.startDiscovery();
      if (success) {
        state = state.copyWith(
          status: DiscoveryStatus.discovering,
          discoveredPeers: [],
        );
        debugPrint('OMNILINK_DISCOVERY: Discovery engine active. Searching for peers...');
        return true;
      } else {
        state = state.copyWith(
          status: DiscoveryStatus.error,
          errorMessage: 'Failed to start nearby discovery engine.',
        );
        return false;
      }
    } catch (e) {
      state = state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: e.toString(),
      );
      return false;
    }
  }

  Future<bool> stopDiscovery() async {
    try {
      await _adapter.stopDiscovery();
      final isStillConnected = state.connectedPeerId != null &&
          await _adapter.isConnected(state.connectedPeerId!);
      state = state.copyWith(
        status: isStillConnected ? DiscoveryStatus.connected : DiscoveryStatus.ready,
        discoveredPeers: [],
      );
      return true;
    } catch (e) {
      debugPrint('OMNILINK_DISCOVERY: Error stopping discovery: $e');
      return false;
    }
  }

  Future<bool> connectPeer(String peerId) async {
    try {
      final alreadyConnected = await _adapter.isConnected(peerId);
      if (alreadyConnected) {
        debugPrint('OMNILINK_DISCOVERY: Peer $peerId is already natively connected. Synchronizing discovery state.');
        state = state.copyWith(
          status: DiscoveryStatus.connected,
          connectedPeerId: peerId,
        );
        return true;
      }

      state = state.copyWith(
        status: DiscoveryStatus.connecting,
        connectedPeerId: peerId,
      );
      debugPrint('OMNILINK_DISCOVERY: Initiating connection to peer: $peerId');
      final success = await _adapter.connectPeer(peerId);
      if (!success) {
        state = state.copyWith(
          status: DiscoveryStatus.error,
          errorMessage: 'Failed to initiate connection to $peerId',
        );
      }
      return success;
    } catch (e) {
      state = state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: e.toString(),
      );
      return false;
    }
  }

  void _handlePeerEvent(PeerConnectionEvent event) {
    debugPrint('OMNILINK_DISCOVERY: Peer event: ${event.eventType} peerId=${event.peerId} name=${event.friendlyName}');

    switch (event.eventType) {
      case PeerConnectionEventType.onPeerFound:
        final newPeer = DiscoveredPeer(
          endpointId: event.peerId,
          deviceName: (event.friendlyName != null && event.friendlyName!.isNotEmpty)
              ? event.friendlyName!
              : 'OMNILINK_${event.peerId}',
        );
        final currentList = List<DiscoveredPeer>.from(state.discoveredPeers);
        if (!currentList.contains(newPeer)) {
          currentList.add(newPeer);
        }
        state = state.copyWith(
          status: DiscoveryStatus.peerFound,
          discoveredPeers: currentList,
        );
        break;

      case PeerConnectionEventType.onPeerLost:
        final currentList = List<DiscoveredPeer>.from(state.discoveredPeers)
          ..removeWhere((p) => p.endpointId == event.peerId);
        state = state.copyWith(
          discoveredPeers: currentList,
          status: currentList.isNotEmpty
              ? DiscoveryStatus.peerFound
              : DiscoveryStatus.discovering,
        );
        break;

      case PeerConnectionEventType.onConnected:
        state = state.copyWith(
          status: DiscoveryStatus.connected,
          connectedPeerId: event.peerId,
          connectedPeerName: (event.friendlyName != null && event.friendlyName!.isNotEmpty)
              ? event.friendlyName!
              : 'OMNILINK_${event.peerId}',
        );
        debugPrint('OMNILINK_DISCOVERY: Connected to ${event.peerId}! (PING telemetry disabled; route handshake handles liveness)');
        break;

      case PeerConnectionEventType.onDisconnected:
        state = state.copyWith(
          status: DiscoveryStatus.disconnected,
          connectedPeerId: null,
          connectedPeerName: null,
          pingPongRttMs: null,
        );
        debugPrint('OMNILINK_DISCOVERY: Disconnected from peer: ${event.peerId}');
        break;

      case PeerConnectionEventType.onError:
        state = state.copyWith(
          status: DiscoveryStatus.error,
          errorMessage: event.errorMessage ?? 'Transport connection error',
        );
        break;
    }
  }

  /// Sends a PING payload over the offline transport link (manual diagnostic only).
  // ignore: unused_element
  Future<void> _sendPing(String peerId) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final pingData = jsonEncode({'type': 'PING', 'timestamp': now});
      final bytes = Uint8List.fromList(utf8.encode(pingData));
      await _adapter.sendPacket(peerId, bytes);
      debugPrint('OMNILINK_TRANSPORT: Sent PING to $peerId at $now');
    } catch (e) {
      debugPrint('OMNILINK_TRANSPORT: Error sending PING: $e');
    }
  }

  /// Handles incoming PING / PONG packet payloads and computes RTT.
  /// Ignores PacketEnvelope traffic (handled by RouterEngine) to avoid log pollution.
  void _handleIncomingPacket(IncomingPacketEvent event) {
    try {
      final str = utf8.decode(event.payloadBytes);
      final json = jsonDecode(str) as Map<String, dynamic>;
      // PacketEnvelope carries packetId/senderId/messageType — not our concern.
      if (json.containsKey('packetId') || json.containsKey('messageType')) return;
      final type = json['type'] as String?;

      if (type == 'PING') {
        final pingTime = json['timestamp'] as int?;
        debugPrint('OMNILINK_TRANSPORT: Received PING from ${event.senderPeerId}. Responding PONG...');
        _sendPong(event.senderPeerId, pingTime);
      } else if (type == 'PONG') {
        final origTime = json['timestamp'] as int?;
        if (origTime != null) {
          final now = DateTime.now().millisecondsSinceEpoch;
          final rtt = now - origTime;
          debugPrint('OMNILINK_TRANSPORT: Received PONG from ${event.senderPeerId}! RTT = $rtt ms');
          state = state.copyWith(pingPongRttMs: rtt);
        }
      }
    } catch (e) {
      // Application envelopes (binary or PacketEnvelope JSON) are expected here; ignore quietly.
    }
  }

  /// Responds with PONG payload containing original timestamp.
  Future<void> _sendPong(String peerId, int? origTimestamp) async {
    try {
      final pongData = jsonEncode({
        'type': 'PONG',
        'timestamp': origTimestamp ?? DateTime.now().millisecondsSinceEpoch,
      });
      final bytes = Uint8List.fromList(utf8.encode(pongData));
      await _adapter.sendPacket(peerId, bytes);
      debugPrint('OMNILINK_TRANSPORT: Sent PONG to $peerId');
    } catch (e) {
      debugPrint('OMNILINK_TRANSPORT: Error sending PONG: $e');
    }
  }

  @override
  void dispose() {
    _peerEventSubscription?.cancel();
    _packetSubscription?.cancel();
    super.dispose();
  }
}
