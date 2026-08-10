# Document 19: Tech Stack & Tools Specification

## 1. Overview & Dual-Perspective Stack Comparison

OMNILINK distinguishes between the **Fastest MVP Stack** (designed for rapid prototyping and validation) and the **Best Long-Term Stack** (designed for cross-platform hardware ubiquity and production scale).

---

## 2. Tech Stack Comparison Matrix

| Architectural Layer | Fastest MVP Stack (Phase 1 Target) | Best Long-Term Stack (Phase 13+ Target) |
| :--- | :--- | :--- |
| **Layer 1: UI / Application** | Flutter (Dart 3.x) + Riverpod 2.x | Flutter (Dart 3.x) + Riverpod / BLoC |
| **Layer 2: Core Engine** | **Pure Dart Engine** | **Portable Rust Core (`libomnilink_core.a`)** |
| **Layer 3: Android Transport**| Kotlin + Google Nearby Connections API | Kotlin + Native BLE / Wi-Fi Direct Custom Drivers |
| **Layer 3: iOS Transport** | N/A (Phase 5 Spike) | Native Swift (CoreBluetooth + Network.framework) |
| **Local DB Storage** | `drift` / `sqflite` (SQLite ORM) | Native SQLite / `rusqlite` in Rust Core |
| **Secure Key Storage** | `flutter_secure_storage` | Android Keystore / iOS Keychain via FFI |
| **Crypto Primitives** | Dart `cryptography` package | `libsodium` / `RustCrypto` / Tink |
| **Inter-Layer Bridge** | Platform Channels (`MethodChannel`) | C-FFI / `flutter_rust_bridge` + Platform Channels |

---

## 3. Recommended Development Tools & Environment

- **Primary IDE**: Android Studio (with Flutter and Dart plugins installed).
- **Secondary IDE (iOS)**: Xcode 15+ (for future iOS Swift native testing).
- **Build Systems**: Gradle (Android), CocoaPods / Swift Package Manager (iOS), Cargo (Future Rust core).
- **Static Analysis**: `flutter analyze` with strict linter rules (`very_good_analysis`).

---

## 4. CI/CD & Testing Infrastructure Recommendations

- **Source Control**: Git with conventional commit messages (`feat:`, `fix:`, `docs:`, `chore:`).
- **Continuous Integration**: GitHub Actions runner compiling `flutter build apk --debug` on pull requests.
- **Automated Unit Testing**: `flutter test` running on pull requests to ensure protocol envelope and crypto regress tests pass.

---

## 5. Technology Choice Risk Analysis

1. **Google Nearby Connections Dependency (MVP Risk)**:
   - *Risk*: Requires Google Play Services on target Android devices.
   - *Mitigation*: Acceptable for MVP validation; Phase 2 introduces standalone Kotlin BLE drivers for open-source AOSP compatibility.
2. **Dart Isolates vs Rust FFI (Long-Term Tradeoff)**:
   - *Risk*: Dart GC pauses could impact high-frequency packet routing.
   - *Mitigation*: Extract Layer 2 to Rust static library when routing complexity demands zero-GC memory guarantees.
