import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:omnilink/core/crypto/crypto_service.dart';
import 'package:omnilink/core/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Slice 1B.1 — Crypto Key Architecture Unit Tests', () {
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

    test('1. First installation generates all required independent keys', () async {
      const storage = FlutterSecureStorage();
      final notifier = IdentityNotifier(cryptoService, storage);
      final state = await waitForIdentity(notifier);

      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
      expect(state.masterKeyPair, isNotNull);
      expect(state.staticX25519KeyPair, isNotNull);
      expect(state.signedPreKeyPair, isNotNull);
      expect(state.nodeId, isNotNull);
      expect(state.nodeId!.length, equals(64));
      expect(state.staticX25519PublicKeyHex, isNotNull);
      expect(state.staticX25519PublicKeyHex!.length, equals(64));
      expect(state.signedPreKeyPublicKeyHex, isNotNull);
      expect(state.signedPreKeyPublicKeyHex!.length, equals(64));
    });

    test('2 & 3 & 4 & 5. Second initialization loads identical persisted keys', () async {
      const storage = FlutterSecureStorage();
      final notifier1 = IdentityNotifier(cryptoService, storage);
      final state1 = await waitForIdentity(notifier1);

      final notifier2 = IdentityNotifier(cryptoService, storage);
      final state2 = await waitForIdentity(notifier2);

      expect(state2.nodeId, equals(state1.nodeId));
      expect(state2.staticX25519PublicKeyHex, equals(state1.staticX25519PublicKeyHex));
      expect(state2.signedPreKeyPublicKeyHex, equals(state1.signedPreKeyPublicKeyHex));
    });

    test('6. Ed25519 and X25519 key material are mathematically independent', () async {
      const storage = FlutterSecureStorage();
      final notifier = IdentityNotifier(cryptoService, storage);
      final state = await waitForIdentity(notifier);

      // Ensure public keys are distinct strings
      expect(state.nodeId, isNot(equals(state.staticX25519PublicKeyHex)));
      expect(state.nodeId, isNot(equals(state.signedPreKeyPublicKeyHex)));
      expect(state.staticX25519PublicKeyHex, isNot(equals(state.signedPreKeyPublicKeyHex)));

      // Verify key types
      final edPub = await state.masterKeyPair!.extractPublicKey();
      final xStaticPub = await state.staticX25519KeyPair!.extractPublicKey();
      final xSpkPub = await state.signedPreKeyPair!.extractPublicKey();

      expect(edPub.type.name, equals('ed25519'));
      expect(xStaticPub.type.name, equals('x25519'));
      expect(xSpkPub.type.name, equals('x25519'));
    });

    test('7. Public keys correspond directly to stored private key seeds', () async {
      const storage = FlutterSecureStorage();
      final notifier = IdentityNotifier(cryptoService, storage);
      final state = await waitForIdentity(notifier);

      // Extract seeds and recreate keypairs
      final edSeed = await cryptoService.extractEd25519Seed(state.masterKeyPair!);
      final restoredEd = await cryptoService.restoreEd25519KeyPair(edSeed);
      final restoredNodeId = await cryptoService.getEd25519PublicKeyHex(restoredEd);
      expect(restoredNodeId, equals(state.nodeId));

      final xSeed = await cryptoService.extractX25519Seed(state.staticX25519KeyPair!);
      final restoredX = await cryptoService.restoreX25519KeyPair(xSeed);
      final restoredXPub = await cryptoService.getX25519PublicKeyHex(restoredX);
      expect(restoredXPub, equals(state.staticX25519PublicKeyHex));
    });

    test('8. Missing X25519 key can be generated without changing Ed25519 identity (Backward Compatibility)', () async {
      const storage = FlutterSecureStorage();

      // Simulate legacy installation: ONLY omnilink_master_ed25519_seed exists in storage
      final legacyKeyPair = await cryptoService.generateEd25519KeyPair();
      final legacySeed = await cryptoService.extractEd25519Seed(legacyKeyPair);
      final legacyNodeId = await cryptoService.getEd25519PublicKeyHex(legacyKeyPair);

      await storage.write(
        key: 'omnilink_master_ed25519_seed',
        value: legacySeed.join(','),
      );

      // Now launch IdentityNotifier
      final notifier = IdentityNotifier(cryptoService, storage);
      final state = await waitForIdentity(notifier);

      // Identity MUST match legacyNodeId
      expect(state.nodeId, equals(legacyNodeId));

      // X25519 keys must be populated freshly
      expect(state.staticX25519PublicKeyHex, isNotNull);
      expect(state.signedPreKeyPublicKeyHex, isNotNull);
    });

    test('9. Malformed identity seed fails safely (Fail-Closed)', () async {
      const storage = FlutterSecureStorage();

      // Write corrupted seed (length != 32)
      await storage.write(
        key: 'omnilink_master_ed25519_seed',
        value: '1,2,3,4,5',
      );

      final notifier = IdentityNotifier(cryptoService, storage);
      final state = await waitForIdentity(notifier);

      expect(state.isLoading, isFalse);
      expect(state.error, isNotNull);
      expect(state.error, contains('CORRUPTED_IDENTITY_SEED'));
      expect(state.masterKeyPair, isNull);
    });
  });
}
