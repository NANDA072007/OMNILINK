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
import 'repositories/peer_repository.dart';
import 'models/packet_envelope.dart';
import 'models/signed_key_bundle.dart';
import 'crypto/signed_prekey_manager.dart';
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

// 2. Transport Adapter (Android Native Radio Transport)
// Single concrete instance shared by the abstract transport provider and
// Android-only features (radio status, battery exemption, resume hooks).
final androidTransportAdapterProvider = Provider<AndroidTransportAdapter>((ref) {
  final adapter = AndroidTransportAdapter();
  adapter.initialize();
  ref.onDispose(() => adapter.dispose());
  return adapter;
});

final transportAdapterProvider = Provider<TransportAdapter>((ref) {
  return ref.watch(androidTransportAdapterProvider);
});

// 3. Identity Management (Master Ed25519 Key)
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
});

class IdentityState {
  final SimpleKeyPair? masterKeyPair; // Ed25519 master identity key
  final SimpleKeyPair? staticX25519KeyPair; // Independent static X25519 key
  final SimpleKeyPair? signedPreKeyPair; // Independent X25519 signed pre-key
  final SignedKeyBundle? activeSignedKeyBundle;
  final String? nodeId; // Hex encoded Ed25519 public key
  final String? staticX25519PublicKeyHex;
  final String? signedPreKeyPublicKeyHex;
  final bool isLoading;
  final String? error;

  IdentityState({
    this.masterKeyPair,
    this.staticX25519KeyPair,
    this.signedPreKeyPair,
    this.activeSignedKeyBundle,
    this.nodeId,
    this.staticX25519PublicKeyHex,
    this.signedPreKeyPublicKeyHex,
    this.isLoading = false,
    this.error,
  });

  IdentityState copyWith({
    SimpleKeyPair? masterKeyPair,
    SimpleKeyPair? staticX25519KeyPair,
    SimpleKeyPair? signedPreKeyPair,
    SignedKeyBundle? activeSignedKeyBundle,
    String? nodeId,
    String? staticX25519PublicKeyHex,
    String? signedPreKeyPublicKeyHex,
    bool? isLoading,
    String? error,
  }) {
    return IdentityState(
      masterKeyPair: masterKeyPair ?? this.masterKeyPair,
      staticX25519KeyPair: staticX25519KeyPair ?? this.staticX25519KeyPair,
      signedPreKeyPair: signedPreKeyPair ?? this.signedPreKeyPair,
      activeSignedKeyBundle: activeSignedKeyBundle ?? this.activeSignedKeyBundle,
      nodeId: nodeId ?? this.nodeId,
      staticX25519PublicKeyHex:
          staticX25519PublicKeyHex ?? this.staticX25519PublicKeyHex,
      signedPreKeyPublicKeyHex:
          signedPreKeyPublicKeyHex ?? this.signedPreKeyPublicKeyHex,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
    );
  }
}

class IdentityNotifier extends StateNotifier<IdentityState> {
  final CryptoService _cryptoService;
  final FlutterSecureStorage _storage;
  late final SignedPreKeyManager spkManager;

  static const _seedKey = 'omnilink_master_ed25519_seed';
  static const _staticX25519SeedKey = 'omnilink_static_x25519_seed';

  IdentityNotifier(this._cryptoService, this._storage)
      : super(IdentityState(isLoading: true)) {
    spkManager = SignedPreKeyManager(_cryptoService, _storage);
    Future.microtask(() => _initIdentity());
  }

