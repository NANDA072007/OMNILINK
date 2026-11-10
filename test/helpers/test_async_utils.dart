import 'dart:async';

/// Deterministically polls [condition] until it returns a non-null value or [timeout] expires.
/// Catches and suppresses transient exceptions during polling to prevent premature abortion,
/// only throwing [TimeoutException] if the condition is never satisfied within [timeout].
Future<T> pollUntil<T>({
  required FutureOr<T?> Function() condition,
  Duration timeout = const Duration(seconds: 4),
  Duration pollInterval = const Duration(milliseconds: 20),
  String message = 'Asynchronous condition timed out',
}) async {
  final stopwatch = Stopwatch()..start();
  Object? lastError;
  while (stopwatch.elapsed < timeout) {
    try {
      final result = await condition();
      if (result != null) return result;
    } catch (e) {
      lastError = e;
    }
    await Future.delayed(pollInterval);
  }
  throw TimeoutException(
    '$message (elapsed: ${stopwatch.elapsedMilliseconds}ms, timeout: ${timeout.inMilliseconds}ms${lastError != null ? ', lastError: $lastError' : ''})',
    timeout,
  );
}
