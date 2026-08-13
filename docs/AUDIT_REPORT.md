# OMNILINK Architecture Audit Report

**Document Status**: Final Architectural Audit  
**Date**: August 13, 2026  
**Target Audience**: External Systems Architect (Database Persistence & Multi-Hop Mesh Routing Designers)  
**Target Codebase**: `d:\Android projects\OMNILINK`

---

## 1. Identity & State Management

### Device Identity Generation & Persistence
Local device identity is based on an **Ed25519 master keypair** (RFC 8032). 
- **Generation & Derivation**: Created or restored via `CryptoService.generateEd25519KeyPair()` / `CryptoService.restoreEd25519KeyPair(seed)`.
- **Node ID**: Derived as the 64-character hex-encoded string of the Ed25519 public key (`_cryptoService.getEd25519PublicKeyHex(keyPair)`).
- **Persistence**: Key seed (32 bytes) is stored in `FlutterSecureStorage` under the key `'omnilink_master_ed25519_seed'`. On Android, it uses `AndroidOptions(encryptedSharedPreferences: true)` backed by Android Keystore System.

```dart
// Code snippet from lib/core/providers.dart (Lines 69-86)
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
```

### Riverpod State Providers (`lib/core/providers.dart`)
State management is built on `flutter_riverpod` (v2.5.1):

```dart
// Core Services
final cryptoServiceProvider = Provider<CryptoService>((ref) => CryptoService());

final packetServiceProvider = Provider<PacketService>((ref) {
  return PacketService(cryptoService: ref.watch(cryptoServiceProvider));
});

// Transport Adapter (Android Native Radio Transport)
final transportAdapterProvider = Provider<TransportAdapter>((ref) {
  final adapter = AndroidTransportAdapter();
  adapter.initialize();
  ref.onDispose(() => adapter.dispose());
  return adapter;
});

// Secure Storage & Identity
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
});

final identityProvider = StateNotifierProvider<IdentityNotifier, IdentityState>((ref) {
  return IdentityNotifier(
    ref.watch(cryptoServiceProvider),
    ref.watch(secureStorageProvider),
  );
});

final peerListProvider = StateNotifierProvider<PeerListNotifier, List<PeerDevice>>((ref) {
  return PeerListNotifier(ref.watch(transportAdapterProvider));
});
```

### Connected Peers & PeerDevice Model (`lib/core/models/peer_device.dart`)
Nearby radio devices are tracked in-memory by `PeerListNotifier` as a `List<PeerDevice>`.

```dart
enum PeerConnectionStatus {
  discovered,
  connecting,
  connected,
  disconnected,
}

class PeerDevice {
  final String peerId;          // Transient transport endpoint ID (e.g. Nearby endpointId "9A8B")
  final String? nodeId;         // Hex Ed25519 public key (set after IDENTITY_EXCHANGE)
  final String friendlyName;     // Human-readable nickname
  final DateTime lastSeenAt;    // Discovery timestamp
  final int? rssi;               // Signal strength (dBm)
  final String transportType;   // e.g. "ANDROID_NEARBY"
  final PeerConnectionStatus connectionStatus;

  const PeerDevice({
    required this.peerId,
    this.nodeId,
    required this.friendlyName,
    required this.lastSeenAt,
    this.rssi,
    required this.transportType,
    required this.connectionStatus,
  });
}
```

---

## 2. Protocol & Packet Models

### `PacketEnvelope` Structure (`lib/core/models/packet_envelope.dart`)
All mesh communication uses **Protocol v0.1 JSON Packet Envelopes** bounded strictly to a **4,096-byte MTU ceiling**.

```dart
class PacketEnvelope {
  final String protocolVersion; // Default '0.1'
  final String packetId;        // UUID v4
  final String senderId;        // Hex Ed25519 Public Key of Sender
  final String recipientId;     // Hex Ed25519 Public Key of Recipient
  final int createdAt;          // Unix epoch timestamp (ms)
  final int expiresAt;          // Unix epoch timestamp (ms)
  final int ttl;                // Time-To-Live hop limit (default: 7)
  final int hopCount;           // Incremented per hop (default: 0)
  final int maxHops;            // Hard ceiling (default: 7)
  final int priority;           // Priority class (default: 1)
  final String messageType;     // Packet type string
  final String payloadHash;     // SHA-256 hash of encrypted payload
  final String signature;       // Hex Ed25519 signature over canonical digest
  final String encryptedPayload;// Base64 ChaCha20-Poly1305 payload

  String toCanonicalString() {
    return '$packetId$senderId$recipientId$createdAt$payloadHash';
  }

  int get sizeInBytes => utf8.encode(toJson()).length;
  bool get exceedsMtuLimit => sizeInBytes > 4096;
}
```

