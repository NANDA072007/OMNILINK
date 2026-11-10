import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../database/database_service.dart';
import '../models/packet_envelope.dart';
import 'crypto_service.dart';
import 'signed_prekey_manager.dart';

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
  final DatabaseService? _dbService;
  final Uuid _uuid = const Uuid();

  /// In-memory LRU Hash Ring set for duplicate packet detection & replay prevention.
  /// Bounded capacity (default 2,000 recently processed packet IDs).
  final Set<String> _processedPacketIds = {};
  final int _maxCacheSize;
  final List<String> _cacheInsertionOrder = [];

  PacketService({
    required CryptoService cryptoService,
    DatabaseService? dbService,
    int maxCacheSize = 2000,
  })  : _cryptoService = cryptoService,
        _dbService = dbService,
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
    String? ephemeralPublicKey,
    String? packetId,
    int priority = 1,
    int ttl = 7,
    int maxHops = 7,
    int validityDurationMs = 86400000, // Default 24 hour expiration
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = now + validityDurationMs;
    final id = packetId ?? _uuid.v4();

    // 1. Compute SHA-256 hash of encrypted payload string
    final payloadBytes = Uint8List.fromList(utf8.encode(encryptedPayloadBase64));
    final payloadHash = await _cryptoService.sha256Hex(payloadBytes);

    // 2. Construct temporary envelope without signature
    final unsignedEnvelope = PacketEnvelope(
      protocolVersion: '0.1',
      packetId: id,
      senderId: senderNodeId,
      recipientId: recipientNodeId,
      ephemeralPublicKey: ephemeralPublicKey,
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
      packetId: id,
      senderId: senderNodeId,
      recipientId: recipientNodeId,
      ephemeralPublicKey: ephemeralPublicKey,
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

  /// Builds a signed control-plane envelope (routing metadata, sync summaries,
  /// delivery receipts).
  ///
  /// Control payloads are authenticated but intentionally not confidential:
  /// routing metadata must be readable by relays. Confidentiality for user
  /// payloads is handled by [createEncryptedMessageEnvelope].
  Future<PacketEnvelope> createSignedControlEnvelope({
    required String senderNodeId,
    required SimpleKeyPair senderKeyPair,
    required String recipientNodeId,
    required String messageType,
    required String payloadJson,
    required String packetId,
    int ttl = 1,
    int maxHops = 1,
    int priority = 0,
    Duration validity = const Duration(minutes: 5),
  }) {
    return createEnvelope(
      senderNodeId: senderNodeId,
      recipientNodeId: recipientNodeId,
      messageType: messageType,
      encryptedPayloadBase64: payloadJson,
      senderKeyPair: senderKeyPair,
      packetId: packetId,
      ttl: ttl,
      maxHops: maxHops,
      priority: priority,
      validityDurationMs: validity.inMilliseconds,
    );
  }

  // --------------------------------------------------------------------------
  // INBOUND PACKET VALIDATION & DEDUPLICATION
  // --------------------------------------------------------------------------

  /// Validates inbound packet envelope for structural integrity, protocol version,
  /// expiration, clock skew, MTU bounds, payload digest match, Ed25519 signature,
  /// and replay protection (RAM LRU + SQLite processed_packets).
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

    // 6 & 7. Parallel Isolate Offloading for Payload Hash Integrity & Ed25519 Signature Verification
    final payloadBytes = Uint8List.fromList(utf8.encode(envelope.encryptedPayload));
    final canonicalBytes = envelope.toCanonicalBytes();

    final results = await Future.wait([
      _cryptoService.sha256Hex(payloadBytes),
      _cryptoService.verifySignature(
        message: canonicalBytes,
        signatureHex: envelope.signature,
        publicKeyHex: envelope.senderId,
      ),
    ]);

    final expectedHash = results[0] as String;
    final isValidSignature = results[1] as bool;

    if (envelope.payloadHash != expectedHash) {
      throw PacketValidationException(
        'PAYLOAD_HASH_MISMATCH',
        'Payload hash does not match computed SHA-256 digest.',
      );
    }

    if (!isValidSignature) {
      throw PacketValidationException(
        'INVALID_SIGNATURE',
        'Ed25519 signature verification failed.',
      );
    }

    // 8. Replay Check (RAM LRU -> SQLite) after Cryptographic Authentication
    if (await isDuplicate(envelope.packetId)) {
      throw PacketValidationException(
        'DUPLICATE_PACKET',
        'Packet "${envelope.packetId}" has already been processed (replay detected).',
      );
    }

    return true;
  }

  /// Checks whether a packet ID has been processed in RAM LRU cache OR SQLite store.
  Future<bool> isDuplicate(String packetId) async {
    if (_processedPacketIds.contains(packetId)) {
      return true;
    }
    if (_dbService != null) {
      final isDbProcessed = await _dbService!.isPacketProcessed(packetId);
      if (isDbProcessed) {
        markProcessed(packetId);
        return true;
      }
    }
    return false;
  }

  /// Synchronously checks whether a packet ID exists in the in-memory RAM LRU cache.
  bool isDuplicateInRam(String packetId) {
    return _processedPacketIds.contains(packetId);
  }

  /// Atomically claims a packet as processed in SQLite and RAM LRU cache.
  /// Throws PacketValidationException('DUPLICATE_PACKET') if already claimed.
  Future<void> claimProcessedPacket(PacketEnvelope envelope) async {
    final packetId = envelope.packetId;

    if (_processedPacketIds.contains(packetId)) {
      throw PacketValidationException(
        'DUPLICATE_PACKET',
        'Packet $packetId already claimed in RAM deduplication cache.',
      );
    }

    if (_dbService != null) {
      final claimed = await _dbService!.claimPacketProcessed(
        packetId: packetId,
        senderId: envelope.senderId,
        createdAt: envelope.createdAt,
        expiresAt: envelope.expiresAt,
      );

      if (!claimed) {
        markProcessed(packetId);
        throw PacketValidationException(
          'DUPLICATE_PACKET',
          'Packet $packetId already claimed in SQLite persistent store.',
        );
      }
    }

    markProcessed(packetId);
  }

  /// Validates inbound envelope AND atomically claims it in persistent replay table.
  Future<bool> validateAndClaimEnvelope(PacketEnvelope envelope) async {
    final isValid = await validateEnvelope(envelope);
    if (!isValid) return false;
    await claimProcessedPacket(envelope);
    return true;
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

  /// Returns an unmodifiable set of all recently processed packet IDs.
  Set<String> getProcessedPacketIds() {
    return Set.unmodifiable(_processedPacketIds);
  }

  /// Returns the RAM replay cache merged with the persistent SQLite replay
  /// table. Anti-entropy must use this: the RAM cache is empty after restart.
  Future<Set<String>> getProcessedPacketIdsFromStore({int limit = 10000}) async {
    final ids = <String>{..._processedPacketIds};
    final dbService = _dbService;
    if (dbService != null) {
      try {
        final persisted = await dbService.getProcessedPacketIds(
          limit: limit,
          notExpiredAfter: DateTime.now().millisecondsSinceEpoch,
        );
        ids.addAll(persisted);
      } catch (_) {
        // Fall back to the RAM cache if the replay table is unavailable.
      }
    }
    return ids;
  }

  /// Clears the in-memory deduplication cache.
  void clearDeduplicationCache() {
    _processedPacketIds.clear();
    _cacheInsertionOrder.clear();
  }

  // --------------------------------------------------------------------------
  // END-TO-END CRYPTOGRAPHIC MESSAGE ENCRYPTION & DECRYPTION
  // --------------------------------------------------------------------------

  /// End-to-End Cryptographic Message Envelope Creation for Outbound Messages.
  /// Uses Dual-ECDH + HKDF-SHA256 key agreement and ChaCha20-Poly1305 AEAD payload encryption.
  /// Ephemeral private key is generated fresh per message and destroyed immediately after encryption.
  Future<PacketEnvelope> createEncryptedMessageEnvelope({
    required String senderNodeId,
    required SimpleKeyPair senderKeyPair,
    required SimpleKeyPair senderStaticX25519KeyPair,
    required String recipientNodeId,
    required String recipientStaticX25519PublicKeyHex,
    required String plaintextBody,
    String? packetId,
    String messageType = 'MESSAGE_PAYLOAD',
  }) async {
    // 1. Generate fresh ephemeral X25519 keypair EA for this message
    final ephemeralKeyPair = await _cryptoService.generateX25519KeyPair();
    final ephemeralPublicKeyHex = await _cryptoService.getX25519PublicKeyHex(ephemeralKeyPair);

    // 2. Derive Dual-ECDH K_msg for sender
    final messageKey = await _cryptoService.deriveSenderMessageKey(
      ephemeralKeyPair: ephemeralKeyPair,
      staticX25519KeyPair: senderStaticX25519KeyPair,
      aliceEd25519PublicKeyHex: senderNodeId,
      bobTargetPublicKeyHex: recipientStaticX25519PublicKeyHex,
    );

    // 3. Encrypt plaintext body using ChaCha20-Poly1305 AEAD
    final plaintextBytes = Uint8List.fromList(utf8.encode(plaintextBody));
    final encryptedPayloadBase64 = await _cryptoService.encryptPayload(
      plaintext: plaintextBytes,
      secretKey: messageKey,
    );

    // 4. Construct signed packet envelope including ephemeralPublicKey
    final envelope = await createEnvelope(
      senderNodeId: senderNodeId,
      recipientNodeId: recipientNodeId,
      messageType: messageType,
      encryptedPayloadBase64: encryptedPayloadBase64,
      senderKeyPair: senderKeyPair,
      ephemeralPublicKey: ephemeralPublicKeyHex,
      packetId: packetId,
    );

    return envelope;
  }

  /// End-to-End Cryptographic Message Decryption for Inbound Envelopes.
  /// Performs Dual-ECDH key derivation and ChaCha20-Poly1305 AEAD decryption.
  /// Supports current active pre-key as well as grace pre-keys for DTN delivery.
  Future<String> decryptMessageEnvelope({
    required PacketEnvelope envelope,
    required SimpleKeyPair recipientStaticKeyPair,
    required SignedPreKeyManager spkManager,
    String? senderStaticX25519PublicKeyHex,
  }) async {
    final ephHex = envelope.ephemeralPublicKey;
    if (ephHex == null || ephHex.isEmpty) {
      throw PacketValidationException(
        'MISSING_EPHEMERAL_KEY',
        'Inbound envelope "${envelope.packetId}" is missing required ephemeral public key for Dual-ECDH.',
      );
    }

    final senderStaticX2519Hex = senderStaticX25519PublicKeyHex ?? envelope.senderId;

    // 1. Attempt decryption using recipient's static X25519 KeyPair
    try {
      final messageKey = await _cryptoService.deriveRecipientMessageKey(
        bobTargetKeyPair: recipientStaticKeyPair,
        aliceEphemeralPublicKeyHex: ephHex,
        aliceStaticX25519PublicKeyHex: senderStaticX2519Hex,
        aliceEd25519PublicKeyHex: envelope.senderId,
        bobTargetPublicKeyHex: await _cryptoService.getX25519PublicKeyHex(recipientStaticKeyPair),
      );

      final decryptedBytes = await _cryptoService.decryptPayload(
        base64Payload: envelope.encryptedPayload,
        secretKey: messageKey,
      );
      return utf8.decode(decryptedBytes);
    } catch (_) {}

    // 2. Fallback: Search inventory for active & grace SPKs
    final inventory = await spkManager.getInventory();
    for (final record in inventory) {
      final spkKeyPair = await spkManager.getPreKeyPairById(record.id);
      if (spkKeyPair == null) continue;

      try {
        final messageKey = await _cryptoService.deriveRecipientMessageKey(
          bobTargetKeyPair: spkKeyPair,
          aliceEphemeralPublicKeyHex: ephHex,
          aliceStaticX25519PublicKeyHex: senderStaticX2519Hex,
          aliceEd25519PublicKeyHex: envelope.senderId,
          bobTargetPublicKeyHex: record.publicKeyHex,
        );

        final decryptedBytes = await _cryptoService.decryptPayload(
          base64Payload: envelope.encryptedPayload,
          secretKey: messageKey,
        );
        return utf8.decode(decryptedBytes);
      } catch (_) {}
    }

    throw PacketValidationException(
      'AEAD_DECRYPTION_FAILED',
      'AEAD decryption failed for packet "${envelope.packetId}". Invalid key or corrupted payload.',
    );
  }
}
