import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:omnilink/core/crypto/crypto_service.dart';
import 'package:omnilink/core/crypto/packet_service.dart';
import 'package:omnilink/core/models/packet_envelope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Slice 1B.6 — Signature Boundary & Relay Mutation Unit Tests', () {
    late CryptoService cryptoService;
    late PacketService packetService;
    late SimpleKeyPair senderKeyPair;
    late String senderNodeIdHex;
    late SimpleKeyPair recipientKeyPair;
    late String recipientNodeIdHex;

    setUp(() async {
      cryptoService = CryptoService();
      packetService = PacketService(cryptoService: cryptoService);

      senderKeyPair = await cryptoService.generateEd25519KeyPair();
      senderNodeIdHex = await cryptoService.getEd25519PublicKeyHex(senderKeyPair);

      recipientKeyPair = await cryptoService.generateEd25519KeyPair();
      recipientNodeIdHex = await cryptoService.getEd25519PublicKeyHex(recipientKeyPair);
    });

    test('1 & Mandatory Section 6. Relay Mutation Test: Relay mutating TTL and hopCount leaves signature 100% VALID', () async {
      final ephKey = await cryptoService.generateX25519KeyPair();
      final ephHex = await cryptoService.getX25519PublicKeyHex(ephKey);

      // Sender creates original packet with ttl=10, hopCount=0
      final originalPacket = await packetService.createEnvelope(
        senderNodeId: senderNodeIdHex,
        recipientNodeId: recipientNodeIdHex,
        ephemeralPublicKey: ephHex,
        messageType: 'TEXT_MESSAGE',
        encryptedPayloadBase64: base64Encode(utf8.encode('Encrypted Secret Payload')),
        senderKeyPair: senderKeyPair,
        ttl: 10,
      );

      expect(originalPacket.ttl, equals(10));
      expect(originalPacket.hopCount, equals(0));
      expect(await packetService.validateEnvelope(originalPacket), isTrue);

      // Intermediate Relay Mutates TTL -> 9, HopCount -> 1
      final relayedPacket = originalPacket.copyWith(
        ttl: 9,
        hopCount: 1,
      );

      // Ed25519 signature MUST remain 100% VALID!
      final isValidRelayed = await packetService.validateEnvelope(relayedPacket);
      expect(isValidRelayed, isTrue, reason: 'Relay mutation of TTL/hopCount MUST NOT invalidate the Ed25519 signature');
    });

    test('2 & Mandatory Section 7. Tampering Tests: Modifying ANY immutable field invalidates signature', () async {
      final ephKey = await cryptoService.generateX25519KeyPair();
      final ephHex = await cryptoService.getX25519PublicKeyHex(ephKey);

      final packet = await packetService.createEnvelope(
        senderNodeId: senderNodeIdHex,
        recipientNodeId: recipientNodeIdHex,
        ephemeralPublicKey: ephHex,
        messageType: 'TEXT_MESSAGE',
        encryptedPayloadBase64: base64Encode(utf8.encode('Original Payload')),
        senderKeyPair: senderKeyPair,
      );

      expect(await packetService.validateEnvelope(packet), isTrue);

      // 1. Tamper packetId
      final tPacketId = packet.copyWith(packetId: 'tampered-uuid-999');
      expect(
        () async => await packetService.validateEnvelope(tPacketId),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('INVALID_SIGNATURE'))),
      );

      // 2. Tamper senderId
      final otherSender = await cryptoService.generateEd25519KeyPair();
      final tSender = packet.copyWith(senderId: await cryptoService.getEd25519PublicKeyHex(otherSender));
      expect(
        () async => await packetService.validateEnvelope(tSender),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('INVALID_SIGNATURE'))),
      );

      // 3. Tamper recipientId
      final tRecipient = packet.copyWith(recipientId: 'node_tampered_recipient_99999999999999999999999999999999');
      expect(
        () async => await packetService.validateEnvelope(tRecipient),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('INVALID_SIGNATURE'))),
      );

      // 4. Tamper ephemeralPublicKey
      final tamperedEphKey = await cryptoService.generateX25519KeyPair();
      final tEph = packet.copyWith(ephemeralPublicKey: await cryptoService.getX25519PublicKeyHex(tamperedEphKey));
      expect(
        () async => await packetService.validateEnvelope(tEph),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('INVALID_SIGNATURE'))),
      );

      // 5. Tamper createdAt
      final tCreated = packet.copyWith(createdAt: packet.createdAt - 500);
      expect(
        () async => await packetService.validateEnvelope(tCreated),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('INVALID_SIGNATURE'))),
      );

      // 6. Tamper expiresAt
      final tExpires = packet.copyWith(expiresAt: packet.expiresAt + 1000);
      expect(
        () async => await packetService.validateEnvelope(tExpires),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('INVALID_SIGNATURE'))),
      );

      // 7. Tamper messageType
      final tType = packet.copyWith(messageType: 'CONTROL_ACK');
      expect(
        () async => await packetService.validateEnvelope(tType),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('INVALID_SIGNATURE'))),
      );

      // 8. Tamper encryptedPayload
      final tPayload = packet.copyWith(encryptedPayload: base64Encode(utf8.encode('Tampered Payload')));
      expect(
        () async => await packetService.validateEnvelope(tPayload),
        throwsA(isA<PacketValidationException>()),
      );

      // 9. Tamper signature
      final tSig = packet.copyWith(signature: '0' * 128);
      expect(
        () async => await packetService.validateEnvelope(tSig),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('INVALID_SIGNATURE'))),
      );
    });

    test('3 & Section 14. Serialization Roundtrip: Canonical bytes and signature validation survive JSON serialization', () async {
      final ephKey = await cryptoService.generateX25519KeyPair();
      final ephHex = await cryptoService.getX25519PublicKeyHex(ephKey);

      final originalPacket = await packetService.createEnvelope(
        senderNodeId: senderNodeIdHex,
        recipientNodeId: recipientNodeIdHex,
        ephemeralPublicKey: ephHex,
        messageType: 'TEXT_MESSAGE',
        encryptedPayloadBase64: base64Encode(utf8.encode('Serialization Roundtrip Text')),
        senderKeyPair: senderKeyPair,
      );

      final jsonString = originalPacket.toJson();
      final deserializedPacket = PacketEnvelope.fromJson(jsonString);

      expect(deserializedPacket.toCanonicalString(), equals(originalPacket.toCanonicalString()));
      expect(deserializedPacket.toCanonicalBytes(), equals(originalPacket.toCanonicalBytes()));
      expect(await packetService.validateEnvelope(deserializedPacket), isTrue);
    });

    test('4 & Section 15. Malformed Packet Handling: Malformed JSON or invalid keys fail closed', () async {
      const invalidJson = '{"packet_id": "bad-id", "sender_id": "short"}';
      expect(() => PacketEnvelope.fromJson(invalidJson), throwsA(anything));

      final ephKey = await cryptoService.generateX25519KeyPair();
      final ephHex = await cryptoService.getX25519PublicKeyHex(ephKey);

      final validPacket = await packetService.createEnvelope(
        senderNodeId: senderNodeIdHex,
        recipientNodeId: recipientNodeIdHex,
        ephemeralPublicKey: ephHex,
        messageType: 'TEXT_MESSAGE',
        encryptedPayloadBase64: base64Encode(utf8.encode('Valid Payload')),
        senderKeyPair: senderKeyPair,
      );

      final invalidKeyPacket = validPacket.copyWith(senderId: 'NOT_HEX_KEY');
      expect(
        () async => await packetService.validateEnvelope(invalidKeyPacket),
        throwsA(anything),
      );
    });
  });
}
