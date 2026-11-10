import 'dart:convert';

enum TransferDirection {
  incoming,
  outgoing,
}

extension TransferDirectionX on TransferDirection {
  String toDbString() => name.toUpperCase();

  static TransferDirection fromDbString(String value) {
    switch (value.toUpperCase()) {
      case 'OUTGOING':
        return TransferDirection.outgoing;
      case 'INCOMING':
      default:
        return TransferDirection.incoming;
    }
  }
}

enum TransferState {
  pending,
  offerSent,
  accepted,
  sending,
  receiving,
  completed,
  failed,
  canceled,
}

extension TransferStateX on TransferState {
  String toDbString() {
    switch (this) {
      case TransferState.pending:
        return 'PENDING';
      case TransferState.offerSent:
        return 'OFFER_SENT';
      case TransferState.accepted:
        return 'ACCEPTED';
      case TransferState.sending:
        return 'SENDING';
      case TransferState.receiving:
        return 'RECEIVING';
      case TransferState.completed:
        return 'COMPLETED';
      case TransferState.failed:
        return 'FAILED';
      case TransferState.canceled:
        return 'CANCELED';
    }
  }

  static TransferState fromDbString(String value) {
    switch (value.toUpperCase()) {
      case 'OFFER_SENT':
        return TransferState.offerSent;
      case 'ACCEPTED':
        return TransferState.accepted;
      case 'SENDING':
        return TransferState.sending;
      case 'RECEIVING':
        return TransferState.receiving;
      case 'COMPLETED':
        return TransferState.completed;
      case 'FAILED':
        return TransferState.failed;
      case 'CANCELED':
        return TransferState.canceled;
      case 'PENDING':
      default:
        return TransferState.pending;
    }
  }
}

class PayloadTransfer {
  final String payloadId;
  final TransferDirection direction;
  final String senderNodeId;
  final String recipientNodeId;
  final String fileName;
  final String payloadType;
  final String mimeType;
  final int totalSize;
  final int totalChunks;
  final int receivedChunks;
  final String finalSha256;
  final TransferState transferState;
  final String? localFilePath;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PayloadTransfer({
    required this.payloadId,
    required this.direction,
    required this.senderNodeId,
    required this.recipientNodeId,
    required this.fileName,
    required this.payloadType,
    required this.mimeType,
    required this.totalSize,
    required this.totalChunks,
    this.receivedChunks = 0,
    required this.finalSha256,
    required this.transferState,
    this.localFilePath,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'payload_id': payloadId,
      'direction': direction.toDbString(),
      'sender_node_id': senderNodeId,
      'recipient_node_id': recipientNodeId,
      'file_name': fileName,
      'payload_type': payloadType,
      'mime_type': mimeType,
      'total_size': totalSize,
      'total_chunks': totalChunks,
      'received_chunks': receivedChunks,
      'final_sha256': finalSha256,
      'transfer_state': transferState.toDbString(),
      'local_file_path': localFilePath,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory PayloadTransfer.fromMap(Map<String, dynamic> map) {
    return PayloadTransfer(
      payloadId: map['payload_id'] as String,
      direction: TransferDirectionX.fromDbString(map['direction'] as String? ?? 'INCOMING'),
      senderNodeId: map['sender_node_id'] as String,
      recipientNodeId: map['recipient_node_id'] as String,
      fileName: map['file_name'] as String,
      payloadType: map['payload_type'] as String,
      mimeType: map['mime_type'] as String,
      totalSize: (map['total_size'] as num).toInt(),
      totalChunks: (map['total_chunks'] as num).toInt(),
      receivedChunks: (map['received_chunks'] as num? ?? 0).toInt(),
      finalSha256: map['final_sha256'] as String,
      transferState: TransferStateX.fromDbString(map['transfer_state'] as String? ?? 'PENDING'),
      localFilePath: map['local_file_path'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch((map['created_at'] as num).toInt()),
      updatedAt: DateTime.fromMillisecondsSinceEpoch((map['updated_at'] as num).toInt()),
    );
  }

  String toJson() => jsonEncode(toMap());

  factory PayloadTransfer.fromJson(String source) =>
      PayloadTransfer.fromMap(jsonDecode(source) as Map<String, dynamic>);

  PayloadTransfer copyWith({
    String? payloadId,
    TransferDirection? direction,
    String? senderNodeId,
    String? recipientNodeId,
    String? fileName,
    String? payloadType,
    String? mimeType,
    int? totalSize,
    int? totalChunks,
    int? receivedChunks,
    String? finalSha256,
    TransferState? transferState,
    String? localFilePath,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return PayloadTransfer(
      payloadId: payloadId ?? this.payloadId,
      direction: direction ?? this.direction,
      senderNodeId: senderNodeId ?? this.senderNodeId,
      recipientNodeId: recipientNodeId ?? this.recipientNodeId,
      fileName: fileName ?? this.fileName,
      payloadType: payloadType ?? this.payloadType,
      mimeType: mimeType ?? this.mimeType,
      totalSize: totalSize ?? this.totalSize,
      totalChunks: totalChunks ?? this.totalChunks,
      receivedChunks: receivedChunks ?? this.receivedChunks,
      finalSha256: finalSha256 ?? this.finalSha256,
      transferState: transferState ?? this.transferState,
      localFilePath: localFilePath ?? this.localFilePath,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
