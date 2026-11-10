import 'dart:typed_data';

class PayloadChunk {
  final String payloadId;
  final int chunkIndex;
  final String chunkSha256;
  final Uint8List? chunkData;
  final DateTime receivedAt;

  const PayloadChunk({
    required this.payloadId,
    required this.chunkIndex,
    required this.chunkSha256,
    this.chunkData,
    required this.receivedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'payload_id': payloadId,
      'chunk_index': chunkIndex,
      'chunk_sha256': chunkSha256,
      'chunk_data': chunkData,
      'received_at': receivedAt.millisecondsSinceEpoch,
    };
  }

  factory PayloadChunk.fromMap(Map<String, dynamic> map) {
    final rawData = map['chunk_data'];
    Uint8List? dataBytes;
    if (rawData is Uint8List) {
      dataBytes = rawData;
    } else if (rawData is List) {
      dataBytes = Uint8List.fromList(List<int>.from(rawData));
    }

    return PayloadChunk(
      payloadId: map['payload_id'] as String,
      chunkIndex: (map['chunk_index'] as num).toInt(),
      chunkSha256: map['chunk_sha256'] as String,
      chunkData: dataBytes,
      receivedAt: DateTime.fromMillisecondsSinceEpoch((map['received_at'] as num).toInt()),
    );
  }

  PayloadChunk copyWith({
    String? payloadId,
    int? chunkIndex,
    String? chunkSha256,
    Uint8List? chunkData,
    DateTime? receivedAt,
  }) {
    return PayloadChunk(
      payloadId: payloadId ?? this.payloadId,
      chunkIndex: chunkIndex ?? this.chunkIndex,
      chunkSha256: chunkSha256 ?? this.chunkSha256,
      chunkData: chunkData ?? this.chunkData,
      receivedAt: receivedAt ?? this.receivedAt,
    );
  }
}
