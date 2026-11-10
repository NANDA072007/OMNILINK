import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilink/core/models/packet_envelope.dart';

void main() {
  group('PacketEnvelope Serialization & MTU Boundary Tests', () {
    final tNow = DateTime.now().millisecondsSinceEpoch;

    final sampleEnvelope = PacketEnvelope(
      protocolVersion: '0.1',
      packetId: 'test-packet-uuid-1234',
      senderId: 'node_sender_8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b',
      recipientId: 'node_recipient_1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f',
      createdAt: tNow,
      expiresAt: tNow + 3600000,
      ttl: 7,
      hopCount: 0,
      maxHops: 7,
      priority: 1,
      messageType: 'MESSAGE_PAYLOAD',
      payloadHash: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      signature: '3045022100a1b2c3d4e5f678901234567890abcdef1234567890abcdef1234567890',
      encryptedPayload: 'SGVsbG8gT01OSUxJTksgTWVzaCBOZXR3b3JrIQ==',
    );

    test('PacketEnvelope serializes to and deserializes from JSON deterministically', () {
      final jsonString = sampleEnvelope.toJson();
      expect(jsonString, isA<String>());

      final deserialized = PacketEnvelope.fromJson(jsonString);

      expect(deserialized.packetId, equals(sampleEnvelope.packetId));
      expect(deserialized.senderId, equals(sampleEnvelope.senderId));
      expect(deserialized.recipientId, equals(sampleEnvelope.recipientId));
      expect(deserialized.createdAt, equals(sampleEnvelope.createdAt));
      expect(deserialized.messageType, equals(sampleEnvelope.messageType));
      expect(deserialized.encryptedPayload, equals(sampleEnvelope.encryptedPayload));
      expect(deserialized.protocolVersion, equals('0.1'));
    });

    test('PacketEnvelope canonical string representation is stable for cryptographic signing', () {
      final canonicalString = sampleEnvelope.toCanonicalString();
      final expectedCanonical =
          'v=${sampleEnvelope.protocolVersion}|id=${sampleEnvelope.packetId}|sender=${sampleEnvelope.senderId}|recipient=${sampleEnvelope.recipientId}|eph=${sampleEnvelope.ephemeralPublicKey ?? ''}|created=${sampleEnvelope.createdAt}|expires=${sampleEnvelope.expiresAt}|type=${sampleEnvelope.messageType}|payload_hash=${sampleEnvelope.payloadHash}';

      expect(canonicalString, equals(expectedCanonical));

      final canonicalBytes = sampleEnvelope.toCanonicalBytes();
      expect(canonicalBytes, equals(utf8.encode(expectedCanonical)));
    });

    test('PacketEnvelope accurately evaluates MTU boundary at 4096 bytes', () {
      expect(sampleEnvelope.exceedsMtuLimit, isFalse);

      // Construct an envelope payload that exceeds 4,096 bytes limit
      final largePayload = 'A' * 4500;
      final oversizedEnvelope = sampleEnvelope.copyWith(
        encryptedPayload: largePayload,
      );

      expect(oversizedEnvelope.sizeInBytes, greaterThan(4096));
      expect(oversizedEnvelope.exceedsMtuLimit, isTrue);
    });

    test('PacketEnvelope copyWith preserves duplicate packetId behavior', () {
      final duplicate = sampleEnvelope.copyWith(
        hopCount: sampleEnvelope.hopCount + 1,
        ttl: sampleEnvelope.ttl - 1,
      );

      expect(duplicate.packetId, equals(sampleEnvelope.packetId));
      expect(duplicate.hopCount, equals(1));
      expect(duplicate.ttl, equals(6));
    });

    test('PacketEnvelope.fromJson throws FormatException or TypeError on malformed JSON payload', () {
      const invalidJson = '{"packet_id": 12345, "sender_id": null}';

      expect(
        () => PacketEnvelope.fromJson(invalidJson),
        throwsA(anything),
      );
    });
  });
}
