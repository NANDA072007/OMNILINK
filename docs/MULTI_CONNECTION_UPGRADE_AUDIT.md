# 📑 OMNILINK Multi-Peer Connection & Traffic Handling Architecture Audit & Upgrade Blueprint

**Target System:** OMNILINK Offline Mesh Communication Protocol  
**Author:** Principal Mesh Networking Architect  
**Status:** Architectural Audit & Multi-Peer Upgrade Blueprint  
**Date:** August 15, 2026  

---

##  EXECUTIVE SUMMARY & ARCHITECTURAL SCORE

```
===================================================================================
               OMNILINK MULTI-PEER READINESS AUDIT SCORE: 6.5 / 10
===================================================================================
 [X] Transport Abstraction & Event Attribution:   8.0 / 10 (PeerId correctly passed)
 [X] 5-Layer Routing Engine & Deduplication:     9.0 / 10 (RouterEngine operational)
 [X] Persistent Outbox & Store-and-Forward:      8.5 / 10 (SQLite backed, decay)
 [!] Native Radio Topology (P2P_STAR):            4.0 / 10 (Hardcoded Strategy)
 [!] Per-Peer Buffer & Congestion Control:        3.5 / 10 (Global unbuffered channel)
 [!] Concurrent Crypto Session Registry:         4.5 / 10 (Single active key focus)
===================================================================================
```

OMNILINK has successfully implemented a **5-layer DTN routing engine** (`RouterEngine`), a **PRoPHET delivery predictability engine** (`ProphetEngine`), and an **automatic outbox queue daemon** (`OutboxDaemon`). However, the transport layer and native Android implementation currently rely on **`Strategy.P2P_STAR`** and unbuffered global stream dispatching. 

Moving from 1-to-1 direct connections to a scalable **high-density mesh capable of handling multiple simultaneous peer connections under heavy traffic** requires upgrading native radio strategy, introducing per-peer send queues, isolating concurrent crypto sessions, and establishing backpressure-aware packet dispatching.

---

## 1. CURRENT ONE-TO-ONE ASSUMPTIONS & BLOCKERS

| Severity | File Path & Context | Code Reference / Snippet | Why It Blocks Multi-Peer Operation |
| :--- | :--- | :--- | :--- |
| **CRITICAL** | `android/app/src/main/kotlin/org/omnilink/transport/NearbyConnectionsManager.kt:29` | `private val strategy = Strategy.P2P_STAR` | Forces Google Nearby Connections into a 1-to-N Hub-and-Spoke topology. Spoke devices cannot connect directly to each other without going through the central hub node. Prevents true multi-hop peer-to-peer mesh routing. |
| **HIGH** | `lib/ui/screens/chat_screen.dart:280-305` | `ref.listen(localInboundStreamProvider, ...)` filtering by `widget.peerId` | UI directly subscribes to stream events inside individual screens rather than relying on a centralized inbox store. Multiple unhandled incoming packets from non-active chats bypass UI state notifications if screen is unmounted. |
| **HIGH** | `lib/core/crypto/crypto_service.dart:18-35` | Single active session key cache per device instance | While `encryptPayload` accepts key parameters, key exchange logic in UI/providers assumes a single active handshake session at a time, risking session key collisions during concurrent peer handshakes. |
| **MEDIUM** | `lib/transport_bridge/android_transport_adapter.dart:110-125` | `sendPacket(String peerId, Uint8List payload)` unqueued execution | Invokes native MethodChannel `sendPacket` directly. If multiple threads or UI components call `sendPacket` simultaneously for different peers, radio payloads clog native buffers without rate limiting or priority preemption. |
| **MEDIUM** | `lib/core/routing/outbox_daemon.dart:70-115` | `_isFlushing` single global boolean lock | When `_isFlushing` is `true`, connecting to a *second* peer while flushing the first peer blocks the outbox daemon from processing the new peer's outbox items concurrently. |
| **LOW** | `lib/ui/screens/discovery_screen.dart:45-70` | UI displays single active target selection | Selecting a peer in the discovery screen navigates to a 1-to-1 chat view. Does not show multi-peer connection topology graph or active relay link health indicators. |

