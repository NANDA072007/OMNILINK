# Document 02: Overall System Architecture

## 1. Architectural Philosophy & Layered Blueprint

OMNILINK adheres strictly to a **3-Layer Architecture Pattern**. This separation guarantees that user interface concerns, network business rules, and low-level physical radio implementations remain decoupled, testable, and cross-platform capable.

```
+-----------------------------------------------------------------------+
|                      LAYER 1: UI / APPLICATION                        |
|                           (Flutter / Dart)                            |
|                                                                       |
|  - Chat UI Screen          - Contacts Screen       - Nearby Peer UI   |
|  - SOS / Emergency UI      - Debug & Log Overlay   - App State (Bloc) |
+-----------------------------------------------------------------------+
                                  |
                                  | Flutter Platform Channels
                                  | (MethodChannel & EventChannel)
                                  v
+-----------------------------------------------------------------------+
|                 LAYER 2: CORE COMMUNICATION ENGINE                    |
|                (Dart in MVP -> Portable Rust Core)                    |
|                                                                       |
|  - Cryptographic Identity   - Packet Encoding/Decoding (JSON/CBOR)   |
|  - E2E Payload Crypto       - Deduplication & Replay Hash Cache       |
|  - Message State Machine    - Outbox / Store-and-Forward Queue        |
|  - TTL & Hop Counter Logic  - Opportunistic Mesh Routing Protocol     |
+-----------------------------------------------------------------------+
                                  |
                                  | Abstract Transport Interface
                                  | (Kotlin Interface / Swift Protocol)
                                  v
+-----------------------------------------------------------------------+
|               LAYER 3: TRANSPORT / NATIVE RADIO LAYER                 |
|                  (Platform Native Implementations)                    |
|                                                                       |
|   +---------------------------------+  +---------------------------+  |
|   |         ANDROID (Kotlin)        |  |        iOS (Swift)        |  |
|   | - Nearby Connections API        |  | - MultipeerConnectivity   |  |
|   | - BLE Advertiser / Scanner      |  | - CoreBluetooth           |  |
|   | - Wi-Fi Direct Manager          |  | - Network.framework       |  |
|   +---------------------------------+  +---------------------------+  |
+-----------------------------------------------------------------------+
```

---

## 2. Layer Responsibilities & Strict Boundaries

### 2.1 Layer 1: UI / Application Layer
- **Technology**: Flutter / Dart (Riverpod or BLoC state management).
- **Responsibilities**:
  - Render screens (Chat, Peer List, Settings, Permissions Onboarding, Debug Logs).
  - Handle user input and format outbound messages.
  - Subscribe to message state streams to update UI indicators (Sending, Sent, Delivered, Failed).
  - Manage secure local persistence for UI configuration.
- **Strict Boundary Rules**:
  - 🚫 **MUST NOT** directly invoke Bluetooth, BLE, or Wi-Fi platform APIs.
  - 🚫 **MUST NOT** parse raw radio packet headers directly.

### 2.2 Layer 2: Core Communication Engine Layer
- **Technology**: Dart (MVP) -> Portable Rust Library (Long-term cross-platform core).
- **Responsibilities**:
  - Manage device identity keypairs (Ed25519) and session keys (X25519).
  - Encrypt message payloads before transmission and decrypt received payloads.
  - Wrap payloads into standard OMNILINK Protocol Envelopes (verifying Packet ID, TTL, Signatures).
  - Maintain the outbox message queue, store-and-forward buffer, and deduplication cache.
  - Handle routing tables, hop counters, and transport priority selection.
- **Strict Boundary Rules**:
  - 🚫 **MUST NOT** contain Flutter UI components or Flutter framework dependencies.
  - 🚫 **MUST NOT** bind directly to OS specific radio drivers without using abstract Transport interfaces.

### 2.3 Layer 3: Transport / Native Radio Layer
- **Technology**: Native Kotlin (Android) / Native Swift (iOS).
- **Responsibilities**:
  - Scan for nearby peers using OS-specific physical radio interfaces.
  - Establish low-level socket, GATT, or RFCOMM connections between hardware radios.
  - Transmit raw binary byte streams received from Layer 2.
  - Notify Layer 2 of peer discovery, loss, connection state, and incoming binary packets.
  - Manage OS wake locks, background service lifecycles, and system permissions.
- **Strict Boundary Rules**:
  - 🚫 **MUST NOT** attempt to decrypt or inspect encrypted packet payloads.
  - 🚫 **MUST NOT** handle chat UI formatting or business routing decisions.

---

## 3. Communication Bridges Between Layers

### 3.1 Layer 1 <-> Layer 2 Bridge
In the MVP (where Layer 2 is implemented in Dart), Layer 1 and Layer 2 execute in the same Dart Isolate. Clean OOP contracts isolate UI state management from core engine processing:
```dart
abstract class CoreEngineFacade {
  Future<void> sendMessage(String recipientId, String text);
  Stream<MessageStateUpdate> get messageStateStream;
  Stream<List<PeerDevice>> get nearbyPeersStream;
}
```

### 3.2 Layer 2 <-> Layer 3 Bridge (Platform Channels)
Communication between Dart (Layer 2) and Kotlin/Swift (Layer 3) occurs via standard Flutter platform channels:
- **`MethodChannel("omnilink/transport/control")`**: Imperative calls from Dart to native code (e.g., `startDiscovery()`, `connectPeer()`, `sendPacket()`).
- **`EventChannel("omnilink/transport/events")`**: Continuous asynchronous event streams from native code to Dart (e.g., `onPeerFound`, `onPeerLost`, `onPacketReceived`).

```
+------------------+   MethodChannel.invokeMethod()   +-------------------+
|  Dart (Layer 2)  | -------------------------------> |  Kotlin (Layer 3) |
|                  | <------------------------------- |  Native Transport |
+------------------+      EventChannel Sink Event     +-------------------+
```

---

## 4. Architectural Evolution Path (MVP to Production)

```
[ PHASE 1: MVP ]           [ PHASE 2: HARDENING ]         [ PHASE 3: LONG-TERM ]
+-------------------+      +-------------------+          +-------------------+
|  Flutter UI (Dart)|      |  Flutter UI (Dart)|          |  Flutter UI (Dart)|
+-------------------+      +-------------------+          +-------------------+
|  Core Engine (Dart)|     |  Core Engine (Dart)|         |  Core Engine (Rust|
+-------------------+      +-------------------+          |  via FFI / C-ABI) |
| Kotlin Transport  |      | Kotlin & Swift    |          +-------------------+
| (Nearby API)      |      | Native Transports |          | Native Transports |
+-------------------+      +-------------------+          +-------------------+
```

- **Phase 1 (MVP)**: Fast prototyping. Core Engine in Dart, Android-only Kotlin transport using Nearby Connections API.
- **Phase 2 (Multi-Transport)**: Add native BLE and Wi-Fi Direct abstractions in Kotlin, introduce Swift native transport layer for iOS.
- **Phase 3 (Rust Core Migration)**: Extract Layer 2 logic into a pure, thread-safe **Rust static library (`libomnilink_core.a` / `.so`)**. Use C-FFI / `flutter_rust_bridge` to run the exact same core engine on Android, iOS, Linux gateways, and dedicated hardware relays.
