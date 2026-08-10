# Specification: Technical Packet Schema (Protocol v0.1)

## 1. Packet Envelope Field Reference Table & Hard MTU Bounds

> [!IMPORTANT]
> **PACKET SIZE & MTU LIMITS**:
> - **Maximum Plaintext Message**: 2 KB (2,048 bytes)
> - **Maximum Encrypted Payload**: 4 KB (4,096 bytes) Base64 encoded
> - **Maximum Full Envelope**: 4 KB (4,096 bytes) Total JSON payload
> - **Maximum Nearby Connections Payload**: 4 KB (4,096 bytes)
> Packets exceeding 4,096 bytes MUST be rejected with error `INVALID_PACKET_SIZE`.

| Field Name | Data Type | Required? | Description | Example Value |
| :--- | :--- | :--- | :--- | :--- |
| `protocol_version` | String | Mandatory | Protocol version string | `"0.1"` |
| `packet_id` | String | Mandatory | UUIDv4 unique packet identifier | `"a5f8e3b1-90c4-4d8e-b812-7f2a1e345678"` |
| `sender_id` | String | Mandatory | Sender Ed25519 public key (64 hex chars) | `"8f3b2a1c9d4e5f60718293a4b5c6d7e8..."` |
| `recipient_id` | String | Mandatory | Recipient Ed25519 public key or `"BROADCAST"` | `"1a2b3c4d5e6f708192a3b4c5d6e7f8a9..."` |
| `created_at` | Integer | Mandatory | Epoch creation timestamp (milliseconds) | `1775836800000` |
| `expires_at` | Integer | Mandatory | Epoch expiration timestamp (milliseconds) | `1775923200000` |
| `ttl` | Integer | Mandatory | Time-To-Live hop counter (decrements) | `7` |
| `hop_count` | Integer | Mandatory | Number of relay hops traversed (increments) | `0` |
| `max_hops` | Integer | Mandatory | Maximum allowable relay hops | `7` |
| `priority` | Integer | Mandatory | Priority tier (`0`=Low, `1`=Normal, `2`=Emergency SOS) | `1` |
| `message_type` | String | Mandatory | Message opcode | `"MESSAGE_PAYLOAD"` |
| `payload_hash` | String | Mandatory | SHA-256 hash of `encrypted_payload` (hex) | `"e3b0c44298fc1c149afbf4c8996fb924..."` |
| `signature` | String | Mandatory | Ed25519 signature over envelope metadata | `"3045022100a89d4f2b1e7c...d8e9f0a1"` |
| `encrypted_payload` | String | Mandatory | Base64-encoded ChaCha20-Poly1305 ciphertext | `"v8K3pLz9xQmW2rT1vY6uI...aBcDeFgH"` |

---

## 2. Canonical Signature Digest Construction

To generate or verify `signature`:
1. Concatenate strings: `packet_id + sender_id + recipient_id + created_at.toString() + payload_hash`.
2. Compute SHA-256 digest over concatenated UTF-8 byte array.
3. Sign digest using Sender's Ed25519 Private Key.

---

## 3. Future File Transfer Note (v0.3+ Out of Scope for MVP)
Files and attachments exceeding 4 KB require fragmentation. In future protocol versions, file transfers will utilize `FILE_METADATA`, `FILE_CHUNK`, and `FILE_COMPLETE` opcodes. **File transfers are explicitly OUT OF SCOPE for Protocol v0.1 MVP.**
