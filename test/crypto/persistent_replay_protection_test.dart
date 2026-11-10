import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:omnilink/core/crypto/crypto_service.dart';
import 'package:omnilink/core/crypto/packet_service.dart';
import 'package:omnilink/core/database/database_service.dart';
import 'package:omnilink/core/models/packet_envelope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('Slice 1B.7 — Persistent Replay Protection & Migration Tests', () {
    late CryptoService cryptoService;
    late DatabaseService dbService;
    late PacketService packetService;
    late SimpleKeyPair senderKeyPair;
    late String senderNodeIdHex;
    late SimpleKeyPair recipientKeyPair;
    late String recipientNodeIdHex;

    setUp(() async {
      databaseFactory = databaseFactoryFfi;
      dbService = DatabaseService();

      // Ensure a fresh clean SQLite in-memory / FFI database per test run
      final db = await dbService.database;
      await db.delete('processed_packets');

      cryptoService = CryptoService();
      packetService = PacketService(
        cryptoService: cryptoService,
        dbService: dbService,
      );

      senderKeyPair = await cryptoService.generateEd25519KeyPair();
      senderNodeIdHex = await cryptoService.getEd25519PublicKeyHex(senderKeyPair);

      recipientKeyPair = await cryptoService.generateEd25519KeyPair();
      recipientNodeIdHex = await cryptoService.getEd25519PublicKeyHex(recipientKeyPair);
    });

    test('1 & 2. First packet accepted, duplicate packet rejected', () async {
      final packet = await packetService.createEnvelope(
        senderNodeId: senderNodeIdHex,
        recipientNodeId: recipientNodeIdHex,
        messageType: 'TEXT_MESSAGE',
        encryptedPayloadBase64: base64Encode(utf8.encode('Hello World')),
        senderKeyPair: senderKeyPair,
      );

      // First validation + claim
      final isValid = await packetService.validateAndClaimEnvelope(packet);
      expect(isValid, isTrue);

      // Second validation -> Must be rejected as DUPLICATE_PACKET
      expect(
        () async => await packetService.validateEnvelope(packet),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('DUPLICATE_PACKET'))),
      );
    });

    test('3 & 8. Replay Protection survives RAM cache clearing (Simulated App Restart)', () async {
      final packet = await packetService.createEnvelope(
        senderNodeId: senderNodeIdHex,
        recipientNodeId: recipientNodeIdHex,
        messageType: 'TEXT_MESSAGE',
        encryptedPayloadBase64: base64Encode(utf8.encode('Persistent Replay Packet')),
        senderKeyPair: senderKeyPair,
      );

      await packetService.validateAndClaimEnvelope(packet);

      // Simulate App Restart by wiping in-memory RAM LRU cache
      packetService.clearDeduplicationCache();

      // SQLite processed_packets table MUST still detect and reject the replay!
      expect(
        () async => await packetService.validateEnvelope(packet),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('DUPLICATE_PACKET'))),
      );
    });

    test('4 & 10. Atomic Claim Race Condition: Concurrent delivery attempts yield exactly 1 claim', () async {
      final packet = await packetService.createEnvelope(
        senderNodeId: senderNodeIdHex,
        recipientNodeId: recipientNodeIdHex,
        messageType: 'TEXT_MESSAGE',
        encryptedPayloadBase64: base64Encode(utf8.encode('Concurrent Packet')),
        senderKeyPair: senderKeyPair,
      );

      // Clear RAM cache to force concurrent SQLite atomic claims
      packetService.clearDeduplicationCache();

      int successCount = 0;
      int duplicateCount = 0;

      // Launch 5 simultaneous async claim tasks
      final results = await Future.wait(
        List.generate(5, (_) async {
          try {
            await packetService.claimProcessedPacket(packet);
            return 'SUCCESS';
          } on PacketValidationException catch (e) {
            if (e.errorCode == 'DUPLICATE_PACKET') return 'DUPLICATE';
            rethrow;
          }
        }),
      );

      for (final res in results) {
        if (res == 'SUCCESS') successCount++;
        if (res == 'DUPLICATE') duplicateCount++;
      }

      expect(successCount, equals(1), reason: 'Exactly ONE concurrent claim MUST succeed');
      expect(duplicateCount, equals(4), reason: 'All other concurrent claims MUST be safely rejected as DUPLICATE');
    });

    test('5. Tampered packet ID fails signature verification, not replay detection', () async {
      final packet = await packetService.createEnvelope(
        senderNodeId: senderNodeIdHex,
        recipientNodeId: recipientNodeIdHex,
        messageType: 'TEXT_MESSAGE',
        encryptedPayloadBase64: base64Encode(utf8.encode('Original Packet')),
        senderKeyPair: senderKeyPair,
      );

      final tamperedIdPacket = packet.copyWith(packetId: 'tampered-uuid-999');

      expect(
        () async => await packetService.validateEnvelope(tamperedIdPacket),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('INVALID_SIGNATURE'))),
      );
    });

    test('6. Expired packet rejected before replay table lookup', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final expiredPacket = PacketEnvelope(
        protocolVersion: '0.1',
        packetId: 'expired-packet-123',
        senderId: senderNodeIdHex,
        recipientId: recipientNodeIdHex,
        createdAt: now - 100000,
        expiresAt: now - 1000, // Expired 1 second ago
        messageType: 'TEXT_MESSAGE',
        payloadHash: 'hash',
        signature: 'sig',
        encryptedPayload: 'payload',
      );

      expect(
        () async => await packetService.validateEnvelope(expiredPacket),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('PACKET_EXPIRED'))),
      );
    });

    test('7. Future packet beyond clock skew threshold rejected', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final futurePacket = PacketEnvelope(
        protocolVersion: '0.1',
        packetId: 'future-packet-123',
        senderId: senderNodeIdHex,
        recipientId: recipientNodeIdHex,
        createdAt: now + 400000, // 400s in future (> 300s threshold)
        expiresAt: now + 1000000,
        messageType: 'TEXT_MESSAGE',
        payloadHash: 'hash',
        signature: 'sig',
        encryptedPayload: 'payload',
      );

      expect(
        () async => await packetService.validateEnvelope(futurePacket),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('CLOCK_SKEW_EXCEEDED'))),
      );
    });

    test('13. Cleanup Policy: Purges only expired packets, active replay entries remain intact', () async {

      final pExpired = await packetService.createEnvelope(
        senderNodeId: senderNodeIdHex,
        recipientNodeId: recipientNodeIdHex,
        messageType: 'TEXT_MESSAGE',
        encryptedPayloadBase64: base64Encode(utf8.encode('Expired Packet')),
        senderKeyPair: senderKeyPair,
        validityDurationMs: 100, // Expire quickly
      );

      final pActive = await packetService.createEnvelope(
        senderNodeId: senderNodeIdHex,
        recipientNodeId: recipientNodeIdHex,
        messageType: 'TEXT_MESSAGE',
        encryptedPayloadBase64: base64Encode(utf8.encode('Active Packet')),
        senderKeyPair: senderKeyPair,
        validityDurationMs: 3600000, // 1 hour validity
      );

      await packetService.claimProcessedPacket(pExpired);
      await packetService.claimProcessedPacket(pActive);

      // Wait 150ms for pExpired to expire
      await Future.delayed(const Duration(milliseconds: 150));
      final currentTime = DateTime.now().millisecondsSinceEpoch;

      final purgedCount = await dbService.purgeExpiredProcessedPackets(currentTimestampMs: currentTime);
      expect(purgedCount, equals(1));

      // Active packet MUST remain in processed_packets table
      final isActiveStillProcessed = await dbService.isPacketProcessed(pActive.packetId);
      expect(isActiveStillProcessed, isTrue);
    });

    test('14. Multiple distinct packet IDs remain independent', () async {
      final p1 = await packetService.createEnvelope(
        senderNodeId: senderNodeIdHex,
        recipientNodeId: recipientNodeIdHex,
        messageType: 'TEXT_MESSAGE',
        encryptedPayloadBase64: base64Encode(utf8.encode('Message 1')),
        senderKeyPair: senderKeyPair,
      );

      final p2 = await packetService.createEnvelope(
        senderNodeId: senderNodeIdHex,
        recipientNodeId: recipientNodeIdHex,
        messageType: 'TEXT_MESSAGE',
        encryptedPayloadBase64: base64Encode(utf8.encode('Message 2')),
        senderKeyPair: senderKeyPair,
      );

      expect(await packetService.validateAndClaimEnvelope(p1), isTrue);
      expect(await packetService.validateAndClaimEnvelope(p2), isTrue);
    });

    test('15. Unauthenticated packet is rejected at signature check BEFORE reaching replay lookup or claim', () async {
      final validPacket = await packetService.createEnvelope(
        senderNodeId: senderNodeIdHex,
        recipientNodeId: recipientNodeIdHex,
        messageType: 'TEXT_MESSAGE',
        encryptedPayloadBase64: base64Encode(utf8.encode('Payload')),
        senderKeyPair: senderKeyPair,
      );

      // Corrupt signature
      final unauthPacket = validPacket.copyWith(signature: '0' * 128);

      expect(
        () async => await packetService.validateEnvelope(unauthPacket),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('INVALID_SIGNATURE'))),
      );

      // Verify unauthenticated packet ID was NEVER recorded in SQLite processed_packets
      expect(await dbService.isPacketProcessed(unauthPacket.packetId), isFalse);
    });
  });
}
