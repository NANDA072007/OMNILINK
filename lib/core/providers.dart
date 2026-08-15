import 'dart:async';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../transport_bridge/android_transport_adapter.dart';
import '../transport_bridge/transport_adapter.dart';
import 'crypto/crypto_service.dart';
import 'crypto/packet_service.dart';
import 'database/database_service.dart';
import 'models/message.dart';
import 'models/peer_device.dart';
import 'repositories/message_repository.dart';
import 'repositories/outbox_repository.dart';
import 'repositories/peer_repository.dart';
import 'models/packet_envelope.dart';
import 'routing/mesh_router.dart';
import 'routing/outbox_daemon.dart';
import 'routing/providers.dart';
import 'routing/prophet_engine.dart';
import 'routing/router_engine.dart';

// 1. Core Services & Database
final cryptoServiceProvider = Provider<CryptoService>((ref) => CryptoService());

final packetServiceProvider = Provider<PacketService>((ref) {
  return PacketService(cryptoService: ref.watch(cryptoServiceProvider));
});

final databaseServiceProvider = Provider<DatabaseService>((ref) => DatabaseService.instance);

final peerRepositoryProvider = Provider<PeerRepository>((ref) {
  return PeerRepository(dbService: ref.watch(databaseServiceProvider));
});

final messageRepositoryProvider = Provider<MessageRepository>((ref) {
  return MessageRepository(dbService: ref.watch(databaseServiceProvider));
});

final outboxRepositoryProvider = Provider<OutboxRepository>((ref) {
  return OutboxRepository(dbService: ref.watch(databaseServiceProvider));
});

// 2. Transport Adapter (Android Native Radio Transport)
final transportAdapterProvider = Provider<TransportAdapter>((ref) {
  final adapter = AndroidTransportAdapter();
  adapter.initialize();
  ref.onDispose(() => adapter.dispose());
  return adapter;
});

// 3. Identity Management (Master Ed25519 Key)
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
});

class IdentityState {
  final SimpleKeyPair? masterKeyPair;
  final String? nodeId; // Hex encoded public key
  final bool isLoading;

  IdentityState({
    this.masterKeyPair,
    this.nodeId,
    this.isLoading = false,
  });

