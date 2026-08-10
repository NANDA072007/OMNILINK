# Specification: Security Architecture & Cryptographic Enforcement

## 1. Mandatory Cryptographic Suite

OMNILINK strictly prohibits custom, un-audited cryptographic algorithms. All implementation components must conform to the primitives below:

```text
[ Identity Keypair ] -------> Ed25519 (RFC 8032) - Digital Signatures
[ Session ECDH ] -----------> X25519 (RFC 7748) - Diffie-Hellman Key Exchange
[ AEAD Cipher ] ------------> ChaCha20-Poly1305 (RFC 8439) - Authenticated Encryption
[ Key Derivation ] ---------> HKDF-SHA256 (RFC 5869) - Extract-and-Expand KDF
[ Cryptographic Hash ] -----> SHA-256 (FIPS 180-4) - Packet Hashing & Fingerprints
[ SAS Mac Function ] -------> HMAC-SHA256 (RFC 2104) - Short Authentication String
```

---

## 2. Key Exchange & Perfect Forward Secrecy (v0.1 vs v0.2 Strategy)

- **v0.1 MVP Baseline**: Static X25519 key exchange signed with Ed25519 identity keys to ensure fast, non-blocking 2-device MVP text communication.
- **v0.2 Hardening Phase**: Ephemeral X25519 session keys derived per session, signed by device Ed25519 key, combined with 128-bit session nonces and timestamps. Ephemeral private keys MUST NOT be persisted long-term.

---

## 3. Short Authentication String (SAS) 6-Digit Derivation

To protect against Man-in-the-Middle (MITM) attacks during trusted pairing:

### 3.1 Mathematical Derivation
```text
shared_secret = X25519(local_private_key, remote_public_key)
sas_input = shared_secret + device_A_nonce + device_B_nonce + session_id + protocol_version
hmac_digest = HMAC-SHA256(sas_input, key="omnilink-sas-v1")
SAS_code = First 6 decimal digits of (BigEndianUint64(hmac_digest[0..8]) mod 1,000,000)
```

### 3.2 SAS Enforcement Rules
- **6-Digit Display**: Presented as `XXX-XXX` (e.g. `482-915`) on both devices.
- **Explicit Confirmation**: Users confirm matching codes on both screens.
- **Rate-Limiting**: Max 3 confirmation attempts per minute. Connection drops on mismatch.
- **Payload Gating**: Sensitive message payloads MUST NOT be transmitted until SAS pairing is confirmed for trusted pairing mode.

---

## 4. Replay Protection & Rejection Policy

- **LRU Hash Ring**: Maintains seen `packet_id` hashes in a memory-mapped bloom filter / LRU ring buffer. Any inbound packet whose `packet_id` is present in the cache is discarded silently without processing.
- **Clock Skew Threshold**: Any packet carrying a `created_at` timestamp more than **300 seconds (5 minutes)** ahead of local system epoch time, or older than envelope `expires_at`, is rejected immediately.
