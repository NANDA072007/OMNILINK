# Document 03: Flutter Presentation & Application Architecture

## 1. Directory & Package Structure

The Flutter application (Layer 1) follows a **Feature-First Architecture** combined with clean separation between UI components and domain controllers.

```text
lib/
├── main.dart                          # Application entrypoint & initialization
├── core/
│   ├── constants/                     # UI colors, typography, theme definitions
│   ├── errors/                        # App exceptions and error mapping
│   ├── storage/                       # Drift (SQLite) database & SecureStorage wrappers
│   └── utils/                         # Date formatters, logging helpers
├── features/
│   ├── chat/                          # Chat screen, conversation list, message bubbles
│   │   ├── domain/                    # Message entities, state enums
│   │   ├── presentation/              # ChatScreen, ConversationListScreen
│   │   └── providers/                 # Riverpod controllers for message flow
│   ├── nearby_devices/                # Discovery screen, peer list UI
│   │   ├── domain/                    # PeerDevice entity
│   │   ├── presentation/              # NearbyPeersScreen, PeerCard
│   │   └── providers/                 # DiscoveryState controllers
│   ├── sos/                           # Emergency SOS UI & rapid broadcast view
│   ├── settings/                      # User profile, keys export, permissions status
│   └── debug/                         # Real-time packet log overlay & radio monitor
├── transport_bridge/                  # Platform Channel bindings to Layer 3
│   ├── transport_adapter.dart         # Abstract Dart Transport Interface
│   ├── native_transport_bridge.dart   # MethodChannel / EventChannel implementation
│   └── models/                        # Serialized peer & packet DTOs
```

---

## 2. Recommended Dependencies

| Package | Purpose | Justification |
| :--- | :--- | :--- |
| **`flutter_riverpod`** (v2.5+) | State Management | Reactive, safe dependency injection, easily testable without BuildContext. |
| **`drift`** + **`sqlite3_flutter_libs`** | Local DB Storage | Type-safe reactive SQLite ORM for offline message queues and contact caching. |
| **`flutter_secure_storage`** | Key Storage | Stores private cryptographic keys in Android Keystore / iOS Keychain safely. |
| **`permission_handler`** | System Permissions | Simplifies requesting Android 12+ Nearby, BLE, and Location permissions. |
| **`cryptography`** | Dart Crypto Primitives| Provides Ed25519, X25519, and ChaCha20-Poly1305 in pure Dart for MVP. |
| **`logger`** | Structured Logging | Color-coded console logs for internal debugging and packet tracing. |

---

## 3. State Management Paradigm (Riverpod)

```
[ UI Component (ChatScreen) ]
             |
             | Ref.watch(chatControllerProvider)
             v
[ ChatController (StateNotifier / AsyncNotifier) ]
             |
             | Calls CoreEngine facade
             v
[ Core Communication Engine Layer ]
```

### Key Providers:
- **`transportBridgeProvider`**: Singleton provider managing platform channel lifecycle.
- **`nearbyPeersProvider`**: StreamProvider emitting `List<PeerDevice>` discovered by native radios.
- **`conversationProvider(peerId)`**: Notifier managing message list for a specific peer.
- **`debugLogsProvider`**: StateNotifier recording recent raw packet events for the debug overlay.

---

## 4. Dart Transport Interface Contract (`TransportAdapter`)

To isolate Flutter from platform channel details, all native platform calls must implement the `TransportAdapter` interface:

```dart
/// Abstract interface exposing physical radio operations to Dart.
abstract class TransportAdapter {
  /// Initialize native transport listeners and platform channels.
  Future<void> initialize();

  /// Start scanning for nearby peer devices.
  Future<void> startDiscovery();

  /// Stop active peer scanning to conserve power.
  Future<void> stopDiscovery();

  /// Initiate direct connection to a discovered peer.
  Future<void> connectPeer(String peerId);

  /// Terminate connection with a peer.
  Future<void> disconnectPeer(String peerId);

  /// Transmit raw encrypted bytes to a peer over native radio.
  Future<bool> sendPacket(String peerId, List<int> rawPacketBytes);

  /// Stream emitting status updates for peer discovery and connection lifecycle.
  Stream<PeerConnectionEvent> get peerEvents;

  /// Stream emitting incoming raw packet byte arrays from native radio.
  Stream<IncomingPacketEvent> get incomingPackets;
}
```

---

## 5. Screen Inventory & Flow Navigation

1. **Permissions Onboarding Screen**: Mandatory initial flow explaining why Bluetooth, Nearby Devices, and Location permissions are required for offline P2P communication.
2. **Nearby Discovery Screen**: Radar/list view showing nearby discovered OMNILINK devices, signal strength (RSSI), and connection buttons.
3. **Conversation List Screen**: List of all active/past 1:1 direct threads with last message timestamp and delivery status indicators.
4. **Chat Screen**: Text messaging interface, message delivery status icons (Sending `⏳`, Sent `✓`, Delivered `✓✓`, Failed `❌`), and manual re-transmit trigger.
5. **Debug Log Overlay**: Slide-over terminal panel showing real-time raw JSON packets, platform channel events, and cryptographic verification logs.

---

## 6. Testing Strategy for UI Layer

- **Widget Tests**: Mock `TransportAdapter` using Riverpod overrides to test UI reaction to peer discovery, incoming messages, and connection drops without native hardware.
- **Unit Tests**: Verify `ChatController` state transitions, message queue sorting, and input validation.
