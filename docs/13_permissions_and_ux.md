# Document 13: Permissions & UX Specification

## 1. Android Permission Strategy

Modern Android versions enforce strict runtime permission models for local radio access to protect user privacy.

```text
[ App First Launch ]
        |
        v
[ Onboarding Screen 1: Explain Purpose ]
"OMNILINK needs Bluetooth and Nearby permissions to talk to nearby devices without Internet."
        |
        v
[ System Permission Requests ]
  1. BLUETOOTH_SCAN (Android 12+)
  2. BLUETOOTH_CONNECT (Android 12+)
  3. NEARBY_WIFI_DEVICES (Android 13+)
  4. ACCESS_FINE_LOCATION (Android 10-11 fallback)
        |
        +---> [ Granted ] ---> Navigate to Nearby Peers Screen
        |
        +---> [ Denied ] ----> Show Educational Friction Screen ("Radio Access Disabled")
```

---

## 2. Permission Explanation UX Rules

> [!IMPORTANT]
> **TRANSPARENT PRIVACY PROMPT**: Users must be shown a pre-permission modal *before* invoking standard system dialogs. The prompt must explicitly state: "Location and Nearby permissions are required by Android to scan for physical Bluetooth and Wi-Fi radios. OMNILINK does NOT track or upload your GPS location to any server."

---

## 3. Foreground Service & Battery UX Controls

- **Optional Toggle**: Offline background radio listening is OFF by default.
- **User Activation**: The user must explicitly turn ON "Offline Network Mode" in settings to start the foreground service.
- **Persistent Notification**: Displays a clear status bar notification: *"OMNILINK Offline Network Active - Listening for nearby devices"*.
- **Battery Disclaimer**: Settings screen explicitly warns: *"Active offline scanning increases battery consumption by ~2-5% per hour depending on radio density."*
- **Immediate Stopping**: Toggling Offline Network Mode OFF immediately kills the native Android Foreground Service.

---

## 4. Trusted Peer 6-Digit SAS Pairing UX

When establishing a trusted pairing with a newly discovered peer:
1. **Modal Popup**: Displays a 6-digit decimal code (e.g. `482-915`) computed from `HMAC-SHA256(shared_secret + nonces, "omnilink-sas-v1")`.
2. **Visual Comparison**: Both users inspect each other's screen to confirm matching 6-digit codes.
3. **Buttons**:
   - `[ Confirm Match ]`: Marks peer as `TRUSTED`. Enables sensitive messaging.
   - `[ Reject / Mismatch ]`: Drops transport connection immediately.
4. **Rate-Limiting**: Max 3 pairing confirmation attempts per minute.

---

## 5. Screen Wireframe Specifications & User Flow

### 5.1 Onboarding & Permissions Screen
- **Elements**: Illustration of offline devices connected by radio waves, explicit privacy assurance, "Enable Offline Communication" CTA button.

### 5.2 Nearby Devices Discovery Screen
- **Elements**: Animated radar pulse icon, toggle switch ("Offline Discovery ON/OFF"), list of discovered peers showing friendly name, signal strength indicator (RSSI), and "Connect" button.

### 5.3 Chat Screen & Message State Icons
- **Elements**: 1:1 chat thread view, input box, send button, live message delivery status indicators:
  - `⏳` Queued / Encrypting
  - `✓` Sent to Transport
  - `✓✓` Delivered to Remote Device
  - `❌` Failed (Tap to retry)

### 5.4 In-App Debug & Logs Overlay
- **Elements**: Developer overlay accessible via 3-finger tap or drawer item. Shows scrolling live feed of raw JSON packets, platform channel events, and cryptographic verification logs.

### 5.5 Emergency SOS & Safety Disclaimer Modal
- **Elements**: Prominent red SOS button. When pressed, displays mandatory confirmation:
  > **Emergency Notice**: OMNILINK is a peer-to-peer experimental network. It is NOT connected to 911 or emergency services. Tap 'Broadcast SOS' to send your location payload to all nearby OMNILINK devices within local radio range.
