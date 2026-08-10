# Document 10: iOS Feasibility & Research Report

## 1. Objective & Scope

While Phase 1 MVP is restricted to Android, OMNILINK's 3-Layer Architecture requires early research into iOS feasibility. This document evaluates Apple's native radio APIs, iOS background execution restrictions, and platform boundary hurdles.

---

## 2. iOS Native Networking APIs Comparison

| iOS API Framework | Protocol / Underlying Tech | Discovery Support | Background Feasibility | Cross-Platform (iOS-Android) |
| :--- | :--- | :--- | :--- | :--- |
| **MultipeerConnectivity** | Wi-Fi P2P + Bluetooth Classic | High (`MCNearbyServiceAdvertiser`) | **Very Low** (Suspended within 30s in background) | 🚫 **Apple Only** (No Android interop) |
| **CoreBluetooth** | Bluetooth Low Energy (GATT) | High (`CBCentralManager` / `CBPeripheralManager`) | **Medium** (Tolerates background scanning with strict limits) | **YES** (Standard BLE GATT interop) |
| **Network.framework** | P2P Wi-Fi / Bonjour (`NWListener`) | Medium (`NWBrowser`) | **Low** (Requires active background socket mode) | **YES** (Over standard TCP/UDP) |

---

## 3. Critical iOS Constraints & Hurdles

### 3.1 Background Execution Limitations (The #1 iOS Risk)
Apple iOS aggressively suspends non-foreground applications to preserve battery:
- **MultipeerConnectivity** sessions freeze completely when the user switches apps or locks the screen.
- **CoreBluetooth** can advertise and scan in the background *only* if the app requests `bluetooth-central` and `bluetooth-peripheral` UIBackgroundModes. However, iOS throttles advertising frequencies dynamically, making discovery times drop significantly.

### 3.2 Required Permission Strings (`Info.plist`)
- `NSBluetoothAlwaysUsageDescription`: Mandatory explanation for BLE scanning.
- `NSLocalNetworkUsageDescription`: Mandatory for Bonjour / Wi-Fi peer discovery on iOS 14+.

### 3.3 Lack of Cross-Platform Multipeer Connectivity
Apple's `MultipeerConnectivity` framework relies on proprietary Apple Wi-Fi/Bluetooth handshakes. It **cannot** communicate directly with Android's Nearby Connections API or Wi-Fi Direct interfaces.

---

## 4. Cross-Platform Android <-> iOS Strategy (Phase 9 Target)

To achieve direct P2P messaging between an iPhone and an Android phone:

```text
[ Android Device ]                                           [ iOS Device ]
        |                                                          |
  (BLE Peripheral) <======== BLE Standard GATT ========> (BLE Central)
  Advertises GATT Service                                Scans for GATT UUID
  UUID: 0000FE55-...                                     0000FE55-...
```

1. **BLE GATT Profile as Common Denominator**: Android acts as BLE Peripheral (GATT Server), iOS acts as BLE Central (GATT Client), or vice versa.
2. **Wi-Fi Hotspot Handshake**: Use BLE to exchange temporary Local Wi-Fi Access Point credentials, then upgrade payload transmission to high-speed TCP sockets via `Network.framework`.
