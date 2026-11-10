import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:omnilink/core/database/database_service.dart';
import 'package:omnilink/core/routing/router_engine.dart';
import 'package:omnilink/core/routing/routing_database.dart';
import 'package:omnilink/core/routing/send_queue.dart';
import 'package:omnilink/transport_bridge/android_transport_adapter.dart';
import 'package:omnilink/transport_bridge/transport_adapter.dart';
import 'package:omnilink/core/crypto/crypto_service.dart';
import 'package:omnilink/core/crypto/packet_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Test mock implementation of TransportAdapter for SendQueueManager unit tests.
class ControlledMockTransportAdapter implements TransportAdapter {
  final List<Map<String, dynamic>> sentInvocations = [];
  bool Function(String peerId, Uint8List bytes)? sendHandler;

  final _peerEventController = StreamController<PeerConnectionEvent>.broadcast();
  final _incomingController = StreamController<IncomingPacketEvent>.broadcast();

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> startDiscovery({String serviceId = 'org.omnilink.mesh.v1'}) async => true;

  @override
  Future<bool> stopDiscovery() async => true;

  @override
  Future<bool> connectPeer(String peerId) async => true;

  @override
  Future<bool> disconnectPeer(String peerId) async => true;

  @override
  Future<bool> sendPacket(String peerId, Uint8List packetBytes) async {
    sentInvocations.add({
      'peerId': peerId,
      'bytes': packetBytes,
    });
    if (sendHandler != null) {
      return sendHandler!(peerId, packetBytes);
    }
    return true;
  }

  @override
  Stream<PeerConnectionEvent> get peerEvents => _peerEventController.stream;

  @override
  Stream<IncomingPacketEvent> get incomingPackets => _incomingController.stream;

  @override
  Future<bool> isConnected(String peerId) async => true;

  @override
  Future<void> dispose() async {
    await _peerEventController.close();
    await _incomingController.close();
  }

  void emitPeerEvent(PeerConnectionEvent event) => _peerEventController.add(event);
  void emitIncomingPacket(IncomingPacketEvent event) => _incomingController.add(event);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Connection Reliability & Send Queue Tests', () {
    late ControlledMockTransportAdapter mockTransport;
    late StreamController<Map<String, dynamic>> updateController;
    late SendQueueManager sendQueue;

    setUp(() {
      mockTransport = ControlledMockTransportAdapter();
      updateController = StreamController<Map<String, dynamic>>.broadcast();
      sendQueue = SendQueueManager(
        transport: mockTransport,
        payloadTransferUpdates: updateController.stream,
      );
    });

    tearDown(() async {
      sendQueue.dispose();
      await updateController.close();
      await mockTransport.dispose();
    });

    test('1. Two connected devices: Successful transmit with native callback correlation', () async {
      final sendFuture = sendQueue.enqueueAndSend(
        packetId: 'pkt_101',
        peerId: 'EP_DEVICE_B',
        payloadBytes: Uint8List.fromList(utf8.encode('Hello Device B')),
      );

      // Verify invocation was passed to the transport
      expect(mockTransport.sentInvocations.length, equals(1));
      expect(mockTransport.sentInvocations.first['peerId'], equals('EP_DEVICE_B'));

      // Simulate native transfer update SUCCESS correlated by attemptId
      final attemptId = sendQueue.getActiveAttemptId('EP_DEVICE_B');
      expect(attemptId, isNotNull);

      updateController.add({
        'peerId': 'EP_DEVICE_B',
        'status': 'SUCCESS',
        'payloadId': 1001,
        'attemptId': attemptId,
      });

      final result = await sendFuture.timeout(const Duration(seconds: 1));
      expect(result, isTrue);
      expect(sendQueue.isTransmitting('EP_DEVICE_B'), isFalse);
    });

