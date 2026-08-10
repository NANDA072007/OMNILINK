# Document 12: Message State Machine Specification

## 1. Message State Diagram

Every message in OMNILINK moves through a formal deterministic state lifecycle.

```text
       [ User Drafts Message ]
                  |
                  v
              ( DRAFT )
                  |
         [ Press Send Button ]
                  |
                  v
             ( QUEUED ) ------------------------+
                  |                             |
         [ Encrypt & Format ]                   |
                  |                             | (No Peer Discovered / Out of Range)
                  v                             |
            ( ENCRYPTED )                       v
                  |                    ( SEARCHING_FOR_PEER )
         [ Push to Native Transport ]           |
                  |                             | (Peer Appears & Connects)
                  v                             v
            ( SENDING ) <-----------------------+
                  |
      +-----------+-----------+
      | (Radio Fail)          | (Ack Received from Peer)
      v                       v
  ( FAILED )            ( DELIVERED )
      |                       |
 [ User Taps Retry ]    [ Remote ACK ]
      |                       v
      +--------------> ( RECEIPT_RECEIVED )
```

---

## 2. State Definitions & Transitions

| State Name | UI Representation | Entry Condition | Exit Condition / Trigger |
| :--- | :--- | :--- | :--- |
| **`DRAFT`** | Text field input | User typing in ChatScreen. | User clicks "Send". |
| **`QUEUED`** | Clock Icon `⏳` | Message saved to `messages` database table. | Core engine fetches item for encryption. |
| **`ENCRYPTED`** | Clock Icon `⏳` | ChaCha20-Poly1305 ciphertext payload generated. | Pushed to native platform channel outbox. |
| **`SEARCHING_FOR_PEER`**| Pulse Icon `📡` | Transport link inactive or peer disconnected. | Discovered peer connects or TTL expires. |
| **`SENDING`** | Single Gray Check `✓` | Bytes actively streaming over Nearby Connections API. | Native radio returns payload result or timeout. |
| **`DELIVERED`** | Double Gray Check `✓✓` | Receiving device sends back link-level transport ACK. | End-to-end receipt packet arrives. |
| **`RECEIPT_RECEIVED`** | Double Blue Check `✓✓` | Recipient app emits cryptographic `DELIVERY_RECEIPT`. | Terminal successful state. |
| **`FAILED`** | Red Warning Icon `❌` | Max retries reached, radio link dropped, or rejected. | User manually taps "Retry". |
| **`EXPIRED`** | Muted Warning `⌛` | Envelope `expires_at` timestamp elapsed. | Garbage collected by database cleaner. |

---

## 3. Exponential Backoff with Jitter Policy

When transmission over native radio fails (e.g. peer briefly moves out of range), retries follow an **exponential backoff schedule with randomized jitter**:

```text
Base Delay Schedule:
  Attempt 1: 1s  + Jitter (0-200ms)
  Attempt 2: 2s  + Jitter (0-400ms)
  Attempt 3: 4s  + Jitter (0-800ms)
  Attempt 4: 8s  + Jitter (0-1000ms)
  Attempt 5: 16s + Jitter (0-1000ms)
  Attempt 6: 32s + Jitter (0-1000ms)
  Attempt 7: Transition to FAILED state (No indefinite retries)
```

- **Max Retries**: 6 attempts (totaling ~63 seconds of backoff).
- **Jitter Rationale**: Randomized jitter prevents simultaneous retry collision storms when multiple devices re-enter radio range at the same instant.
- **Terminal Failure**: Messages DO NOT retry indefinitely. After Attempt 6, status transitions to `FAILED` and requires explicit user tap to retry.
