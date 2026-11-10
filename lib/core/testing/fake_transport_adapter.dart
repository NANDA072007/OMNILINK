import 'dart:async';
import 'dart:typed_data';

import '../../transport_bridge/transport_adapter.dart';

/// Test double implementing [TransportAdapter] for deterministic unit and integration testing.
/// Simulates radio discovery, state changes, packet reception, and link disconnections without platform channels.
class FakeTransportAdapter implements TransportAdapter {
  final StreamController<PeerConnectionEvent> _peerEventsController =
      StreamController<PeerConnectionEvent>.broadcast();

  final StreamController<IncomingPacketEvent> _incomingPacketsController =
      StreamController<IncomingPacketEvent>.broadcast();

  bool isInitialized = false;
  bool isDiscoveringActive = false;
  bool isBluetoothEnabled = true;

  final Set<String> connectedPeers = {};
  final Map<String, List<Uint8List>> sentPackets = {};

  @override
  Future<void> initialize() async {
    isInitialized = true;
  }

  @override
  Future<bool> startDiscovery({String serviceId = 'org.omnilink.mesh.v1'}) async {
    if (!isBluetoothEnabled) return false;
    isDiscoveringActive = true;
    return true;
  }

  @override
  Future<bool> stopDiscovery() async {
    isDiscoveringActive = false;
    return true;
  }

  @override
  Future<bool> connectPeer(String peerId) async {
    if (!isBluetoothEnabled) return false;
    connectedPeers.add(peerId);
    simulatePeerConnected(peerId);
    return true;
  }

  @override
  Future<bool> disconnectPeer(String peerId) async {
    connectedPeers.remove(peerId);
    simulatePeerDisconnected(peerId);
    return true;
  }

  @override
  Future<bool> sendPacket(String peerId, Uint8List packetBytes) async {
    if (!connectedPeers.contains(peerId)) return false;
    sentPackets.putIfAbsent(peerId, () => []).add(packetBytes);
    return true;
  }

  @override
  Stream<PeerConnectionEvent> get peerEvents => _peerEventsController.stream;

  @override
  Stream<IncomingPacketEvent> get incomingPackets => _incomingPacketsController.stream;

  @override
  Future<bool> isConnected(String peerId) async {
    return connectedPeers.contains(peerId);
  }

  @override
  Future<void> dispose() async {
    await _peerEventsController.close();
    await _incomingPacketsController.close();
    isInitialized = false;
  }

  // ===========================================================================
  // TEST SIMULATION METHODS
  // ===========================================================================

  /// Simulates discovering a remote peer on radio scan.
  void simulatePeerDiscovered(String peerId, {String? friendlyName, int? rssi}) {
    _peerEventsController.add(
      PeerConnectionEvent(
        eventType: PeerConnectionEventType.onPeerFound,
        peerId: peerId,
        friendlyName: friendlyName ?? 'Peer_$peerId',
        rssi: rssi ?? -55,
      ),
    );
  }

  /// Simulates active peer connection establishment.
  void simulatePeerConnected(String peerId, {String? friendlyName}) {
    connectedPeers.add(peerId);
    _peerEventsController.add(
      PeerConnectionEvent(
        eventType: PeerConnectionEventType.onConnected,
        peerId: peerId,
        friendlyName: friendlyName ?? 'Peer_$peerId',
      ),
    );
  }

  /// Simulates peer disconnection event.
  void simulatePeerDisconnected(String peerId) {
    connectedPeers.remove(peerId);
    _peerEventsController.add(
      PeerConnectionEvent(
        eventType: PeerConnectionEventType.onDisconnected,
        peerId: peerId,
      ),
    );
  }

  /// Simulates receiving an incoming packet payload from a peer over physical link.
  void simulatePacketReceived(String senderPeerId, Uint8List payloadBytes) {
    _incomingPacketsController.add(
      IncomingPacketEvent(
        senderPeerId: senderPeerId,
        payloadBytes: payloadBytes,
      ),
    );
  }

  /// Simulates Bluetooth adapter state toggle.
  void simulateBluetoothStateChanged(bool enabled) {
    isBluetoothEnabled = enabled;
    if (!enabled) {
      isDiscoveringActive = false;
      final copy = List<String>.from(connectedPeers);
      for (final p in copy) {
        simulatePeerDisconnected(p);
      }
    }
  }

  /// Simulates native transport error event.
  void simulateError(String errorCode, String errorMessage) {
    _peerEventsController.add(
      PeerConnectionEvent(
        eventType: PeerConnectionEventType.onError,
        peerId: 'system',
        errorCode: errorCode,
        errorMessage: errorMessage,
      ),
    );
  }

  /// Clears tracked sent packets for test assertions.
  void clearSentPackets() {
    sentPackets.clear();
  }
}
