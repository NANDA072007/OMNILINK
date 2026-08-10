# Document 00: Project Overview

## 1. Vision & Core Objective

OMNILINK is designed as a transport-agnostic, offline communication network. Its primary objective is to guarantee peer-to-peer data transmission between mobile devices when centralized telecom networks (cellular towers, internet backbones, DNS, local Wi-Fi routers) are unavailable, overloaded, degraded, or deliberately restricted.

The core philosophy of OMNILINK is **hardware ubiquity**. It does not require specialized LoRa dongles, satellite radios, or proprietary transceivers. Instead, it aggregates and orchestrates the existing radios present in modern smartphones—Bluetooth Classic, Bluetooth Low Energy (BLE), Wi-Fi Direct, Wi-Fi Aware, and Local Wi-Fi APs—into a seamless mesh fabric.

---

## 2. Problem Statement

### 2.1 The Single Point of Failure in Modern Communication
Every standard messaging application (WhatsApp, Signal, Telegram, iMessage) relies on an unbroken chain of centralized infrastructure:
1. Local device -> 2. Radio Access Network (Cell tower / Wi-Fi Router) -> 3. Internet Service Provider -> 4. Central Cloud Server -> 5. Recipient ISP -> 6. Recipient Device.

If *any link* in this chain breaks, communication fails completely.

### 2.2 Critical Failure Modes
- **Natural Disasters**: Earthquakes, floods, and hurricanes frequently sever power grids and knock out cellular base stations.
- **Extreme Density & Congestion**: Music festivals, sports events, and political rallies overload local cell towers, rendering data service unusable.
- **Remote / Off-Grid Environments**: Wilderness hiking, rural areas, maritime journeys, and search-and-rescue ops lack cellular coverage entirely.
- **Infrastructure Shutdowns**: Man-made blackouts or telecom disruptions cut off access to global servers.

### 2.3 Why Existing Offline Apps Fall Short
Existing offline peer-to-peer messaging applications suffer from four main flaws:
1. **Single Radio Lock-in**: Locking exclusively to BLE or Wi-Fi Direct limits bandwidth, range, or discovery speed.
2. **Platform Silos**: Poor interop between Android P2P protocols and iOS Multipeer framework.
3. **Battery Exhaustion**: Unoptimized continuous scanning drains device batteries within hours.
4. **Lack of Store-and-Forward Routing**: If the recipient is not currently online, messages drop instead of hopping through intermediate nodes asynchronously.

---

## 3. High-Level Solution Architecture

OMNILINK abstracts heterogeneous physical communications into a unified logical network:

```
[ Sender (Node A) ]
        |
        | (Wi-Fi Direct - High Throughput)
        v
[ Intermediate Relay (Node B) ]
        |
        | (BLE - Low Power / Range Extension)
        v
[ Intermediate Relay (Node C) ]
        |
        | (Store-and-Forward / Physical Mobility)
        v
[ Target Recipient (Node D) ]
```

### Key Solution Highlights
- **Zero-Knowledge Multi-Hop Forwarding**: Intermediate nodes relay packets securely without reading payload contents (End-to-End Encrypted via X25519 + ChaCha20-Poly1305).
- **Transport Abstraction**: The core engine treats radios as swappable `TransportAdapters` based on range, throughput, and power availability.
- **Asynchronous Store-and-Forward**: If Node D is out of range, Node C buffers the encrypted packet locally until Node D appears or another viable relay comes into proximity.

---

## 4. Example Use Cases & Flow Scenarios

### Use Case A: Off-Grid Wilderness Survival
- **Context**: A team of hikers in a deep canyon without cellular service.
- **Flow**: Hiker 1 sends an SOS alert. The packet broadcasts over BLE to Hiker 2 (50 meters away). Hiker 2 moves closer to base camp, where Hiker 3 receives the relayed packet over Wi-Fi Direct and displays the SOS location on their map.

### Use Case B: Disaster Recovery & Urban Grid Failure
- **Context**: An earthquake knocks out power and cell service across a city block.
- **Flow**: Citizen A seeks medical assistance. A message is composed and signed. Neighbor B's phone picks up the packet while passing Citizen A's house. Neighbor B walks toward a emergency relief center where Doctor C's device syncs with Neighbor B and receives Citizen A's message.

---

## 5. Long-Term Vision vs. MVP Scope

| Feature / Dimension | Initial MVP Scope (Phase 1) | Long-Term Target (Phase 10+) |
| :--- | :--- | :--- |
| **Target Platform** | Android Only | Android, iOS, Desktop, Linux Gateway |
| **Node Count** | Exactly 2 Nodes (Point-to-Point) | Infinite Multi-Hop Mesh |
| **Transport Protocol**| Android Nearby Connections API | BLE, Wi-Fi Direct, Wi-Fi Aware, Custom LoRa / Hardware |
| **Core Language** | Dart / Kotlin Hybrid | Portable Rust Core Engine |
| **Payload Types** | Short Plaintext Messages | Text, Images, Voice Snippets, Vector Map Data, SOS Alerts |
| **Routing Strategy** | Direct Single-Hop Link | Adaptive Opportunistic Routing (Epidemic / PRoPHET) |

---

## 6. Target Users & Persona Profiles

1. **The Outdoor Adventurer**: Requires reliable location & text sharing during off-grid wilderness trips.
2. **Emergency Preparedness / First Responder**: Needs low-power localized communication during power or grid outages.
3. **High-Density Event Goers**: Wants local peer messaging in crowded environments where cell networks stall.
4. **Privacy-Conscious Individuals**: Prefers serverless, zero-metadata-leakage peer communication.

---

## 7. Major Architectural Risks & Mitigations

1. **OS Radio Background Restrictions**: iOS and Android restrict continuous background radio scanning to conserve battery.
   - *Mitigation*: Design epoch-based burst scanning and clear user guidance for foreground operation during high-priority communication.
2. **Battery Consumption**: Continuous Wi-Fi/Bluetooth scanning rapidly consumes power.
   - *Mitigation*: Dynamic radio state scheduling (BLE for beaconing, Wi-Fi Direct only for high-bandwidth payloads).
3. **Routing Loops & Flooding Storms**: Multi-hop networks can suffer from packet amplification.
   - *Mitigation*: Strict TTL (Time-To-Live) limits, hop counters, and LRU packet-deduplication hash caches.

---

## 8. Definition of Success

OMNILINK succeeds when any two supported mobile devices can establish an authenticated, end-to-end encrypted channel over native local radios without an active internet connection, exchange messages with guaranteed integrity, and present a seamless messaging UI to the end user.
