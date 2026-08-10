# Document 16: Project Roadmap (Phase 0 to Phase 14)

## 1. Roadmap Overview

The development roadmap is structured into 15 progressive phases, moving from initial architectural planning to cross-platform deployment, multi-hop mesh routing, and custom hardware integration.

```text
[ Phase 0 - 1 ]   Architecture, Risk Validation & Protocol Specifications (COMPLETED)
       |
       v
[ Phase 2 - 4 ]   Flutter Setup, Android Platform Channel & Direct 1:1 MVP (CURRENT TARGET)
       |
       v
[ Phase 5 - 6 ]   iOS Feasibility Spike & Core Protocol Hardening
       |
       v
[ Phase 7 - 8 ]   Multi-hop Mesh Relay & Offline Store-and-Forward Engine
       |
       v
[ Phase 9 - 11]   Cross-Platform iOS/Android BLE Interop & Internet Gateways
       |
       v
[ Phase 12- 14]   Rust Core Extraction & Dedicated Relay Hardware Integration
```

---

## 2. Detailed Phase Breakdown

### Phase 0: Naming, Research & Risk Validation
- **Goal**: Establish project feasibility, perform risk evaluation, define internal codename (`OMNILINK`).
- **Deliverable**: Initial research notes & risk matrix.

### Phase 1: Pre-Code Documentation & Protocol Specification
- **Goal**: Produce complete pre-code specification pack.
- **Deliverables**: Architecture docs 00-19, protocol spec v0.1, data models, manual test checklists.

### Phase 2: Flutter Project Setup & UI Skeleton
- **Goal**: Initialize Flutter workspace in Android Studio with Riverpod state management and feature screens.
- **Deliverables**: Runnable Flutter app shell with Chat, Nearby Peers, Settings, and Debug views.

### Phase 3: Android Platform Channel Prototype
- **Goal**: Implement Kotlin `MethodChannel` and `EventChannel` bindings for radio control.
- **Deliverables**: Basic Dart-to-Kotlin handshake logging ping/pong events.

### Phase 4: Android Direct Messaging MVP (Phase 1 Target Milestone)
- **Goal**: Two physical Android devices exchange an encrypted text message directly via Nearby Connections API.
- **Deliverables**: Fully passing `android_direct_mvp.md` manual checklist execution.

### Phase 5: iOS Feasibility Spike
- **Goal**: Build small iOS Swift prototype testing CoreBluetooth and MultipeerConnectivity background limits.
- **Deliverables**: iOS feasibility report and cross-platform BLE design.

### Phase 6: Core Protocol Hardening
- **Goal**: Formalize binary CBOR encoding, signature verification, and timestamp expiry checks.
- **Deliverables**: Automated test suite for protocol envelopes and key management.

### Phase 7: Android Multi-Hop Relay
- **Goal**: Enable Node B to relay an encrypted message from Node A to Node C without decrypting payload.
- **Deliverables**: 3-node Android relay test verification.

### Phase 8: Offline Store-and-Forward Engine
- **Goal**: Buffer encrypted messages in local SQLite database when target is offline, flushing when peer reconnects.
- **Deliverables**: Asynchronous store-and-forward queue dispatcher.

### Phase 9: Android <-> iOS Cross-Platform Support
- **Goal**: Direct BLE GATT socket communication between an iPhone and an Android phone.
- **Deliverables**: Dual-platform P2P text exchange.

### Phase 10: Heterogeneous Transport Routing
- **Goal**: Dynamic switching between BLE (low power) and Wi-Fi Direct (high bandwidth).
- **Deliverables**: Adaptive transport manager core component.

### Phase 11: Internet Gateway Synchronization
- **Goal**: Opportunistically upload buffered mesh messages to cloud servers when a node gains cellular/Wi-Fi internet access.
- **Deliverables**: Hybrid mesh-to-cloud bridge adapter.

### Phase 12: Security, UX & Battery Hardening
- **Goal**: Duty-cycle radio scanning, audit cryptographic key storage, refine permission onboarding.
- **Deliverables**: Low-power battery profile (< 3% drain/hour).

### Phase 13: Portable Rust Core Extraction
- **Goal**: Re-write Layer 2 Core Engine in Rust (`libomnilink_core.a`) and bind via FFI.
- **Deliverables**: Unified Rust core running on Android and iOS.

### Phase 14: Dedicated Relay Hardware
- **Goal**: Support ESP32 / LoRa static relay nodes running the Rust core for long-range wilderness mesh coverage.
- **Deliverables**: Custom hardware firmware integration.
