import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:omnilink/core/crypto/safety_number_generator.dart';
import 'package:omnilink/core/identity/trust_store.dart';
import 'package:omnilink/core/database/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUp(() async {
    final db = await DatabaseService.instance.database;
    await db.execute('CREATE TABLE IF NOT EXISTS identity_trust (node_id TEXT PRIMARY KEY, trust_state TEXT NOT NULL, verified_at INTEGER, verified_method TEXT, key_fingerprint TEXT NOT NULL, revoked_at INTEGER);');
    await db.execute('DELETE FROM identity_trust;');
  });

  group('Safety Number Generator & Trust Store Tests', () {
    const keyA = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';
    const keyB = 'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5';
    const keyC = '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff';

    test('safety number is stable for same keypair regardless of ordering', () {
      final num1 = SafetyNumberGenerator.generateSafetyNumber(
        localPublicKeyHex: keyA,
        remotePublicKeyHex: keyB,
      );

      final num2 = SafetyNumberGenerator.generateSafetyNumber(
        localPublicKeyHex: keyB,
        remotePublicKeyHex: keyA,
      );

      expect(num1, equals(num2));
      expect(num1.split(' ').length, equals(12));
    });

    test('safety number changes when remote key changes', () {
      final numAB = SafetyNumberGenerator.generateSafetyNumber(
        localPublicKeyHex: keyA,
        remotePublicKeyHex: keyB,
      );

      final numAC = SafetyNumberGenerator.generateSafetyNumber(
        localPublicKeyHex: keyA,
        remotePublicKeyHex: keyC,
      );

      expect(numAB, isNot(equals(numAC)));
    });

    test('key fingerprint calculation is deterministic and 16 characters long', () {
      final fpB1 = SafetyNumberGenerator.computeFingerprint(keyB);
      final fpB2 = SafetyNumberGenerator.computeFingerprint(keyB);

      expect(fpB1, equals(fpB2));
      expect(fpB1.length, equals(16));
    });

    test('trust state persists and key change produces KEY_CHANGED_SINCE_VERIFICATION warning', () async {
      final fpB = SafetyNumberGenerator.computeFingerprint(keyB);
      final fpC = SafetyNumberGenerator.computeFingerprint(keyC);

      final testDbService = DatabaseService();
      final store = TrustStore(dbService: testDbService);
      await store.initTable();

      // 1. Initial unverified check
      var record = await store.getTrustRecord(keyB, fpB);
      expect(record.trustState, equals(TrustState.unverified));

      // 2. Verify contact
      await store.verifyContact(keyB, fpB, viaQr: true);
      record = await store.getTrustRecord(keyB, fpB);
      expect(record.trustState, equals(TrustState.verifiedQr));

      // 3. Contact presents a new public key fingerprint (Key Change Attack / MITM)
      record = await store.getTrustRecord(keyB, fpC);
      expect(record.trustState, equals(TrustState.keyChangedSinceVerification));
    });
  });
}
