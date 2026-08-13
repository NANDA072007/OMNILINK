import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// Singleton SQLite Database Service managing raw tables, version migrations,
/// and standard CRUD operations for OMNILINK offline mesh persistence.
///
/// See docs/11_data_model.md for data specifications.
class DatabaseService {
  static const String _dbName = 'omnilink_mesh.db';
  static const int _dbVersion = 1;

  static final DatabaseService instance = DatabaseService._internal();
  static Database? _database;

  DatabaseService._internal();

  factory DatabaseService() => instance;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
    );
  }

  /// Creates SQLite database tables on initial launch.
  Future<void> _onCreate(Database db, int version) async {
    // 1. Peers table
    await db.execute('''
      CREATE TABLE peers (
        node_id TEXT PRIMARY KEY,
        peer_id TEXT,
        friendly_name TEXT,
        last_seen_at INTEGER,
        rssi INTEGER,
        transport_type TEXT,
        connection_status TEXT
      )
    ''');

    // 2. Messages table
    await db.execute('''
      CREATE TABLE messages (
        message_id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        sender_node_id TEXT NOT NULL,
        recipient_node_id TEXT NOT NULL,
        plaintext_body TEXT,
        state TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // 3. Outbox Queue table for Store-and-Forward offline mesh delivery
    await db.execute('''
      CREATE TABLE outbox_queue (
        packet_id TEXT PRIMARY KEY,
        recipient_node_id TEXT NOT NULL,
        envelope_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        attempts INTEGER DEFAULT 0
      )
    ''');
  }

  // --------------------------------------------------------------------------
  // GENERIC CRUD HELPER METHODS
  // --------------------------------------------------------------------------

  Future<int> insert(
    String table,
    Map<String, dynamic> data, {
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.replace,
  }) async {
    final db = await database;
    return await db.insert(
      table,
      data,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  Future<List<Map<String, dynamic>>> query(
    String table, {
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    int? limit,
  }) async {
    final db = await database;
    return await db.query(
      table,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
    );
  }

  Future<int> update(
    String table,
    Map<String, dynamic> data, {
    required String where,
    required List<dynamic> whereArgs,
  }) async {
    final db = await database;
    return await db.update(
      table,
      data,
      where: where,
      whereArgs: whereArgs,
    );
  }

  Future<int> delete(
    String table, {
    required String where,
    required List<dynamic> whereArgs,
  }) async {
    final db = await database;
    return await db.delete(
      table,
      where: where,
      whereArgs: whereArgs,
    );
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
