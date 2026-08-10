# OMNILINK

> **Transport-Agnostic Offline Communication Network**

---

> [!WARNING]
> **INTERNAL CODENAME WARNING**
> `OMNILINK` is an internal development codename. Public release will require trademark validation, brand availability checks, and legal clearance.

> [!IMPORTANT]
> **SAFETY & EMERGENCY DISCLAIMER**
> OMNILINK is an experimental peer-to-peer / mesh communication system intended for secondary or off-grid messaging. **IT IS NOT A REPLACEMENT FOR EMERGENCY SERVICES (E.G., 911, 112, 999 OR OFFICIAL EMERGENCY FIRST RESPONDERS).** Do not rely on OMNILINK as your sole means of communication in life-threatening situations.

---

## 👁️ Vision

To empower human communication when traditional infrastructure fails, is congested, is shut down, or is unavailable—enabling resilient, peer-to-peer, encrypted messaging directly between devices without relying on cellular towers or central servers.

## 🚨 Problem Statement

Modern mobile communication relies entirely on centralized infrastructure (cellular towers, ISPs, cloud servers). When natural disasters, physical grid failures, political shutdowns, or extreme network congestion (concerts, stadium events) occur, standard communication breaks down completely. Existing offline solutions often require specialized hardware (e.g., LoRa radios, walkie-talkies) or fail to operate cross-platform seamlessly.

## 💡 Solution Overview

OMNILINK leverages existing smartphone hardware radios (Bluetooth Classic, BLE, Wi-Fi Direct, Wi-Fi Aware, local Wi-Fi networks) to construct a dynamic, peer-to-peer communication fabric. Data travels hop-by-hop across nearby devices using adaptive transport selection, store-and-forward mechanisms, and end-to-end encryption.

```
+-------------+       Wi-Fi Direct       +-------------+       Bluetooth        +-------------+
|  Node A     | -----------------------> |  Node B     | ---------------------> |  Node C     |
| (Sender)    |                          | (Relay)     |                        | (Recipient) |
+-------------+                          +-------------+                        +-------------+
```

## 🏗️ 3-Layer Architecture Summary

OMNILINK strictly separates concerns across 3 primary layers:

1. **UI / Application Layer (Flutter / Dart)**: Responsible exclusively for user experience, chat interfaces, settings, state management, and local presentation logic.
2. **Core Communication Engine Layer (Dart for MVP / Rust long-term)**: The brain of the system. Manages cryptographic identity, packet construction, end-to-end encryption, deduplication, message queues, state machine, and routing rules.
3. **Transport / Native Radio Layer (Kotlin on Android / Swift on iOS)**: Handles physical hardware radio management, peer discovery, low-level link establishment, and raw binary packet transmission over platform-native APIs.

```
+-------------------------------------------------------------+
|                 1. UI / Application Layer                   |
|                   (Flutter / Dart UI)                       |
+-------------------------------------------------------------+
                              | Platform Channels (Method/Event)
+-------------------------------------------------------------+
|            2. Core Communication Engine Layer               |
|            (Identity, Crypto, Queue, Routing)               |
+-------------------------------------------------------------+
                              | Transport Interface API
+-------------------------------------------------------------+
|              3. Transport / Native Radio Layer              |
|        (Android: Kotlin / Nearby Connections / BLE / Wi-Fi) |
|        (iOS: Swift / Multipeer / CoreBluetooth)             |
+-------------------------------------------------------------+
```

## 📱 Flutter Choice Rationale

Flutter was selected for Layer 1 to enable rapid UI prototyping, cross-platform code reuse between Android and iOS, and leverage a reactive UI paradigm. **Flutter does not directly manipulate physical low-level radio APIs**; instead, it delegates radio operations to native platform code via standard `MethodChannel` and `EventChannel` constructs.

## 🎯 MVP Scope (Android Direct Messaging)

The initial Minimum Viable Product (MVP) is strictly bounded:
- **Goal**: Two Android devices discover each other, establish a direct local connection over **Android Nearby Connections API**, and exchange an end-to-end encrypted text message without cellular or internet access.
- **In Scope**: Flutter UI, Android Native Transport (Kotlin), 1:1 direct connection, manual pairing/discovery, basic end-to-end encryption (Ed25519/X25519/ChaCha20-Poly1305), delivery status lifecycle, debug logs.
- **Out of Scope**: Multi-hop relay, store-and-forward, iOS support, file/media transfers, group chats, internet gateway bridging, custom hardware, Rust core extraction.

## 📂 Repository Structure

```
OMNILINK/
├── README.md
├── CHANGELOG.md
├── .gitignore
├── docs/                      # Architectural documentation & design packs
│   ├── 00_project_overview.md
│   ├── 01_mvp_scope.md
│   ├── 02_system_architecture.md
│   ├── 03_flutter_architecture.md
│   ├── 04_core_communication_engine.md
│   ├── 05_protocol_spec.md
│   ├── 06_identity_and_security.md
│   ├── 07_transport_abstraction.md
│   ├── 08_platform_channel_design.md
│   ├── 09_android_native_transport_design.md
│   ├── 10_ios_feasibility_report.md
│   ├── 11_data_model.md
│   ├── 12_message_state_machine.md
│   ├── 13_permissions_and_ux.md
│   ├── 14_test_plan.md
│   ├── 15_risk_register.md
│   ├── 16_roadmap.md
│   ├── 17_decision_log.md
│   ├── 18_task_breakdown.md
│   └── 19_tech_stack.md
├── spec/                      # Technical specifications & packet schemas
│   ├── packets.md
│   ├── messages.md
│   ├── transports.md
│   ├── security.md
│   └── platform_channels.md
└── tests/                     # Manual and automated verification suites
    └── manual_test_checklists/
        └── android_direct_mvp.md
```

---
*Status: Initial Architecture & Specification Stage (Pre-code Phase).*
