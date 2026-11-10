import 'package:sqflite/sqflite.dart';
import '../diagnostics/app_logger.dart';

class SchemaMigrationException implements Exception {
  final String message;
  final int fromVersion;
  final int toVersion;
  final Object? cause;

  const SchemaMigrationException(this.message, {required this.fromVersion, required this.toVersion, this.cause});

  @override
  String toString() => 'SchemaMigrationException: $message (v$fromVersion -> v$toVersion, cause: $cause)';
}

/// Manages incremental SQLite database schema migrations step-by-step.
/// Ensures all schema upgrades execute inside atomic transactions with complete rollback safety.
class SchemaMigrator {
  /// Migration step handler definition.
  final int fromVersion;
  final int toVersion;
  final Future<void> Function(Transaction txn) migrateStep;

  const SchemaMigrator({
    required this.fromVersion,
    required this.toVersion,
    required this.migrateStep,
  });

  /// Executes database schema migrations sequentially from [oldVersion] to [newVersion].
  static Future<void> migrate({
    required Database db,
    required int oldVersion,
    required int newVersion,
    required String dbName,
    required List<SchemaMigrator> steps,
  }) async {
    if (oldVersion >= newVersion) return;

    AppLogger.info('Starting schema migration for $dbName (v$oldVersion -> v$newVersion)', domain: LogDomain.db);
    final stopwatch = Stopwatch()..start();

    try {
      await db.transaction((txn) async {
        int current = oldVersion;

        while (current < newVersion) {
          final nextVersion = current + 1;
          final step = steps.firstWhere(
            (s) => s.fromVersion == current && s.toVersion == nextVersion,
            orElse: () => throw SchemaMigrationException(
              'Missing migration step implementation from v$current to v$nextVersion',
              fromVersion: current,
              toVersion: nextVersion,
            ),
          );

          AppLogger.info('Executing migration step v$current -> v$nextVersion for $dbName', domain: LogDomain.db);
          await step.migrateStep(txn);
          current = nextVersion;
        }
      });

      stopwatch.stop();
      AppLogger.info(
        'Successfully completed schema migration for $dbName to v$newVersion in ${stopwatch.elapsedMilliseconds}ms',
        domain: LogDomain.db,
      );
    } catch (e, s) {
      stopwatch.stop();
      AppLogger.error(
        'Failed schema migration for $dbName (v$oldVersion -> v$newVersion). Transaction rolled back.',
        domain: LogDomain.db,
        error: e,
        stackTrace: s,
      );
      throw SchemaMigrationException(
        'Database migration failed for $dbName',
        fromVersion: oldVersion,
        toVersion: newVersion,
        cause: e,
      );
    }
  }
}