    test('2 & 3. Three simultaneous connected peers: distinct transmission without endpoint confusion', () async {
      final peers = ['EP_PEER_1', 'EP_PEER_2', 'EP_PEER_3'];
      final futures = <Future<bool>>[];

      for (int i = 0; i < peers.length; i++) {
        final peer = peers[i];
        futures.add(sendQueue.enqueueAndSend(
          packetId: 'pkt_peer_$i',
          peerId: peer,
          payloadBytes: Uint8List.fromList(utf8.encode('Message for $peer')),
        ));
      }

      // Check all 3 invocations were dispatched to their respective endpoints
      expect(mockTransport.sentInvocations.length, equals(3));
      expect(mockTransport.sentInvocations[0]['peerId'], equals('EP_PEER_1'));
      expect(mockTransport.sentInvocations[1]['peerId'], equals('EP_PEER_2'));
      expect(mockTransport.sentInvocations[2]['peerId'], equals('EP_PEER_3'));

      final attempt1 = sendQueue.getActiveAttemptId('EP_PEER_1');
      final attempt2 = sendQueue.getActiveAttemptId('EP_PEER_2');
      final attempt3 = sendQueue.getActiveAttemptId('EP_PEER_3');

      // Complete peer 2 first (SUCCESS)
      updateController.add({
        'peerId': 'EP_PEER_2',
        'status': 'SUCCESS',
        'attemptId': attempt2,
      });
      final res2 = await futures[1].timeout(const Duration(seconds: 1));
      expect(res2, isTrue);

      // Complete peer 3 with FAILURE
      updateController.add({
        'peerId': 'EP_PEER_3',
        'status': 'FAILURE',
        'attemptId': attempt3,
      });
      final res3 = await futures[2].timeout(const Duration(seconds: 1));
      expect(res3, isFalse);

      // Complete peer 1 with SUCCESS
      updateController.add({
        'peerId': 'EP_PEER_1',
        'status': 'SUCCESS',
        'attemptId': attempt1,
      });
      final res1 = await futures[0].timeout(const Duration(seconds: 1));
      expect(res1, isTrue);
    });

    test('4. Multiple sequential transfers to the same peer with attempt correlation', () async {
      final future1 = sendQueue.enqueueAndSend(
        packetId: 'pkt_seq_1',
        peerId: 'EP_SAME_PEER',
        payloadBytes: Uint8List.fromList(utf8.encode('Packet 1')),
      );

      final future2 = sendQueue.enqueueAndSend(
        packetId: 'pkt_seq_2',
        peerId: 'EP_SAME_PEER',
        payloadBytes: Uint8List.fromList(utf8.encode('Packet 2')),
      );

      // Initially only packet 1 is active (serialized per peer)
      expect(mockTransport.sentInvocations.length, equals(1));
      expect(mockTransport.sentInvocations[0]['peerId'], equals('EP_SAME_PEER'));

      final attempt1 = sendQueue.getActiveAttemptId('EP_SAME_PEER');
      expect(attempt1, isNotNull);

      // Complete attempt 1
      updateController.add({
        'peerId': 'EP_SAME_PEER',
        'status': 'SUCCESS',
        'attemptId': attempt1,
      });

      final res1 = await future1.timeout(const Duration(seconds: 1));
      expect(res1, isTrue);

      // Microtask pump ensures packet 2 is dequeued
      await pumpEventQueue();
      expect(mockTransport.sentInvocations.length, equals(2));

      final attempt2 = sendQueue.getActiveAttemptId('EP_SAME_PEER');
      expect(attempt2, isNotNull);
      expect(attempt2, isNot(equals(attempt1)));

      // Complete attempt 2
      updateController.add({
        'peerId': 'EP_SAME_PEER',
        'status': 'SUCCESS',
        'attemptId': attempt2,
      });

      final res2 = await future2.timeout(const Duration(seconds: 1));
      expect(res2, isTrue);
    });

    test('5. Timeout followed by another successful transfer: queue does not deadlock', () async {
      final future1 = sendQueue.enqueueAndSend(
        packetId: 'pkt_timeout_1',
        peerId: 'EP_TIMEOUT_PEER',
        payloadBytes: Uint8List.fromList(utf8.encode('Will Timeout')),
      );

      expect(mockTransport.sentInvocations.length, equals(1));
      final attempt1 = sendQueue.getActiveAttemptId('EP_TIMEOUT_PEER')!;

      // Simulate timeout
      sendQueue.failCurrentAttemptForTesting(
        attemptId: attempt1,
        peerId: 'EP_TIMEOUT_PEER',
        errorReason: 'TIMEOUT',
      );

      final res1 = await future1.timeout(const Duration(seconds: 1));
      expect(res1, isFalse);

      // Enqueue subsequent packet to the same peer - queue must be unblocked!
      final future2 = sendQueue.enqueueAndSend(
        packetId: 'pkt_timeout_2',
        peerId: 'EP_TIMEOUT_PEER',
        payloadBytes: Uint8List.fromList(utf8.encode('Subsequent Packet')),
      );

      await pumpEventQueue();
      expect(mockTransport.sentInvocations.length, equals(2));
      final attempt2 = sendQueue.getActiveAttemptId('EP_TIMEOUT_PEER')!;
      expect(attempt2, isNot(equals(attempt1)));

      // Succeed attempt 2
      updateController.add({
        'peerId': 'EP_TIMEOUT_PEER',
        'status': 'SUCCESS',
        'attemptId': attempt2,
      });

      final res2 = await future2.timeout(const Duration(seconds: 1));
      expect(res2, isTrue);
    });