  IdentityState copyWith({
    SimpleKeyPair? masterKeyPair,
    String? nodeId,
    bool? isLoading,
  }) {
    return IdentityState(
      masterKeyPair: masterKeyPair ?? this.masterKeyPair,
      nodeId: nodeId ?? this.nodeId,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class IdentityNotifier extends StateNotifier<IdentityState> {
  final CryptoService _cryptoService;
  final FlutterSecureStorage _storage;
  static const _seedKey = 'omnilink_master_ed25519_seed';

  IdentityNotifier(this._cryptoService, this._storage)
      : super(IdentityState(isLoading: true)) {
    _initIdentity();
  }

  Future<void> _initIdentity() async {
    try {
      final seedString = await _storage.read(key: _seedKey);
      SimpleKeyPair keyPair;
      if (seedString != null) {
        final seed = List<int>.from(seedString.split(',').map(int.parse));
        keyPair = await _cryptoService.restoreEd25519KeyPair(seed);
      } else {
        keyPair = await _cryptoService.generateEd25519KeyPair();
        final seed = await _cryptoService.extractEd25519Seed(keyPair);
        await _storage.write(key: _seedKey, value: seed.join(','));
      }
      final nodeId = await _cryptoService.getEd25519PublicKeyHex(keyPair);
      state = IdentityState(masterKeyPair: keyPair, nodeId: nodeId, isLoading: false);
    } catch (e) {
      state = IdentityState(isLoading: false);
    }
  }
}

final identityProvider = StateNotifierProvider<IdentityNotifier, IdentityState>((ref) {
  return IdentityNotifier(
    ref.watch(cryptoServiceProvider),
    ref.watch(secureStorageProvider),
  );
});

// 4. Peer Discovery & Persistence State
class PeerListNotifier extends StateNotifier<List<PeerDevice>> {
  final TransportAdapter _adapter;
  final PeerRepository _peerRepository;
  late final StreamSubscription _subscription;

  PeerListNotifier(this._adapter, this._peerRepository) : super([]) {
    _loadSavedPeers();
    _subscription = _adapter.peerEvents.listen(_handleEvent);
  }

  Future<void> _loadSavedPeers() async {
    final savedPeers = await _peerRepository.getAllPeers();
    if (savedPeers.isNotEmpty) {
      state = savedPeers;
    }
  }

  void _handleEvent(PeerConnectionEvent event) {
    final now = DateTime.now();
    switch (event.eventType) {
      case PeerConnectionEventType.onPeerFound:
        final existingIndex = state.indexWhere((p) => p.peerId == event.peerId);
        PeerDevice peer;
        if (existingIndex == -1) {
          peer = PeerDevice(
            peerId: event.peerId,
            friendlyName: event.friendlyName ?? 'Unknown',
            lastSeenAt: now,
            rssi: event.rssi,
            transportType: event.transportType,
            connectionStatus: PeerConnectionStatus.discovered,
          );
          state = [...state, peer];
        } else {
          peer = state[existingIndex].copyWith(
            lastSeenAt: now,
            rssi: event.rssi ?? state[existingIndex].rssi,
          );
          state = [
            for (final p in state)
              if (p.peerId == event.peerId) peer else p
          ];
        }
        _peerRepository.savePeer(peer);
        break;

      case PeerConnectionEventType.onPeerLost:
        state = state.where((p) => p.peerId != event.peerId).toList();
        break;

      case PeerConnectionEventType.onConnected:
        state = [
          for (final p in state)
            if (p.peerId == event.peerId)
              p.copyWith(connectionStatus: PeerConnectionStatus.connected)
            else
              p
        ];
        final connectedIndex = state.indexWhere((p) => p.peerId == event.peerId);
        if (connectedIndex != -1) {
          _peerRepository.savePeer(state[connectedIndex]);
        }
        break;

      case PeerConnectionEventType.onDisconnected:
        state = [
          for (final p in state)
            if (p.peerId == event.peerId)
              p.copyWith(connectionStatus: PeerConnectionStatus.disconnected)
            else
              p
        ];
        final disconnectedIndex = state.indexWhere((p) => p.peerId == event.peerId);
        if (disconnectedIndex != -1) {
          _peerRepository.savePeer(state[disconnectedIndex]);
        }
        break;

      case PeerConnectionEventType.onError:
        break;
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

final peerListProvider = StateNotifierProvider<PeerListNotifier, List<PeerDevice>>((ref) {
  return PeerListNotifier(
    ref.watch(transportAdapterProvider),
    ref.watch(peerRepositoryProvider),
  );
});

// 5. Conversation Message State (SQLite Backed)
class ConversationMessagesNotifier extends StateNotifier<List<Message>> {
  final String conversationId;
  final MessageRepository _messageRepo;

  ConversationMessagesNotifier(this.conversationId, this._messageRepo) : super([]) {
    loadMessages();
  }

  Future<void> loadMessages() async {
    final messages = await _messageRepo.getMessagesForConversation(conversationId);
    state = messages;
  }
}

final conversationMessagesProvider = StateNotifierProvider.family<
    ConversationMessagesNotifier, List<Message>, String>((ref, conversationId) {
  return ConversationMessagesNotifier(
    conversationId,
    ref.watch(messageRepositoryProvider),
  );
});

// 6. Global Multi-Hop Mesh Router
final meshRouterProvider = Provider<MeshRouter>((ref) {
  final router = MeshRouter(
    transportAdapter: ref.watch(transportAdapterProvider),
    packetService: ref.watch(packetServiceProvider),
    outboxRepo: ref.watch(outboxRepositoryProvider),
    getConnectedPeers: () => ref.read(peerListProvider),
    getMyNodeId: () => ref.read(identityProvider).nodeId,
  );
  ref.onDispose(() => router.dispose());
  return router;
});

// 7. Store-and-Forward Outbox Daemon
final outboxDaemonProvider = Provider<OutboxDaemon>((ref) {
  final daemon = OutboxDaemon(
    db: ref.watch(routingDatabaseProvider),
    transport: ref.watch(transportAdapterProvider),
    router: ref.watch(routerEngineProvider),
    messageRepo: ref.watch(messageRepositoryProvider),
    getConnectedPeers: () => ref.read(peerListProvider),
  );
  ref.onDispose(() => daemon.dispose());
  return daemon;
});

// 8. Central 5-Layer Router Engine Provider
final routerEngineProvider = Provider<RouterEngine>((ref) {
  final engine = RouterEngine(
    transport: ref.watch(transportAdapterProvider),
    packetService: ref.watch(packetServiceProvider),
    cryptoService: ref.watch(cryptoServiceProvider),
    db: ref.watch(routingDatabaseProvider),
    getMyNodeId: () => ref.read(identityProvider).nodeId ?? '',
    getConnectedPeers: () => ref.read(peerListProvider),
  );
  ref.onDispose(() => engine.dispose());
  return engine;
});

final localInboundStreamProvider = StreamProvider<PacketEnvelope>((ref) {
  final router = ref.watch(routerEngineProvider);
  return router.localInboundStream;
});

final prophetEngineProvider = Provider<ProphetEngine>((ref) {
  final router = ref.watch(routerEngineProvider);
  return router.prophetEngine;
});
