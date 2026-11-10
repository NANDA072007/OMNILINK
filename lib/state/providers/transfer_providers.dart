import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../../core/segmentation/transfer_manager.dart';

final transferManagerProvider = Provider<TransferManager>((ref) {
  final router = ref.watch(routerEngineProvider);
  final manager = TransferManager(sendQueueManager: router.sendQueueManager);
  ref.onDispose(() => manager.dispose());
  return manager;
});

final activeTransfersProvider =
    StateNotifierProvider<ActiveTransfersNotifier, Map<String, TransferProgress>>((ref) {
  final manager = ref.watch(transferManagerProvider);
  return ActiveTransfersNotifier(manager);
});

class ActiveTransfersNotifier extends StateNotifier<Map<String, TransferProgress>> {
  final TransferManager _manager;
  StreamSubscription<TransferProgress>? _sub;

  ActiveTransfersNotifier(this._manager) : super({}) {
    _sub = _manager.onProgressChanged.listen((progress) {
      final updated = Map<String, TransferProgress>.from(state);
      updated[progress.payloadId] = progress;
      state = Map.unmodifiable(updated);
    });
  }

  void cancelTransfer(String payloadId, String peerId) {
    _manager.cancelTransfer(payloadId, peerId);
    final updated = Map<String, TransferProgress>.from(state);
    updated.remove(payloadId);
    state = Map.unmodifiable(updated);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
