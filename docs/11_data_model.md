# Document 11: Local Data Model & SQLite Schema

## 1. Overview

OMNILINK maintains a lightweight local relational store (`Drift` / `SQLite`) to persist identity profiles, discovered contacts, outbox queues, and conversation threads offline.

---

## 2. Relational Schema Definitions (SQL / Drift Format)

### 2.1 `device_profiles` Table
Stores local identity keypairs and system configuration.
```sql
CREATE TABLE device_profiles (
    node_id TEXT PRIMARY KEY NOT NULL,        -- Hex Ed25519 Public Key
    friendly_name TEXT NOT NULL,              -- User-chosen nickname
    created_at INTEGER NOT NULL,              -- Epoch timestamp (ms)
    is_active BOOLEAN NOT NULL DEFAULT 1
);
```

### 2.2 `peer_devices` Table
Tracks discovered and trusted nearby peer nodes.
```sql
CREATE TABLE peer_devices (
    peer_node_id TEXT PRIMARY KEY NOT NULL,   -- Hex Ed25519 Public Key
    friendly_name TEXT,                        -- Last advertised nickname
    last_seen_at INTEGER NOT NULL,            -- Epoch timestamp (ms)
    rssi INTEGER,                              -- Signal strength indicator
    transport_type TEXT NOT NULL,              -- E.g. "ANDROID_NEARBY"
    connection_status TEXT NOT NULL            -- "DISCOVERED", "CONNECTED", "DISCONNECTED"
);
```

### 2.3 `messages` Table
Local log of sent, received, and queued user text messages.
```sql
CREATE TABLE messages (
    message_id TEXT PRIMARY KEY NOT NULL,     -- UUIDv4 String
    conversation_id TEXT NOT NULL,            -- Peer Node ID (1:1 chat ID)
    sender_node_id TEXT NOT NULL,             -- Sender Ed25519 Public Key
    recipient_node_id TEXT NOT NULL,          -- Recipient Ed25519 Public Key
    plaintext_body TEXT,                      -- Decrypted plaintext (NULL if relaying)
    state TEXT NOT NULL,                      -- E.g. "QUEUED", "SENDING", "DELIVERED"
    created_at INTEGER NOT NULL,              -- Created Epoch timestamp (ms)
    updated_at INTEGER NOT NULL,              -- Last state update timestamp
    FOREIGN KEY(conversation_id) REFERENCES peer_devices(peer_node_id)
);
```

### 2.4 `outbox_queue` Table
Transient queue managing outbound transmission retries over native radio with exponential backoff and jitter limits.
```sql
CREATE TABLE outbox_queue (
    queue_id INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id TEXT UNIQUE NOT NULL,          -- FK to messages table
    recipient_node_id TEXT NOT NULL,          -- Target peer node ID
    serialized_packet TEXT NOT NULL,          -- Encrypted JSON/Binary packet
    retry_count INTEGER NOT NULL DEFAULT 0,   -- Transmission attempt count
    max_retries INTEGER NOT NULL DEFAULT 6,   -- Maximum allowable retries before FAILED (default 6)
    last_error_code TEXT,                     -- Error log code (e.g. "RADIO_LINK_DROPPED")
    last_error_message TEXT,                  -- Human-readable error description
    next_retry_at INTEGER NOT NULL,           -- Backoff retry epoch timestamp
    backoff_policy TEXT NOT NULL DEFAULT 'EXPONENTIAL_JITTER', -- Retry strategy identifier
    priority INTEGER NOT NULL DEFAULT 1,       -- 0=Low, 1=Normal, 2=SOS
    FOREIGN KEY(message_id) REFERENCES messages(message_id) ON DELETE CASCADE
);
```

### 2.5 `inbox_relay_store` Table (Future Store-and-Forward Phase)
```sql
CREATE TABLE inbox_relay_store (
    packet_id TEXT PRIMARY KEY NOT NULL,
    recipient_node_id TEXT NOT NULL,
    serialized_packet TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    received_at INTEGER NOT NULL
);
```

---

## 3. Data Flow Diagram

```text
[ User Enters Text ] ----> Insert to `messages` (state="QUEUED")
                                  |
                                  v
                           Insert to `outbox_queue`
                                  |
                                  v
                    Send over Platform Channel -> Native Radio
                                  |
                                  +--> ACK Received -> Delete from `outbox_queue`
                                                   -> Update `messages` (state="DELIVERED")
```
