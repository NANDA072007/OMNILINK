# Document 14: Test Plan & Quality Assurance Strategy

## 1. Overview & Testing Pyramid

The testing strategy spans unit, integration, platform channel, and physical multi-device manual testing.

```text
               / \
              /   \
             / Manual\              <- Physical 2-Device Android Tests (Checklist)
            /  Device \
           /----------- \
          / Integration  \          <- Platform Channel & Database Integration Tests
         /----------------\
        /    Unit Tests    \        <- Dart Core Crypto, Protocol Envelopes, State Machines
       /--------------------\
```

---

## 2. Automated Test Suites

### 2.1 Dart Unit Tests (`test/unit/`)
- **Protocol Envelope Test**: Verify JSON serialization, deserialization, and required field validation.
- **Crypto Engine Test**: Test Ed25519 key generation, X25519 key exchange, ChaCha20-Poly1305 encryption, and tampering detection.
- **Deduplication Cache Test**: Verify LRU hash ring drops duplicate packet IDs correctly.
- **State Machine Test**: Validate message lifecycle transitions (`QUEUED` -> `SENDING` -> `DELIVERED`).

### 2.2 Flutter Widget Tests (`test/widget/`)
- Mock `TransportAdapter` interface. Verify UI renders discovered peers, message list updates, and error toasts appear on connection drops.

### 2.3 Kotlin Platform Channel Tests (`android/app/src/test/`)
- Mock `ConnectionsClient` using Robolectric to test native MethodChannel responses and event emission.

---

## 3. Manual Physical Device Testing (MVP Focus)

Since physical wireless radios (Bluetooth, Wi-Fi Direct) cannot be fully simulated in Android emulators, manual testing on two physical Android devices is mandatory.

### Test Environment Requirements:
- 2x Physical Android Devices (Android 10+).
- Airplane Mode ON (Cellular and external Internet disabled).
- Bluetooth and Wi-Fi radios toggled ON.

### Execution Target:
Follow the comprehensive manual checklist in `tests/manual_test_checklists/android_direct_mvp.md`.

---

## 4. Key Failure Scenarios to Validate

1. **Permission Revocation**: Revoke Bluetooth/Location permission while app is running; verify app gracefully displays error toast instead of crashing.
2. **Radio Toggled Off**: Turn off Bluetooth during active message payload transmission; verify state transitions to `FAILED` or `SEARCHING_FOR_PEER`.
3. **Out-of-Range Walking**: Walk Device B 50 meters away until connection drops; verify `onPeerLost` event fires and UI updates.
4. **Background Lock-screen Test**: Lock screen of Device B; send message from Device A; verify message delivers upon screen unlock.