---

## 2. TRANSPORT LAYER MULTI-PEER READINESS AUDIT

### Detailed Transport Questionnaire & Analysis

1. **Can the current transport connect to multiple peers at the same time?**
   - **Yes, partially.** Kotlin `NearbyConnectionsManager.kt` maintains `connectedPeers = mutableSetOf<String>()` and supports multiple endpoint callbacks. However, connection topology is constrained by `P2P_STAR`.
2. **Does Nearby strategy currently support multi-peer mesh topology?**
   - **No.** The current codebase uses `Strategy.P2P_STAR` (`NearbyConnectionsManager.kt:29`).
3. **What limitations are created by `P2P_STAR`?**
   - Under `P2P_STAR`, one device acts as the central host (advertising) while peripheral devices (discovering) connect as spokes. Peripheral spokes **cannot discover or connect to each other** while connected to the host, forming a star rather than a web/mesh.
4. **Should OMNILINK upgrade to `P2P_CLUSTER`?**
   - **Yes.** `Strategy.P2P_CLUSTER` allows any node to connect to any other node, enabling multi-directional, multi-hop mesh topologies (M-to-N).
5. **Can the device advertise and discover simultaneously?**
   - **Yes.** In `NearbyConnectionsManager.kt:187`, `startDiscovery()` explicitly calls `startAdvertising()`.
6. **Are peer events and incoming packets correctly attributed to sender peerId?**
   - **Yes.** Native Kotlin callbacks construct `IncomingPacketEvent` with explicit `senderPeerId` and `payloadBytes` (`OmnilinkTransportPlugin.kt:142`).
7. **Is EventChannel thread-safe under high-frequency traffic?**
   - **No.** High-frequency packet streams on `EventChannel` marshal byte arrays across the Flutter platform thread. Under heavy traffic (>50 pkts/sec), GC pressure on platform channels can cause dropped frames or UI thread micro-stuttering.

```
+-----------------------------------------------------------------------------------+
|                           CURRENT VS TARGET TRANSPORT                             |
+-----------------------------------------------------------------------------------+
| Feature                    | Current Codebase            | Target Multi-Peer     |
+----------------------------+-----------------------------+-----------------------+
| Nearby Strategy            | P2P_STAR (Star/Hub)         | P2P_CLUSTER (Mesh)    |
| Endpoint Connections       | Up to 4-7 (Hardware capped) | Dynamic Pool (Max 8)  |
| Direct Spoke-to-Spoke      | Blocked by Hub              | Fully Supported       |
| Concurrent Outbox Flush    | Global Lock (_isFlushing)   | Per-Peer Send Queues  |
| Connection Registry        | Set<String> connectedPeers  | MultiPeerRegistry Map |
+-----------------------------------------------------------------------------------+
```

---

## 3. PACKET PIPELINE READINESS

### Current Inbound Packet Path

```
+-------------------+      Method/EventChannel     +---------------------------+
| Native Nearby API | ---------------------------> | AndroidTransportAdapter   |
+-------------------+                              +---------------------------+
                                                                 |
                                                                 v
+-------------------+      Stream Subscription     +---------------------------+
| UI Chat Screen    | <--------------------------- | RouterEngine (Layer 1-5)  |
+-------------------+                              +---------------------------+
```

### Target Multi-Peer Packet Pipeline Architecture

