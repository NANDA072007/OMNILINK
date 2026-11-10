import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:omnilink/core/crypto/crypto_service.dart';
import 'package:omnilink/core/crypto/crypto_tasks.dart';
import 'package:omnilink/core/crypto/crypto_worker_pool.dart';
import 'package:omnilink/core/diagnostics/metrics_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CryptoWorkerPool & CryptoService Persistent Isolate Pool Tests', () {
    late CryptoWorkerPool pool;
    late CryptoService cryptoService;

    setUp(() async {
      pool = CryptoWorkerPool(workerCount: 2);
      await pool.initialize();
      cryptoService = CryptoService(workerPool: pool);
      MetricsService.instance.clear();
    });

    tearDown(() {
      pool.dispose();
    });

    test('Result correctness for Ed25519 signing and verification via worker pool', () async {
      final keyPair = await cryptoService.generateEd25519KeyPair();
      final pubHex = await cryptoService.getEd25519PublicKeyHex(keyPair);
      final message = Uint8List.fromList(utf8.encode('OMNILINK Test Payload 123'));

      final sigHex = await cryptoService.signMessage(message, keyPair);
      expect(sigHex.length, equals(128));

      final isValid = await cryptoService.verifySignature(
        message: message,
        signatureHex: sigHex,
        publicKeyHex: pubHex,
      );

      expect(isValid, isTrue);
    });

    test('Result correctness for ChaCha20-Poly1305 encryption and decryption via worker pool', () async {
      final secretKey = await Chacha20.poly1305Aead().newSecretKey();
      final plaintext = Uint8List.fromList(utf8.encode('Top Secret Mesh Message Payload'));

      final base64Cipher = await cryptoService.encryptPayload(
        plaintext: plaintext,
        secretKey: secretKey,
      );
      expect(base64Cipher.isNotEmpty, isTrue);

      final decrypted = await cryptoService.decryptPayload(
        base64Payload: base64Cipher,
        secretKey: secretKey,
      );

      expect(utf8.decode(decrypted), equals('Top Secret Mesh Message Payload'));
    });

    test('500 parallel signature verifications complete successfully without isolate exhaustion', () async {
      final keyPair = await cryptoService.generateEd25519KeyPair();
      final pubHex = await cryptoService.getEd25519PublicKeyHex(keyPair);
      final message = Uint8List.fromList(utf8.encode('Burst verification payload'));
      final sigHex = await cryptoService.signMessage(message, keyPair);

      final futures = <Future<bool>>[];
      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < 500; i++) {
        futures.add(cryptoService.verifySignature(
          message: message,
          signatureHex: sigHex,
          publicKeyHex: pubHex,
        ));
      }

      final results = await Future.wait(futures);
      stopwatch.stop();

      expect(results.length, equals(500));
      expect(results.every((r) => r == true), isTrue);
      expect(pool.activeWorkerCount, equals(2));
    });

    test('Queue overflow throws CryptoPoolOverloadedException when maxQueueSize is exceeded', () async {
      final smallPool = CryptoWorkerPool(workerCount: 1);
      await smallPool.initialize();

      final futures = <Future>[];
      bool overflowCaught = false;

      try {
        for (int i = 0; i < 2100; i++) {
          futures.add(smallPool.execute<String>(
            taskType: CryptoTaskType.sha256Hex,
            params: {'input': Uint8List.fromList([i])},
          ));
        }
        await Future.wait(futures);
      } catch (e) {
        if (e is CryptoPoolOverloadedException) {
          overflowCaught = true;
        }
      } finally {
        smallPool.dispose();
      }

      expect(overflowCaught, isTrue);
    });
  });
}
