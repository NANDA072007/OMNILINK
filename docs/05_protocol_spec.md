# Document 05: OMNILINK Protocol Specification (Version 0.1)

## 1. Protocol Goals & Overview

The **OMNILINK Protocol (v0.1)** defines the binary and JSON framing rules for peer-to-peer data interchange over heterogeneous native transports.

### Protocol Goals
1. **Transport Agnostic**: The packet structure is completely independent of whether it travels over BLE, Wi-Fi Direct, or cellular backhaul.
2. **End-to-End Encrypted**: Relays cannot inspect payload contents; payload plaintext is unreadable to intermediate transport nodes.
3. **Loop & Replay Protection**: Strict hop counts, time-to-live (TTL), session nonces, and deterministic packet hashing eliminate flooding loops.
4. **Self-Authenticating**: Every packet header carries a cryptographic signature binding metadata to the sender.

---

## 2. Envelope Specification & Hard MTU Bounds

For **Protocol v0.1 (MVP)**, JSON encoding is used to simplify debugging, serialization, and log inspection.

> [!IMPORTANT]
> **STRICT PACKET SIZE CEILING (v0.1 Bounds)**:
> - **Maximum Plaintext Message**: 2 KB (2,048 bytes)
> - **Maximum Encrypted Payload**: 4 KB (4,096 bytes) Base64 encoded
> - **Maximum Full Envelope**: 4 KB (4,096 bytes) Total JSON size
> - Oversized packets are immediately rejected with error opcode `INVALID_PACKET_SIZE`.

```json
{
  "protocol_version": "0.1",
  "packet_id": "a5f8e3b1-90c4-4d8e-b812-7f2a1e345678",
  "sender_id": "ed25519_pubkey_hex_string_64_chars",
  "recipient_id": "ed25519_pubkey_hex_string_64_chars",
  "created_at": 1775836800000,
  "expires_at": 1775923200000,
  "ttl": 7,
  "hop_count": 0,
  "max_hops": 7,
  "priority": 1,
  "message_type": "MESSAGE_PAYLOAD",
  "payload_hash": "sha256_hash_hex_of_encrypted_payload",
  "signature": "ed25519_signature_hex_over_header_and_payload_hash",
  "encrypted_payload": "base64_encoded_chacha20poly1305_ciphertext"
}
```

---

## 3. Envelope Field Definitions

| Field Name | Type | Mandatory? | Description |
| :--- | :--- | :--- | :--- |
| `protocol_version` | String | Yes | Version identifier (e.g., `"0.1"`). |
| `packet_id` | String | Yes | Unique UUIDv4 string identifying this packet. |
| `sender_id` | String | Yes | Hex-encoded Ed25519 Public Key of original sender (64 hex chars). |
| `recipient_id` | String | Yes | Hex-encoded Ed25519 Public Key of intended recipient (or `"BROADCAST"`). |
| `created_at` | Integer | Yes | Unix epoch timestamp in milliseconds when packet was generated. |
| `expires_at` | Integer | Yes | Unix epoch timestamp in milliseconds after which packet must be dropped. |
| `ttl` | Integer | Yes | Time-To-Live counter. Decremented by 1 at each relay hop. Dropped when 0. |
| `hop_count` | Integer | Yes | Incremented by 1 at each hop (starts at 0 at original sender). |
| `max_hops` | Integer | Yes | Maximum permissible hops (default 7). |
| `priority` | Integer | Yes | `0` = Low/Background, `1` = Normal, `2` = High/Emergency SOS. |
| `message_type` | String | Yes | Protocol message opcode (see Section 4). |
| `payload_hash` | String | Yes | SHA-256 hash of `encrypted_payload` (hex encoded). |
| `signature` | String | Yes | Sender Ed25519 signature over (`packet_id + sender_id + recipient_id + created_at + payload_hash`). |
| `encrypted_payload` | String | Yes | Base64-encoded ciphertext payload (or empty string for control signals). |

---

## 4. Message Types Inventory

1. **`HELLO`**: Sent on link establishment to announce local presence and capability mask.
2. **`IDENTITY_EXCHANGE`**: Exchanges public keys and initial handshake parameters (Static X25519 in v0.1 MVP; Signed Ephemeral Session Keys in v0.2).
3. **`MESSAGE_PAYLOAD`**: Carries encrypted user text (max 2 KB plaintext).
4. **`DELIVERY_RECEIPT`**: Signed delivery confirmation emitted by final destination back to sender.
5. **`FORWARD_REQUEST`** (Future Phase): Asks an intermediate node to store-and-forward a packet payload.
6. **`ROUTE_REQUEST`** / **`ROUTE_RESPONSE`** (Future Phase): Discovers active paths to distant node IDs.
7. **`GOODBYE`**: Graceful tear-down signal before disconnecting native radio transport.

### 4.1 Future File Transfer Fragmentation Note
In future versions (v0.3+), payloads exceeding 4 KB (e.g. photos, voice memos, files) will require fragmentation using dedicated opcodes: `FILE_METADATA`, `FILE_CHUNK`, and `FILE_COMPLETE`. **File transfers and packet fragmentation are explicitly OUT OF SCOPE for the MVP.**

---

## 5. Concrete JSON Packet Example (MVP Direct Text Message)

```json
{
  "protocol_version": "0.1",
  "packet_id": "c7a912d4-3e5f-4a11-b8d9-2e6f4a8b9c10",
  "sender_id": "8f3b2a1c9d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4",
  "recipient_id": "1a2b3c4d5e6f708192a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5",
  "created_at": 1775836850000,
  "expires_at": 1775923250000,
  "ttl": 7,
  "hop_count": 0,
  "max_hops": 7,
  "priority": 1,
  "message_type": "MESSAGE_PAYLOAD",
  "payload_hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "signature": "3045022100a89d4f2b1e7c...d8e9f0a1b2c3d4",
  "encrypted_payload": "v8K3pLz9xQmW2rT1vY6uI...aBcDeFgHiJkLmNoP"
}
```
