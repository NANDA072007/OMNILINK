import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;

/// Container for a single stream-segmented payload chunk.
class ChunkData {
  final int chunkIndex;
  final Uint8List byteData;
  final String chunkSha256;

  const ChunkData({
    required this.chunkIndex,
    required this.byteData,
    required this.chunkSha256,
  });
}

/// Memory-efficient payload segmenter utilizing Dart file streaming ([RandomAccessFile])
/// to slice files up to 10MB into MTU-bounded 3,000-byte segments with deterministic nonces.
class PayloadSegmenter {
  /// Default MTU-safe payload chunk boundary in bytes.
  static const int defaultMaxChunkSize = 3000;

  /// Streams file chunks directly from disk using [RandomAccessFile] to maintain low memory usage (< 10MB RAM).
  Stream<ChunkData> streamFileChunks(
    String filePath,
    String payloadId, {
    int maxChunkSize = defaultMaxChunkSize,
  }) async* {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('Target file for segmentation does not exist', filePath);
    }

    final raf = await file.open(mode: FileMode.read);
    int chunkIndex = 0;

    try {
      final fileLength = await raf.length();
      int position = 0;

      while (position < fileLength) {
        final buffer = await raf.read(maxChunkSize);
        if (buffer.isEmpty) break;

        final byteData = Uint8List.fromList(buffer);
        final chunkSha256 = crypto.sha256.convert(byteData).toString();

        yield ChunkData(
          chunkIndex: chunkIndex,
          byteData: byteData,
          chunkSha256: chunkSha256,
        );

        chunkIndex++;
        position += buffer.length;
      }
    } finally {
      await raf.close();
    }
  }

  /// Reads only the targeted window of chunks using seek positioning ([raf.setPosition]),
  /// preventing expensive full-file re-reads on every sliding window ACK.
  Future<List<ChunkData>> readWindowChunks(
    String filePath,
    int startChunkIndex,
    int windowSize, {
    int maxChunkSize = defaultMaxChunkSize,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('Target file for window read does not exist', filePath);
    }

    final raf = await file.open(mode: FileMode.read);
    final chunks = <ChunkData>[];

    try {
      final fileLength = await raf.length();
      final byteOffset = startChunkIndex * maxChunkSize;

      if (byteOffset < fileLength) {
        await raf.setPosition(byteOffset);

        for (int i = 0; i < windowSize; i++) {
          final currentPos = await raf.position();
          if (currentPos >= fileLength) break;

          final buffer = await raf.read(maxChunkSize);
          if (buffer.isEmpty) break;

          final byteData = Uint8List.fromList(buffer);
          final chunkSha256 = crypto.sha256.convert(byteData).toString();

          chunks.add(ChunkData(
            chunkIndex: startChunkIndex + i,
            byteData: byteData,
            chunkSha256: chunkSha256,
          ));
        }
      }
    } finally {
      await raf.close();
    }

    return chunks;
  }

  /// Computes final SHA-256 hash of a file via streaming to prevent loading full payload into RAM.
  Future<String> calculateFinalSha256(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('File does not exist for SHA-256 computation', filePath);
    }
    final digest = await crypto.sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// Derives a mathematically unique 12-byte ChaCha20-Poly1305 nonce for a specific [chunkIndex].
  /// Uses first 8 bytes of [basePayloadNonce] + 4-byte little-endian [chunkIndex].
  Uint8List deriveChunkNonce(Uint8List basePayloadNonce, int chunkIndex) {
    if (basePayloadNonce.length < 8) {
      throw ArgumentError('Base payload nonce must be at least 8 bytes long');
    }

    final nonce = Uint8List(12);
    for (int i = 0; i < 8; i++) {
      nonce[i] = basePayloadNonce[i];
    }

    final byteData = ByteData.sublistView(nonce);
    byteData.setUint32(8, chunkIndex, Endian.little);

    return nonce;
  }
}
