# Document 17: Architectural Decision Log (ADR)

## 1. Overview

This document records the foundational architectural decisions made for the OMNILINK project in Architecture Decision Record (ADR) format.

---

## 2. Decision Records

### ADR-01: Internal Codename Usage
- **Status**: ACCEPTED
- **Context**: The project requires an identifier during development before legal brand availability checks are completed.
- **Decision**: Use `OMNILINK` as the internal codename. All documentation and code namespaces will use `omnilink`. Public release will require trademark validation.

### ADR-02: Flutter for Layer 1 Presentation
- **Status**: ACCEPTED
- **Context**: Rapid cross-platform UI development is needed for Android and future iOS support.
- **Decision**: Adopt Flutter / Dart for Layer 1 (UI and high-level app flow).
- **Consequences**: Flutter allows a single codebase for UI, but must NOT directly touch low-level radio APIs.

### ADR-03: Native Kotlin for Android Transport Layer
- **Status**: ACCEPTED
- **Context**: Low-level radio APIs (Bluetooth, Wi-Fi Direct, Nearby Connections) require direct platform OS access.
- **Decision**: Implement Layer 3 on Android using native Kotlin.

### ADR-04: Platform Channel Bridge (MethodChannel & EventChannel)
- **Status**: ACCEPTED
- **Context**: Flutter must communicate asynchronously with native Kotlin radio drivers.
- **Decision**: Use `MethodChannel` for imperative controls (`startDiscovery`, `sendPacket`) and `EventChannel` for streaming events (`onPeerFound`, `onPacketReceived`).

### ADR-05: Single Transport (Nearby Connections API) for MVP
- **Status**: ACCEPTED
- **Context**: MVP must remain simple and fast to execute without complex multi-radio orchestration logic.
- **Decision**: Use Google Nearby Connections API as the exclusive native transport for Phase 1 MVP.

### ADR-06: Dart Core Communication Engine for MVP
- **Status**: ACCEPTED
- **Context**: Avoid premature build-toolchain complexity during early prototyping.
- **Decision**: Write Layer 2 Core Engine in pure Dart for Phase 1 MVP.

### ADR-07: Defer Rust Core Extraction to Phase 13
- **Status**: ACCEPTED
- **Context**: Rust provides cross-platform portability across mobile, desktop, and embedded devices, but adds FFI overhead early on.
- **Decision**: Defer Rust core extraction until protocol rules and mobile prototypes are proven on Android.

### ADR-08: Standard Cryptographic Primitives Only
- **Status**: ACCEPTED
- **Context**: Custom cryptography introduces critical vulnerability risks.
- **Decision**: Mandate standard primitives: Ed25519 (Signatures), X25519 (ECDH), ChaCha20-Poly1305 (AEAD Encryption), SHA-256 (Hashing).

### ADR-09: Postpone iOS Native Implementation Until Phase 5/9
- **Status**: ACCEPTED
- **Context**: iOS enforces strict background radio restrictions that require focused research.
- **Decision**: Complete Android MVP (Phase 4) first before building native Swift iOS drivers.

### ADR-10: Postpone Dedicated Relay Hardware to Phase 14
- **Status**: ACCEPTED
- **Context**: Hardware integration (ESP32/LoRa) distracts from core software protocol validation.
- **Decision**: Focus exclusively on standard mobile phone hardware radios first.
