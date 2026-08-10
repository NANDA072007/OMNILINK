# Document 01: MVP Scope Specification

## 1. Executive Summary & MVP Statement

The Minimum Viable Product (MVP) for **OMNILINK** is strictly defined to prove the core feasibility of offline, device-to-device encrypted messaging on Android using native radios and a Flutter presentation layer.

> **MVP Feasibility Statement**:
> "Two physical Android devices, running the OMNILINK Flutter application without SIM cards, cellular data, or external Wi-Fi routers, can discover each other over local native radios, establish an authenticated secure channel, and exchange an end-to-end encrypted text message."

---

## 2. MVP User Story

```text
AS AN offline user without internet or cellular connectivity,
I WANT TO discover a nearby contact's Android device and send them an encrypted text message,
SO THAT we can communicate directly over local radio without relying on third-party infrastructure.
```

---

## 3. Strict Boundary Matrix: In-Scope vs. Out-of-Scope

### 3.1 In-Scope Features (MVP Phase 1)
- **Target OS**: Android 10+ (API Level 29+).
- **Device Count**: Exactly 2 physical Android devices (1:1 connection).
- **Transport**: **Android Nearby Connections API** (P2P Cluster / Point-to-Point mode over Wi-Fi + Bluetooth hybrid).
- **Presentation Layer**: Flutter UI (Single codebase for view logic).
- **Native Radio Adapter**: Kotlin-based platform channel implementation.
- **Cryptography**:
  - Device Identity: Ed25519 Keypair generation & local persistence.
  - Ephemeral Key Exchange: X25519 (ECDH).
  - Payload Encryption: ChaCha20-Poly1305 AEAD.
- **Message Types**: Plaintext short messages (maximum 500 characters).
- **State Machine**: Message status tracking (`DRAFT` -> `QUEUED` -> `SENDING` -> `DELIVERED` -> `FAILED`).
- **Permissions**: Runtime handling for Bluetooth, Location, and Nearby Devices on Android.
- **Logging**: In-app scrollable debug/log overlay to verify packet tx/rx.

### 3.2 Out-of-Scope Features (Deferred to Future Phases)
- 🚫 **iOS Support**: No Swift code, no Apple MultipeerConnectivity for MVP.
- 🚫 **Multi-hop Relay**: No forwarding through Node C (A -> B direct only).
- 🚫 **Store-and-Forward**: Messages fail if recipient is offline at transmit time.
- 🚫 **Media & File Attachments**: No images, audio files, or documents.
- 🚫 **Group Messaging**: 1:1 chat rooms only.
- 🚫 **Automatic Multi-Transport Failover**: Single static transport selected (Nearby Connections).
- 🚫 **Internet Gateways**: No synchronization back to cloud servers.
- 🚫 **Rust Core Engine**: MVP engine written cleanly in Dart/Kotlin.
- 🚫 **Dedicated Mesh Hardware**: No ESP32, LoRa, or custom hardware integration.

---

## 4. Key Assumptions

1. Both physical test devices are in physical proximity (within 10–20 meters).
2. Users grant all requested Android system permissions (Bluetooth, Location, Nearby Devices).
3. Google Play Services is available on target Android test devices to support the Nearby Connections API.
4. The test app runs in the foreground during peer discovery and message exchange.

---

## 5. Open Questions & Architectural Decisions

| # | Question | Decision / Workaround for MVP | Impact |
| :--- | :--- | :--- | :--- |
| **Q1** | Should Nearby Connections use `P2P_CLUSTER` or `P2P_POINT_TO_POINT` strategy? | Use **`P2P_CLUSTER`**. Allows future multi-device mesh expansion without changing strategy. | Simplifies transport migration in Phase 2. |
| **Q2** | Where should key generation and encryption occur in the MVP? | **Dart Layer** using standard high-level crypto bindings, or **Kotlin Layer**. Dart crypto (`cryptography` package) keeps MVP zero-dependency native-side. | Speeds up MVP development. |
| **Q3** | How do we display raw packet exchanges for debugging? | Implement an in-app EventChannel stream feed to a dedicated "Debug Logs" UI screen. | Crucial for manual test verification. |

---

## 6. MVP Success Criteria

1. **Discovery Success**: Device A discovers Device B within 15 seconds of tapping "Start Discovery".
2. **Connection Success**: Devices exchange cryptographic identities and form a secure channel within 10 seconds of user acceptance.
3. **Payload Integrity**: Device A sends `"Hello OMNILINK"` -> Device B receives and decrypts `"Hello OMNILINK"` with 100% byte fidelity.
4. **Status Acknowledgment**: Device A's UI transitions message state from `SENDING` to `DELIVERED` upon receiving native ACK from Device B.

---

## 7. Definition of Done (DoD) for MVP

- [ ] Flutter app builds cleanly on Android Studio.
- [ ] Kotlin plugin correctly registers `MethodChannel` and `EventChannel`.
- [ ] App requests and handles all Android 12+ / 13+ runtime permissions smoothly.
- [ ] Two real physical Android phones complete a direct messaging session without internet.
- [ ] End-to-end encryption keys are generated, safely stored in `flutter_secure_storage`, and verified.
- [ ] All manual test steps in `tests/manual_test_checklists/android_direct_mvp.md` pass successfully.
