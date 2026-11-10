# Week 1 — Reliable Message Delivery (Phase 0)

**Goal:** make text messages survive radio drops, app restarts, and duplicate deliveries without being lost.
The target is not "no interruptions" — the target is **no message loss and exactly-once effect across interruptions**.

**Branch:** `main`  
**Scope owner:** OMNILINK core (Dart + Kotlin platform channel)

---

## Root causes found during the audit

- [x] **Link ACK was treated as end-to-end delivery.** Outbox rows were deleted and messages marked `delivered` as soon as Nearby accepted the payload.
- [x] **Delivery receipts were invalid packets.** The receipt reused the original message's signature and payload hash, so receivers rejected it.
- [x] **Control packets were unsigned.** Route sync, route requests/replies, and anti-entropy packets used `signature: 'public_metadata'`, which fails Ed25519 verification and silently blocks catch-up.
- [x] **Inbound decryption used the wrong sender key.** Dual-ECDH fell back to the Ed25519 `senderId` instead of the learned static X25519 key.
- [x] **Duplicate messages were dropped without re-sending a receipt.** A lost receipt caused endless retries.
- [x] **Messages expired after 10 retries (~minutes), not at envelope expiry (24h).**
- [x] **Every outbox read reset `sending` rows to `pending`**, allowing double-sends and races.
- [x] **Two `OutboxDaemon` instances existed** (one inside `RouterEngine`, one from Riverpod), both flushing the same queue.
- [x] **Peer-connected orchestration ran twice** (RouterEngine + OutboxDaemon each handled the same event).
- [x] **Inbound payloads existed only in a 512-event RAM buffer.** Engine teardown/process death lost them.
- [x] **No background radio ownership.** No wake lock, single discovery retry, no reconnect, and the service did not arm radios.
- [x] **Two transport adapter instances existed** (core provider + radio-status provider), so radio events and the engine used different objects.

---

## Week 1 todo

### A. Signed control plane

- [x] Add `PacketService.createSignedControlEnvelope(...)`.
- [x] Replace every `signature: 'public_metadata'` in `route_protocol.dart` with a real signed envelope.
- [x] Sign `ROUTING_TABLE_SYNC`, `ROUTE_ADVERTISEMENT`, `ROUTE_REQUEST`, `ROUTE_REPLY`.
- [x] Sign `SYNC_HANDSHAKE`, `SYNC_SESSION_START`, `SYNC_PAGE`, `SYNC_SESSION_END`, `SYNC_REQUEST`.
- [x] Fix paginated sync cursor so MTU-reduced pages do not skip packet IDs.
- [x] Verify a signed control envelope passes `validateAndClaimEnvelope` on a fresh node.

### B. End-to-end delivery confirmation

- [x] Build `DELIVERY_RECEIPT` with its own payload hash and Ed25519 signature.
- [x] Make `_processInboundMessagePayload` return `bool`.
- [x] Send the receipt **only after** the message is committed to SQLite.
- [x] Emit the local inbound event **after** persistence so the UI does not race the DB write.
- [x] On a duplicate `MESSAGE_PAYLOAD`, recover if needed and re-send the receipt.
- [x] On a duplicate `DELIVERY_RECEIPT`, process it idempotently.
- [x] Resolve the sender's static X25519 key from the peer registry before decrypting.

### C. Receipt-driven outbox lifecycle

- [x] Persist every outbound user message to `outbox_queue` **before** the first send attempt.
- [x] Keep the outbox row after a link ACK; mark `MessageState.delivered` only.
- [x] Delete the outbox row on a verified `DELIVERY_RECEIPT`.
- [x] Add a receipt grace period before retrying a link-acked packet.
- [x] Stop expiring messages after 10 retries; expire by envelope `expiresAt` only.
- [x] Replace the destructive `sending -> pending` reset with lease-based due queries.
- [x] Add `getDueOutboxPackets`, `claimOutboxPackets`, and `markOutboxPacketsAwaitingReceipt`.
- [x] Remove per-failure `Timer` retries that bypass the queue state.
- [x] Prevent a late link-ACK from regressing `receiptReceived` back to `delivered`.

### D. Single ownership

- [x] Make `outboxDaemonProvider` return `routerEngineProvider.outboxDaemon` instead of constructing a second daemon.
- [x] Remove `OutboxDaemon`'s duplicate peer-event subscription.
- [x] Remove the duplicate `sendSyncHandshake` call from `RouterEngine._handlePeerEvent`.
- [x] Route disconnect cleanup through one `onPeerDisconnected` path.