```
+-----------------------------------------------------------------------------------+
|                        NATIVE TRANSPORT & EVENT CHANNEL                           |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|              GLOBAL PACKET DISPATCHER (Priority Queue & Deduplication)            |
+-----------------------------------------------------------------------------------+
        |                                |                                  |
        v                                v                                  v
+-------------------+          +-------------------+              +-------------------+
| Control Packets   |          | Data Packets      |              | Delivery Receipts |
| (Sync/Adv/Request)|          | (Encrypted Chat)  |              | (ACK Packets)     |
+-------------------+          +-------------------+              +-------------------+
        |                                |                                  |
        v                                v                                  v
+-----------------------------------------------------------------------------------+
|              ROUTER ENGINE (Layer 1 Direct -> Layer 2 DV -> Layer 3 PRoPHET)      |
+-----------------------------------------------------------------------------------+
        |                                                                   |
        | (Target is Local Node)                                            | (Target is Remote Node)
        v                                                                   v
+-----------------------------------+               +-------------------------------+
| Decrypt & Save to SQLite Inbox    |               | Forward via Per-Peer Queue    |
+-----------------------------------+               +-------------------------------+
```

### Packet Processing Findings
- **Global Packet Dispatcher:** `RouterEngine` acts as the central interceptor (`lib/core/routing/router_engine.dart:98`).
- **Closed Screen Handling:** Packets arriving while `ChatScreen` is closed are stored safely in SQLite database via `MessageRepository` and `RoutingDatabaseService`.
- **Crypto Offloading:** Crypto operations (Ed25519 signature checks & ChaCha20 decryption) currently execute on the main Dart isolate. Under high traffic, crypto processing must be offloaded to background `compute()` isolates.

---

## 4. SEND PIPELINE READINESS

```
===================================================================================
                     SEND PIPELINE AUDIT FINDINGS
===================================================================================
 [!] Concurrent Sends:       Fire-and-forget directly to TransportAdapter.
 [!] Per-Peer Queues:        Missing. Outbox is global per database table.
 [!] Pacing / Rate Control:   500ms fixed sleep during outbox flush.
 [!] Backpressure:           No transport feedback if native Bluetooth buffer fills.
 [!] Priority Ordering:      Implemented in SQLite query (UrgencyScore sorting).
===================================================================================
```

### Weaknesses in Current Send Path
1. **Lack of Per-Peer Queueing:** Calling `router.sendMessage()` executes an immediate write to native transport without checking if that specific radio peer is currently completing a previous payload transfer.
2. **Fixed Pacing Delay:** `OutboxDaemon.dart:125` uses a fixed `Future.delayed(const Duration(milliseconds: 500))` sleep between packets. On fast Wi-Fi Direct, 500ms wastes bandwidth; on congested Bluetooth RFCOMM, 500ms may still overflow radio buffers.
3. **Missing MTU Pacing & Chunking:** Payload sizes exceeding Bluetooth LE / RFCOMM MTU (~512 bytes - 10KB) rely on Android Nearby's internal payload chunking. High-frequency large payload sends can starve small priority control packets (Routing Sync / ACKs).

---

## 5. STATE MANAGEMENT READINESS

### Current Riverpod Providers Audit (`lib/core/providers.dart`)

```dart
// Currently Implemented Providers
final transportAdapterProvider = Provider<TransportAdapter>(...);
final routingDatabaseProvider = Provider<RoutingDatabaseService>(...);
final routerEngineProvider = Provider<RouterEngine>(...);
final prophetEngineProvider = Provider<ProphetEngine>(...);
final outboxDaemonProvider = Provider<OutboxDaemon>(...);
final peerListProvider = StateNotifierProvider<PeerListNotifier, List<PeerDevice>>(...);
```

### Missing State Providers Required for Multi-Peer Operation

1. **`multiPeerManagerProvider`**: Exposes a `Map<String, MultiPeerState>` tracking per-peer link quality, RSSI, byte throughput rate, and active transport channel (Nearby Wi-Fi vs Bluetooth RFCOMM).
2. **`sessionRegistryProvider`**: Tracks per-peer active encryption session keys, ephemeral ECDH handshakes, and key expiration timers.
3. **`perPeerSendQueueProvider`**: Exposes queue depth, buffer backpressure, and transmission status for each connected peer link.
4. **`trafficMetricsProvider`**: Real-time stream of incoming/outgoing bytes/sec, dropped duplicate packets, and packet routing latency metrics.

---

## 6. CRYPTO & CONCURRENT SESSION READINESS

