# Document 06: Identity & Security Model

## 1. Cryptographic Identity & Public Key Fingerprinting

OMNILINK discards traditional phone numbers, central accounts, and email addresses. Device identities are **cryptographic keypairs** generated locally on the device during initial setup.

```text
[ Ed25519 Private Key ] ---- Secret (Stored in Android Keystore / iOS Keychain)
        |
        v
[ Ed25519 Public Key ] ---- Hex String (64 Chars) === Canonical Device Node ID
        |
        v (SHA-256 Truncated / QR Code / SAS)
[ Human-Readable Display Tag ] (e.g., "Alice @ 8F3B-2A1C")
```

- **Master Signing Key**: **Ed25519** curve keypair.
- **Node ID**: The hex-encoded 256-bit public key string.
- **Friendly Name**: User-selected nickname (e.g., "Alice"), stored in payload metadata, editable at any time without changing cryptographic identity.

---

## 2. Standard Cryptographic Primitives

> [!CAUTION]
> **NO CUSTOM CRYPTOGRAPHY RULE**: OMNILINK strictly uses standardized, widely audited cryptographic primitives. Custom mathematical ciphers or non-standard key expansion functions are prohibited.

| Purpose | Selected Primitive | Standard |
| :--- | :--- | :--- |
| **Long-Term Identity Signatures** | **Ed25519** | RFC 8032 |
| **Key Exchange / ECDH** | **X25519** | RFC 7748 |
| **Authenticated Payload Encryption**| **ChaCha20-Poly1305** | RFC 8439 (AEAD) |
| **Hashing & Fingerprinting** | **SHA-256** | FIPS 180-4 |

---

## 3. Security Roadmap & Perfect Forward Secrecy (PFS) Strategy

To keep the initial MVP execution tight and non-blocking while retaining a clear path to production security:

### 3.1 Protocol v0.1 MVP Security Model (Baseline)
- Uses **static X25519 key exchange** combined with **Ed25519-signed identity exchange**.
- Enables 1:1 direct encrypted text messaging between two Android devices without complex session negotiation state machines.

### 3.2 Protocol v0.2 Security Hardening Milestone (Perfect Forward Secrecy)
- Introduces **ephemeral X25519 session keys** derived per session.
- **Signed Ephemeral Keys**: Ephemeral public keys MUST be signed by the device's long-term Ed25519 identity key.
- **Replay Protection**: Ephemeral handshakes include random session nonces (128-bit) and timestamps.
- **Ephemeral Key Lifecycle**: Ephemeral private keys MUST NOT be persisted long-term to memory or disk; they are zeroed upon session disconnect.
- *Note*: If PFS can be implemented cleanly in Dart during Phase 1 without delaying the MVP, it may be included early as a non-blocking hardening option.

---

## 4. Out-of-Band (OOB) Pairing & 6-Digit SAS Verification

To prevent Man-in-the-Middle (MITM) attacks during trusted peer pairing:

### 4.1 SAS Derivation Formula
SAS is derived directly from the negotiated session shared secret and transcript parameter nonces:

```text
shared_secret = X25519(local_private_key, remote_public_key)
sas_input = shared_secret + device_A_nonce + device_B_nonce + session_id + protocol_version
SAS = First 6 decimal digits of HMAC-SHA256(sas_input, "omnilink-sas-v1")
```

### 4.2 SAS Pairing Enforcement Rules
1. **6-Digit Decimal Code**: Displayed visually on both device screens (e.g. `482-915`).
2. **User Confirmation**: User must explicitly confirm that 6-digit codes match on both screens.
3. **Abortion on Mismatch**: If user rejects or codes do not match, pairing is aborted immediately and connection drops.
4. **Rate-Limiting**: Confirmation attempts are limited to 3 attempts per minute per peer to prevent brute-force verification.
5. **Trusted State Gating**: Sensitive message payloads MUST NOT be transmitted until SAS pairing is confirmed for trusted pairing mode.

---

## 5. Key Storage & Security Infrastructure

- **Android**: Master seed and private keys are stored using `flutter_secure_storage` backed by the hardware-isolated **Android Keystore System** (TEE/StrongBox).
- **iOS**: Keys are persisted in the **iOS Keychain** with `kSecAccessControlBiometryAny` flags.

---

## 6. Security Threat Matrix & Mitigations

| Threat Vector | Description | Architectural Mitigation |
| :--- | :--- | :--- |
| **Replay Attacks** | Adversary re-broadcasts captured valid packets. | LRU `packet_id` cache + session nonces drop duplicate packets. |
| **Man-in-the-Middle (MITM)**| Rogue node injects public key during initial exchange. | Out-of-Band 6-digit SAS confirmation + Ed25519 signature checks. |
| **Relay Eavesdropping** | Intermediate hop inspects relay packet data. | Mandatory ChaCha20-Poly1305 E2E payload encryption. |
| **Mesh Spam & DoS** | Malicious device floods radio channel with dummy packets. | Strict `max_hops` (TTL = 7) + local rate limiting (max 10 pkts/sec). |
| **Signature Forgery** | Adversary alters recipient header metadata. | Header parameters bound to Ed25519 signature digest. |
