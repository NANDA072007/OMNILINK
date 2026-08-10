import 'dart:convert';

/// Represents the deterministic state lifecycle of an OMNILINK message.
/// See docs/12_message_state_machine.md for details.
enum MessageState {
  /// Message is currently being drafted in the chat UI.
  draft,

  /// Message saved locally in SQLite outbox queue, waiting to be processed.
  queued,

  /// Payload encrypted with ChaCha20-Poly1305 and envelope signed.
  encrypted,

  /// Transport link inactive; waiting for target peer to be discovered & connected.
  searchingForPeer,

  /// Bytes actively streaming over native radio transport (Nearby Connections).
  sending,

  /// Link-level transport ACK received from remote node.
  delivered,

  /// Final end-to-end receipt packet (DELIVERY_RECEIPT) received and verified.
  receiptReceived,

  /// Transmission failed after max retries or link drop. User can tap to retry.
  failed,

  /// TTL or envelope expiration timestamp elapsed before delivery.
  expired,
}

extension MessageStateX on MessageState {
  String toDbString() {
    switch (this) {
      case MessageState.draft:
        return 'DRAFT';
      case MessageState.queued:
        return 'QUEUED';
      case MessageState.encrypted:
        return 'ENCRYPTED';
      case MessageState.searchingForPeer:
        return 'SEARCHING_FOR_PEER';
      case MessageState.sending:
        return 'SENDING';
      case MessageState.delivered:
        return 'DELIVERED';
      case MessageState.receiptReceived:
        return 'RECEIPT_RECEIVED';
      case MessageState.failed:
        return 'FAILED';
      case MessageState.expired:
        return 'EXPIRED';
    }
  }

  static MessageState fromDbString(String value) {
    switch (value.toUpperCase()) {
      case 'DRAFT':
        return MessageState.draft;
      case 'QUEUED':
        return MessageState.queued;
      case 'ENCRYPTED':
        return MessageState.encrypted;
      case 'SEARCHING_FOR_PEER':
        return MessageState.searchingForPeer;
      case 'SENDING':
        return MessageState.sending;
      case 'DELIVERED':
        return MessageState.delivered;
      case 'RECEIPT_RECEIVED':
        return MessageState.receiptReceived;
      case 'FAILED':
        return MessageState.failed;
      case 'EXPIRED':
        return MessageState.expired;
      default:
        return MessageState.failed;
    }
  }
}

/// Local representation of a text message in an OMNILINK conversation thread.
class Message {
  final String messageId;
  final String conversationId;
  final String senderNodeId;
  final String recipientNodeId;
  final String? plaintextBody;
  final MessageState state;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Message({
    required this.messageId,
    required this.conversationId,
    required this.senderNodeId,
    required this.recipientNodeId,
    this.plaintextBody,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
  });

  Message copyWith({
    String? messageId,
    String? conversationId,
    String? senderNodeId,
    String? recipientNodeId,
    String? plaintextBody,
    MessageState? state,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Message(
      messageId: messageId ?? this.messageId,
      conversationId: conversationId ?? this.conversationId,
      senderNodeId: senderNodeId ?? this.senderNodeId,
      recipientNodeId: recipientNodeId ?? this.recipientNodeId,
      plaintextBody: plaintextBody ?? this.plaintextBody,
      state: state ?? this.state,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'message_id': messageId,
      'conversation_id': conversationId,
      'sender_node_id': senderNodeId,
      'recipient_node_id': recipientNodeId,
      'plaintext_body': plaintextBody,
      'state': state.toDbString(),
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      messageId: map['message_id'] as String,
      conversationId: map['conversation_id'] as String,
      senderNodeId: map['sender_node_id'] as String,
      recipientNodeId: map['recipient_node_id'] as String,
      plaintextBody: map['plaintext_body'] as String?,
      state: MessageStateX.fromDbString(map['state'] as String),
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }

  String toJson() => jsonEncode(toMap());

  factory Message.fromJson(String source) =>
      Message.fromMap(jsonDecode(source) as Map<String, dynamic>);

  @override
  String toString() {
    return 'Message(id: $messageId, state: ${state.name}, from: ${senderNodeId.substring(0, 8)}..., to: ${recipientNodeId.substring(0, 8)}...)';
  }
}