- **Current Implementation:** `CryptoService` (`lib/core/crypto/crypto_service.dart`) handles Ed25519 message signing and ChaCha20 payload encryption using canonical payload hashes.
- **Concurrent Session Challenge:** When 5 peers connect simultaneously, identity exchanges (`IDENTITY_ANNOUNCE` / `IDENTITY_RESPONSE`) occur in parallel. 
- **Required Upgrade:** Introduce `SessionRegistry` storing session keys in an immutable `Map<String, PeerSessionKey>`. Session keys must automatically expire upon link disconnection (`onDisconnected`) to prevent key reuse vulnerabilities.

---

## 7. ROUTING READINESS MATRIX

| Routing Capability | Current Status in Codebase | Implementation File | Upgrade Required for Multi-Peer |
| :--- | :--- | :--- | :--- |
| **Node ID Inspection** | Fully Implemented | `PacketEnvelope.recipientId` | None (Works correctly) |
| **Ingress Loop Exclusion** | Fully Implemented | `RouterEngine._selectNextHop()` | Excludes `ingressPeerId` when forwarding |
| **TTL / HopCount Mutating** | Fully Implemented | `PacketEnvelope.copyWith()` | Mutates hopCount & decrements TTL |
| **Distance Vector Routing** | Fully Implemented | `RouteProtocol` & `RouteEntry` | 45s periodic table sync |
| **PRoPHET Delivery Predictability** | Fully Implemented | `ProphetEngine.dart` | Decays probabilities hourly ($\gamma = 0.98$) |
| **Store-and-Forward Outbox** | Fully Implemented | `OutboxDaemon.dart` | Needs per-peer flush isolation |
| **Multi-Path Parallel Forwarding** | Partially Implemented | Layer 4 Controlled Flood | Needs per-peer backpressure awareness |

---

## 8. HIGH-TRAFFIC SCALING RISKS & MITIGATION BLUEPRINT

### Risk 1: Bluetooth RFCOMM Radio Congestion & Payload Drop
- **Why It Happens:** Bluetooth hardware interfaces support limited throughput (~20-50 KB/s). Flooding multiple chat messages or routing tables simultaneously causes native buffer overruns.
- **Location:** `NearbyConnectionsManager.kt` & `AndroidTransportAdapter.dart`.
- **Mitigation:** Implement `PerPeerSendQueue` with leaky-bucket rate limiting (max 15 KB/s per Bluetooth peer, 500 KB/s per Wi-Fi Direct peer).

### Risk 2: EventChannel Flooding & UI Thread Stuttering
- **Why It Happens:** High packet rates emit native platform channel events on the main Android/Flutter UI thread, triggering excessive microtasks and GC spikes.
- **Location:** `lib/transport_bridge/android_transport_adapter.dart:45-60`.
- **Mitigation:** Batch incoming platform channel packet events into 50ms byte buffers before pushing to `RouterEngine`.

### Risk 3: Broadcast Storms & Duplicate Packet Propagation
- **Why It Happens:** In a multi-peer mesh, a broadcast packet (`ROUTING_TABLE_SYNC` or `ROUTE_REQUEST`) sent to 5 peers can echo back from multiple nodes simultaneously.
- **Location:** `lib/core/crypto/packet_service.dart`.
- **Mitigation:** Global LRU deduplication cache (`maxCapacity = 5000`, TTL 10 mins). `RouterEngine` drops packets whose `packetId` exists in the cache before signature verification.

### Risk 4: Main Isolate Crypto Processing Delays
- **Why It Happens:** Verifying Ed25519 signatures and performing ChaCha20 decryption synchronously on the main Dart isolate takes 3-8ms per packet. Receiving 20 packets/sec consumes 160ms/sec of UI render frame time.
- **Location:** `lib/core/crypto/crypto_service.dart`.
- **Mitigation:** Offload packet signature verification and decryption to background worker isolates using `Isolate.run()` or `compute()`.

---

## 9. ANDROID NEARBY MULTI-CONNECTION CONSTRAINTS

