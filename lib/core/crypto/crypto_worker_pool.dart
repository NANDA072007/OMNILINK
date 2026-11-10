import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:collection/collection.dart';
import 'package:cryptography/cryptography.dart';

import '../diagnostics/app_logger.dart';
import '../diagnostics/metrics_service.dart';
import 'crypto_tasks.dart';

class CryptoPoolOverloadedException implements Exception {
  final String message;
  const CryptoPoolOverloadedException(this.message);
  @override
  String toString() => 'CryptoPoolOverloadedException: $message';
}

class CryptoTaskException implements Exception {
  final String message;
  final String? stackTrace;
  const CryptoTaskException(this.message, [this.stackTrace]);
  @override
  String toString() => 'CryptoTaskException: $message (stackTrace: $stackTrace)';
}

/// Persistent Worker Isolate Pool for heavy OMNILINK cryptographic operations.
/// Eliminates per-operation Isolate.run allocation churn while maintaining worker crash recovery.
class CryptoWorkerPool {
  static const int maxQueueSize = 2048;
  final int workerCount;

  final List<_WorkerHandle> _workers = [];
  final List<CryptoTaskRequest> _taskQueue = [];
  final Map<String, Completer<dynamic>> _pendingCompleters = {};
  final Map<String, DateTime> _taskEnqueuedTimes = {};

  bool _isInitialized = false;
  int _taskCounter = 0;

  CryptoWorkerPool({int? workerCount})
      : workerCount = workerCount ?? _computeDefaultWorkerCount();

  static int _computeDefaultWorkerCount() {
    try {
      final cores = Platform.numberOfProcessors;
      return max(2, min(4, cores - 1));
    } catch (_) {
      return 2;
    }
  }

  bool get isInitialized => _isInitialized;
  int get queueDepth => _taskQueue.length;
  int get activeWorkerCount => _workers.where((w) => w.isAlive).length;

  Future<void> initialize() async {
    if (_isInitialized) return;

    AppLogger.info('Initializing CryptoWorkerPool with $workerCount worker isolates...', domain: LogDomain.crypto);

    for (int i = 0; i < workerCount; i++) {
      await _spawnWorker(i);
    }

    _isInitialized = true;
    AppLogger.info('CryptoWorkerPool successfully initialized ($workerCount workers active)', domain: LogDomain.crypto);
  }

  Future<void> _spawnWorker(int id) async {
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();

    final handle = _WorkerHandle(
      id: id,
      receivePort: receivePort,
      errorPort: errorPort,
      exitPort: exitPort,
    );

    _workers.add(handle);

    final isolate = await Isolate.spawn(
      _cryptoWorkerEntryPoint,
      receivePort.sendPort,
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
    );

    handle.isolate = isolate;

    handle.subscription = receivePort.listen((message) {
      if (message is SendPort) {
        handle.sendPort = message;
        handle.isAlive = true;
        _processNextTask();
      } else if (message is CryptoTaskResponse) {
        _handleTaskResponse(message);
        handle.isBusy = false;
        _processNextTask();
      }
    });

    errorPort.listen((errorData) {
      AppLogger.error('Worker isolate $id crashed with error: $errorData', domain: LogDomain.crypto);
      MetricsService.instance.increment('crypto_worker_restarts');
      _respawnWorker(handle);
    });

    exitPort.listen((_) {
      if (handle.isAlive) {
        AppLogger.warn('Worker isolate $id exited unexpectedly. Respawning...', domain: LogDomain.crypto);
        MetricsService.instance.increment('crypto_worker_restarts');
        _respawnWorker(handle);
      }
    });
  }

  Future<void> _respawnWorker(_WorkerHandle handle) async {
    handle.dispose();
    _workers.remove(handle);
    await _spawnWorker(handle.id);
  }

