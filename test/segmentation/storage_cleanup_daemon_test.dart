import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:omnilink/core/database/database_service.dart';
import 'package:omnilink/core/segmentation/models/payload_transfer.dart';
import 'package:omnilink/core/segmentation/storage_cleanup_daemon.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('StorageCleanupDaemon Unit Tests', () {
    late DatabaseService testDbService;
    late Directory tempDir;
    late StorageCleanupDaemon daemon;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cleanup_daemon_test_');
      testDbService = DatabaseService.instance;
      final db = await testDbService.database;
      await db.execute('DELETE FROM payload_transfers');
      await db.execute('DELETE FROM payload_chunks');

      daemon = StorageCleanupDaemon(dbService: testDbService);
    });

    tearDown(() async {
      daemon.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('runCleanupScan purges failed transfers older than 1 hour and physical files', () async {
      final dummyFile = File('${tempDir.path}/stale_failed.txt');
      await dummyFile.writeAsString('Dummy stale payload content');

      final twoHoursAgo = DateTime.now().millisecondsSinceEpoch - (2 * 60 * 60 * 1000);

      final transfer = PayloadTransfer(
        payloadId: 'pld_stale_1',
        direction: TransferDirection.incoming,
        senderNodeId: 'node_a',
        recipientNodeId: 'node_b',
        fileName: 'stale_failed.txt',
        payloadType: 'text',
        mimeType: 'text/plain',
        totalSize: 100,
        totalChunks: 1,
        finalSha256: 'dummy_hash',
        transferState: TransferState.failed,
        localFilePath: dummyFile.path,
        createdAt: DateTime.fromMillisecondsSinceEpoch(twoHoursAgo),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(twoHoursAgo),
      );

      await testDbService.insert('payload_transfers', transfer.toMap());

      await daemon.runCleanupScan();

      final rows = await testDbService.query('payload_transfers', where: 'payload_id = ?', whereArgs: ['pld_stale_1']);
      expect(rows.isEmpty, isTrue);
      expect(dummyFile.existsSync(), isFalse);
    });
  });
}
