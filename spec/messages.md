# Specification: Message Types & Opcode Schemas

## 1. Overview of Opcodes

This specification defines the 8 primary message opcodes supported by the OMNILINK protocol.

---

## 2. Message Opcode Specifications

### 2.1 `HELLO`
- **Purpose**: Initial link handshake when two native radios establish connection.
- **Sender Behavior**: Broadcasts local node capabilities upon radio link up.
- **Receiver Behavior**: Caches peer node capability payload and responds with local `HELLO`.
- **Payload Schema**:
  ```json
  {
    "device_name": "Alice_Pixel7",
    "supported_transports": ["ANDROID_NEARBY", "BLE"],
    "battery_level": 85
  }
  ```

### 2.2 `IDENTITY_EXCHANGE`
- **Purpose**: Exchanges public keys and ephemeral X25519 DH parameters for session key derivation.
- **Sender Behavior**: Sends sender's X25519 ephemeral public key (`eph_pk`).
- **Receiver Behavior**: Derives shared symmetric session key using local X25519 secret key and sender's `eph_pk`.
- **Payload Schema**:
  ```json
  {
    "ephemeral_x25519_pk": "hex_string_64_chars",
    "identity_ed25519_pk": "hex_string_64_chars"
  }
  ```

### 2.3 `MESSAGE_PAYLOAD`
- **Purpose**: Carries user text, location data, or binary attachment payload.
- **Sender Behavior**: Formats plaintext into JSON, encrypts with session key, and emits envelope.
- **Receiver Behavior**: Decrypts payload, verifies Poly1305 MAC tag, updates chat thread UI, and emits `DELIVERY_RECEIPT`.
- **Payload Schema (Decrypted Plaintext)**:
  ```json
  {
    "content_type": "text/plain",
    "body": "Hello OMNILINK world!",
    "timestamp": 1775836800000
  }
  ```

### 2.4 `DELIVERY_RECEIPT`
- **Purpose**: Confirms successful receipt and decryption of a message payload by final recipient.
- **Sender Behavior**: Emitted automatically by recipient upon successful payload decryption.
- **Receiver Behavior**: Updates original sender's message state from `DELIVERED` to `RECEIPT_RECEIVED` (`✓✓` blue checks).
- **Payload Schema**:
  ```json
  {
    "target_packet_id": "a5f8e3b1-90c4-4d8e-b812-7f2a1e345678",
    "status": "DECRYPTED_SUCCESSFULLY",
    "received_at": 1775836805000
  }
  ```

### 2.5 `FORWARD_REQUEST` (Future Phase)
- **Purpose**: Requests an intermediate relay node to buffer and store-and-forward an encrypted envelope.

### 2.6 `ROUTE_REQUEST` / `ROUTE_RESPONSE` (Future Phase)
- **Purpose**: Queries active multi-hop paths to distant unreachable node IDs across the mesh network.

### 2.7 `GOODBYE`
- **Purpose**: Graceful session termination notice prior to turning off radio or disconnecting.
