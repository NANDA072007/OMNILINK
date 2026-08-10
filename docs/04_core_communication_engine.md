# Document 04: Core Communication Engine Specification

## 1. Engine Responsibilities & Domain Boundary

The **Core Communication Engine (Layer 2)** functions as the central brain of OMNILINK. It operates independently of physical UI rendering and low-level radio driver mechanics.

```text
                               +----------------------------------------+
                               |     CORE COMMUNICATION ENGINE (L2)     |
                               |                                        |
  Inbound Packets from         |  [ Packet Deserializer & Validator ]   |
  Native Transport             |                   |                    |
  ---------------------------> |  [ Deduplication Hash Cache ]          |
                               |                   |                    |
                               |  [ Key Manager & Payload Decryptor ]   |
                               |                   |                    |
                               |  [ State Machine & Outbox Queue ]      |
                               +----------------------------------------+
                                                   |
                                                   v
                                        Delivered to UI Layer
```

---

## 2. Component Breakdown

### 2.1 Identity & Key Manager
- Generates and persists the device's master **Ed25519** signing keypair.
- Derives or negotiates ephemeral **X25519** key pairs for session encryption.
- Computes public key fingerprints (`SHA-256` of Ed25519 Public Key) used as canonical `Device Node IDs`.

### 2.2 Packet Processor & Serializer
- Formats outbound messages into standardized **OMNILINK Protocol Packets (ver 0.1)**.
- Encrypts payload contents using **ChaCha20-Poly1305 AEAD**.
- Signs header metadata with the sender's Ed25519 private key.
- Validates signature integrity, timestamp freshness, and TTL limits upon receiving inbound packets.

### 2.3 Deduplication & Replay Prevention Engine
- Maintains an in-memory **LRU Hash Ring** of recently processed `packet_id`s (TTL bounded, default 24 hours).
- Drops duplicate packets immediately to prevent forwarding loops and replay attacks.

### 2.4 Outbox & Queue Dispatcher
- Manages an offline persistent SQLite outbox (`drift`).
- Tracks state lifecycle of outbound packets (`QUEUED` -> `SENDING` -> `DELIVERED`).
- Implements exponential backoff retry algorithms when transmission over native radio fails.

### 2.5 TTL & Routing Engine (Future Phase)
- Bypassed in MVP (MVP uses direct single-hop point-to-point transmission).
- Future Phase: Handles hop count decrementing, multi-hop route evaluation, epidemic epidemic flooding, and store-and-forward storage policy.

---

## 3. MVP Implementation vs. Long-Term Rust Core Roadmap

### 3.1 MVP Implementation (Phase 1: Pure Dart)
For the MVP, Layer 2 is written entirely in **Dart** within the Flutter project:
- **Pros**: Zero native C/C++ build toolchain complexity, zero FFI memory marshaling overhead, instant hot reload.
- **Crypto Library**: Standard `cryptography` package in Dart (backed by native OS C-bindings where available).

### 3.2 Long-Term Implementation (Phase 13: Rust Core Engine)
Once protocol rules stabilize, Layer 2 will be extracted into a standalone **Rust static library (`omnilink_core`)**:

```text
                       +-----------------------------------+
                       |         omnilink_core             |
                       |       (Pure Rust C-ABI)           |
                       +-----------------------------------+
                         /               |               \
                        /                |                \
            Flutter Mobile          Linux Gateway       Embedded / Micro
          (Android / iOS FFI)       (Daemon App)       (LoRa Relay Box)
```

- **Why Rust?**:
  1. Memory safety without garbage collection pauses.
  2. Single shared codebase across Android (JNI via `flutter_rust_bridge`), iOS (Swift C-interop), Linux servers, and embedded microcontrollers.
  3. High performance serialization and cryptographic operations.

---

## 4. Key Data Structures (Pseudocode)

```dart
/// Representation of an active protocol engine state.
class EngineStatus {
  final String localNodeId;
  final int activePeerCount;
  final int outboxPendingCount;
  final int deduplicationCacheSize;

  EngineStatus({
    required this.localNodeId,
    required this.activePeerCount,
    required this.outboxPendingCount,
    required this.deduplicationCacheSize,
  });
}

/// Outbound queue item waiting for transmission.
class PendingOutboxMessage {
  final String messageId;
  final String recipientNodeId;
  final List<int> serializedEncryptedPacket;
  final DateTime queuedAt;
  int retryAttempts;

  PendingOutboxMessage({
    required this.messageId,
    required this.recipientNodeId,
    required this.serializedEncryptedPacket,
    required this.queuedAt,
    this.retryAttempts = 0,
  });
}
```
