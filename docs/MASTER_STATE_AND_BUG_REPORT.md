# MASTER STATE AND BUG REPORT: OMNILINK CODEBASE AUDIT

**Audit Date:** August 15, 2026  
**Auditor:** Principal Systems Architect & Expert Code Auditor  
**Target Repository:** `OMNILINK` (`main` branch)

---

## 1. Executive Summary of Broken State

OMNILINK is currently failing to achieve reliable sub-100ms message delivery due to a fundamental breakdown between transient radio endpoint identifiers (`peerId`, e.g. `"9A8B"`) and persistent cryptographic node identifiers (`nodeId`, 64-character hex string). Asymmetric secret key seed derivation (`"$myNodeId:${widget.peerId}"` vs sender/recipient order) causes silent ChaCha20 decryption failures on the receiving device, dropping packets into a black hole. Furthermore, single-boolean global lockouts (`_isFlushing`) in `OutboxDaemon` and bypassing `SendQueueManager` during outbox flushes cause message queue deadlocks and packet loss under multi-peer connections.

---

## 2. The Outbound Deadlock Map

### Step-by-Step Outbound Trace (`chat_screen.dart` $\rightarrow$ `RouterEngine` $\rightarrow$ `TransportAdapter`)

1. **User Taps Send Button (`lib/ui/screens/chat_screen.dart:168`)**
   - User inputs text and invokes `_sendMessage()`.
   - `chat_screen.dart:192-194`:
     ```dart
     final isDirectlyConnected = connectedPeers.any(
       (p) => p.nodeId == widget.peerId || p.peerId == widget.peerId,
     );
     ```
   - **FLAW:** If `widget.peerId` is the 64-char `nodeId`, but `peerListProvider` contains a `PeerDevice` where `nodeId` has not yet been resolved (`p.nodeId == null` and `p.peerId == "9A8B"`), `isDirectlyConnected` evaluates to `false`. The message is set to `MessageState.queued` in SQLite immediately.

2. **Asymmetric Key Seed Derivation (`lib/ui/screens/chat_screen.dart:225-228`)**
   - Encrypts payload before passing to `RouterEngine`:
     ```dart
     final keySeed = await cryptoService.sha256Hex(
       Uint8List.fromList(utf8.encode('$myNodeId:${widget.peerId}')),
     );
     final secretKey = SecretKey(utf8.encode(keySeed.substring(0, 32)));
     ```
   - **FLAW 1:** If `widget.peerId` is transient `"9A8B"`, sender derives `keySeed` from `"A:9A8B"`. Recipient B receives `envelope.senderId = A` and `envelope.recipientId = B`, deriving `keySeed` from `"A:B"`. The secret keys **DO NOT MATCH**, causing decryption to fail on the recipient.
   - **FLAW 2:** Even if both sides use 64-char node IDs, Sender A computes `sha256("A:B")`, but if Recipient B computes `sha256("$myNodeId:${envelope.senderId}")` (which is `"B:A"`), the string order differs unless sorted lexicographically.

3. **Route Selection & Layer 1 Direct Lookups (`lib/core/routing/router_engine.dart:284-304`)**
   - `RouterEngine.sendMessage(envelope)` calls `_selectNextHop()`:
     ```dart
     final mappedPeerId = _nodeIdToPeerId[envelope.recipientId];
     final directPeer = connectedPeers.firstWhere(
       (p) => p.peerId == envelope.recipientId ||
              p.nodeId == envelope.recipientId ||
              p.peerId == mappedPeerId,
       orElse: () => ...
     );
     ```
   - **FLAW:** If `envelope.recipientId` is `"9A8B"`, `_nodeIdToPeerId["9A8B"]` returns `null`. If `p.nodeId` in `connectedPeers` is `null`, Layer 1 fails and returns `RouteStrategy.storeAndForward`. The message is saved to SQLite `outbox_queue` instead of being transmitted over the active radio connection.

4. **Outbox Daemon Global Lockout (`lib/core/routing/outbox_daemon.dart:100`)**
   - `OutboxDaemon.onPeerConnected(String peerId)` starts with:
     ```dart
     if (_isFlushing) return;
     _isFlushing = true;
     ```
   - **FLAW:** `_isFlushing` is a single instance boolean flag. If a periodic maintenance task (`maintenance()` at line 205) or anti-entropy sync is flushing outbox packets for Peer X, any concurrent peer connection or identity discovery for Peer Y is **PERMANENTLY REJECTED AND DROPPED**.

5. **Outbox Flusher Bypasses `SendQueueManager` (`lib/core/routing/outbox_daemon.dart:138`)**
   - When `OutboxDaemon` flushes pending packets:
     ```dart
     final success = await transport.sendPacket(peerId, payloadBytes);
     ```
   - **FLAW:** `OutboxDaemon` calls `transport.sendPacket()` directly in a loop, completely bypassing `SendQueueManager`! It has no per-peer queueing, no lock serialisation, and no 3-second deadlock timeouts.

