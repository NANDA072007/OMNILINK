# Document 08: Platform Channel Design Specification

## 1. Overview & Communication Architecture

Platform channels provide the IPC bridge between Layer 2 (Dart Core Engine) and Layer 3 (Native Kotlin Radio Transport).

```text
+------------------------------------------------------------------------+
|                     FLUTTER LAYER (Dart Isolate)                       |
|                                                                        |
|  [ NativeTransportBridge ]                                             |
|        |                                                               |
|        |-- MethodChannel.invokeMethod(...) ------------+               |
|        |                                               |               |
|        |<-- EventChannel.receiveBroadcastStream() --+  |               |
+--------|--------------------------------------------|--|---------------+
         |                                            |  |
         | IPC Platform Channel Boundary              |  |
         |                                            |  |
+--------|--------------------------------------------|--|---------------+
|        v                                            |  v               |
|  [ MethodCallHandler ]                              | [ EventSink ]    |
|                                                     |                  |
|                    ANDROID NATIVE LAYER (Kotlin)    +                  |
|                    [ OmnilinkTransportPlugin ]                         |
+------------------------------------------------------------------------+
```

---

## 2. Channel Names & Contract Identifiers

- **MethodChannel Identifier**: `omnilink/transport/control`
- **EventChannel Identifier**: `omnilink/transport/events`

---

## 3. Dart-to-Kotlin Methods (`MethodChannel`)

| Method Name | Arguments | Return Type | Purpose |
| :--- | :--- | :--- | :--- |
| `startDiscovery` | `{"serviceId": String}` | `Boolean` | Begins scanning for nearby peer devices emitting service ID. |
| `stopDiscovery` | `null` | `Boolean` | Stops peer discovery scanning to save power. |
| `connectPeer` | `{"peerId": String}` | `Boolean` | Initiates radio connection to a discovered endpoint. |
| `disconnectPeer` | `{"peerId": String}` | `Boolean` | Closes active transport session with a peer. |
| `sendPacket` | `{"peerId": String, "payload": ByteArray}` | `Boolean` | Transmits raw binary/string packet to connected peer. |
| `getTransportStatus`| `null` | `Map<String, Any>`| Returns current radio adapter health and peer counts. |

---

## 4. Kotlin-to-Dart Events (`EventChannel`)

Events are pushed asynchronously from Kotlin to Dart as structured `Map<String, Dynamic>` payload dictionaries containing an `"eventType"` header field:

### 4.1 Event Op-codes
1. **`onPeerFound`**: Discovered a nearby node.
   ```json
   {
     "eventType": "onPeerFound",
     "peerId": "NEARBY_EP_9A8B",
     "friendlyName": "Alice_Phone",
     "rssi": -65,
     "transportType": "ANDROID_NEARBY"
   }
   ```
2. **`onPeerLost`**: Discovered peer moved out of range.
   ```json
   {
     "eventType": "onPeerLost",
     "peerId": "NEARBY_EP_9A8B"
   }
   ```
3. **`onConnected`**: Transport link established with peer.
   ```json
   {
     "eventType": "onConnected",
     "peerId": "NEARBY_EP_9A8B"
   }
   ```
4. **`onDisconnected`**: Transport link terminated.
   ```json
   {
     "eventType": "onDisconnected",
     "peerId": "NEARBY_EP_9A8B"
   }
   ```
5. **`onPacketReceived`**: Incoming packet payload received from native radio.
   ```json
   {
     "eventType": "onPacketReceived",
     "senderPeerId": "NEARBY_EP_9A8B",
     "payloadBytes": [123, 34, 112, 114, 111, 116, 111, 99, 111, 108, 95, ... ]
   }
   ```
6. **`onError`**: Transport level failure event.
   ```json
   {
     "eventType": "onError",
     "errorCode": "TRANSPORT_INITIALIZATION_FAILED",
     "errorMessage": "Bluetooth permissions denied by OS."
   }
   ```

---

## 5. Threading & Lifecycle Handling

- **Main Thread Isolation**: Platform channel invocations in Kotlin run on the **Android UI Main Thread**. Native radio I/O calls must immediately dispatch execution to Kotlin Coroutines using `Dispatchers.IO` to prevent UI stutter in Flutter.
- **App Lifecycle Pauses**: When Flutter transitions to `AppLifecycleState.paused`, `stopDiscovery()` is invoked unless a foreground service wake lock is explicitly acquired.
