# Document 07: Transport Abstraction Layer Design

## 1. Transport Interface Contract

To enable multi-radio switching and platform isolation, the native layer abstracts all physical communications behind a single unified interface.

```kotlin
// Native Kotlin Abstract Transport Contract
interface NativeTransportAdapter {
    val transportId: String
    val capabilities: TransportCapabilities

    fun startDiscovery(serviceId: String, callback: TransportDiscoveryCallback)
    fun stopDiscovery()

    fun connectPeer(peerId: String, connectionCallback: ConnectionCallback)
    fun disconnectPeer(peerId: String)

    fun sendPacket(peerId: String, packetBytes: ByteArray): Boolean
    fun isConnected(peerId: String): Boolean
}
```

---

## 2. Radio Technology Comparison Matrix (Android)

| Transport API | Bandwidth | Range | Power Drain | Background Reliability | Discovery Speed | MVP Choice? |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Android Nearby Connections API** | **High** (Wi-Fi + BLE hybrid) | 10–50m | Medium | Medium | **Fast** (< 15s) | **SELECTED FOR MVP** |
| **BLE (Bluetooth Low Energy)** | Very Low (10–50 kbps) | 30–100m | **Very Low** | **High** (Background OS tolerant) | Medium (20–30s) | Phase 2 |
| **Wi-Fi Direct (P2P)** | **Very High** (10-100 Mbps)| 50–100m | High | Low (Requires user prompt on old OS)| Fast | Phase 2 |
| **Wi-Fi Aware (NAN)** | High | 20–50m | Low-Medium | Medium (Android 8+ restricted) | Fast | Phase 3 |
| **Classic Bluetooth (RFCOMM)** | Medium (1–2 Mbps) | 10m | High | High | Slow (Manual pairing) | Legacy Backup |

---

## 3. Why Nearby Connections API was Chosen for MVP

1. **Integrated Multi-Radio Management**: The Nearby Connections API automatically manages underlying BLE advertisement, Bluetooth RFCOMM handshake, and Wi-Fi Direct socket upgrades internally.
2. **Simplified Peer Lifecycle**: Exposes clean `onEndpointFound`, `onEndpointLost`, and `onPayloadReceived` callbacks directly into native Kotlin.
3. **High Bandwidth Support**: Automatically scales up transport to Wi-Fi Direct when payload size demands higher throughput.
4. **Fast Prototyping**: Eliminates writing 2,000+ lines of raw Android BLE GATT server boilerplate during Phase 1.

---

## 4. Transport Selection & Switching Matrix (Future Multi-Transport Core)

In Phase 10+, the Core Communication Engine selects active transports dynamically based on payload priority and battery level:

```text
[ Outbound Packet ]
        |
        +---> Is Payload > 100 KB? (e.g., Image / Map Tile)
        |         |-- YES --> Request Wi-Fi Direct Transport
        |         |-- NO ---> Is Device Battery < 20%?
        |                         |-- YES --> Request BLE Transport
        |                         |-- NO ---> Request Nearby Connections / Best Available
```

---

## 5. Transport Capability Ratings

```json
{
  "transport_id": "ANDROID_NEARBY_CONNECTIONS",
  "max_packet_bytes": 1048576,
  "supports_broadcast": false,
  "bandwidth_class": "HIGH",
  "latency_class": "LOW",
  "battery_cost_tier": "MEDIUM",
  "requires_location_services": true
}
```
