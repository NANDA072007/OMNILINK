import 'dart:async';
import 'dart:io';
import '../database/database_service.dart';
import '../diagnostics/app_logger.dart';
import 'models/payload_transfer.dart';

/// Background daemon preventing storage exhaustion from abandoned, failed, or stale payload transfers.
class StorageCleanupDaemon {
  final DatabaseService dbService;
  Timer? _periodicTimer;

  static const Duration defaultInterval = Duration(hours: 6);

  StorageCleanupDaemon({
    DatabaseService? dbService,
  }) : dbService = dbService ?? DatabaseService.instance;

  /// Starts periodic background storage cleanup scans.
  void start({Duration interval = defaultInterval}) {
    _periodicTimer?.cancel();
    // Run initial scan asynchronously on startup
    runCleanupScan();
    _periodicTimer = Timer.periodic(interval, (_) => runCleanupScan());
  }

  /// Scans SQLite database and physical storage for stale transfers to purge.
  Future<void> runCleanupScan() async {
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final oneHourAgoMs = nowMs - (60 * 60 * 1000);
      final fortyEightHoursAgoMs = nowMs - (48 * 60 * 60 * 1000);

      final rows = await dbService.query(
        'payload_transfers',
        where: '(transfer_state IN (?, ?) AND updated_at < ?) OR (transfer_state IN (?, ?, ?) AND updated_at < ?)',
        whereArgs: [
          TransferState.failed.toDbString(),
          TransferState.canceled.toDbString(),
          oneHourAgoMs,
          TransferState.pending.toDbString(),
          TransferState.sending.toDbString(),
          TransferState.receiving.toDbString(),
          fortyEightHoursAgoMs,
        ],
      );

      if (rows.isEmpty) return;

      int bytesFreed = 0;
      int purgedCount = 0;

      final db = await dbService.database;
      await db.transaction((txn) async {
        for (final row in rows) {
          final payloadId = row['payload_id'] as String;
          final filePath = row['local_file_path'] as String?;
          final totalSize = (row['total_size'] as num?)?.toInt() ?? 0;

          if (filePath != null) {
            final file = File(filePath);
            if (await file.exists()) {
              try {
                final length = await file.length();
                await file.delete();
                bytesFreed += length;
              } catch (_) {}
            } else {
              bytesFreed += totalSize;
            }
          }

          await txn.delete('payload_chunks', where: 'payload_id = ?', whereArgs: [payloadId]);
          await txn.delete('payload_transfers', where: 'payload_id = ?', whereArgs: [payloadId]);
          purgedCount++;
        }
      });

      final mbFreed = (bytesFreed / (1024 * 1024)).toStringAsFixed(2);
      AppLogger.info('StorageCleanupDaemon purged $purgedCount stale transfers, freeing $mbFreed MB disk space.', domain: LogDomain.crypto);
    } catch (e) {
      AppLogger.error('StorageCleanupDaemon scan error: $e', domain: LogDomain.crypto);
    }
  }

  void stop() => dispose();

  void dispose() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }
}
