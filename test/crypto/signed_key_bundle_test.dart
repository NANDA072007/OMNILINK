import 'package:flutter_test/flutter_test.dart';
import 'package:omnilink/core/crypto/crypto_service.dart';
import 'package:omnilink/core/models/signed_key_bundle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Slice 1B.2 — SignedKeyBundle Unit & Security Tests', () {
    late CryptoService cryptoService;

    setUp(() {
      cryptoService = CryptoService();
    });

    test('1. Valid SignedKeyBundle creates and verifies successfully', () async {
      final aliceEd = await cryptoService.generateEd25519KeyPair();
      final aliceStaticX = await cryptoService.generateX25519KeyPair();
      final aliceSpkX = await cryptoService.generateX25519KeyPair();

      final staticHex = await cryptoService.getX25519PublicKeyHex(aliceStaticX);
      final spkHex = await cryptoService.getX25519PublicKeyHex(aliceSpkX);

      final bundle = await cryptoService.createSignedKeyBundle(
        masterEd25519KeyPair: aliceEd,
        staticX25519PublicKeyHex: staticHex,
        signedPreKeyPublicKeyHex: spkHex,
        timestamp: 1776850000000,
      );

      expect(bundle.signature, isNotEmpty);
      expect(bundle.signature.length, equals(128));

      final isValid = await cryptoService.verifySignedKeyBundle(bundle);
      expect(isValid, isTrue);
    });

    test('2. Identity public key modified -> verification fails', () async {
      final aliceEd = await cryptoService.generateEd25519KeyPair();
      final aliceStaticX = await cryptoService.generateX25519KeyPair();
      final aliceSpkX = await cryptoService.generateX25519KeyPair();

      final staticHex = await cryptoService.getX25519PublicKeyHex(aliceStaticX);
      final spkHex = await cryptoService.getX25519PublicKeyHex(aliceSpkX);

      final bundle = await cryptoService.createSignedKeyBundle(
        masterEd25519KeyPair: aliceEd,
        staticX25519PublicKeyHex: staticHex,
        signedPreKeyPublicKeyHex: spkHex,
      );

      final bobEd = await cryptoService.generateEd25519KeyPair();
      final bobNodeId = await cryptoService.getEd25519PublicKeyHex(bobEd);

      final tamperedBundle = SignedKeyBundle(
        protocolVersion: bundle.protocolVersion,
        identityPublicKeyHex: bobNodeId, // Tampered identity
        staticX25519PublicKeyHex: bundle.staticX25519PublicKeyHex,
        signedPreKeyPublicKeyHex: bundle.signedPreKeyPublicKeyHex,
        timestamp: bundle.timestamp,
        signature: bundle.signature,
      );

      final isValid = await cryptoService.verifySignedKeyBundle(tamperedBundle);
      expect(isValid, isFalse);
    });

    test('3 & Mandatory 7.1. Static X25519 Key substitution (Mallory MITM attack) -> verification FAILS', () async {
      // Alice identity and keys
      final aliceEd = await cryptoService.generateEd25519KeyPair();
      final aliceStaticX = await cryptoService.generateX25519KeyPair();
      final aliceSpkX = await cryptoService.generateX25519KeyPair();

      final aliceStaticHex = await cryptoService.getX25519PublicKeyHex(aliceStaticX);
      final aliceSpkHex = await cryptoService.getX25519PublicKeyHex(aliceSpkX);

      final bundle = await cryptoService.createSignedKeyBundle(
        masterEd25519KeyPair: aliceEd,
        staticX25519PublicKeyHex: aliceStaticHex,
        signedPreKeyPublicKeyHex: aliceSpkHex,
      );

      // Mallory generates her own X25519 key
      final malloryStaticX = await cryptoService.generateX25519KeyPair();
      final malloryStaticHex = await cryptoService.getX25519PublicKeyHex(malloryStaticX);

      // Mallory substitutes Alice's static key with Mallory's key, keeping Alice's signature
      final mitmBundle = SignedKeyBundle(
        protocolVersion: bundle.protocolVersion,
        identityPublicKeyHex: bundle.identityPublicKeyHex,
        staticX25519PublicKeyHex: malloryStaticHex, // SUBMITTED MALLORY KEY!
        signedPreKeyPublicKeyHex: bundle.signedPreKeyPublicKeyHex,
        timestamp: bundle.timestamp,
        signature: bundle.signature, // Alice's original signature
      );

      final isValid = await cryptoService.verifySignedKeyBundle(mitmBundle);
      expect(isValid, isFalse, reason: 'Key substitution MUST be detected by signature check');
    });

    test('4. Signed Pre-Key public key modified -> verification fails', () async {
      final aliceEd = await cryptoService.generateEd25519KeyPair();
      final aliceStaticX = await cryptoService.generateX25519KeyPair();
      final aliceSpkX = await cryptoService.generateX25519KeyPair();

      final staticHex = await cryptoService.getX25519PublicKeyHex(aliceStaticX);
      final spkHex = await cryptoService.getX25519PublicKeyHex(aliceSpkX);

      final bundle = await cryptoService.createSignedKeyBundle(
        masterEd25519KeyPair: aliceEd,
        staticX25519PublicKeyHex: staticHex,
        signedPreKeyPublicKeyHex: spkHex,
      );

      final fakeSpkHex = '00' * 32;

      final tamperedBundle = SignedKeyBundle(
        protocolVersion: bundle.protocolVersion,
        identityPublicKeyHex: bundle.identityPublicKeyHex,
        staticX25519PublicKeyHex: bundle.staticX25519PublicKeyHex,
        signedPreKeyPublicKeyHex: fakeSpkHex,
        timestamp: bundle.timestamp,
        signature: bundle.signature,
      );

      final isValid = await cryptoService.verifySignedKeyBundle(tamperedBundle);
      expect(isValid, isFalse);
    });

    test('5 & 6. Protocol version or timestamp modified -> verification fails', () async {
      final aliceEd = await cryptoService.generateEd25519KeyPair();
      final staticX = await cryptoService.generateX25519KeyPair();
      final spkX = await cryptoService.generateX25519KeyPair();

      final bundle = await cryptoService.createSignedKeyBundle(
        masterEd25519KeyPair: aliceEd,
        staticX25519PublicKeyHex: await cryptoService.getX25519PublicKeyHex(staticX),
        signedPreKeyPublicKeyHex: await cryptoService.getX25519PublicKeyHex(spkX),
        timestamp: 10000,
      );

      final tamperedTsBundle = SignedKeyBundle(
        protocolVersion: bundle.protocolVersion,
        identityPublicKeyHex: bundle.identityPublicKeyHex,
        staticX25519PublicKeyHex: bundle.staticX25519PublicKeyHex,
        signedPreKeyPublicKeyHex: bundle.signedPreKeyPublicKeyHex,
        timestamp: 999999, // Tampered timestamp
        signature: bundle.signature,
      );

      expect(await cryptoService.verifySignedKeyBundle(tamperedTsBundle), isFalse);
    });

    test('7 & 8. Modified or truncated signature -> rejected', () async {
      final aliceEd = await cryptoService.generateEd25519KeyPair();
      final staticX = await cryptoService.generateX25519KeyPair();
      final spkX = await cryptoService.generateX25519KeyPair();

      final bundle = await cryptoService.createSignedKeyBundle(
        masterEd25519KeyPair: aliceEd,
        staticX25519PublicKeyHex: await cryptoService.getX25519PublicKeyHex(staticX),
        signedPreKeyPublicKeyHex: await cryptoService.getX25519PublicKeyHex(spkX),
      );

      final truncatedBundle = SignedKeyBundle(
        protocolVersion: bundle.protocolVersion,
        identityPublicKeyHex: bundle.identityPublicKeyHex,
        staticX25519PublicKeyHex: bundle.staticX25519PublicKeyHex,
        signedPreKeyPublicKeyHex: bundle.signedPreKeyPublicKeyHex,
        timestamp: bundle.timestamp,
        signature: bundle.signature.substring(0, 64), // Truncated signature
      );

      expect(await cryptoService.verifySignedKeyBundle(truncatedBundle), isFalse);
    });

    test('9 & 10. Invalid key length -> rejected', () async {
      final bundle = SignedKeyBundle(
        protocolVersion: '0.1',
        identityPublicKeyHex: 'invalid_short_hex',
        staticX25519PublicKeyHex: '00' * 32,
        signedPreKeyPublicKeyHex: '00' * 32,
        timestamp: 1000,
        signature: '00' * 64,
      );

      expect(await cryptoService.verifySignedKeyBundle(bundle), isFalse);
    });

    test('11 & 12. Canonical byte serialization is deterministic and unambiguous', () async {
      final bundle1 = SignedKeyBundle(
        protocolVersion: '0.1',
        identityPublicKeyHex: 'AA' * 32,
        staticX25519PublicKeyHex: 'BB' * 32,
        signedPreKeyPublicKeyHex: 'CC' * 32,
        timestamp: 123456,
        signature: '00' * 64,
      );

      final bundle2 = SignedKeyBundle.fromJson(bundle1.toJson());

      expect(bundle2.toCanonicalString(), equals(bundle1.toCanonicalString()));
      expect(bundle2.toCanonicalBytes(), equals(bundle1.toCanonicalBytes()));
    });
  });
}
