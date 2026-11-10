import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;

import '../diagnostics/app_logger.dart';
import '../diagnostics/metrics_service.dart';

/// Tracks active paginated anti-entropy synchronization sessions between mesh peers.
class SyncSession {
  final String sessionId;
  final String peerId;
  final int protocolVersion;
  final int totalEstimatedCount;
  final int pageSize;
  final String checksumAlgorithm;
  final DateTime startTime;

  final Set<int> receivedPageIndices = {};
  final Map<int, List<String>> receivedPages = {};
  int? totalPageCount;
  String? expectedFinalChecksum;

  SyncSession({
    required this.sessionId,
    required this.peerId,
    required this.protocolVersion,
    required this.totalEstimatedCount,
    required this.pageSize,
    this.checksumAlgorithm = 'sha256',
    DateTime? startTime,
  }) : startTime = startTime ?? DateTime.now();

  bool isComplete(int totalPages) {
    if (receivedPageIndices.length < totalPages) return false;
    for (int i = 0; i < totalPages; i++) {
      if (!receivedPageIndices.contains(i)) return false;
    }
    return true;
  }

  List<String> getCombinedPacketIds() {
    final sortedIndices = receivedPages.keys.toList()..sort();
    final combined = <String>[];
    for (final idx in sortedIndices) {
      combined.addAll(receivedPages[idx]!);
    }
    return combined;
  }

  static String computeChecksum(List<String> packetIds) {
    final concatenated = packetIds.join(':');
    final bytes = utf8.encode(concatenated);
    final digest = crypto.sha256.convert(bytes);
    return digest.toString();
  }
}

/// Manages active inbound and outbound MTU-safe sync sessions with timeout cleanup.
class SyncSessionManager {
  final Map<String, SyncSession> _sessions = {};
  Timer? _timeoutTimer;

  static const Duration sessionTimeout = Duration(seconds: 30);

  SyncSessionManager() {
    _startTimeoutMonitor();
  }

  void _startTimeoutMonitor() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _cleanupTimedOutSessions();
    });
  }

  SyncSession createSession({
    required String sessionId,
    required String peerId,
    required int protocolVersion,
    required int totalEstimatedCount,
    required int pageSize,
    String checksumAlgorithm = 'sha256',
  }) {
    final session = SyncSession(
      sessionId: sessionId,
      peerId: peerId,
      protocolVersion: protocolVersion,
      totalEstimatedCount: totalEstimatedCount,
      pageSize: pageSize,
      checksumAlgorithm: checksumAlgorithm,
    );
    _sessions[sessionId] = session;
    MetricsService.instance.increment('sync_sessions_started');
    return session;
  }

  SyncSession? getSession(String sessionId) => _sessions[sessionId];

  /// Stores an incoming page. Returns true if accepted, false if duplicate or invalid.
  bool handlePage({
    required String sessionId,
    required int pageIndex,
    required List<String> packetIdChunk,
    required String pageChecksum,
  }) {
    final session = _sessions[sessionId];
    if (session == null) return false;

    // Duplicate check
    if (session.receivedPageIndices.contains(pageIndex)) {
      AppLogger.warn('SyncSession $sessionId ignored duplicate page index $pageIndex', domain: LogDomain.routing);
      return false;
    }

    // Page Checksum verification
    final computedChecksum = SyncSession.computeChecksum(packetIdChunk);
    if (computedChecksum != pageChecksum) {
      AppLogger.error('SyncSession $sessionId checksum mismatch on page $pageIndex', domain: LogDomain.routing);
      return false;
    }

    session.receivedPageIndices.add(pageIndex);
    session.receivedPages[pageIndex] = packetIdChunk;
    MetricsService.instance.increment('sync_pages_received');
    return true;
  }

  /// Cancels all active sync sessions associated with a disconnected peer.
  void cancelSessionsForPeer(String peerId) {
    final toRemove = _sessions.values.where((s) => s.peerId == peerId).map((s) => s.sessionId).toList();
    for (final sid in toRemove) {
      _sessions.remove(sid);
      MetricsService.instance.increment('sync_sessions_failed');
      AppLogger.info('Cancelled sync session $sid due to peer disconnect: $peerId', domain: LogDomain.routing);
    }
  }

  void completeSession(String sessionId) {
    final session = _sessions.remove(sessionId);
    if (session != null) {
      final duration = DateTime.now().difference(session.startTime).inMilliseconds;
      MetricsService.instance.increment('sync_sessions_completed');
      MetricsService.instance.setGauge('sync_session_duration_ms', duration.toDouble());
    }
  }

  void _cleanupTimedOutSessions() {
    final now = DateTime.now();
    final expired = _sessions.values
        .where((s) => now.difference(s.startTime) > sessionTimeout)
        .map((s) => s.sessionId)
        .toList();

    for (final sid in expired) {
      _sessions.remove(sid);
      MetricsService.instance.increment('sync_sessions_failed');
      AppLogger.warn('Sync session $sid timed out after ${sessionTimeout.inSeconds}s', domain: LogDomain.routing);
    }
  }

  void dispose() {
    _timeoutTimer?.cancel();
    _sessions.clear();
  }
}