### Defined Message Types
- **Currently in Runtime Code**:
  - `'MESSAGE_PAYLOAD'`: Used in `lib/ui/screens/chat_screen.dart` for encrypted 1:1 text messages.
- **Protocol Spec Definitions** (`docs/05_protocol_spec.md` & `spec/packets.md`):
  - `'IDENTITY_EXCHANGE'`: Exchange of master Ed25519 public keys and friendly names.
  - `'SESSION_INIT'`: Ephemeral X25519 ECDH key exchange.
  - `'MESSAGE_PAYLOAD'`: End-to-end encrypted user text payload.
  - `'DELIVERY_RECEIPT'`: Cryptographic receipt acknowledging message arrival.
  - `'ROUTING_TABLE'`: Peer distance-vector routing exchange.

### `CryptoService` & `PacketService` Instantiation
- `CryptoService` (`lib/core/crypto/crypto_service.dart`): Pure Dart wrapper around `package:cryptography` providing Ed25519 signing/verification, X25519 ECDH, ChaCha20-Poly1305 AEAD, and SHA-256 digest generation.
- `PacketService` (`lib/core/crypto/packet_service.dart`): Wraps `CryptoService` to create signed envelopes, validate clock skew / expiration / signatures, and manage a 1,000-element LRU deduplication ring buffer (`_processedPacketIds`).

---

## 3. Transport Bridge

### `TransportAdapter` Abstract Contract (`lib/transport_bridge/transport_adapter.dart`)

```dart
abstract class TransportAdapter {
  Future<void> initialize();
  Future<bool> startDiscovery({String serviceId = 'org.omnilink.mesh.v1'});
  Future<bool> stopDiscovery();
  Future<bool> connectPeer(String peerId);
  Future<bool> disconnectPeer(String peerId);
  Future<bool> sendPacket(String peerId, Uint8List packetBytes);

  Stream<PeerConnectionEvent> get peerEvents;
  Stream<IncomingPacketEvent> get incomingPackets;

  Future<bool> isConnected(String peerId);
  Future<void> dispose();
}
```

### EventChannel & MethodChannel Mapping (`lib/transport_bridge/android_transport_adapter.dart`)
- **Outbound Commands**: Issued over `MethodChannel("omnilink/transport/control")`.
- **Inbound Event Stream**: Listens to `EventChannel("omnilink/transport/events")`.

```dart
void _handleNativeEvent(dynamic rawEvent) {
  if (rawEvent is! Map) return;
  final map = Map<String, dynamic>.from(rawEvent);
  final eventType = map['eventType'] as String?;

  if (eventType == 'onPacketReceived') {
    final senderPeerId = (map['senderPeerId'] ?? map['senderId']) as String? ?? 'unknown_peer';
    final rawPayload = map['payloadBytes'];

    Uint8List payloadBytes;
    if (rawPayload is Uint8List) {
      payloadBytes = rawPayload;
    } else if (rawPayload is List) {
      payloadBytes = Uint8List.fromList(List<int>.from(rawPayload));
    } else {
      payloadBytes = Uint8List(0);
    }

    _incomingPacketController.add(
      IncomingPacketEvent(
        senderPeerId: senderPeerId,
        payloadBytes: payloadBytes,
      ),
    );
  } else {
    final peerEvent = PeerConnectionEvent.fromMap(map);
    _peerEventController.add(peerEvent);
  }
}
```

---

## 4. Current Persistence (Storage) Audit

### Package Dependencies (`pubspec.yaml`)
- `sqflite: ^2.3.2`: Installed in `pubspec.yaml`.
- `path: ^1.9.0`: Installed in `pubspec.yaml`.
- `flutter_secure_storage: ^9.0.0`: Installed & actively used for Ed25519 master key seed.

### Database Implementation Status
- **No SQLite database is implemented in runtime Dart code yet.**
- The data tables specified in `docs/11_data_model.md` (`messages`, `peer_devices`, `outbox_queue`) are documented as design specifications but have not been initialized with `openDatabase()` or wired to Riverpod.

