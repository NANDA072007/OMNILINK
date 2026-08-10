# Document 15: Project Risk Register

## 1. Executive Summary

This risk register identifies technical, operational, legal, and security risks associated with building the OMNILINK offline communication platform, along with likelihood, impact, and mitigation strategies.

---

## 2. Risk Matrix

| Risk ID | Risk Description | Category | Likelihood | Impact | Mitigation Strategy | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **RSK-01** | **iOS Background Suspension**: Apple iOS suspends BLE/Multipeer discovery when app is backgrounded, breaking passive relaying. | Technical | **High** | **High** | Design user-facing foreground modes; prioritize BLECentral background scanning; focus Phase 1 on Android. | Active |
| **RSK-02** | **Android Permission Complexity**: Fragmented Android API permission requirements (API 29 vs 31 vs 33 vs 34) confuse users. | UX / Technical | **High** | Medium | Implement transparent, friction-free onboarding UI explaining exact radio permissions. | Active |
| **RSK-03** | **Battery Exhaustion**: Continuous radio scanning drains smartphone batteries rapidly. | Hardware | **High** | **High** | Duty-cycled burst scanning; optional user-controlled Foreground Service; clear battery warnings in UX. | Active |
| **RSK-04** | **Aggressive OEM App Kills**: Manufacturer Android ROMs (Xiaomi MIUI, Samsung Device Care, Huawei) kill background services regardless of foreground notification. | Platform | **High** | Medium | Document transparently that continuous offline listening survival cannot be guaranteed on all aggressive OEM devices; instruct users to disable OEM battery optimization manually. | Active |
| **RSK-05** | **Emergency Liability**: Users rely on app during life-threatening crises expecting 911 connectivity. | Legal | Medium | **Critical** | Mandatory safety disclaimers in onboarding and SOS modal stating app is NOT connected to emergency services. | Active |
| **RSK-06** | **Mesh Broadcast Spam / DoS**: Malicious nodes flood local mesh with junk packets, exhausting radio bandwidth. | Security | Medium | Medium | Strict TTL limits (`max_hops=7`), rate limiting (max 10 pkts/sec), 4 KB MTU ceiling, and instant peer blocklisting. | Planned |
| **RSK-07** | **Trademark / Naming Conflict**: `OMNILINK` brand name collides with existing commercial trademarks. | Legal | Medium | Low | Maintain `OMNILINK` as internal codename only until trademark search clears public launch name. | Active |
| **RSK-08** | **Crypto Implementation Bug**: Improper key storage or static nonce reuse leads to message decryption vulnerability. | Security | Low | **Critical** | Standard primitives only (Ed25519, X25519, ChaCha20-Poly1305 AEAD); 6-digit SAS transcript derivation. | Active |
| **RSK-09** | **Routing Loops**: Packets circulate infinitely between relays Node A, B, and C. | Architecture| Low | Medium | Mandatory LRU packet ID hash cache and decrementing TTL counters. | Mitigated |
