import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warn, error }

enum LogDomain { db, transport, crypto, routing, ui, battery }

/// Structured diagnostic logger for OMNILINK.
/// Enforces strict domain tagging, log level filtering, and secret redaction rules.
class AppLogger {
  static LogLevel minLogLevel = kReleaseMode ? LogLevel.info : LogLevel.debug;

  /// RegExp patterns matching sensitive key material and tokens to prevent accidental logging.
  static final List<RegExp> _sensitivePatterns = [
    RegExp(r'(?:private|secret|seed|master|symmetric|sk|payload|auth|token)[\w\-_]*\s*[:=]\s*[^\s,;}]+', caseSensitive: false),
    RegExp(r'(?:0x)?[0-9a-fA-F]{64}'), // 64-character raw hex keys
  ];

  static void debug(String message, {LogDomain domain = LogDomain.routing}) {
    log(LogLevel.debug, domain, message);
  }

  static void info(String message, {LogDomain domain = LogDomain.routing}) {
    log(LogLevel.info, domain, message);
  }

  static void warn(String message, {LogDomain domain = LogDomain.routing, Object? error, StackTrace? stackTrace}) {
    log(LogLevel.warn, domain, message, error: error, stackTrace: stackTrace);
  }

  static void error(String message, {LogDomain domain = LogDomain.routing, Object? error, StackTrace? stackTrace}) {
    log(LogLevel.error, domain, message, error: error, stackTrace: stackTrace);
  }

  static void log(LogLevel level, LogDomain domain, String message, {Object? error, StackTrace? stackTrace}) {
    if (level.index < minLogLevel.index) return;

    final sanitizedMessage = redact(message);
    final timestamp = DateTime.now().toIso8601String();
    final logLine = '[${level.name.toUpperCase()}] [${domain.name.toUpperCase()}] [$timestamp] $sanitizedMessage';

    debugPrint(logLine);

    if (error != null) {
      debugPrint('  Error: ${redact(error.toString())}');
    }
    if (stackTrace != null) {
      debugPrint('  StackTrace:\n$stackTrace');
    }
  }

  /// Redacts potential secret key material, seed bytes, or sensitive tokens from log strings.
  static String redact(String input) {
    if (input.isEmpty) return input;
    String sanitized = input;

    // Apply redaction rules
    for (final pattern in _sensitivePatterns) {
      sanitized = sanitized.replaceAllMapped(pattern, (match) {
        final text = match.group(0) ?? '';
        if (text.contains('=')) {
          final parts = text.split('=');
          return '${parts[0]}=[REDACTED]';
        }
        if (text.contains(':')) {
          final parts = text.split(':');
          return '${parts[0]}: [REDACTED]';
        }
        return '[REDACTED_KEY]';
      });
    }

    return sanitized;
  }
}
