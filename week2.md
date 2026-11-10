# Week 2 — Mesh Correctness and Efficiency (Block 2)

**Goal:** make catch-up work after restarts, keep a resendable sent history, stop blind flooding, and reduce duplicate control traffic.

**Branch:** `main`  
**Depends on:** Week 1 delivery lifecycle + Block 1 native durability

---

## Root causes found

- [x] **Anti-entropy summary used the RAM-only replay cache.** After a restart the summary vector forgot every previously processed packet, so peers re-sent history.
- [x] **Sent packets were deleted on delivery receipt.** `SYNC_REQUEST` could not answer for a packet after the outbox row was removed.
- [x] **Outbox flush treated any packet with `ttl > 0` as relevant to every connected peer.** That is a blind flood, not controlled relay.
- [x] **Duplicate messages could trigger a receipt storm.** Every duplicate re-sent a receipt with no throttle.
- [x] **No persisted sent-history expiry.** A resend store needs its own TTL/cleanup.

---

## Week 2 todo

### A. Persistent anti-entropy

- [x] Add `DatabaseService.getProcessedPacketIds(...)` with expiry filtering.
- [x] Add `PacketService.getProcessedPacketIdsFromStore()` merging RAM + SQLite.
- [x] Use the persistent set in `SYNC_HANDSHAKE` and `SYNC_SESSION_END` missing-packet calculation.
- [x] Include sent-history IDs in the local summary vector.
- [x] Batch `SYNC_REQUEST` into MTU-safe 40-ID batches.

### B. Sent-history retention

- [x] Add schema v7 `sent_history` table.
- [x] Copy the outbox packet into `sent_history` on verified delivery receipt.
- [x] Delete the outbox row only after the sent-history insert.
- [x] Answer `SYNC_REQUEST` from both outbox and sent history.
- [x] Chunk sent-history lookups beneath SQLite variable limits.
- [x] Purge sent-history rows at envelope expiry.
- [x] Add a regression test for resend-after-receipt.

### C. Controlled relay

- [x] Send an outbox packet only when the peer is the direct recipient or the active route's next hop.
- [x] Trigger `ROUTE_REQUEST` for destinations with no route.
- [x] Keep direct-recipient delivery immediate.
- [x] Add route-cache-per-flush to avoid repeated DB lookups.

### D. Receipt traffic

- [x] Throttle duplicate receipt sends per packet ID.
- [x] Purge old throttle entries during maintenance.

### Deferred within Block 2

- [ ] Read receipts + unread counts.
- [ ] Per-conversation ordering (sequence/Lamport clock).
- [ ] Route aging execution and probabilistic invalidation.
- [ ] Explicit `lease_until` / `last_attempt_at` / `attempt_count` columns (current `next_retry_at` acts as the lease).
- [ ] Expired/failed message retry UI polish.
- [ ] Three-node physical relay validation.

---

## Acceptance criteria

- [x] After an app restart, anti-entropy still knows previously processed packet IDs.
- [x] A delivered packet can be re-sent on `SYNC_REQUEST` until expiry.
- [x] The outbox flusher no longer offers every queued packet to every peer.
- [x] Unknown routes trigger route discovery instead of blind flooding.
- [x] Duplicate messages do not produce an unbounded receipt stream.
- [x] Large offline gaps produce batched sync requests instead of an oversized control packet.
- [x] Analyzer and tests stay green.

---

## Progress log

| Date | Item | Status | Notes |
|---|---|---|---|
| 2026-11-10 | Week 2 audit | Done | Persistent sync/sent-history/fan-out gaps identified |
| 2026-11-10 | Schema v7 + sent history | Done | `sent_history` table + expiry purge |
| 2026-11-10 | Persistent anti-entropy | Done | RAM + SQLite processed IDs |
| 2026-11-10 | Controlled relay | Done | Direct/next-hop only + route request |
| 2026-11-10 | Receipt throttling | Done | 5s per-packet throttle, test override |
| 2026-11-10 | Batched sync requests | Done | 40-ID MTU-safe batches |
| 2026-11-10 | Full verification | Done | analyze clean, 178 tests, APK built |

---

## Verification

- `flutter analyze` — 0 issues.
- `flutter test` — **178 tests passed**.
- `flutter build apk --debug` — passed (78s incremental build).
- New tests:
  - `test/routing/sent_history_test.dart` — sent-history storage, expiry purge, queued lookup.
  - `test/protocol/delivery_lifecycle_test.dart` — persistent processed IDs + sent-history retention after receipt.

## Key references

- `lib/core/database/database_service.dart`
- `lib/core/crypto/packet_service.dart`
- `lib/core/routing/route_protocol.dart`
- `lib/core/routing/outbox_daemon.dart`
- `lib/core/routing/routing_database.dart`
- `lib/core/routing/router_engine.dart`
- `test/routing/sent_history_test.dart`
