import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../models/packet_envelope.dart';
import 'crypto_service.dart';

/// Exception thrown when packet validation or framing fails.
class PacketValidationException implements Exception {
  final String errorCode;
  final String message;

  PacketValidationException(this.errorCode, this.message);

  @override
  String toString() => 'PacketValidationException($errorCode): $message';
}

/// Service responsible for constructing, signing, validating, and deduplicating
/// OMNILINK Protocol v0.1 JSON packet envelopes.
/// Defined in docs/04_core_communication_engine.md and spec/packets.md.
class PacketService {
  final CryptoService _cryptoService;
  final Uuid _uuid = const Uuid();

  /// In-memory LRU Hash Ring set for duplicate packet detection & replay prevention.
  /// Bounded capacity (default 2,000 recently processed packet IDs).
  final Set<String> _processedPacketIds = {};
  final int _maxCacheSize;
  final List<String> _cacheInsertionOrder = [];

  PacketService({
    required CryptoService cryptoService,
    int maxCacheSize = 2000,
  })  : _cryptoService = cryptoService,
        _maxCacheSize = maxCacheSize;

  // --------------------------------------------------------------------------
  // OUTBOUND PACKET CREATION & SIGNING
  // --------------------------------------------------------------------------

  /// Creates a signed OMNILINK Protocol v0.1 JSON packet envelope.
  Future<PacketEnvelope> createEnvelope({
    required String senderNodeId,
    required String recipientNodeId,
    required String messageType,
    required String encryptedPayloadBase64,
    required SimpleKeyPair senderKeyPair,
    int priority = 1,
    int ttl = 7,
    int maxHops = 7,
    int validityDurationMs = 86400000, // Default 24 hour expiration
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = now + validityDurationMs;
    final packetId = _uuid.v4();

    // 1. Compute SHA-256 hash of encrypted payload string
    final payloadBytes = Uint8List.fromList(utf8.encode(encryptedPayloadBase64));
    final payloadHash = await _cryptoService.sha256Hex(payloadBytes);

    // 2. Construct temporary envelope without signature
    final unsignedEnvelope = PacketEnvelope(
      protocolVersion: '0.1',
      packetId: packetId,
      senderId: senderNodeId,
      recipientId: recipientNodeId,
      createdAt: now,
      expiresAt: expiresAt,
      ttl: ttl,
      hopCount: 0,
      maxHops: maxHops,
      priority: priority,
      messageType: messageType,
      payloadHash: payloadHash,
      signature: '',
      encryptedPayload: encryptedPayloadBase64,
    );

    // 3. Compute Ed25519 signature over canonical digest bytes
    final signatureHex = await _cryptoService.signMessage(
      unsignedEnvelope.toCanonicalBytes(),
      senderKeyPair,
    );

    // 4. Return complete signed envelope
    final signedEnvelope = PacketEnvelope(
      protocolVersion: '0.1',
      packetId: packetId,
      senderId: senderNodeId,
      recipientId: recipientNodeId,
      createdAt: now,
      expiresAt: expiresAt,
      ttl: ttl,
      hopCount: 0,
      maxHops: maxHops,
      priority: priority,
      messageType: messageType,
      payloadHash: payloadHash,
      signature: signatureHex,
      encryptedPayload: encryptedPayloadBase64,
    );

    // 5. Enforce MTU ceiling check (4,096 bytes)
    if (signedEnvelope.exceedsMtuLimit) {
      throw PacketValidationException(
        'INVALID_PACKET_SIZE',
        'Packet size (${signedEnvelope.sizeInBytes} bytes) exceeds 4,096 byte MTU ceiling.',
      );
    }

    return signedEnvelope;
  }

  // --------------------------------------------------------------------------
  // INBOUND PACKET VALIDATION & DEDUPLICATION
  // --------------------------------------------------------------------------

  /// Validates inbound packet envelope for structural integrity, protocol version,
  /// expiration, clock skew, MTU bounds, payload digest match, and Ed25519 signature.
  Future<bool> validateEnvelope(PacketEnvelope envelope) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. Protocol Version Check
    if (envelope.protocolVersion != '0.1') {
      throw PacketValidationException(
        'UNSUPPORTED_PROTOCOL_VERSION',
        'Protocol version "${envelope.protocolVersion}" is not supported.',
      );
    }

    // 2. Expiration Check
    if (now > envelope.expiresAt) {
      throw PacketValidationException(
        'PACKET_EXPIRED',
        'Packet expired at ${envelope.expiresAt} (current time: $now).',
      );
    }

    // 3. Clock Skew Check (reject packets created > 300s in the future)
    const maxClockSkewMs = 300000; // 5 minutes
    if (envelope.createdAt > now + maxClockSkewMs) {
      throw PacketValidationException(
        'CLOCK_SKEW_EXCEEDED',
        'Packet timestamp is in the future beyond allowable threshold.',
      );
    }

    // 4. TTL Check
    if (envelope.ttl <= 0) {
      throw PacketValidationException(
        'TTL_EXHAUSTED',
        'Packet TTL decremented to 0.',
      );
    }

    // 5. MTU Size Check
    if (envelope.exceedsMtuLimit) {
      throw PacketValidationException(
        'INVALID_PACKET_SIZE',
        'Packet size (${envelope.sizeInBytes} bytes) exceeds 4,096 byte ceiling.',
      );
    }

    // 6. Payload Hash Integrity Check
    final payloadBytes = Uint8List.fromList(utf8.encode(envelope.encryptedPayload));
    final expectedHash = await _cryptoService.sha256Hex(payloadBytes);
    if (envelope.payloadHash != expectedHash) {
      throw PacketValidationException(
        'PAYLOAD_HASH_MISMATCH',
        'Payload hash does not match computed SHA-256 digest.',
      );
    }

    // 7. Ed25519 Digital Signature Verification
    final isValidSignature = await _cryptoService.verifySignature(
      message: envelope.toCanonicalBytes(),
      signatureHex: envelope.signature,
      publicKeyHex: envelope.senderId,
    );

    if (!isValidSignature) {
      throw PacketValidationException(
        'INVALID_SIGNATURE',
        'Ed25519 signature verification failed.',
      );
    }

    return true;
  }

  /// Checks whether a packet ID has recently been processed.
  bool isDuplicate(String packetId) {
    return _processedPacketIds.contains(packetId);
  }

  /// Marks a packet ID as processed in the LRU deduplication cache ring buffer.
  void markProcessed(String packetId) {
    if (_processedPacketIds.contains(packetId)) return;

    if (_processedPacketIds.length >= _maxCacheSize) {
      final oldestId = _cacheInsertionOrder.removeAt(0);
      _processedPacketIds.remove(oldestId);
    }

    _processedPacketIds.add(packetId);
    _cacheInsertionOrder.add(packetId);
  }

  /// Clears the in-memory deduplication cache.
  void clearDeduplicationCache() {
    _processedPacketIds.clear();
    _cacheInsertionOrder.clear();
  }
}