  Future<void> _initIdentity() async {
    try {
      // 1. Load or generate Master Ed25519 Identity
      final edSeedString = await _storage.read(key: _seedKey);
      SimpleKeyPair masterKeyPair;
      if (edSeedString != null && edSeedString.isNotEmpty) {
        final seed = List<int>.from(edSeedString.split(',').map(int.parse));
        if (seed.length != 32) {
          throw const FormatException('CORRUPTED_IDENTITY_SEED: Invalid Ed25519 seed length');
        }
        masterKeyPair = await _cryptoService.restoreEd25519KeyPair(seed);
      } else {
        masterKeyPair = await _cryptoService.generateEd25519KeyPair();
        final seed = await _cryptoService.extractEd25519Seed(masterKeyPair);
        await _storage.write(key: _seedKey, value: seed.join(','));
      }
      final nodeId = await _cryptoService.getEd25519PublicKeyHex(masterKeyPair);

      // 2. Load or generate Independent Static X25519 Encryption Key
      final staticSeedString = await _storage.read(key: _staticX25519SeedKey);
      SimpleKeyPair staticX25519KeyPair;
      if (staticSeedString != null && staticSeedString.isNotEmpty) {
        final seed = List<int>.from(staticSeedString.split(',').map(int.parse));
        if (seed.length != 32) {
          throw const FormatException('CORRUPTED_STATIC_KEY_SEED: Invalid X25519 static seed length');
        }
        staticX25519KeyPair = await _cryptoService.restoreX25519KeyPair(seed);
      } else {
        staticX25519KeyPair = await _cryptoService.generateX25519KeyPair();
        final seed = await _cryptoService.extractX25519Seed(staticX25519KeyPair);
        await _storage.write(key: _staticX25519SeedKey, value: seed.join(','));
      }
      final staticX25519PublicKeyHex =
          await _cryptoService.getX25519PublicKeyHex(staticX25519KeyPair);

      // 3. Load or generate Active Signed Pre-Key via SignedPreKeyManager
      final signedPreKeyPair = await spkManager.getOrInitializeActivePreKey();
      final signedPreKeyPublicKeyHex =
          await _cryptoService.getX25519PublicKeyHex(signedPreKeyPair);

      // 4. Create active SignedKeyBundle binding identity and public keys
      final activeBundle = await _cryptoService.createSignedKeyBundle(
        masterEd25519KeyPair: masterKeyPair,
        staticX25519PublicKeyHex: staticX25519PublicKeyHex,
        signedPreKeyPublicKeyHex: signedPreKeyPublicKeyHex,
      );

      state = IdentityState(
        masterKeyPair: masterKeyPair,
        staticX25519KeyPair: staticX25519KeyPair,
        signedPreKeyPair: signedPreKeyPair,
        activeSignedKeyBundle: activeBundle,
        nodeId: nodeId,
        staticX25519PublicKeyHex: staticX25519PublicKeyHex,
        signedPreKeyPublicKeyHex: signedPreKeyPublicKeyHex,
        isLoading: false,
      );
    } catch (e) {
      state = IdentityState(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// Manually triggers SPK rotation or performs periodic maintenance.
  Future<void> rotateSignedPreKey({bool force = false}) async {
    if (state.masterKeyPair == null || state.staticX25519PublicKeyHex == null) return;
    final newKeyPair = await spkManager.rotateIfNeeded(force: force);
    if (newKeyPair != null) {
      final newSpkHex = await _cryptoService.getX25519PublicKeyHex(newKeyPair);
      final newBundle = await _cryptoService.createSignedKeyBundle(
        masterEd25519KeyPair: state.masterKeyPair!,
        staticX25519PublicKeyHex: state.staticX25519PublicKeyHex!,
        signedPreKeyPublicKeyHex: newSpkHex,
      );
      state = state.copyWith(
        signedPreKeyPair: newKeyPair,
        signedPreKeyPublicKeyHex: newSpkHex,
        activeSignedKeyBundle: newBundle,
      );
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
      // Always reset connectionStatus to disconnected on fresh app initialization
      state = savedPeers
          .map((p) => p.copyWith(connectionStatus: PeerConnectionStatus.disconnected))
          .toList();
    }
  }

  void _handleEvent(PeerConnectionEvent event) {
    final now = DateTime.now();
    switch (event.eventType) {
      case PeerConnectionEventType.onPeerFound:
        final existingIndex = state.indexWhere(
          (p) => p.peerId == event.peerId || (event.friendlyName != null && p.friendlyName == event.friendlyName),
        );
        PeerDevice peer;
        if (existingIndex == -1) {
          peer = PeerDevice(
            peerId: event.peerId,
            friendlyName: event.friendlyName ?? 'Unknown Device',
            lastSeenAt: now,
            rssi: event.rssi,
            transportType: event.transportType,
            connectionStatus: PeerConnectionStatus.discovered,
          );
          state = [...state, peer];
        } else {
          peer = state[existingIndex].copyWith(
            peerId: event.peerId,
            friendlyName: event.friendlyName ?? state[existingIndex].friendlyName,
            lastSeenAt: now,
            rssi: event.rssi ?? state[existingIndex].rssi,
            connectionStatus: PeerConnectionStatus.discovered,
          );
          state = [
            for (int i = 0; i < state.length; i++)
              if (i == existingIndex) peer else state[i]
          ];
        }
        _peerRepository.savePeer(peer);
        break;

      case PeerConnectionEventType.onPeerLost:
        // Do not purge a peer if it is currently connected
        state = state.where((p) => p.peerId != event.peerId || p.connectionStatus == PeerConnectionStatus.connected).toList();
        break;

      case PeerConnectionEventType.onConnected:
        // Merge on peerId first, then on stable friendlyName for endpoint rotation
        // (Nearby generates fresh 4-char endpointIds per session before nodeId is known).
        var connectedIndex = state.indexWhere((p) => p.peerId == event.peerId);
        if (connectedIndex == -1 && event.friendlyName != null && event.friendlyName!.isNotEmpty) {
          connectedIndex = state.indexWhere(
            (p) => p.nodeId == null && p.friendlyName == event.friendlyName,
          );
        }
        if (connectedIndex == -1) {
          final newPeer = PeerDevice(
            peerId: event.peerId,
            friendlyName: event.friendlyName ?? 'Peer_${event.peerId}',
            lastSeenAt: now,
            transportType: event.transportType,
            connectionStatus: PeerConnectionStatus.connected,
          );
          state = [...state, newPeer];
          _peerRepository.savePeer(newPeer);
        } else {
          state = [
            for (int i = 0; i < state.length; i++)
              if (i == connectedIndex)
                state[i].copyWith(
                  peerId: event.peerId,
                  connectionStatus: PeerConnectionStatus.connected,
                  lastSeenAt: now,
                  friendlyName: (event.friendlyName != null && event.friendlyName!.isNotEmpty)
                      ? event.friendlyName!
                      : state[i].friendlyName,
                )
              else
                state[i]
          ];
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

  /// Associates a transient peerId with a cryptographic nodeId and authenticated staticX25519PublicKeyHex, merging and deduplicating contacts cleanly.
  void updatePeerNodeId(String peerId, String nodeId, {String? friendlyName, String? staticX25519PublicKeyHex}) {
    final Map<String, PeerDevice> deduplicated = {};
    bool matched = false;

    for (final p in state) {
      if (p.peerId == peerId || p.nodeId == nodeId) {
        matched = true;
        final updated = p.copyWith(
          nodeId: nodeId,
          peerId: peerId,
          connectionStatus: PeerConnectionStatus.connected,
          lastSeenAt: DateTime.now(),
          staticX25519PublicKeyHex: (staticX25519PublicKeyHex != null && staticX25519PublicKeyHex.isNotEmpty)
              ? staticX25519PublicKeyHex
              : p.staticX25519PublicKeyHex,
          friendlyName: (friendlyName != null && friendlyName.isNotEmpty)
              ? friendlyName
              : (p.friendlyName.isNotEmpty && !p.friendlyName.startsWith('Peer_')
                  ? p.friendlyName
                  : (nodeId.length >= 6 ? 'Peer_${nodeId.substring(0, 6)}' : p.friendlyName)),
        );
        deduplicated[nodeId] = updated;
      } else {
        final key = p.nodeId ?? p.peerId;
        if (!deduplicated.containsKey(key)) {
          deduplicated[key] = p;
        }
      }
    }

    if (!matched && nodeId.isNotEmpty) {
      deduplicated[nodeId] = PeerDevice(
        peerId: peerId,
        nodeId: nodeId,
        friendlyName: (friendlyName != null && friendlyName.isNotEmpty)
            ? friendlyName
            : (nodeId.length >= 6 ? 'Peer_${nodeId.substring(0, 6)}' : 'Peer_$peerId'),
        lastSeenAt: DateTime.now(),
        connectionStatus: PeerConnectionStatus.connected,
        transportType: 'ANDROID_NEARBY',
        staticX25519PublicKeyHex: staticX25519PublicKeyHex,
      );
    }

    state = deduplicated.values.toList();

    final target = deduplicated[nodeId];
    if (target != null) {
      _peerRepository.savePeer(target);
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

// 6. Store-and-Forward Outbox Daemon
// RouterEngine constructs and owns the single daemon instance. Creating a
// second one here would run two competing flushers over the same SQLite queue.
final outboxDaemonProvider = Provider<OutboxDaemon>((ref) {
  return ref.watch(routerEngineProvider).outboxDaemon;
});

// 8. Central 5-Layer Router Engine Provider
final routerEngineProvider = Provider<RouterEngine>((ref) {
  final engine = RouterEngine(
    transport: ref.watch(transportAdapterProvider),
    packetService: ref.watch(packetServiceProvider),
    cryptoService: ref.watch(cryptoServiceProvider),
    db: ref.watch(routingDatabaseProvider),
    getMyNodeId: () => ref.read(identityProvider).nodeId ?? '',
    getMasterKeyPair: () => ref.read(identityProvider).masterKeyPair,
    getStaticX25519KeyPair: () => ref.read(identityProvider).staticX25519KeyPair,
    getSignedKeyBundle: () => ref.read(identityProvider).activeSignedKeyBundle,
    getConnectedPeers: () => ref.read(peerListProvider),
    messageRepo: ref.watch(messageRepositoryProvider),
  );
  engine.onPeerNodeIdDiscovered = (peerId, nodeId, staticX25519PublicKeyHex) {
    ref.read(peerListProvider.notifier).updatePeerNodeId(
      peerId,
      nodeId,
      staticX25519PublicKeyHex: staticX25519PublicKeyHex,
    );
  };
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