1. **Nearby Strategy Choice:**
   - Upgrade from `Strategy.P2P_STAR` to **`Strategy.P2P_CLUSTER`**.
   - `P2P_CLUSTER` enables true M-to-N mesh networks where every device can advertise, discover, and maintain peer links with any surrounding node.
2. **Hardware Connection Limits:**
   - Android Bluetooth chips physically cap stable simultaneous connections to **4–7 active endpoints**. Attempting to connect to an 8th device often results in `STATUS_BLUETOOTH_ERROR` or connection drops.
   - *Strategy:* `MultiPeerConnectionManager` must limit active radio links to **6 peers**, maintaining remaining discovered nodes in an inactive queue.
3. **Foreground Service Requirement:**
   - Android 14+ (API 34) requires `FOREGROUND_SERVICE_CONNECTED_DEVICE` permission and a visible persistent notification (`OmnilinkForegroundService.kt`). Without this, Android Doze mode destroys Nearby scanners when the screen locks.

---

## 10. DESIRED TARGET MULTI-PEER ARCHITECTURE

```
+-----------------------------------------------------------------------------------+
|                            TARGET MULTI-PEER ARCHITECTURE                         |
+-----------------------------------------------------------------------------------+

   +-----------------------------------------------------------------------------+
   |                     MultiPeerConnectionManager                             |
   | - Manages connection lifecycle for up to 6 concurrent endpoints             |
   | - Maps native transport endpoint ID -> OMNILINK nodeId                       |
   | - Exposes active connection pool StateNotifier                               |
   +-----------------------------------------------------------------------------+
                                         |
                                         v
   +-----------------------------------------------------------------------------+
   |                       Global PacketDispatcher                               |
   | - Single transport stream listener                                          |
   | - LRU Deduplication (5000 packets)                                          |
   | - Decodes envelope & classifies packet type                                 |
   | - Offloads Ed25519/ChaCha20 crypto validation to Worker Isolate             |
   +-----------------------------------------------------------------------------+
                                         |
                                         v
   +-----------------------------------------------------------------------------+
   |                            RouterEngine                                     |
   | - Layer 1: Direct Link Evaluation                                           |
   | - Layer 2: Distance Vector Route Table                                      |
   | - Layer 3: PRoPHET Delivery Predictability                                  |
   | - Layer 4: Controlled Flood                                                 |
   | - Layer 5: Store-and-Forward Outbox                                         |
   +-----------------------------------------------------------------------------+
                   |                                             |
                   v (Outbound Packet)                           v (Local Inbox)
   +---------------------------------------+     +-------------------------------+
   |        PerPeerSendQueue               |     | SQLite Inbox Message Database |
   | - Priority Queue (High/Normal/Low)    |     +-------------------------------+
   | - Leaky-Bucket Rate Limiter           |
   | - Retries & Backoff                   |
   +---------------------------------------+
```

---

## 11. MULTI-PEER UPGRADE ROADMAP

```
+-----------------------------------------------------------------------------------+
|                        8-PHASE MULTI-PEER IMPLEMENTATION ROADMAP                  |
+-----------------------------------------------------------------------------------+
```

### Phase 1: Native Transport P2P_CLUSTER Upgrade
- **Goal:** Change Nearby Connections strategy from `P2P_STAR` to `P2P_CLUSTER`.
- **Files Modified:** `android/app/src/main/kotlin/org/omnilink/transport/NearbyConnectionsManager.kt`.
- **Acceptance Criteria:** 3 physical Android test devices can form a fully connected triangle network without connection rejection.
- **Risk Level:** Medium (Requires testing across older Android radio chipsets).

### Phase 2: Multi-Peer Connection Registry (`MultiPeerConnectionManager`)
- **Goal:** Create central Dart connection registry mapping native endpoint IDs to cryptographic Node IDs.
- **Files Created:** `lib/core/routing/multi_peer_manager.dart`.
- **Acceptance Criteria:** Dynamic connection state map reflects active link health, RSSI, and radio transport type.
- **Risk Level:** Low.

