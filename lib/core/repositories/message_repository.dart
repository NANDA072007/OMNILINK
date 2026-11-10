import '../database/database_service.dart';
import '../models/message.dart';

/// Repository managing persistence, retrieval, and status updates for chat messages.
class MessageRepository {
  final DatabaseService _dbService;

  MessageRepository({DatabaseService? dbService})
      : _dbService = dbService ?? DatabaseService.instance;

  /// Saves or updates a [Message] record in the SQLite database.
  Future<void> saveMessage(Message message) async {
    await _dbService.insert('messages', message.toMap());
  }

  /// Retrieves all messages associated with a conversation thread, ordered by creation time.
  Future<List<Message>> getMessagesForConversation(String conversationId) async {
    final rows = await _dbService.query(
      'messages',
      where: 'conversation_id = ? OR sender_node_id = ? OR recipient_node_id = ?',
      whereArgs: [conversationId, conversationId, conversationId],
      orderBy: 'created_at ASC',
    );

    return rows.map((map) => Message.fromMap(map)).toList();
  }

  /// Migrates transient peerId conversation entries to permanent 64-char nodeId in SQLite.
  Future<void> migrateConversationId(String oldId, String newId) async {
    if (oldId == newId || oldId.isEmpty || newId.isEmpty) return;
    try {
      await _dbService.update(
        'messages',
        {'conversation_id': newId},
        where: 'conversation_id = ?',
        whereArgs: [oldId],
      );
      await _dbService.update(
        'messages',
        {'recipient_node_id': newId},
        where: 'recipient_node_id = ?',
        whereArgs: [oldId],
      );
    } catch (_) {}
  }

  /// Updates the delivery lifecycle [MessageState] for a specific message.
  Future<void> updateMessageState(String messageId, MessageState state) async {
    final updatedAt = DateTime.now().millisecondsSinceEpoch;

    await _dbService.update(
      'messages',
      {
        'state': state.toDbString(),
        'updated_at': updatedAt,
      },
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  /// Applies a non-terminal state update without regressing a message that
  /// already received its end-to-end receipt.
  Future<void> updateMessageStateUnlessReceiptReceived(
    String messageId,
    MessageState state,
  ) async {
    await _dbService.update(
      'messages',
      {
        'state': state.toDbString(),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'message_id = ? AND state != ?',
      whereArgs: [messageId, MessageState.receiptReceived.toDbString()],
    );
  }

  /// Returns true when a message with [messageId] is already persisted.
  Future<bool> hasMessage(String messageId) async {
    final rows = await _dbService.query(
      'messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Deletes a specific message from history.
  Future<void> deleteMessage(String messageId) async {
    await _dbService.delete(
      'messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }
}