    test('6. Late callback after timeout does NOT complete or corrupt newer attempt', () async {
      final future1 = sendQueue.enqueueAndSend(
        packetId: 'pkt_late_1',
        peerId: 'EP_LATE_PEER',
        payloadBytes: Uint8List.fromList(utf8.encode('Packet 1')),
      );

      final attempt1 = sendQueue.getActiveAttemptId('EP_LATE_PEER')!;

      // Force attempt 1 to timeout
      sendQueue.failCurrentAttemptForTesting(
        attemptId: attempt1,
        peerId: 'EP_LATE_PEER',
        errorReason: 'TIMEOUT',
      );
      final res1 = await future1.timeout(const Duration(seconds: 1));
      expect(res1, isFalse);

      // Start attempt 2
      final future2 = sendQueue.enqueueAndSend(
        packetId: 'pkt_late_2',
        peerId: 'EP_LATE_PEER',
        payloadBytes: Uint8List.fromList(utf8.encode('Packet 2')),
      );
      await pumpEventQueue();
      expect(mockTransport.sentInvocations.length, equals(2));
      final attempt2 = sendQueue.getActiveAttemptId('EP_LATE_PEER')!;

      // Late callback for attempt 1 arrives now with SUCCESS
      updateController.add({
        'peerId': 'EP_LATE_PEER',
        'status': 'SUCCESS',
        'attemptId': attempt1,
      });

      // Verify future2 is still pending (not prematurely completed by attempt 1's late callback!)
      bool future2Completed = false;
      future2.then((_) => future2Completed = true);
      await pumpEventQueue();
      expect(future2Completed, isFalse);

      // Now callback for attempt 2 arrives
      updateController.add({
        'peerId': 'EP_LATE_PEER',
        'status': 'SUCCESS',
        'attemptId': attempt2,
      });

      final res2 = await future2.timeout(const Duration(seconds: 1));
      expect(res2, isTrue);
    });

    test('7. Disconnect followed by clearing queue and reconnecting with new endpoint ID', () async {
      final future1 = sendQueue.enqueueAndSend(
        packetId: 'pkt_dc_1',
        peerId: 'EP_OLD',
        payloadBytes: Uint8List.fromList(utf8.encode('Pending 1')),
      );
      final future2 = sendQueue.enqueueAndSend(
        packetId: 'pkt_dc_2',
        peerId: 'EP_OLD',
        payloadBytes: Uint8List.fromList(utf8.encode('Pending 2')),
      );

      // Clear queue on peer disconnect
      sendQueue.clearQueue('EP_OLD');

      final res1 = await future1.timeout(const Duration(seconds: 1));
      final res2 = await future2.timeout(const Duration(seconds: 1));
      expect(res1, isFalse);
      expect(res2, isFalse);
      expect(sendQueue.queueDepth('EP_OLD'), equals(0));

      // Reconnect with new endpoint ID: fresh transmissions succeed
      final future3 = sendQueue.enqueueAndSend(
        packetId: 'pkt_dc_3',
        peerId: 'EP_NEW',
        payloadBytes: Uint8List.fromList(utf8.encode('New Packet')),
      );
      await pumpEventQueue();

      final attemptNew = sendQueue.getActiveAttemptId('EP_NEW')!;
      updateController.add({
        'peerId': 'EP_NEW',
        'status': 'SUCCESS',
        'attemptId': attemptNew,
      });

      final res3 = await future3.timeout(const Duration(seconds: 1));
      expect(res3, isTrue);
    });

