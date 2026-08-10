# Specification: Physical Radio Transports

## 1. Transport Capabilities Inventory Table

| Transport ID | Platform Support | Bandwidth | Max Packet Size | Latency | Battery Cost | MVP Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`ANDROID_NEARBY`** | Android 10+ | High (Wi-Fi + BLE) | 32 KB / Chunk | Low (< 50ms) | Medium | **PRIMARY MVP TRANSPORT** |
| **`BLE_GATT`** | Android / iOS | Low (10-50 kbps) | 512 Bytes / Att | Medium (100-300ms) | Very Low | Target Phase 2 |
| **`WIFI_DIRECT`** | Android / iOS | Very High (100 Mbps)| 1 MB / Frame | Very Low (< 10ms)| High | Target Phase 2 |
| **`WIFI_AWARE`** | Android 8+ | High (10-50 Mbps) | 64 KB / Chunk | Low (< 20ms) | Medium | Target Phase 3 |
| **`LOCAL_LAN`** | Android / iOS / PC | Extremely High | 10 MB / Frame | Instant (< 5ms) | Very Low | Target Phase 4 |
| **`INTERNET_GATEWAY`**| Cloud Server | Unlimited | Unlimited | Variable | Low | Target Phase 11 |
| **`HARDWARE_LORA`** | ESP32 / Embedded | Very Low (1 kbps) | 250 Bytes | High (1-3s) | Ultra Low | Target Phase 14 |

---

## 2. Transport Selection Preference Algorithm

When sending an outbound message, the Layer 2 transport selector evaluates active transports in the following priority order:

```text
1. If Local Wi-Fi LAN connected -> Use LOCAL_LAN
2. Else if Payload > 50 KB -> Upgrade to WIFI_DIRECT / ANDROID_NEARBY
3. Else if Battery < 15% -> Downgrade to BLE_GATT
4. Default -> ANDROID_NEARBY (P2P Cluster mode)
```