### Phase 3: Background Worker Isolate Crypto Offloading
- **Goal:** Offload packet hash computation, Ed25519 signature checks, and ChaCha20 decryption to background isolates.
- **Files Modified:** `lib/core/crypto/crypto_service.dart`.
- **Acceptance Criteria:** Processing 50 incoming packets/sec introduces < 1ms main thread blocking time.
- **Risk Level:** Low.

### Phase 4: Per-Peer Send Queues & Leaky-Bucket Pacing
- **Goal:** Replace direct fire-and-forget sending with isolated per-peer transmission queues.
- **Files Created:** `lib/core/routing/send_queue.dart`.
- **Acceptance Criteria:** Sending a 1MB file payload to Peer A does not stall or delay high-priority text messages sent to Peer B.
- **Risk Level:** Medium.

### Phase 5: Parallel Route Discovery & Multi-Hop Relay
- **Goal:** Enable intermediate mesh nodes to relay encrypted data packets across 3+ hops.
- **Files Modified:** `lib/core/routing/router_engine.dart` & `route_protocol.dart`.
- **Acceptance Criteria:** Device A sends message to Device C via Device B (A $\to$ B $\to$ C). Device B relays packet without decrypting message contents.
- **Risk Level:** Medium.

### Phase 6: Per-Peer Outbox Isolation & Anti-Entropy Sync
- **Goal:** Refactor `OutboxDaemon` to run concurrent outbox flushes per peer without global lock contention.
- **Files Modified:** `lib/core/routing/outbox_daemon.dart`.
- **Acceptance Criteria:** Connecting to Device B and Device C simultaneously flushes pending outbox messages in parallel.
- **Risk Level:** Low.

### Phase 7: Traffic Control, Deduplication & Congestion Control
- **Goal:** Implement rate limiters, global packet deduplication, and low-priority packet shedding.
- **Files Created:** `lib/core/routing/traffic_controller.dart`.
- **Acceptance Criteria:** Broadcast storms are clipped immediately at 0% duplicate delivery to UI layer.
- **Risk Level:** Medium.

### Phase 8: Observability & Load Testing
- **Goal:** Add real-time mesh routing analytics and multi-peer performance monitoring.
- **Files Created:** `lib/core/routing/mesh_observability.dart`.
- **Acceptance Criteria:** Live dashboard displays bytes/sec throughput, queue depth, hop latency, and packet loss metrics.
- **Risk Level:** Low.

---

## 12. EXACT FILES TO CREATE OR MODIFY

| Priority | Action | File Path | Purpose |
| :--- | :--- | :--- | :--- |
| **P0** | **MODIFY** | `android/app/src/main/kotlin/org/omnilink/transport/NearbyConnectionsManager.kt` | Switch `Strategy.P2P_STAR` to `Strategy.P2P_CLUSTER`. Enforce 6-device endpoint limit. |
| **P0** | **NEW** | `lib/core/routing/multi_peer_manager.dart` | Manages multi-peer connection state map, endpoint-to-node ID translation, and radio link monitoring. |
| **P1** | **NEW** | `lib/core/routing/send_queue.dart` | Per-peer priority transmission queues with rate-limiting pacing and backpressure handling. |
| **P1** | **NEW** | `lib/core/routing/session_registry.dart` | Manages concurrent per-peer crypto keys, session handshakes, and automatic disconnection cleanup. |
| **P1** | **MODIFY** | `lib/core/routing/router_engine.dart` | Integrates `MultiPeerConnectionManager` and `PerPeerSendQueue` into 5-layer routing decisions. |
| **P2** | **MODIFY** | `lib/core/routing/outbox_daemon.dart` | Removes global `_isFlushing` lock; enables concurrent per-peer outbox flushing. |
| **P2** | **NEW** | `lib/core/routing/traffic_controller.dart` | Implements LRU packet deduplication, rate limits, and priority packet drop rules. |
| **P3** | **MODIFY** | `lib/core/providers.dart` | Exposes Riverpod state providers for multi-peer registry, send queue metrics, and session keys. |