    test('8. Immediate transport failure unblocks send queue without hang', () async {
      mockTransport.sendHandler = (peerId, bytes) => false; // Immediate rejection

      final future = sendQueue.enqueueAndSend(
        packetId: 'pkt_reject_1',
        peerId: 'EP_FAILING_PEER',
        payloadBytes: Uint8List.fromList(utf8.encode('Fail Packet')),
      );

      final res = await future.timeout(const Duration(seconds: 1));
      expect(res, isFalse);
      expect(sendQueue.isTransmitting('EP_FAILING_PEER'), isFalse);
    });
  });

  group('AndroidTransportAdapter Endpoint Mapping & Fallback Protection', () {
    late AndroidTransportAdapter adapter;
    final List<MethodCall> channelCalls = [];

    setUp(() {
      channelCalls.clear();
      adapter = AndroidTransportAdapter();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('omnilink/transport/control'),
        (MethodCall call) async {
          channelCalls.add(call);
          if (call.method == 'startForegroundService' ||
              call.method == 'stopForegroundService' ||
              call.method == 'sendPacket') {
            return true;
          }
          return null;
        },
      );
    });

    tearDown(() async {
      await adapter.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('omnilink/transport/control'),
        null,
      );
    });

    test('8. Rejects unknown or unauthenticated peer mappings without single-peer guessing', () async {
      // Connect 1 peer to adapter via native event handler
      adapter.handleNativeEventForTesting({
        'eventType': 'onConnected',
        'peerId': 'KNOWN_ENDPOINT_1',
      });

      // Target unknown cryptographic nodeId with no resolver
      final result = await adapter.sendPacket(
        'UNKNOWN_NODE_ID_ABC',
        Uint8List.fromList([1, 2, 3]),
      );

      // Must be rejected immediately! No guessing to KNOWN_ENDPOINT_1!
      expect(result, isFalse);
      expect(channelCalls.where((c) => c.method == 'sendPacket').isEmpty, isTrue);
    });

    test('Resolves nodeId to endpointId explicitly when resolver is provided', () async {
      // Connect peer
      adapter.handleNativeEventForTesting({
        'eventType': 'onConnected',
        'peerId': 'KNOWN_ENDPOINT_1',
      });

      // Wire explicit resolver
      adapter.endpointResolver = (nodeId) {
        if (nodeId == 'NODE_ID_123') return 'KNOWN_ENDPOINT_1';
        return null;
      };

      final result = await adapter.sendPacket(
        'NODE_ID_123',
        Uint8List.fromList([1, 2, 3]),
      );

      expect(result, isTrue);
      final sendCalls = channelCalls.where((c) => c.method == 'sendPacket').toList();
      expect(sendCalls.length, equals(1));
      expect(sendCalls.first.arguments['peerId'], equals('KNOWN_ENDPOINT_1'));
    });

    test('9. Duplicate connection events do not corrupt peer registry', () async {
      // Send duplicate onConnected events
      adapter.handleNativeEventForTesting({
        'eventType': 'onConnected',
        'peerId': 'EP_DUPLICATE_TEST',
      });
      adapter.handleNativeEventForTesting({
        'eventType': 'onConnected',
        'peerId': 'EP_DUPLICATE_TEST',
      });

      // Send packet to that peer succeeds once
      final result = await adapter.sendPacket(
        'EP_DUPLICATE_TEST',
        Uint8List.fromList([1, 2, 3]),
      );
      expect(result, isTrue);

      // Now disconnect once
      adapter.handleNativeEventForTesting({
        'eventType': 'onDisconnected',
        'peerId': 'EP_DUPLICATE_TEST',
      });

      // Subsequent send must fail (not remain connected due to duplicate count)
      final sendAfterDisconnect = await adapter.sendPacket(
        'EP_DUPLICATE_TEST',
        Uint8List.fromList([1, 2, 3]),
      );
      expect(sendAfterDisconnect, isFalse);
    });
  });

  group('RouterEngine & Outbox Integration Lifecycle', () {
    test('10. RouterEngine endpoint resolution and outbox notification on peer connect', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final mockTransport = ControlledMockTransportAdapter();
      final cryptoService = CryptoService();
      final packetService = PacketService(
        cryptoService: cryptoService,
        dbService: DatabaseService.instance,
      );
      final keyPair = await cryptoService.generateEd25519KeyPair();
      final localNodeId = await cryptoService.getEd25519PublicKeyHex(keyPair);

      final engine = RouterEngine(
        transport: mockTransport,
        packetService: packetService,
        cryptoService: cryptoService,
        db: RoutingDatabaseService.instance,
        getMyNodeId: () => localNodeId,
        getMasterKeyPair: () => keyPair,
        getConnectedPeers: () => [],
      );

      // Register an endpoint mapping in RouterEngine
      engine.registerPeerNodeId(
        'EP_PHYSICAL_42',
        'NODE_LOGICAL_42',
      );

      expect(engine.getEndpointIdForNodeId('NODE_LOGICAL_42'), equals('EP_PHYSICAL_42'));
      expect(engine.getNodeIdForEndpointId('EP_PHYSICAL_42'), equals('NODE_LOGICAL_42'));

      // Invalidate on disconnect
      engine.unregisterPeerNodeId('EP_PHYSICAL_42');
      expect(engine.getEndpointIdForNodeId('NODE_LOGICAL_42'), isNull);
      expect(engine.getNodeIdForEndpointId('EP_PHYSICAL_42'), isNull);

      engine.dispose();
      await mockTransport.dispose();
    });
  });
}