---

## 3. The Inbound Black Hole Map

### Step-by-Step Inbound Trace (`Kotlin EventChannel` $\rightarrow$ `RouterEngine` $\rightarrow$ `chat_screen.dart`)

1. **Native Native Receiver (`android/.../NearbyConnectionsManager.kt:195`)**
   - Payload arrives over Nearby Connections `onPayloadReceived`.
   - Packages map: `type = "incomingPacket"`, `peerId = endpointId`, `bytes = payload.asBytes()`.
   - Emits event to Flutter `EventChannel` (`omnilink/transport/events`).

2. **Dart Bridge Parsing (`lib/transport_bridge/android_transport_adapter.dart:99-116`)**
   - `_handleNativeEvent` receives map, coerces bytes via `_coerceToUint8List(rawPayload)`, and adds `IncomingPacketEvent(senderPeerId: peerId, payloadBytes: payloadBytes)` to `_incomingPacketController`.

3. **Central Router Engine Dispatch (`lib/core/routing/router_engine.dart:143-160`)**
   - `_handleIncomingPacket(IncomingPacketEvent event)` decodes JSON into `PacketEnvelope`.
   - Performs `packetService.markProcessed(envelope.packetId)`.
   - If `envelope.recipientId == myNodeId`, emits envelope to `_localInboundController`.

4. **ChatScreen Inbound Receiver Drop (`lib/ui/screens/chat_screen.dart:71-78`)**
   - `ChatScreen` listens to `router.localInboundStream` in `_subscribeToIncomingEnvelopes()`:
     ```dart
     final isMatchingPeer = envelope.senderId == widget.peerId ||
         envelope.senderId.startsWith(widget.peerId) ||
         widget.peerId.startsWith(envelope.senderId);

     if (!isMatchingPeer) {
       debugPrint('OMNILINK_DART: [t=$tRecv] ignored envelope because senderId (${envelope.senderId}) does not match current chat peerId (${widget.peerId})');
       return;
     }
     ```
   - **CRITICAL BLACK HOLE:** If `ChatScreen` was opened with transient `widget.peerId = "9A8B"`, but the incoming envelope has `envelope.senderId = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"` (64-char hex):
     - `envelope.senderId == "9A8B"` $\rightarrow$ `false`.
     - `envelope.senderId.startsWith("9A8B")` $\rightarrow$ `false`.
     - `"9A8B".startsWith(envelope.senderId)` $\rightarrow$ `false`.
     - `isMatchingPeer` evaluates to **`false`**.
     - The packet is **IGNORED AND DROPPED SILENTLY** at line 77.

5. **Decryption Failure Exception Trap (`lib/ui/screens/chat_screen.dart:99-138`)**
   - Even if peer matching succeeds, line 99 derives key seed:
     ```dart
     keySeed = await cryptoService.sha256Hex(
       utf8.encode('${envelope.senderId}:${envelope.recipientId}'),
     );
     ```
   - If sender used `"A:9A8B"` due to unmapped `widget.peerId`, and recipient computes `"A:B"`, `cryptoService.decryptPayload()` throws a `MacValidationException`.
   - The exception is caught at line 136 (`catch (e, s)`), logging an error to console while the message is **PERMANENTLY LOST**.

---

## 4. Native Bridge & Topology Reality

1. **Hardcoded Strategy (`android/.../NearbyConnectionsManager.kt:29`)**
   - Strategy is configured as `Strategy.P2P_CLUSTER`:
     ```kotlin
     private val strategy = Strategy.P2P_CLUSTER
     ```
   - *Status:* Correctly configured for M-to-N multi-peer mesh connectivity.

2. **Native Outbound Queue (`android/.../NearbyConnectionsManager.kt:36`)**
   - Maintained as:
     ```kotlin
     private val outboundQueues = ConcurrentHashMap<String, ConcurrentLinkedQueue<ByteArray>>()
     private val inFlightPayloads = ConcurrentHashMap<String, Boolean>()
     ```
   - `sendPacket(peerId, bytes)` enqueues payload and calls `processNextPayload(peerId)`.

3. **Missing Callback Forwarding (`android/.../NearbyConnectionsManager.kt:218-235`)**
   - Native `PayloadCallback` handles `onPayloadTransferUpdate`:
     ```kotlin
     override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {
         if (update.status == PayloadTransferUpdate.Status.SUCCESS) {
             inFlightPayloads[endpointId] = false
             processNextPayload(endpointId)
         }
     }
     ```
   - **CRITICAL GAP:** `onPayloadTransferUpdate` logs payload transfer state inside Kotlin, but **NEVER FORWARDS TRANSFER STATUS EVENTS BACK TO DART `EventChannel`**.
   - Dart's `SendQueueManager` (`lib/core/routing/send_queue.dart:85`) only awaits the MethodChannel `sendPacket` invocation (<2ms), meaning Dart cannot verify actual physical radio delivery completion.