### Message Persistence Status
- Messages are **strictly held in memory** inside `_ChatScreenState._messages` (`List<Message>`).
- Closing or restarting the application currently **erases all message history and discovered contact lists**.

---

## 5. Current Routing & Forwarding Logic

### Packet Fields Available for Routing
The `PacketEnvelope` model already contains the required headers for multi-hop routing:
- `recipientId` (Hex Ed25519 Node ID of destination).
- `senderId` (Hex Ed25519 Node ID of originator).
- `ttl` (Time-To-Live integer, default `7`).
- `hopCount` (Hop counter integer, default `0`).
- `maxHops` (Ceiling limit integer, default `7`).

### Multi-Hop Relay & Store-and-Forward Status
- **Routing Engine**: **No multi-hop routing engine exists yet.**
- **Relay Logic**: When an incoming packet arrives in `ChatScreen`, it checks `event.senderPeerId == widget.peerId`. If it does not match, it ignores the packet. It does **not** evaluate whether `envelope.recipientId` matches the local node, nor does it forward packets to other connected peers.
- **Outbox Queue**: **No store-and-forward outbox exists yet.** If `adapter.sendPacket(peerId, bytes)` returns `false` (peer offline), the message state transitions to `MessageState.failed` and remains in-memory only.

---

## 6. UI Structure

### Discovery & Navigation (`lib/ui/screens/discovery_screen.dart`)
- Acts as the app home screen.
- Displays the local node ID and active radar scanning status.
- Renders a list of discovered/connected `PeerDevice` cards.
- Tapping a peer card navigates to `ChatScreen(peerId: peer.peerId, peerName: peer.friendlyName)`.

### 1:1 Conversation Threads (`lib/ui/screens/chat_screen.dart`)
- **Structure**: Designed for **1:1 peer thread conversations** parameterized by `widget.peerId`.
- **Inbound Message Flow**:
  1. Subscribes to `transportAdapterProvider.incomingPackets`.
  2. Filters packets by `event.senderPeerId == widget.peerId`.
  3. Decodes JSON `PacketEnvelope`.
  4. Checks `PacketService.isDuplicate(envelope.packetId)`.
  5. Validates Ed25519 signature via `PacketService.validateEnvelope(envelope)`.
  6. Decrypts ChaCha20-Poly1305 payload using derived session key.
  7. Instantiates `Message` object with state `MessageState.delivered`.
  8. Calls `setState()` to append to local `_messages` list and renders UI chat bubble.

---

## 7. Gaps & Architectural Requirements

To achieve a production-grade mesh network, the external architect must design the following missing components:

### 1. Database Persistence Layer (SQLite)
- [ ] Create `DatabaseService` using `sqflite` to manage SQLite schema creation and version migrations (`docs/11_data_model.md`).
- [ ] Implement `MessageRepository` to persist all sent and received `Message` records.
- [ ] Implement `PeerRepository` to persist discovered contacts and public key mappings (`nodeId` <-> `peerId`).
- [ ] Wire database repositories into Riverpod providers so UI screens load historical chats on startup.

### 2. Multi-Hop Mesh Routing Layer (`RouterEngine`)
- [ ] Create a centralized `RouterEngine` service positioned between `TransportAdapter` and the UI layer.
- [ ] Inspect incoming packet envelopes:
  - If `envelope.recipientId == myNodeId`: Decrypt and route to local message listener.
  - If `envelope.recipientId != myNodeId`: 
    1. Check `envelope.ttl > 1`.
    2. Check deduplication LRU cache to prevent routing loops.
    3. Decrement `envelope.ttl` by 1 and increment `envelope.hopCount` by 1.
    4. Re-sign or re-broadcast envelope to all connected peers except the ingress peer.

### 3. Store-and-Forward Outbox Daemon (`OutboxDaemon`)
- [ ] Create `outbox_queue` SQLite table to store undelivered `PacketEnvelope` records when a destination node is unreachable.
- [ ] Implement `OutboxDaemon` listening to `transportAdapterProvider.peerEvents`:
  - When `onConnected` or `onPeerFound` fires for a peer, query `outbox_queue` for pending envelopes destined for that `nodeId` (or via next-hop routes).
  - Transmit queued packets automatically and mark status as `delivered` upon receiving cryptographic `DELIVERY_RECEIPT`.
