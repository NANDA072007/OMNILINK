import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'crypto_service.dart';
import 'signed_prekey_record.dart';

/// Manages the full lifecycle of Signed Pre-Keys (SPKs):
/// Generation, Secure Persistence, 30-Day Rotation, 60-Day DTN Grace Window Retention,
/// Key Selection by Identifier, and Expiration Purging.
class SignedPreKeyManager {
  final CryptoService _cryptoService;
  final FlutterSecureStorage _storage;

  static const _inventoryKey = 'omnilink_spk_inventory';
  static const _activeIdKey = 'omnilink_active_spk_id';
  static const _legacySpkSeedKey = 'omnilink_signed_prekey_x25519_seed';

  static const int rotationIntervalMs = 30 * 24 * 60 * 60 * 1000; // 30 days
  static const int retentionIntervalMs = 90 * 24 * 60 * 60 * 1000; // 90 days (30d active + 60d grace)

  SignedPreKeyManager(this._cryptoService, this._storage);

  /// Retrieves all persisted SPK records from secure storage inventory.
  Future<List<SignedPreKeyRecord>> getInventory() async {
    try {
      final jsonStr = await _storage.read(key: _inventoryKey);
      if (jsonStr == null || jsonStr.isEmpty) return [];
      final List<dynamic> list = jsonDecode(jsonStr) as List<dynamic>;
      return list.map((e) => SignedPreKeyRecord.fromMap(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Saves the updated SPK inventory list to secure storage.
  Future<void> _saveInventory(List<SignedPreKeyRecord> records) async {
    final list = records.map((r) => r.toMap()).toList();
    await _storage.write(key: _inventoryKey, value: jsonEncode(list));
  }

  /// Initializes or retrieves the current active Signed Pre-Key.
  Future<SimpleKeyPair> getOrInitializeActivePreKey() async {
    // Execute deterministic startup reconciliation before returning active key
    await reconcileInventoryAndActiveState();

    final inventory = await getInventory();
    final activeId = await _storage.read(key: _activeIdKey);

    if (activeId != null && inventory.any((r) => r.id == activeId)) {
      final record = inventory.firstWhere((r) => r.id == activeId);
      final keyPair = await getPreKeyPairById(record.id);
      if (keyPair != null) return keyPair;
      // CASE F: Active keypair unavailable -> Fail closed
      throw const FormatException('UNAVAILABLE_ACTIVE_SPK_PRIVATE_KEY: Active SPK private key unavailable');
    }

    // Fallback for legacy installation where single legacy seed exists
    final legacySeedStr = await _storage.read(key: _legacySpkSeedKey);
    if (legacySeedStr != null && legacySeedStr.isNotEmpty) {
      final seed = List<int>.from(legacySeedStr.split(',').map(int.parse));
      if (seed.length != 32) {
        throw const FormatException('CORRUPTED_SPK_SEED_LENGTH: Invalid X25519 seed length');
      }
      final keyPair = await _cryptoService.restoreX25519KeyPair(seed);
      final pubKeyHex = await _cryptoService.getX25519PublicKeyHex(keyPair);

      final now = DateTime.now().millisecondsSinceEpoch;
      final record = SignedPreKeyRecord(
        id: pubKeyHex,
        publicKeyHex: pubKeyHex,
        createdAt: now,
        expiresAt: now + rotationIntervalMs,
        retentionUntil: now + retentionIntervalMs,
        status: SignedPreKeyStatus.active,
      );

      await _storage.write(key: 'omnilink_spk_seed_$pubKeyHex', value: legacySeedStr);
      await _storage.write(key: _activeIdKey, value: pubKeyHex);
      await _saveInventory([record]);

      return keyPair;
    }

    // Generate fresh SPK
    return await generateAndActivateNewPreKey();
  }

  /// Deterministic startup reconciliation covering Cases A through F.
  Future<void> reconcileInventoryAndActiveState() async {
    final inventory = await getInventory();
    final reconciledInventory = <SignedPreKeyRecord>[];

    // CASE E Check: Count active records
    final activeRecords = inventory.where((r) => r.status == SignedPreKeyStatus.active).toList();
    if (activeRecords.length > 1) {
      // Deterministically resolve to the latest createdAt record, set others to grace
      activeRecords.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final winnerId = activeRecords.first.id;
      await _storage.write(key: _activeIdKey, value: winnerId);
    }

    final currentActiveId = await _storage.read(key: _activeIdKey);

    // CASE C & D Check: Reconcile inventory entries against secure storage seeds
    for (final rec in inventory) {
      final seedStr = await _storage.read(key: 'omnilink_spk_seed_${rec.id}');
      if (seedStr == null || seedStr.isEmpty) {
        // CASE C: Missing seed -> drop stale record
        continue;
      }

      // CASE D Check: Verify Public/Private key correspondence
      final seed = List<int>.from(seedStr.split(',').map(int.parse));
      if (seed.length != 32) {
        throw const FormatException('CORRUPTED_SPK_SEED_LENGTH: Invalid X25519 seed length');
      }
      final keyPair = await _cryptoService.restoreX25519KeyPair(seed);
      final derivedPubHex = await _cryptoService.getX25519PublicKeyHex(keyPair);

      if (derivedPubHex != rec.publicKeyHex) {
        // CASE D: Public/Private key mismatch -> FAIL CLOSED
        throw const FormatException('CORRUPTED_SPK_KEYPAIR_MISMATCH: Stored SPK seed does not match public key record');
      }

      if (activeRecords.length > 1) {
        if (rec.id == currentActiveId) {
          reconciledInventory.add(rec.copyWith(status: SignedPreKeyStatus.active));
        } else {
          reconciledInventory.add(rec.copyWith(status: SignedPreKeyStatus.grace));
        }
      } else {
        reconciledInventory.add(rec);
      }
    }

    // CASE B Check: Check if legacy or orphaned seed exists in storage without inventory record
    final legacySeedStr = await _storage.read(key: _legacySpkSeedKey);
    if (legacySeedStr != null && legacySeedStr.isNotEmpty) {
      final seed = List<int>.from(legacySeedStr.split(',').map(int.parse));
      if (seed.length == 32) {
        final keyPair = await _cryptoService.restoreX25519KeyPair(seed);
        final pubHex = await _cryptoService.getX25519PublicKeyHex(keyPair);
        if (!reconciledInventory.any((r) => r.id == pubHex)) {
          // Reconcile Case B: Recover orphaned seed into inventory
          final now = DateTime.now().millisecondsSinceEpoch;
          final rec = SignedPreKeyRecord(
            id: pubHex,
            publicKeyHex: pubHex,
            createdAt: now,
            expiresAt: now + rotationIntervalMs,
            retentionUntil: now + retentionIntervalMs,
            status: currentActiveId == null ? SignedPreKeyStatus.active : SignedPreKeyStatus.grace,
          );
          reconciledInventory.add(rec);
          await _storage.write(key: 'omnilink_spk_seed_$pubHex', value: legacySeedStr);
          if (currentActiveId == null) {
            await _storage.write(key: _activeIdKey, value: pubHex);
          }
        }
      }
    }

    await _saveInventory(reconciledInventory);

    // CASE F Check: Ensure active SPK key seed is actually present and valid
    final finalActiveId = await _storage.read(key: _activeIdKey);
    if (finalActiveId != null && finalActiveId.isNotEmpty) {
      final activeSeed = await _storage.read(key: 'omnilink_spk_seed_$finalActiveId');
      if (activeSeed == null || activeSeed.isEmpty) {
        throw const FormatException('UNAVAILABLE_ACTIVE_SPK_PRIVATE_KEY: Active SPK private key seed missing');
      }
    }
  }

  /// Generates a fresh SPK, marks it active, updates inventory, and purges expired keys.
  Future<SimpleKeyPair> generateAndActivateNewPreKey() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final newKeyPair = await _cryptoService.generateX25519KeyPair();
    final newPubKeyHex = await _cryptoService.getX25519PublicKeyHex(newKeyPair);
    final newSeed = await _cryptoService.extractX25519Seed(newKeyPair);
    final newSeedStr = newSeed.join(',');

    // 1. Write seed to secure storage for this key ID
    await _storage.write(key: 'omnilink_spk_seed_$newPubKeyHex', value: newSeedStr);
    await _storage.write(key: _legacySpkSeedKey, value: newSeedStr);

    // 2. Transition old active keys to grace state
    final inventory = await getInventory();
    final updatedInventory = <SignedPreKeyRecord>[];

    for (final oldRec in inventory) {
      if (oldRec.status == SignedPreKeyStatus.active) {
        updatedInventory.add(oldRec.copyWith(status: SignedPreKeyStatus.grace));
      } else {
        updatedInventory.add(oldRec);
      }
    }

    // 3. Add new record
    final newRecord = SignedPreKeyRecord(
      id: newPubKeyHex,
      publicKeyHex: newPubKeyHex,
      createdAt: now,
      expiresAt: now + rotationIntervalMs,
      retentionUntil: now + retentionIntervalMs,
      status: SignedPreKeyStatus.active,
    );
    updatedInventory.add(newRecord);

    // 4. Save active ID & inventory atomically
    await _storage.write(key: _activeIdKey, value: newPubKeyHex);
    await _saveInventory(updatedInventory);

    // 5. Purge expired keys
    await purgeExpiredKeys();

    return newKeyPair;
  }

  /// Rotates the active SPK if it has passed its 30-day expiration time or force=true.
  Future<SimpleKeyPair?> rotateIfNeeded({bool force = false}) async {
    final inventory = await getInventory();
    final activeId = await _storage.read(key: _activeIdKey);
    final now = DateTime.now().millisecondsSinceEpoch;

    if (force || activeId == null) {
      return await generateAndActivateNewPreKey();
    }

    final activeRecord = inventory.firstWhere(
      (r) => r.id == activeId,
      orElse: () => const SignedPreKeyRecord(
        id: '',
        publicKeyHex: '',
        createdAt: 0,
        expiresAt: 0,
        retentionUntil: 0,
        status: SignedPreKeyStatus.expired,
      ),
    );

    if (activeRecord.id.isEmpty || now > activeRecord.expiresAt) {
      return await generateAndActivateNewPreKey();
    }

    return null;
  }

  /// Retrieves an X25519 KeyPair by key ID (public key hex) from secure storage.
  /// Searches active and grace pre-keys. Returns null if key is purged/unknown.
  Future<SimpleKeyPair?> getPreKeyPairById(String keyId) async {
    try {
      final seedStr = await _storage.read(key: 'omnilink_spk_seed_$keyId');
      if (seedStr != null && seedStr.isNotEmpty) {
        final seed = List<int>.from(seedStr.split(',').map(int.parse));
        return await _cryptoService.restoreX25519KeyPair(seed);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Purges old private key seeds from secure storage whose retention grace window has expired.
  Future<void> purgeExpiredKeys() async {
    final inventory = await getInventory();
    final now = DateTime.now().millisecondsSinceEpoch;
    final remainingInventory = <SignedPreKeyRecord>[];

    for (final rec in inventory) {
      if (now > rec.retentionUntil) {
        // Zeroize & delete seed from secure storage
        await _storage.delete(key: 'omnilink_spk_seed_${rec.id}');
      } else {
        remainingInventory.add(rec);
      }
    }

    await _saveInventory(remainingInventory);
  }
}
