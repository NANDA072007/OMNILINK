import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../database/database_service.dart';
import '../diagnostics/app_logger.dart';

enum TrustState {
  unverified,
  verifiedManual,
  verifiedQr,
  verificationRevoked,
  keyChangedSinceVerification,
}

extension TrustStateX on TrustState {
  String toDbString() {
    switch (this) {
      case TrustState.unverified:
        return 'UNVERIFIED';
      case TrustState.verifiedManual:
        return 'VERIFIED_MANUAL';
      case TrustState.verifiedQr:
        return 'VERIFIED_QR';
      case TrustState.verificationRevoked:
        return 'VERIFICATION_REVOKED';
      case TrustState.keyChangedSinceVerification:
        return 'KEY_CHANGED_SINCE_VERIFICATION';
    }
  }

  static TrustState fromDbString(String value) {
    switch (value.toUpperCase()) {
      case 'VERIFIED_MANUAL':
        return TrustState.verifiedManual;
      case 'VERIFIED_QR':
        return TrustState.verifiedQr;
      case 'VERIFICATION_REVOKED':
        return TrustState.verificationRevoked;
      case 'KEY_CHANGED_SINCE_VERIFICATION':
        return TrustState.keyChangedSinceVerification;
      case 'UNVERIFIED':
      default:
        return TrustState.unverified;
    }
  }

  bool get isVerified =>
      this == TrustState.verifiedManual || this == TrustState.verifiedQr;
}

class TrustRecord {
  final String nodeId;
  final TrustState trustState;
  final DateTime? verifiedAt;
  final String? verifiedMethod;
  final String keyFingerprint;
  final DateTime? revokedAt;

  const TrustRecord({
    required this.nodeId,
    required this.trustState,
    this.verifiedAt,
    this.verifiedMethod,
    required this.keyFingerprint,
    this.revokedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'node_id': nodeId,
      'trust_state': trustState.toDbString(),
      'verified_at': verifiedAt?.millisecondsSinceEpoch,
      'verified_method': verifiedMethod,
      'key_fingerprint': keyFingerprint,
      'revoked_at': revokedAt?.millisecondsSinceEpoch,
    };
  }

  factory TrustRecord.fromMap(Map<String, dynamic> map) {
    return TrustRecord(
      nodeId: map['node_id'] as String,
      trustState: TrustStateX.fromDbString((map['trust_state'] as String? ?? 'UNVERIFIED')),
      verifiedAt: map['verified_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['verified_at'] as int)
          : null,
      verifiedMethod: map['verified_method'] as String?,
      keyFingerprint: (map['key_fingerprint'] as String? ?? ''),
      revokedAt: map['revoked_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['revoked_at'] as int)
          : null,
    );
  }
}

/// Singleton Trust Store for persisting and querying contact identity verification records in SQLite.
class TrustStore {
  final DatabaseService _dbService;

  static final TrustStore instance = TrustStore._internal();
  factory TrustStore({DatabaseService? dbService}) =>
      dbService != null ? TrustStore._internal(dbService) : instance;

  TrustStore._internal([DatabaseService? dbService])
      : _dbService = dbService ?? DatabaseService.instance;

  Future<void> initTable() async {
    try {
      final db = await _dbService.database;
      await db.execute('''
        CREATE TABLE IF NOT EXISTS identity_trust (
          node_id TEXT PRIMARY KEY,
          trust_state TEXT NOT NULL,
          verified_at INTEGER,
          verified_method TEXT,
          key_fingerprint TEXT NOT NULL,
          revoked_at INTEGER
        )
      ''');
    } catch (e) {
      debugPrint('TrustStore init table error: $e');
    }
  }

  Future<TrustRecord> getTrustRecord(String nodeId, String currentKeyFingerprint) async {
    await initTable();
    try {
      final db = await _dbService.database;
      final rows = await db.query(
        'identity_trust',
        where: 'node_id = ?',
        whereArgs: [nodeId],
        limit: 1,
      );

      if (rows.isEmpty) {
        return TrustRecord(
          nodeId: nodeId,
          trustState: TrustState.unverified,
          keyFingerprint: currentKeyFingerprint,
        );
      }

      final record = TrustRecord.fromMap(rows.first);

      // Key Change Detection: If stored key fingerprint differs from current key fingerprint
      if (record.trustState.isVerified && record.keyFingerprint != currentKeyFingerprint && currentKeyFingerprint.isNotEmpty) {
        AppLogger.warn('KEY CHANGE DETECTED for $nodeId! Downgrading trust state to KEY_CHANGED_SINCE_VERIFICATION.', domain: LogDomain.crypto);
        final downgraded = TrustRecord(
          nodeId: nodeId,
          trustState: TrustState.keyChangedSinceVerification,
          keyFingerprint: currentKeyFingerprint,
          verifiedAt: record.verifiedAt,
          verifiedMethod: record.verifiedMethod,
        );
        await updateTrustRecord(downgraded);
        return downgraded;
      }

      return record;
    } catch (e) {
      return TrustRecord(
        nodeId: nodeId,
        trustState: TrustState.unverified,
        keyFingerprint: currentKeyFingerprint,
      );
    }
  }

  Future<void> updateTrustRecord(TrustRecord record) async {
    await initTable();
    try {
      final db = await _dbService.database;
      await db.insert(
        'identity_trust',
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      AppLogger.info('Updated trust state for ${record.nodeId} to ${record.trustState.name}', domain: LogDomain.crypto);
    } catch (e) {
      debugPrint('TrustStore update error: $e');
    }
  }

  Future<void> verifyContact(String nodeId, String fingerprint, {bool viaQr = false}) async {
    final record = TrustRecord(
      nodeId: nodeId,
      trustState: viaQr ? TrustState.verifiedQr : TrustState.verifiedManual,
      verifiedAt: DateTime.now(),
      verifiedMethod: viaQr ? 'QR_SCAN' : 'MANUAL_COMPARE',
      keyFingerprint: fingerprint,
    );
    await updateTrustRecord(record);
  }

  Future<void> revokeContact(String nodeId, String fingerprint) async {
    final record = TrustRecord(
      nodeId: nodeId,
      trustState: TrustState.verificationRevoked,
      revokedAt: DateTime.now(),
      keyFingerprint: fingerprint,
    );
    await updateTrustRecord(record);
  }
}
