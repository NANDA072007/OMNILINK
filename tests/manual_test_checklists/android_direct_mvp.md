# Manual Test Checklist: Android Direct 1:1 Messaging MVP

## 1. Test Execution Setup & Environment
- **Prerequisites**: Two physical Android test devices (Device A and Device B) running Android 10+.
- **Environment**: Cellular SIM data OFF, External Wi-Fi Routers OFF (Airplane Mode enabled, Bluetooth & Wi-Fi toggles manually enabled).

---

## 2. Test Cases Verification Table

| Test ID | Scenario / Procedure | Expected Result | Pass / Fail | Notes |
| :--- | :--- | :--- | :--- | :--- |
| **TC-01** | **App Launch**<br>Launch OMNILINK app on both devices. | App opens cleanly to Onboarding screen without crash. | `[ ] PASS` | |
| **TC-02** | **Permission Request**<br>Tap "Enable Offline Communication" on Device A. | Android system prompts for Bluetooth & Nearby permissions. Granted cleanly. | `[ ] PASS` | |
| **TC-03** | **Device Discovery (A -> B)**<br>Tap "Start Discovery" on Device A and Device B. | Device A displays `Bob_Phone` in Nearby Peers list within 15 seconds. | `[ ] PASS` | |
| **TC-04** | **Device Discovery (B -> A)**<br>Verify Device B peer list. | Device B displays `Alice_Phone` in Nearby Peers list. | `[ ] PASS` | |
| **TC-05** | **P2P Link Connection**<br>Tap `Connect` on Device A for `Bob_Phone`. | Both devices establish direct link. Status transitions to `CONNECTED`. | `[ ] PASS` | |
| **TC-06** | **Send Encrypted Message**<br>Type `"Hello OMNILINK Test"` on Device A and tap Send. | Message appears in Device A chat thread with status `✓` (SENDING/SENT). | `[ ] PASS` | |
| **TC-07** | **Receive & Decrypt Payload**<br>Observe Device B chat screen. | Device B receives message, decrypts ChaCha20 payload, and displays `"Hello OMNILINK Test"`. | `[ ] PASS` | |
| **TC-08** | **Delivery Status Update**<br>Observe Device A message status icon. | Device A status updates from single check `✓` to double check `✓✓` (DELIVERED). | `[ ] PASS` | |
| **TC-09** | **Radio Toggle Graceful Recovery**<br>Turn off Bluetooth on Device B mid-session. | Device A displays connection dropped notification without app crash. Message status updates to `FAILED`. | `[ ] PASS` | |
| **TC-10** | **Screen Lock Behavior**<br>Lock screen on Device B. Send message from Device A. | Message delivers cleanly when Device B screen is unlocked. | `[ ] PASS` | |
| **TC-11** | **Debug Log Verification**<br>Open In-App Debug Overlay on Device A. | Raw JSON Protocol v0.1 packet, signatures, and platform channel events are logged clearly. | `[ ] PASS` | |