---

## 5. Riverpod & State Contradictions

1. **Duplicate Mesh Routers**
   - `lib/core/providers.dart:261`: `meshRouterProvider` provides legacy `MeshRouter`.
   - `lib/core/providers.dart:287`: `routerEngineProvider` provides central 5-layer `RouterEngine`.
   - *Contradiction:* Both routers exist simultaneously in the dependency injection graph, risking split-brain packet handling if legacy components reference `meshRouterProvider`.

2. **Duplicate Outbox Repositories**
   - `lib/core/providers.dart:265`: `outboxRepositoryProvider` uses `DatabaseService` (`outbox_messages` table).
   - `lib/core/providers.dart:274`: `outboxDaemonProvider` uses `RoutingDatabaseService` (`outbox_queue` table).
   - *Contradiction:* Two parallel SQLite tables and persistence layers exist for outbox packets.

3. **Uncoordinated EventChannel Stream Subscriptions**
   - `transportAdapterProvider.peerEvents` and `incomingPackets` streams are subscribed to independently by:
     1. `RouterEngine` (`lib/core/routing/router_engine.dart:108`)
     2. `OutboxDaemon` (`lib/core/routing/outbox_daemon.dart:42`)
     3. `PeerListNotifier` (`lib/core/providers.dart:160`)
     4. `RouteProtocol` (`lib/core/routing/route_protocol.dart`)
   - *Risk:* No centralized event dispatcher exists to enforce atomic order of identity learning before packet routing.

---

## 6. The "Silent Killers" Code Snippets

### A. Swallowed Exception in Native Transport Bridge (`lib/transport_bridge/android_transport_adapter.dart:306-358`)
```dart
Future<bool> startRfcommServer() async {
  try {
    final result = await _controlChannel.invokeMethod<bool>('startRfcommServer');
    return result ?? false;
  } catch (e) {
    return false; // Silent swallow! No log, no error propagation.
  }
}
```

### B. Background Outbox Failure Swallowed in UI (`lib/ui/screens/chat_screen.dart:286-288`)
```dart
} catch (e) {
  debugPrint('OMNILINK_UI: Exception during background outbox queueing: $e');
  // Message UI state remains stuck in MessageState.sending forever!
}
```

### C. Single Boolean Lockout in Outbox Daemon (`lib/core/routing/outbox_daemon.dart:100-101`)
```dart
Future<void> onPeerConnected(String peerId) async {
  if (_isFlushing) return; // Rejects all concurrent outbox flushes across all peers!
  _isFlushing = true;
```

---

## 7. Required Surgical Fixes (Prioritized)

1. **Standardize Peer Identification Across UI & Router**
   - Update `ChatScreen` constructor and routing logic to require cryptographic `nodeId`. If navigated to with a transient `peerId`, resolve `nodeId` immediately from `PeerListNotifier` before performing key derivation or message filtering.

2. **Symmetric Secret Key Derivation**
   - Replace asymmetric `sha256("$myNodeId:${widget.peerId}")` with a deterministic, sorted key seed derivation:
     ```dart
     final nodes = [nodeIdA, nodeIdB]..sort();
     final keySeed = await cryptoService.sha256Hex(utf8.encode('${nodes[0]}:${nodes[1]}'));
     ```
   - Guarantees identical secret key calculation on both sender and receiver regardless of sender/recipient role or transient IDs.

3. **Fix Inbound Chat Screen Peer Filter**
   - Modify `ChatScreen._handleIncomingEnvelope()` (`lib/ui/screens/chat_screen.dart:71`) to check mapped `nodeId`:
     ```dart
     final currentPeerNodeId = ref.read(peerListProvider.notifier).getNodeIdForPeer(widget.peerId) ?? widget.peerId;
     final isMatchingPeer = envelope.senderId == currentPeerNodeId || envelope.senderId == widget.peerId;
     ```

4. **Replace Single `_isFlushing` Boolean with Per-Peer Set**
   - In `lib/core/routing/outbox_daemon.dart`:
     ```dart
     final Set<String> _flushingPeers = {};
     if (_flushingPeers.contains(peerId)) return;
     _flushingPeers.add(peerId);
     try { ... } finally { _flushingPeers.remove(peerId); }
     ```

5. **Route Outbox Flushes Through `SendQueueManager`**
   - Modify `OutboxDaemon.onPeerConnected()` (`lib/core/routing/outbox_daemon.dart:138`) to use `router.sendMessage(envelope)` or `sendQueueManager.enqueueAndSend()` to enforce per-peer queueing and 3-second deadlock timeouts.

6. **Deprecate Duplicate Providers & Repositories**
   - Remove legacy `meshRouterProvider` and `OutboxRepository` from `lib/core/providers.dart`, standardizing all store-and-forward routing on `routerEngineProvider` and `outboxDaemonProvider`.