### E. Verification

- [x] Add a signed-control-envelope test.
- [x] Add an outbox lease/receipt lifecycle test.
- [x] Add a duplicate-message receipt recovery test.
- [x] Run `flutter analyze` (0 issues).
- [x] Run `flutter test` (174 tests passed).
- [ ] Manual 2-device smoke test (send, kill receiver, resend, duplicate, receive receipt).

---

## Acceptance criteria

- [x] A message persists across a receiver crash between radio receive and SQLite save.
- [x] A sender retries until a verified receipt arrives, then deletes exactly one outbox row.
- [x] A duplicate message causes a receipt re-send, not a silent drop.
- [x] A duplicate receipt is harmless.
- [x] Control/sync packets pass signature validation.
- [x] No message expires before its envelope `expiresAt`.
- [x] Only one `OutboxDaemon` flushes at a time.
- [ ] Verified on two physical Android devices.

---

## Build backlog — maximum scope

Build-only scope; verification and device testing are later work.

### Block 1 — Real Android delivery survival (P0)

- [x] Native durable inbox spool — persist every received payload to disk before emitting to Dart.
- [x] Dart ACK + replay protocol — native deletes spool rows only after Dart confirms persistence.
- [x] Remove the 512-event payload drop — payloads replay from the durable spool on overflow.
- [x] Foreground service owns radio lifecycle — start advertising + discovery from the service.
- [x] Boot restoration — re-arm discovery/advertising after boot and `START_STICKY` restarts.
- [x] Wake locks — partial wake lock + Wi-Fi lock held by the service.
- [x] Battery-optimization exemption — native query/request + settings prompt.
- [x] Auto-reconnect — backoff + jitter on disconnect, connection failure, and radio toggles.
- [x] Continuous discovery — duty-cycled scan/advertise loop instead of one retry.
- [x] Resume-from-background handshake — snapshot diff, sequence replay, mesh re-arm.
- [x] Per-message notifications — incoming message notification with app launch intent.
- [x] Permission onboarding — Bluetooth/Nearby/Location already present; notifications + battery added.

### Block 2 — Mesh correctness and efficiency (P1)

- [ ] Replace flood fan-out with direct recipient or route-table next hop.
- [ ] Persistent anti-entropy index — read `processed_packets` from SQLite, not the RAM LRU.
- [ ] Sent-history retention — answer `SYNC_REQUEST` after outbox deletion.
- [ ] Receipt throttling/piggybacking.
- [ ] Read receipts + unread counts.
- [ ] Per-conversation ordering (sequence/Lamport clock).
- [ ] Route aging/invalidation and loop prevention.
- [ ] Outbox schema v7 — explicit lease, last-attempt, attempt-count, jittered backoff.
- [ ] Multi-hop 3-node build path (TTL, hop count, ingress exclusion).
- [ ] Pre-key rotation coverage for long-queued messages.
- [ ] Expired/failed message UI with retry.

### Block 3 — File and media sharing (P2)

- [ ] Signed/encrypted envelopes for all transfer packet types.
- [ ] AEAD-encrypt every chunk with a deterministic nonce.
- [ ] Chunk and final hash verification through the envelope path.
- [ ] Resumable transfers with a persisted chunk bitmap.
- [ ] Fix progress counters and cancellation cleanup.
- [ ] File-size/MIME/path validation and storage quota.
- [ ] Attachment UI, progress, open/save, image preview.

### Block 4 — Product surface (P2/P3)

- [ ] Conversation list with last message, timestamp, unread badge.
- [ ] Chat state icons and retry action polish.
- [ ] Trusted devices: TOFU trust, block/allow, verified badge, QR/safety number.
- [ ] Settings: battery mode, relay opt-in, discovery mode, storage, debug export.
- [ ] First-run onboarding and safety disclaimer.
- [ ] Accessibility, localization, text scaling.
- [ ] Notification channel management.

### Block 5 — Release hardening (P3)

- [ ] Schema migrations for all new columns.
- [ ] Android 14/15 background restrictions audit.
- [ ] Release signing configuration.
- [ ] R8/ProGuard keep rules for channels and crypto.
- [ ] Manifest hardening (exported flags, permission minimization).
- [ ] Debug + release APK/AAB build.
- [ ] Upgrade toolchain: Gradle 8.7 → 8.14+, AGP 8.6 → 8.11.1+, Kotlin 2.0 → 2.2.20+.
- [ ] CI build-only pipeline.

### Explicitly out of this block

