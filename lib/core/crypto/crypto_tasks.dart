enum CryptoTaskType {
  sign,
  verify,
  encrypt,
  decrypt,
  deriveSharedKey,
  sha256Hex,
}

enum CryptoTaskPriority {
  high,
  normal,
  low,
}

class CryptoTaskRequest {
  final String taskId;
  final CryptoTaskType taskType;
  final Map<String, dynamic> params;
  final CryptoTaskPriority priority;
  final DateTime createdAt;

  CryptoTaskRequest({
    required this.taskId,
    required this.taskType,
    required this.params,
    this.priority = CryptoTaskPriority.normal,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}

class CryptoTaskResponse {
  final String taskId;
  final dynamic result;
  final String? error;
  final String? stackTrace;

  CryptoTaskResponse({
    required this.taskId,
    this.result,
    this.error,
    this.stackTrace,
  });

  bool get isSuccess => error == null;
}