---

## 13. MULTI-PEER TRAFFIC MANUAL & AUTOMATED TEST PLAN

```
+-----------------------------------------------------------------------------------+
|                        TEST CASE MATRIX & VERIFICATION                            |
+-----------------------------------------------------------------------------------+
```

### Test Case 1: 3-Node Mesh Relay Transmission (A $\to$ B $\to$ C)
- **Steps:**
  1. Connect Node A to Node B via Bluetooth.
  2. Connect Node B to Node C via Bluetooth (Node A and Node C are out of radio range).
  3. Send text message from Node A to Node C.
- **Expected Logs:**
  - `Node A`: `OMNILINK_ROUTER: Layer 2/3 selected relay Node B for recipient Node C`
  - `Node B`: `OMNILINK_ROUTER: Relaying packet msg_123 (sender=Node A, recipient=Node C, ttl=6, hopCount=1)`
  - `Node C`: `OMNILINK_ROUTER: Packet msg_123 arrived at final destination. Decrypting...`
- **Expected UI State:** Node A message shows `✓ Transmitting...` then `✓✓ Delivered to node`.

### Test Case 2: Concurrent Multi-Peer Packet Arrival
- **Steps:**
  1. Connect Node A simultaneously to Node B and Node C.
  2. Have Node B and Node C send chat packets to Node A at the exact same millisecond.
- **Expected Logs:**
  - `OMNILINK_DISPATCHER: Received 2 packets concurrently from peer_B and peer_C.`
  - `OMNILINK_CRYPTO: Decrypted packet 1 from Node B in 2ms.`
  - `OMNILINK_CRYPTO: Decrypted packet 2 from Node C in 2ms.`
- **Expected UI State:** Node A inbox updates both conversation threads instantly without dropping either message.

### Test Case 3: Duplicate Broadcast Clipping (Storm Prevention)
- **Steps:**
  1. Node A broadcasts `ROUTING_TABLE_SYNC`.
  2. Node B and Node C receive the sync envelope and re-broadcast to each other and back to Node A.
- **Expected Logs:**
  - `Node A`: `OMNILINK_DEDUP: Dropped duplicate packet sync_9988 (already in LRU cache).`
- **Expected UI State:** No duplicate processing overhead or UI flicker.

---

## 14. FINAL EXECUTIVE SUMMARY & RECOMMENDATIONS

### Top 5 Blockers
1. **Hardcoded `P2P_STAR` Strategy:** Native Kotlin transport is restricted to a Star/Hub model (`NearbyConnectionsManager.kt:29`).
2. **Global Single-Threaded Send Path:** Lacks per-peer send queues, causing large payloads to block text messages.
3. **Global Outbox Flush Lock (`_isFlushing`):** Prevents parallel outbox processing when multiple peers connect.
4. **Main Isolate Crypto Execution:** High packet rates will stutter UI frame rendering.
5. **Lack of Per-Peer Session Key Isolation:** Key state management assumes single active chat context.

### Top 5 Scaling Risks
1. **Bluetooth RFCOMM Radio Overrun:** Unpaced writes overflow native Android Bluetooth buffer.
2. **Broadcast Echo Storms:** Re-broadcast packets consume battery and radio bandwidth.
3. **EventChannel Platform Thread Lag:** High packet frequency bogs down Flutter UI thread.
4. **Hardware Endpoint Saturation:** Connecting to > 6 peers destabilizes Android Bluetooth stack.
5. **Doze Mode Radio Termination:** Background Doze mode kills mesh scanners without persistent Foreground Service.

### Recommended First Implementation Step
> **Upgrade `NearbyConnectionsManager.kt` from `Strategy.P2P_STAR` to `Strategy.P2P_CLUSTER`**, test 3-device simultaneous triangle connectivity, and implement `lib/core/routing/multi_peer_manager.dart` to track multi-peer endpoint state.

---
*End of Audit Report.*