  /// Executes a cryptographic task using the persistent isolate pool.
  Future<T> execute<T>({
    required CryptoTaskType taskType,
    required Map<String, dynamic> params,
    CryptoTaskPriority priority = CryptoTaskPriority.normal,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_taskQueue.length >= maxQueueSize) {
      MetricsService.instance.increment('crypto_task_rejected');
      throw const CryptoPoolOverloadedException('Crypto task queue depth exceeded maxQueueSize (2048).');
    }

    _taskCounter++;
    final taskId = 'task_${DateTime.now().millisecondsSinceEpoch}_$_taskCounter';
    final request = CryptoTaskRequest(
      taskId: taskId,
      taskType: taskType,
      params: params,
      priority: priority,
    );

    final completer = Completer<dynamic>();
    _pendingCompleters[taskId] = completer;
    _taskEnqueuedTimes[taskId] = DateTime.now();

    if (priority == CryptoTaskPriority.high) {
      _taskQueue.insert(0, request);
    } else {
      _taskQueue.add(request);
    }

    MetricsService.instance.setGauge('crypto_pool_queue_depth', _taskQueue.length.toDouble());
    _processNextTask();

    return completer.future.timeout(timeout, onTimeout: () {
      _pendingCompleters.remove(taskId);
      _taskEnqueuedTimes.remove(taskId);
      throw TimeoutException('Crypto task $taskId timed out after ${timeout.inSeconds}s');
    }).then((res) => res as T);
  }

  void _processNextTask() {
    if (_taskQueue.isEmpty) return;

    final availableWorker = _workers.firstWhereOrNull((w) => w.isAlive && !w.isBusy && w.sendPort != null);
    if (availableWorker == null) return;

    final task = _taskQueue.removeAt(0);
    MetricsService.instance.setGauge('crypto_pool_queue_depth', _taskQueue.length.toDouble());

    final enqueueTime = _taskEnqueuedTimes.remove(task.taskId);
    if (enqueueTime != null) {
      final queueWaitMs = DateTime.now().difference(enqueueTime).inMilliseconds;
      MetricsService.instance.setGauge('crypto_task_queue_wait_ms', queueWaitMs.toDouble());
    }

    availableWorker.isBusy = true;
    MetricsService.instance.startTimer('crypto_task_duration');
    availableWorker.sendPort!.send(task);
  }

  void _handleTaskResponse(CryptoTaskResponse response) {
    MetricsService.instance.stopTimer('crypto_task_duration');
    final completer = _pendingCompleters.remove(response.taskId);
    if (completer == null || completer.isCompleted) return;

    if (response.isSuccess) {
      completer.complete(response.result);
    } else {
      completer.completeError(CryptoTaskException(response.error ?? 'Crypto operation failed', response.stackTrace));
    }
  }

  void dispose() {
    for (final handle in _workers) {
      handle.dispose();
    }
    _workers.clear();
    _taskQueue.clear();
    _pendingCompleters.clear();
    _isInitialized = false;
  }
}

class _WorkerHandle {
  final int id;
  final ReceivePort receivePort;
  final ReceivePort errorPort;
  final ReceivePort exitPort;
  StreamSubscription? subscription;
  Isolate? isolate;
  SendPort? sendPort;
  bool isAlive = false;
  bool isBusy = false;

  _WorkerHandle({
    required this.id,
    required this.receivePort,
    required this.errorPort,
    required this.exitPort,
  });

  void dispose() {
    isAlive = false;
    subscription?.cancel();
    receivePort.close();
    errorPort.close();
    exitPort.close();
    isolate?.kill(priority: Isolate.immediate);
  }
}

/// Worker Isolate Entrypoint running background crypto calculations.
void _cryptoWorkerEntryPoint(SendPort mainSendPort) {
  final workerReceivePort = ReceivePort();
  mainSendPort.send(workerReceivePort.sendPort);

  final ed25519 = Ed25519();
  final x25519 = X25519();
  final chacha20Poly1305 = Chacha20.poly1305Aead();
  final sha256 = Sha256();

  workerReceivePort.listen((message) async {
    if (message is! CryptoTaskRequest) return;

    final request = message;
    try {
      final result = await _executeWorkerTask(request, ed25519, x25519, chacha20Poly1305, sha256);
      mainSendPort.send(CryptoTaskResponse(taskId: request.taskId, result: result));
    } catch (e, s) {
      mainSendPort.send(CryptoTaskResponse(taskId: request.taskId, error: e.toString(), stackTrace: s.toString()));
    }
  });
}

