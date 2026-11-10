import 'dart:convert';

/// JSON payload contained inside TRANSFER_OFFER packet envelopes.
class TransferOfferPayload {
  final String payloadId;
  final String fileName;
  final String mimeType;
  final int totalSize;
  final int totalChunks;
  final String finalSha256;

  const TransferOfferPayload({
    required this.payloadId,
    required this.fileName,
    required this.mimeType,
    required this.totalSize,
    required this.totalChunks,
    required this.finalSha256,
  });

  Map<String, dynamic> toMap() {
    return {
      'payload_id': payloadId,
      'file_name': fileName,
      'mime_type': mimeType,
      'total_size': totalSize,
      'total_chunks': totalChunks,
      'final_sha256': finalSha256,
    };
  }

  factory TransferOfferPayload.fromMap(Map<String, dynamic> map) {
    return TransferOfferPayload(
      payloadId: (map['payload_id'] ?? map['payloadId']) as String,
      fileName: (map['file_name'] ?? map['fileName']) as String,
      mimeType: (map['mime_type'] ?? map['mimeType']) as String,
      totalSize: (map['total_size'] ?? map['totalSize'] as num).toInt(),
      totalChunks: (map['total_chunks'] ?? map['totalChunks'] as num).toInt(),
      finalSha256: (map['final_sha256'] ?? map['finalSha256']) as String,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory TransferOfferPayload.fromJson(String source) =>
      TransferOfferPayload.fromMap(jsonDecode(source) as Map<String, dynamic>);

  TransferOfferPayload copyWith({
    String? payloadId,
    String? fileName,
    String? mimeType,
    int? totalSize,
    int? totalChunks,
    String? finalSha256,
  }) {
    return TransferOfferPayload(
      payloadId: payloadId ?? this.payloadId,
      fileName: fileName ?? this.fileName,
      mimeType: mimeType ?? this.mimeType,
      totalSize: totalSize ?? this.totalSize,
      totalChunks: totalChunks ?? this.totalChunks,
      finalSha256: finalSha256 ?? this.finalSha256,
    );
  }
}

/// JSON payload contained inside CHUNK_PAYLOAD packet envelopes.
class ChunkPayload {
  final String payloadId;
  final int chunkIndex;
  final String chunkSha256;
  final String chunkDataBase64;

  const ChunkPayload({
    required this.payloadId,
    required this.chunkIndex,
    required this.chunkSha256,
    required this.chunkDataBase64,
  });

  Map<String, dynamic> toMap() {
    return {
      'payload_id': payloadId,
      'chunk_index': chunkIndex,
      'chunk_sha256': chunkSha256,
      'chunk_data_base64': chunkDataBase64,
    };
  }

  factory ChunkPayload.fromMap(Map<String, dynamic> map) {
    return ChunkPayload(
      payloadId: (map['payload_id'] ?? map['payloadId']) as String,
      chunkIndex: (map['chunk_index'] ?? map['chunkIndex'] as num).toInt(),
      chunkSha256: (map['chunk_sha256'] ?? map['chunkSha256']) as String,
      chunkDataBase64: (map['chunk_data_base64'] ?? map['chunkDataBase64']) as String,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory ChunkPayload.fromJson(String source) =>
      ChunkPayload.fromMap(jsonDecode(source) as Map<String, dynamic>);

  ChunkPayload copyWith({
    String? payloadId,
    int? chunkIndex,
    String? chunkSha256,
    String? chunkDataBase64,
  }) {
    return ChunkPayload(
      payloadId: payloadId ?? this.payloadId,
      chunkIndex: chunkIndex ?? this.chunkIndex,
      chunkSha256: chunkSha256 ?? this.chunkSha256,
      chunkDataBase64: chunkDataBase64 ?? this.chunkDataBase64,
    );
  }
}

/// JSON payload contained inside CHUNK_ACK packet envelopes.
class ChunkAckPayload {
  final String payloadId;
  final int windowStart;
  final List<int> receivedChunkIndices;
  final List<int> missingChunkIndices;

  const ChunkAckPayload({
    required this.payloadId,
    required this.windowStart,
    required this.receivedChunkIndices,
    required this.missingChunkIndices,
  });

  Map<String, dynamic> toMap() {
    return {
      'payload_id': payloadId,
      'window_start': windowStart,
      'received_chunk_indices': receivedChunkIndices,
      'missing_chunk_indices': missingChunkIndices,
    };
  }

  factory ChunkAckPayload.fromMap(Map<String, dynamic> map) {
    final rawReceived = (map['received_chunk_indices'] ?? map['receivedChunkIndices']) as List?;
    final rawMissing = (map['missing_chunk_indices'] ?? map['missingChunkIndices']) as List?;

    return ChunkAckPayload(
      payloadId: (map['payload_id'] ?? map['payloadId']) as String,
      windowStart: (map['window_start'] ?? map['windowStart'] as num? ?? 0).toInt(),
      receivedChunkIndices: (rawReceived?.cast<num>() ?? []).map((e) => e.toInt()).toList(),
      missingChunkIndices: (rawMissing?.cast<num>() ?? []).map((e) => e.toInt()).toList(),
    );
  }

  String toJson() => jsonEncode(toMap());

  factory ChunkAckPayload.fromJson(String source) =>
      ChunkAckPayload.fromMap(jsonDecode(source) as Map<String, dynamic>);

  ChunkAckPayload copyWith({
    String? payloadId,
    int? windowStart,
    List<int>? receivedChunkIndices,
    List<int>? missingChunkIndices,
  }) {
    return ChunkAckPayload(
      payloadId: payloadId ?? this.payloadId,
      windowStart: windowStart ?? this.windowStart,
      receivedChunkIndices: receivedChunkIndices ?? this.receivedChunkIndices,
      missingChunkIndices: missingChunkIndices ?? this.missingChunkIndices,
    );
  }
}
