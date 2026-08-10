# Changelog

All notable changes to the OMNILINK project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Created complete pre-code documentation and technical specification pack:
  - System Architecture (`docs/02_system_architecture.md`)
  - Flutter UI Architecture (`docs/03_flutter_architecture.md`)
  - Core Communication Engine Spec (`docs/04_core_communication_engine.md`)
  - Protocol v0.1 Specification (`docs/05_protocol_spec.md` & `spec/packets.md`)
  - Identity & Security Model (`docs/06_identity_and_security.md` & `spec/security.md`)
  - Transport Abstraction Layer (`docs/07_transport_abstraction.md` & `spec/transports.md`)
  - Platform Channels Design (`docs/08_platform_channel_design.md` & `spec/platform_channels.md`)
  - Native Android Transport Design (`docs/09_android_native_transport_design.md`)
  - iOS Feasibility & Research (`docs/10_ios_feasibility_report.md`)
  - Local Data Models & State Machine (`docs/11_data_model.md`, `docs/12_message_state_machine.md`)
  - Test Plans & Manual Checklists (`docs/14_test_plan.md`, `tests/manual_test_checklists/android_direct_mvp.md`)
  - Risk Register, Roadmap, Task Breakdown, and Tech Stack Specs (`docs/15_risk_register.md` to `docs/19_tech_stack.md`).
- Implemented OMNILINK Milestone 1 codebase:
  - Core domain models (`Message`, `PeerDevice`, `PacketEnvelope`).
  - Core cryptographic engine in Dart (`CryptoService`, `PacketService`).
  - Transport abstraction layer & platform channel contract (`TransportAdapter`, `AndroidTransportAdapter`, `MockTransportAdapter`).
  - Native Kotlin Android plugin (`OmnilinkTransportPlugin.kt`, `NearbyConnectionsManager.kt`, `OmnilinkForegroundService.kt`, `MainActivity.kt`).
  - Android permissions configuration & Google Nearby Connections API integration (`play-services-nearby:19.3.0`).
  - Presentation UI shell (`DiscoveryScreen`, `ChatScreen`) using Riverpod state management (`providers.dart`).

### Decisions
- Adopted 3-Layer Architecture separating UI (Flutter), Core Engine (Dart/Rust), and Transport (Kotlin/Swift).
- Selected **Android Nearby Connections API** as the primary native transport for Phase 1 MVP.
- Decided on **Ed25519** (signatures/identity), **X25519** (key exchange), and **ChaCha20-Poly1305** (AEAD encryption) for security.
- Scope-locked MVP to 2 Android devices exchange 1 direct encrypted text message.