Future<dynamic> _executeWorkerTask(
  CryptoTaskRequest req,
  Ed25519 ed25519,
  X25519 x25519,
  Cipher chacha20Poly1305,
  Sha256 sha256,
) async {
  switch (req.taskType) {
    case CryptoTaskType.sign:
      final message = req.params['message'] as Uint8List;
      final seed = req.params['seed'] as Uint8List;
      final keyPair = await ed25519.newKeyPairFromSeed(seed);
      final sig = await ed25519.sign(message, keyPair: keyPair);
      return _bytesToHex(sig.bytes);

    case CryptoTaskType.verify:
      final message = req.params['message'] as Uint8List;
      final signatureHex = req.params['signatureHex'] as String;
      final publicKeyHex = req.params['publicKeyHex'] as String;

      final sigBytes = _hexToBytes(signatureHex);
      final pubBytes = _hexToBytes(publicKeyHex);
      final sig = Signature(sigBytes, publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519));
      return await ed25519.verify(message, signature: sig);

    case CryptoTaskType.encrypt:
      final plaintext = req.params['plaintext'] as Uint8List;
      final secretKeyBytes = req.params['secretKeyBytes'] as Uint8List;
      final nonceList = req.params['nonce'] as List<int>?;
      final aadBytes = req.params['aad'] as Uint8List?;

      final secretBox = await chacha20Poly1305.encrypt(
        plaintext,
        secretKey: SecretKey(secretKeyBytes),
        nonce: nonceList,
        aad: aadBytes ?? const [],
      );
      final combined = Uint8List(secretBox.nonce.length + secretBox.mac.bytes.length + secretBox.cipherText.length);
      int offset = 0;
      combined.setAll(offset, secretBox.nonce);
      offset += secretBox.nonce.length;
      combined.setAll(offset, secretBox.mac.bytes);
      offset += secretBox.mac.bytes.length;
      combined.setAll(offset, secretBox.cipherText);

      return base64Encode(combined);

    case CryptoTaskType.decrypt:
      final base64Payload = req.params['base64Payload'] as String;
      final secretKeyBytes = req.params['secretKeyBytes'] as Uint8List;
      final aadBytes = req.params['aad'] as Uint8List?;

      final combined = base64Decode(base64Payload);
      const nonceLength = 12;
      const macLength = 16;

      if (combined.length < nonceLength + macLength) {
        throw const FormatException('INVALID_PAYLOAD: Encrypted payload bytes too short.');
      }

      final nonce = combined.sublist(0, nonceLength);
      final macBytes = combined.sublist(nonceLength, nonceLength + macLength);
      final cipherText = combined.sublist(nonceLength + macLength);

      final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));
      final decrypted = await chacha20Poly1305.decrypt(
        secretBox,
        secretKey: SecretKey(secretKeyBytes),
        aad: aadBytes ?? const [],
      );
      return Uint8List.fromList(decrypted);

    case CryptoTaskType.deriveSharedKey:
      final localPrivateKeyBytes = req.params['localPrivateKey'] as Uint8List;
      final remotePublicKeyBytes = req.params['remotePublicKey'] as Uint8List;

      final localKeyPair = await x25519.newKeyPairFromSeed(localPrivateKeyBytes);
      final remotePub = SimplePublicKey(remotePublicKeyBytes, type: KeyPairType.x25519);
      final sharedSecret = await x25519.sharedSecretKey(keyPair: localKeyPair, remotePublicKey: remotePub);
      return Uint8List.fromList(await sharedSecret.extractBytes());

    case CryptoTaskType.sha256Hex:
      final input = req.params['input'] as Uint8List;
      final digest = await sha256.hash(input);
      return _bytesToHex(digest.bytes);
  }
}

String _bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List _hexToBytes(String hex) {
  hex = hex.replaceAll(' ', '');
  if (hex.length % 2 != 0) throw const FormatException('Invalid hex string length.');
  final result = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}
