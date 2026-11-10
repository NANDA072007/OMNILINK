import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omnilink/core/crypto/crypto_service.dart';
import 'package:omnilink/core/crypto/signed_prekey_manager.dart';
import 'package:omnilink/core/crypto/signed_prekey_record.dart';
import 'package:omnilink/core/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Slice 1B.3 — Signed Pre-Key Lifecycle Unit & Security Tests', () {
    late CryptoService cryptoService;
    late Map<String, String> mockStorageMap;

    setUp(() {
      cryptoService = CryptoService();
      mockStorageMap = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(mockStorageMap);
    });

    Future<IdentityState> waitForIdentity(IdentityNotifier notifier) async {
      int tries = 0;
      while (notifier.state.isLoading && tries < 200) {
        await Future.delayed(const Duration(milliseconds: 10));
        tries++;
      }
      return notifier.state;
    }

    test('1 & 2 & 3. Active SPK exists, corresponds to public key, and persists across restart', () async {
      const storage = FlutterSecureStorage();
      final notifier1 = IdentityNotifier(cryptoService, storage);
      final state1 = await waitForIdentity(notifier1);

      expect(state1.signedPreKeyPair, isNotNull);
      expect(state1.signedPreKeyPublicKeyHex, isNotNull);
      expect(state1.activeSignedKeyBundle, isNotNull);

      // Verify public key corresponds to private key
      final derivedPub = await cryptoService.getX25519PublicKeyHex(state1.signedPreKeyPair!);
      expect(derivedPub, equals(state1.signedPreKeyPublicKeyHex));

      // Re-init notifier (simulating app restart)
      final notifier2 = IdentityNotifier(cryptoService, storage);
      final state2 = await waitForIdentity(notifier2);

      expect(state2.signedPreKeyPublicKeyHex, equals(state1.signedPreKeyPublicKeyHex));
      expect(state2.activeSignedKeyBundle!.signedPreKeyPublicKeyHex, equals(state1.signedPreKeyPublicKeyHex));
    });

    test('4 & 9 & 10. SPK rotation generates new bundle signature while preserving Ed25519 & Static X25519 keys', () async {
      const storage = FlutterSecureStorage();
      final notifier = IdentityNotifier(cryptoService, storage);
      await waitForIdentity(notifier);

      final origNodeId = notifier.state.nodeId;
      final origStaticKeyHex = notifier.state.staticX25519PublicKeyHex;
      final origSpkHex = notifier.state.signedPreKeyPublicKeyHex;
      final origSig = notifier.state.activeSignedKeyBundle!.signature;

      // Rotate SPK
      await notifier.rotateSignedPreKey(force: true);

      final newSpkHex = notifier.state.signedPreKeyPublicKeyHex;
      final newSig = notifier.state.activeSignedKeyBundle!.signature;

      // Identity and Static X25519 MUST REMAIN UNCHANGED
      expect(notifier.state.nodeId, equals(origNodeId));
      expect(notifier.state.staticX25519PublicKeyHex, equals(origStaticKeyHex));

      // SPK and Signature MUST BE NEW
      expect(newSpkHex, isNot(equals(origSpkHex)));
      expect(newSig, isNot(equals(origSig)));

      // New bundle MUST verify cleanly
      final isValid = await cryptoService.verifySignedKeyBundle(notifier.state.activeSignedKeyBundle!);
      expect(isValid, isTrue);
    });

    test('5 & 6 & 11. Old SPK remains available during grace window and is purged after expiration', () async {
      const storage = FlutterSecureStorage();
      final spkManager = SignedPreKeyManager(cryptoService, storage);

      final spk1KeyPair = await spkManager.getOrInitializeActivePreKey();
      final spk1Hex = await cryptoService.getX25519PublicKeyHex(spk1KeyPair);

      // Force rotation to create SPK-2
      final spk2KeyPair = await spkManager.generateAndActivateNewPreKey();
      final spk2Hex = await cryptoService.getX25519PublicKeyHex(spk2KeyPair);

      // SPK-1 MUST still be retrievable from secure storage during grace period
      final retrievedSpk1 = await spkManager.getPreKeyPairById(spk1Hex);
      expect(retrievedSpk1, isNotNull);
      final retrievedSpk1Hex = await cryptoService.getX25519PublicKeyHex(retrievedSpk1!);
      expect(retrievedSpk1Hex, equals(spk1Hex));

      // SPK-2 MUST be active
      final retrievedSpk2 = await spkManager.getPreKeyPairById(spk2Hex);
      expect(retrievedSpk2, isNotNull);

      // Manually manipulate inventory to simulate retention expired (now > retentionUntil)
      final inventory = await spkManager.getInventory();
      final updatedInventory = inventory.map((r) {
        if (r.id == spk1Hex) {
          return r.copyWith(retentionUntil: 1000); // Past timestamp
        }
        return r;
      }).toList();

      // Write manipulated inventory back & purge
      final list = updatedInventory.map((r) => r.toMap()).toList();
      await storage.write(key: 'omnilink_spk_inventory', value: jsonEncode(list));

      // Now run purgeExpiredKeys
      await spkManager.purgeExpiredKeys();

      // SPK-1 seed MUST be purged from secure storage
      final purgedSeed = await storage.read(key: 'omnilink_spk_seed_$spk1Hex');
      expect(purgedSeed, isNull);
    });

    test('12. Crash/Restart preserves consistent active SPK state', () async {
      const storage = FlutterSecureStorage();
      final spkManager = SignedPreKeyManager(cryptoService, storage);

      final activeKey1 = await spkManager.getOrInitializeActivePreKey();
      final activeHex1 = await cryptoService.getX25519PublicKeyHex(activeKey1);

      // Re-initialize manager (simulates restart mid-lifecycle)
      final spkManager2 = SignedPreKeyManager(cryptoService, storage);
      final activeKey2 = await spkManager2.getOrInitializeActivePreKey();
      final activeHex2 = await cryptoService.getX25519PublicKeyHex(activeKey2);

      expect(activeHex2, equals(activeHex1));
    });

    test('13. Startup Reconciliation Case B: Orphaned private seed is recovered into inventory', () async {
      const storage = FlutterSecureStorage();
      final spkManager = SignedPreKeyManager(cryptoService, storage);

      // Generate seed and write directly without inventory
      final orphanKey = await cryptoService.generateX25519KeyPair();
      final orphanPubHex = await cryptoService.getX25519PublicKeyHex(orphanKey);
      final orphanSeed = await cryptoService.extractX25519Seed(orphanKey);

      await storage.write(key: 'omnilink_signed_prekey_x25519_seed', value: orphanSeed.join(','));

      // Run reconciliation
      await spkManager.reconcileInventoryAndActiveState();

      final inventory = await spkManager.getInventory();
      expect(inventory.any((r) => r.id == orphanPubHex), isTrue);
    });

    test('14. Startup Reconciliation Case C: Stale inventory record with missing seed is safely removed', () async {
      const storage = FlutterSecureStorage();
      final spkManager = SignedPreKeyManager(cryptoService, storage);

      final staleRec = SignedPreKeyRecord(
        id: 'stale_id_hex_000',
        publicKeyHex: '00' * 32,
        createdAt: 1000,
        expiresAt: 2000,
        retentionUntil: 3000,
        status: SignedPreKeyStatus.grace,
      );

      await storage.write(key: 'omnilink_spk_inventory', value: jsonEncode([staleRec.toMap()]));

      // Run reconciliation
      await spkManager.reconcileInventoryAndActiveState();

      final inventory = await spkManager.getInventory();
      expect(inventory.any((r) => r.id == 'stale_id_hex_000'), isFalse);
    });

    test('15. Startup Reconciliation Case D: Keypair mismatch FAILS CLOSED', () async {
      const storage = FlutterSecureStorage();
      final spkManager = SignedPreKeyManager(cryptoService, storage);

      final key1 = await cryptoService.generateX25519KeyPair();
      final key1Pub = await cryptoService.getX25519PublicKeyHex(key1);

      // Inventory record has different pubkey than key1Seed
      final corruptRec = SignedPreKeyRecord(
        id: key1Pub,
        publicKeyHex: key1Pub,
        createdAt: 1000,
        expiresAt: 2000,
        retentionUntil: 3000,
        status: SignedPreKeyStatus.active,
      );

      final key2 = await cryptoService.generateX25519KeyPair();
      final key2Seed = await cryptoService.extractX25519Seed(key2); // Mismatched seed!

      await storage.write(key: 'omnilink_spk_inventory', value: jsonEncode([corruptRec.toMap()]));
      await storage.write(key: 'omnilink_spk_seed_$key1Pub', value: key2Seed.join(','));

      // Reconciliation MUST throw CORRUPTED_SPK_KEYPAIR_MISMATCH
      expect(
        () async => await spkManager.reconcileInventoryAndActiveState(),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('CORRUPTED_SPK_KEYPAIR_MISMATCH'))),
      );
    });

    test('16. Startup Reconciliation Case E: Multiple active records resolve to latest createdAt', () async {
      const storage = FlutterSecureStorage();
      final spkManager = SignedPreKeyManager(cryptoService, storage);

      final key1 = await cryptoService.generateX25519KeyPair();
      final key1Pub = await cryptoService.getX25519PublicKeyHex(key1);
      final key1Seed = await cryptoService.extractX25519Seed(key1);

      final key2 = await cryptoService.generateX25519KeyPair();
      final key2Pub = await cryptoService.getX25519PublicKeyHex(key2);
      final key2Seed = await cryptoService.extractX25519Seed(key2);

      final rec1 = SignedPreKeyRecord(
        id: key1Pub,
        publicKeyHex: key1Pub,
        createdAt: 1000,
        expiresAt: 2000,
        retentionUntil: 3000,
        status: SignedPreKeyStatus.active,
      );

      final rec2 = SignedPreKeyRecord(
        id: key2Pub,
        publicKeyHex: key2Pub,
        createdAt: 5000, // Newer record
        expiresAt: 6000,
        retentionUntil: 7000,
        status: SignedPreKeyStatus.active,
      );

      await storage.write(key: 'omnilink_spk_inventory', value: jsonEncode([rec1.toMap(), rec2.toMap()]));
      await storage.write(key: 'omnilink_spk_seed_$key1Pub', value: key1Seed.join(','));
      await storage.write(key: 'omnilink_spk_seed_$key2Pub', value: key2Seed.join(','));

      await spkManager.reconcileInventoryAndActiveState();

      final activeId = await storage.read(key: 'omnilink_active_spk_id');
      expect(activeId, equals(key2Pub)); // Rec2 (newer) must be active
    });

    test('17. Startup Reconciliation Case F: Active SPK private key missing FAILS CLOSED', () async {
      const storage = FlutterSecureStorage();
      final spkManager = SignedPreKeyManager(cryptoService, storage);

      final key1 = await cryptoService.generateX25519KeyPair();
      final key1Pub = await cryptoService.getX25519PublicKeyHex(key1);
      final key1Seed = await cryptoService.extractX25519Seed(key1);

      final activeRec = SignedPreKeyRecord(
        id: key1Pub,
        publicKeyHex: key1Pub,
        createdAt: 1000,
        expiresAt: 2000,
        retentionUntil: 3000,
        status: SignedPreKeyStatus.active,
      );

      await storage.write(key: 'omnilink_spk_inventory', value: jsonEncode([activeRec.toMap()]));
      await storage.write(key: 'omnilink_spk_seed_$key1Pub', value: key1Seed.join(','));
      await storage.write(key: 'omnilink_active_spk_id', value: key1Pub);

      // Now delete active seed
      await storage.delete(key: 'omnilink_spk_seed_$key1Pub');

      // Reconciliation MUST throw UNAVAILABLE_ACTIVE_SPK_PRIVATE_KEY
      expect(
        () async => await spkManager.reconcileInventoryAndActiveState(),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('UNAVAILABLE_ACTIVE_SPK_PRIVATE_KEY'))),
      );
    });
  });
}
