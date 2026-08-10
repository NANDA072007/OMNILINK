import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';

import 'transport_adapter.dart';

/// In-memory mock implementation of physical radio transport.
/// Used for immediate UI testing, widget testing, and emulator debugging
/// without requiring physical Bluetooth/Wi-Fi hardware.
class MockTransportAdapter implements TransportAdapter {
  final StreamController<PeerConnectionEvent> _peerEventController =
      StreamController.broadcast();
  final StreamController<IncomingPacketEvent> _incomingPacketController =
      StreamController.broadcast();

  final Set<String> _connectedPeers = {};
  Timer? _discoveryTimer;
  final Uuid _uuid = const Uuid();

  @override
  Future<void> initialize() async {
    await Future.delayed(const Duration(milliseconds: 500));
  }

  @override
  Stream<PeerConnectionEvent> get peerEvents => _peerEventController.stream;

  @override
  Stream<IncomingPacketEvent> get incomingPackets =>
      _incomingPacketController.stream;

  @override
  Future<bool> startDiscovery({String serviceId = 'org.omnilink.mesh.v1'}) async {
    _discoveryTimer?.cancel();
    // Simulate finding a mock peer after 2 seconds
    _discoveryTimer = Timer(const Duration(seconds: 2), () {
      if (!_peerEventController.isClosed) {
        _peerEventController.add(PeerConnectionEvent(
          eventType: PeerConnectionEventType.onPeerFound,
          peerId: 'MOCK_PEER_${_uuid.v4().substring(0, 4)}',
          friendlyName: 'Mock Device ${Random().nextInt(100)}',
          rssi: -45 - Random().nextInt(30),
          transportType: 'MOCK',
        ));
      }
    });
    return true;
  }

  @override
  Future<bool> stopDiscovery() async {
    _discoveryTimer?.cancel();
    return true;
  }

  @override
  Future<bool> connectPeer(String peerId) async {
    _peerEventController.add(PeerConnectionEvent(
      eventType: PeerConnectionEventType.onConnected,
      peerId: peerId,
      transportType: 'MOCK',
    ));
    _connectedPeers.add(peerId);
    return true;
  }

  @override
  Future<bool> disconnectPeer(String peerId) async {
    _peerEventController.add(PeerConnectionEvent(
      eventType: PeerConnectionEventType.onDisconnected,
      peerId: peerId,
      transportType: 'MOCK',
    ));
    _connectedPeers.remove(peerId);
    return true;
  }

  @override
  Future<bool> sendPacket(String peerId, Uint8List packetBytes) async {
    if (!_connectedPeers.contains(peerId)) return false;
    await Future.delayed(const Duration(milliseconds: 300)); // Simulate latency
    return true;
  }

  @override
  Future<bool> isConnected(String peerId) async =>
      _connectedPeers.contains(peerId);

  @override
  Future<void> dispose() async {
    _discoveryTimer?.cancel();
    await _peerEventController.close();
    await _incomingPacketController.close();
  }

  /// Helper to simulate receiving an incoming raw packet from radio (for UI testing).
  void simulateIncomingPacket(String peerId, Uint8List bytes) {
    if (!_incomingPacketController.isClosed) {
      _incomingPacketController.add(
        IncomingPacketEvent(senderPeerId: peerId, payloadBytes: bytes),
      );
    }
  }
}
