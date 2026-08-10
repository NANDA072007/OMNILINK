# Document 18: Task Breakdown & Sprint Plan (Milestone 1 MVP)

## 1. Overview

This document breaks down **Milestone 1 (Android Direct MVP)** into granular developer tasks with dependencies, estimated sizes, and acceptance criteria.

---

## 2. Task Backlog

| Task ID | Task Name | Component | Est. Size | Dependencies | Acceptance Criteria |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **TSK-01** | **Repository Structure Setup** | Infra | S | None | Directory structure (`lib/`, `android/`, `docs/`, `spec/`, `tests/`) matches specification. |
| **TSK-02** | **Flutter App Initialization** | Flutter UI | S | TSK-01 | Flutter app compiles cleanly in Android Studio with Riverpod dependency. |
| **TSK-03** | **UI Navigation Skeleton** | Flutter UI | M | TSK-02 | Bottom navigation switches between Nearby Peers, Chat List, Settings, and Debug Log screens. |
| **TSK-04** | **Dart Transport Interface** | Dart Engine | S | TSK-02 | `TransportAdapter` abstract class defined with required methods and event streams. |
| **TSK-05** | **Platform Channel Binding** | Bridge | M | TSK-04 | `NativeTransportBridge` connects to `MethodChannel("omnilink/transport/control")`. |
| **TSK-06** | **Android Permission Manager** | Kotlin Native| M | TSK-01 | Native plugin handles Android 12+ `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, and `NEARBY_WIFI_DEVICES`. |
| **TSK-07** | **Nearby Connections Wrapper** | Kotlin Native| L | TSK-06 | `NearbyConnectionsManager.kt` initializes `ConnectionsClient` with `Strategy.P2P_CLUSTER`. |
| **TSK-08** | **Native Event Stream Handler**| Kotlin Native| M | TSK-07 | `onPeerFound`, `onPeerLost`, `onConnected`, `onPacketReceived` events stream to Flutter. |
| **TSK-09** | **Dart Keypair Identity Setup**| Dart Engine | M | TSK-02 | Generates Ed25519 keypair and persists in `flutter_secure_storage`. |
| **TSK-10** | **E2E Payload Cryptography** | Dart Engine | M | TSK-09 | ChaCha20-Poly1305 encryption/decryption functions pass unit tests. |
| **TSK-11** | **Protocol Envelope Handler** | Dart Engine | M | TSK-10 | Formats JSON Protocol v0.1 envelopes with signatures and packet IDs. |
| **TSK-12** | **Outbound Message Sending Flow**| Flutter UI | M | TSK-05, TSK-11 | Tapping "Send" in ChatScreen encrypts message and invokes `sendPacket` platform method. |
| **TSK-13** | **Inbound Message Receiving Flow**| Flutter UI | M | TSK-08, TSK-11 | Incoming packet payload decrypts and appends to active chat thread. |
| **TSK-14** | **Message Delivery Status UI** | Flutter UI | S | TSK-12 | Chat bubble shows status indicators (`QUEUED`, `SENDING`, `DELIVERED`, `FAILED`). |
| **TSK-15** | **In-App Debug Log Overlay** | Flutter UI | S | TSK-08 | Slide-over drawer renders live stream of raw JSON packets and platform channel logs. |
| **TSK-16** | **Two-Device Manual Validation**| QA | L | TSK-14 | All test cases in `tests/manual_test_checklists/android_direct_mvp.md` pass 100%. |
