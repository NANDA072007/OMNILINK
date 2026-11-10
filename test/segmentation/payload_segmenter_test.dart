import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:omnilink/core/segmentation/payload_segmenter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PayloadSegmenter Unit Tests', () {
    late PayloadSegmenter segmenter;
    late Directory tempDir;

    setUp(() async {
      segmenter = PayloadSegmenter();
      tempDir = await Directory.systemTemp.createTemp('segmenter_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('streamFileChunks streams file in 3000-byte chunks and computes correct chunk SHA-256', () async {
      final testFile = File('${tempDir.path}/test_payload.bin');
      // Create a 7,500 byte test file (should produce 3 chunks: 3000, 3000, 1500)
      final dummyBytes = Uint8List(7500);
      for (int i = 0; i < dummyBytes.length; i++) {
        dummyBytes[i] = i % 256;
      }
      await testFile.writeAsBytes(dummyBytes);

      final chunks = await segmenter.streamFileChunks(testFile.path, 'pld_test_1').toList();

      expect(chunks.length, equals(3));
      expect(chunks[0].chunkIndex, equals(0));
      expect(chunks[0].byteData.length, equals(3000));
      expect(chunks[0].chunkSha256, equals(crypto.sha256.convert(dummyBytes.sublist(0, 3000)).toString()));

      expect(chunks[1].chunkIndex, equals(1));
      expect(chunks[1].byteData.length, equals(3000));

      expect(chunks[2].chunkIndex, equals(2));
      expect(chunks[2].byteData.length, equals(1500));
    });

    test('calculateFinalSha256 computes expected hash via streaming', () async {
      final testFile = File('${tempDir.path}/hash_test.txt');
      await testFile.writeAsString('OMNILINK Streaming SHA-256 Test Content');

      final hash = await segmenter.calculateFinalSha256(testFile.path);
      final expectedHash = crypto.sha256.convert(await testFile.readAsBytes()).toString();

      expect(hash, equals(expectedHash));
    });

    test('deriveChunkNonce produces 12-byte unique nonces for distinct chunk indices', () {
      final baseNonce = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);

      final nonce0 = segmenter.deriveChunkNonce(baseNonce, 0);
      final nonce1 = segmenter.deriveChunkNonce(baseNonce, 1);
      final nonce256 = segmenter.deriveChunkNonce(baseNonce, 256);

      expect(nonce0.length, equals(12));
      expect(nonce1.length, equals(12));
      expect(nonce256.length, equals(12));

      // Base 8 bytes must match
      expect(nonce0.sublist(0, 8), equals(baseNonce.sublist(0, 8)));
      expect(nonce1.sublist(0, 8), equals(baseNonce.sublist(0, 8)));

      // Distinct chunk index nonces must differ in trailing 4 bytes
      expect(nonce0, isNot(equals(nonce1)));
      expect(nonce1, isNot(equals(nonce256)));

      // Verify little-endian integer encoding for index 256
      final bd = ByteData.sublistView(nonce256);
      expect(bd.getUint32(8, Endian.little), equals(256));
    });
  });
}
