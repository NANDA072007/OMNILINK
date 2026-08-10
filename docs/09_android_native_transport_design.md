# Document 09: Android Native Transport Design

## 1. Native Plugin Architecture

The Android native transport layer is structured as an isolated Kotlin plugin component embedded in the Android app shell, backed by an optional user-controlled **Foreground Service** to prevent the OS from killing radio sockets during screen lock.

```text
android/app/src/main/kotlin/org/omnilink/
├── MainActivity.kt                      # Binds FlutterEngine to Transport Plugin
└── transport/
    ├── OmnilinkTransportPlugin.kt       # MethodCallHandler & EventChannel.StreamHandler
    ├── OmnilinkForegroundService.kt     # Optional Foreground Service holding notification
    ├── NearbyConnectionsManager.kt      # Google Nearby Connections API Wrapper
    ├── PermissionManager.kt             # Android 12+/14+ Permission Checks & Prompts
    └── models/
        ├── DiscoveredPeer.kt            # Native peer DTO
        └── TransportError.kt            # Standardized transport exceptions
```

---

## 2. Android 14+ Foreground Service Policy & Controls

> [!IMPORTANT]
> **OPTIONAL & USER-VISIBLE FOREGROUND SERVICE RULES**:
> 1. **User Control**: Foreground service is **ONLY** started when the user explicitly enables "Offline Network Mode" or "Active Relay Mode" in app settings.
> 2. **Visible Notification**: Must show an ongoing, non-silent notification: *"OMNILINK Offline Network Active - Listening for nearby devices"*.
> 3. **No Silent Auto-Start**: Must NOT run silently by default upon app boot.
> 4. **Explicit Shutdown**: Must stop immediately when the user disables "Offline Network Mode".
> 5. **Android 14 Type**: Enforces `android:foregroundServiceType="connectedDevice"`.
> 6. **No OEM Survival Guarantee**: Documentation does NOT guarantee survival across aggressive third-party Android OEM battery killers (e.g. Xiaomi MIUI / Samsung Device Care aggressive app kills).

```xml
<!-- AndroidManifest.xml Foreground Service Declaration -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />

<application>
    <service
        android:name="org.omnilink.transport.OmnilinkForegroundService"
        android:foregroundServiceType="connectedDevice"
        android:exported="false" />
</application>
```

---

## 3. Nearby Connections Implementation Overview

The primary transport driver wraps `com.google.android.gms.nearby.connection.ConnectionsClient` using `Strategy.P2P_CLUSTER` (multi-peer cluster networking).

```kotlin
// Pseudocode outline for NearbyConnectionsManager
class NearbyConnectionsManager(private val context: Context) {
    private val connectionsClient = Nearby.getConnectionsClient(context)
    private val SERVICE_ID = "org.omnilink.mesh.v1"

    fun startAdvertising(localDeviceName: String) {
        val options = AdvertisingOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).build()
        connectionsClient.startAdvertising(
            localDeviceName, SERVICE_ID, connectionLifecycleCallback, options
        )
    }

    fun startDiscovery() {
        val options = DiscoveryOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).build()
        connectionsClient.startDiscovery(
            SERVICE_ID, endpointDiscoveryCallback, options
        )
    }

    fun sendPayload(endpointId: String, bytes: ByteArray) {
        if (bytes.size > 4096) {
            throw IllegalArgumentException("INVALID_PACKET_SIZE: Payload exceeds 4 KB ceiling")
        }
        val payload = Payload.fromBytes(bytes)
        connectionsClient.sendPayload(endpointId, payload)
    }
}
```

---

## 4. Hard Packet Framing & MTU Limits

- **Maximum Plaintext Message**: 2 KB (2,048 bytes).
- **Maximum Encrypted Payload**: 4 KB (4,096 bytes).
- **Maximum Full Packet Envelope**: 4 KB (4,096 bytes).
- **Maximum Nearby Connections Payload**: 4 KB (4,096 bytes).
- **Rejection**: Oversized payloads exceeding 4,096 bytes are immediately dropped with error `INVALID_PACKET_SIZE`.

---

## 5. Required Android Permissions Manifest

```xml
<!-- Required for Bluetooth scanning and connectivity -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />

<!-- Android 12+ (API Level 31+) Specific Permissions -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

<!-- Android 13+ (API Level 33+) Nearby Wi-Fi Devices Permission -->
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" android:usesPermissionFlags="neverForLocation" />
```