- Group chat
- Internet gateway bridging
- iOS implementation
- Rust core extraction
- LoRa/ESP32 relay hardware

---

## Deferred to later weeks

- Week 2: Block 2 — mesh correctness, persistent anti-entropy index, receipt throttling, read receipts, ordering, schema v7.
- Week 3: Block 3 — file/media envelope compliance, chunk encryption, resumable transfers, bounded relay fan-out.
- Week 4: Block 4 + Block 5 — product surface, release hardening, fault-injection/soak tests, delivery metrics/SLOs.

---

## Block 1 implementation map

- `android/app/src/main/kotlin/org/omnilink/transport/OmnilinkInboundSpool.kt` — durable inbound payload spool.
- `android/app/src/main/kotlin/org/omnilink/transport/OmnilinkTransportPlugin.kt` — spool ACK/replay, notifications, battery exemption, mesh/alerts methods.
- `android/app/src/main/kotlin/org/omnilink/transport/OmnilinkForegroundService.kt` — service-owned radio lifecycle, wake locks, watchdog.
- `android/app/src/main/kotlin/org/omnilink/transport/NearbyConnectionsManager.kt` — continuous discovery, unique device names, desired-peer reconnect.
- `lib/transport_bridge/android_transport_adapter.dart` — spoolId propagation, snapshot diff, resume handshake, battery/notification APIs.
- `lib/core/routing/router_engine.dart` — spool ACK after handling, inbound message notifications.
- `lib/core/providers.dart` + `lib/state/providers/radio_status_provider.dart` + `lib/state/providers/discovery_state_provider.dart` — single transport instance.
- `lib/main.dart` + `lib/ui/screens/discovery_screen.dart` — resume observer, battery/notification onboarding.

## Verification evidence

- `flutter analyze` — 0 issues.
- `flutter test` — 174 tests passed.
- `dart analyze lib` after Block 1 — 0 issues.
- `flutter build apk --debug` — **passed**. Output: `build/app/outputs/flutter-apk/app-debug.apk`.
- Incremental rebuild after the final Kotlin edits — **passed** in 35s.
- New tests:
  - `test/protocol/delivery_lifecycle_test.dart`
    - signed control envelope verification + tamper rejection
    - outbox retention after link ACK, deletion only after receipt
    - duplicate inbound message re-sends the receipt
  - `test/routing/outbox_lease_lifecycle_test.dart`
    - non-destructive outbox reads
    - lease-gated retries and receipt grace
    - deletion only on receipt
- Updated tests:
  - `test/protocol/router_engine_security_test.dart` now provides the sender's learned static X25519 key, matching the production route-advertisement flow.

---

## Progress log

| Date | Item | Status | Notes |
|---|---|---|---|
| 2026-11-08 | Audit + root-cause list | Done | Initial delivery audit |
| 2026-11-08 | Signed control plane | Done | All `public_metadata` signatures removed |
| 2026-11-08 | End-to-end receipts | Done | Signed, persist-before-ack, duplicate recovery |
| 2026-11-08 | Receipt-driven outbox | Done | Lease-based, receipt-only deletion |
| 2026-11-08 | Single daemon ownership | Done | Riverpod now reuses RouterEngine's daemon |
| 2026-11-08 | Automated verification | Done | analyze clean, 174 tests passing |
| 2026-11-10 | Block 1: native spool + ACK/replay | Done | Durable SQLite spool, replay on attach/overflow |
| 2026-11-10 | Block 1: service radio + wake locks | Done | Service arms radios, watchdog, partial + Wi-Fi locks |
| 2026-11-10 | Block 1: reconnect + discovery | Done | Continuous discovery, desired-peer reconnect, unique device names |
| 2026-11-10 | Block 1: resume + notifications + battery UI | Done | Snapshot diff, resume replay, message notifications, settings tiles |
| 2026-11-10 | Block 1: Android build validation | Done | `app-debug.apk` built; incremental rebuild 35s |
| 2026-11-09 | Two-device manual test | Pending | Requires physical Android devices |

## Key references

- `lib/core/crypto/packet_service.dart`
- `lib/core/routing/router_engine.dart`
- `lib/core/routing/outbox_daemon.dart`
- `lib/core/routing/routing_database.dart`
- `lib/core/routing/route_protocol.dart`
- `lib/core/repositories/message_repository.dart`
- `lib/core/providers.dart`
- `test/protocol/delivery_lifecycle_test.dart`
- `test/routing/outbox_lease_lifecycle_test.dart`
- `test/protocol/signature_boundary_test.dart`
- `test/transport/connection_reliability_test.dart`
