# Specification: Platform Channels Contract Interface

## 1. Overview

This document specifies the exact JSON map contracts passed across `MethodChannel("omnilink/transport/control")` and `EventChannel("omnilink/transport/events")`.

---

## 2. `MethodChannel` Methods

### 2.1 `startDiscovery`
- **Direction**: Dart -> Native Platform
- **Arguments**:
  ```json
  {
    "serviceId": "org.omnilink.mesh.v1"
  }
  ```
- **Returns**: `true` on successful scan start, throws `PlatformException` if permissions missing.

### 2.2 `connectPeer`
- **Direction**: Dart -> Native Platform
- **Arguments**:
  ```json
  {
    "peerId": "NEARBY_EP_9A8B"
  }
  ```
- **Returns**: `true` if connection request dispatched.

### 2.3 `sendPacket`
- **Direction**: Dart -> Native Platform
- **Arguments**:
  ```json
  {
    "peerId": "NEARBY_EP_9A8B",
    "payload": [123, 34, 112, 114, 111, 116, 111, 99, 111, 108, 95, 118, ... ]
  }
  ```
- **Returns**: `true` if binary payload queued into native socket buffer.

---

## 3. `EventChannel` Event Payload Schemas

### 3.1 `onPeerFound`
```json
{
  "eventType": "onPeerFound",
  "peerId": "NEARBY_EP_9A8B",
  "friendlyName": "Bob_Pixel6",
  "rssi": -58,
  "transportType": "ANDROID_NEARBY"
}
```

### 3.2 `onPacketReceived`
```json
{
  "eventType": "onPacketReceived",
  "senderPeerId": "NEARBY_EP_9A8B",
  "payloadBytes": [123, 34, 112, 114, 111, 116, 111, 99, 111, 108, 95, ... ]
}
```
