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
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at ASC',
    );

    return rows.map((map) => Message.fromMap(map)).toList();
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

  /// Deletes a specific message from history.
  Future<void> deleteMessage(String messageId) async {
    await _dbService.delete(
      'messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }
}
