# EversenseKit

A native iOS/macOS Swift framework that provides direct Bluetooth Low Energy (BLE) communication with Senseonics **Eversense E3** and **Eversense 365** CGM transmitters — no companion app required.

EversenseKit is designed as a [LoopKit](https://github.com/LoopKit/LoopKit) `CGMManager` plugin, making it compatible with open-source APS apps such as [Loop](https://github.com/LoopKit/Loop) and [Trio](https://github.com/nightscoutfoundation/trio).

> **Community project.** Join us on [Loop Zulipchat](https://loop.zulipchat.com/) or the [Trio Discord](https://discord.gg/FnwFEFUwXE).  
> Support the Nightscout Foundation: [nightscoutfoundation.org/donate](https://www.nightscoutfoundation.org/donate)

---

## Supported Hardware

| Transmitter | Security Protocol | Cloud Auth Required |
|---|---|---|
| Eversense E3 (90-day) | Plain BLE | No |
| Eversense E3 (180-day) | Plain BLE | No |
| Eversense 365 | SecureV2 (ECDH + AES-CCM) | Yes — Eversense account |

---

## Features

- **Direct BLE** — communicates with the transmitter without the official Eversense app running
- **Real-time glucose** — receives keep-alive push notifications every ~5 minutes with current glucose + trend arrow
- **Backfill** — reads glucose log history to fill gaps after reconnection
- **Full sync** — reads sensor metadata: insertion date, calibration status, firmware version, signal strength, battery level, active alarms, all alarm thresholds
- **Calibration** — sends fingerstick blood glucose values to the transmitter
- **Settings write** — vibrate mode, high/low alarms, rate alarms, predictive alarms, repeat intervals
- **Placement guide** — diagnostic mode for signal-strength feedback during transmitter placement
- **DMS cloud upload** — optional glucose upload to the Eversense portal (365 only, requires account)
- **Automatic reconnection** — exponential backoff with placement-failure detection (status-19 handling)
- **LoopKit integration** — implements `CGMManager`, `GlucoseDisplayable`, and `RawRepresentable` state

---

## Architecture

```
EversenseKit (framework)
├── EversenseCGMManager          # LoopKit CGMManager — public API, state, delegates
├── BluetoothManager             # CBCentralManager wrapper — scan, connect, reconnect
├── PeripheralManager            # CBPeripheralDelegate — GATT, MTU, notifications, packet I/O
│
├── Packets/
│   ├── BasePacket               # Request build (CRC16 / chunk encoding) + response reassembly
│   ├── TransmitterE3            # E3 communicator: readGlucose, fullSync, writeSettings
│   ├── Transmitter365           # 365 communicator: readGlucose, fullSync, writeSettings
│   ├── EversenseE3/             # ~60 individual E3 command/response packet classes
│   └── Eversense365/            # ~40 individual 365 command/response packet classes
│
├── Encryption/
│   ├── CryptoUtil               # P256 ECDH + HKDF-SHA256 session key + AES-CCM encrypt/decrypt
│   ├── CommandOperations        # SecureV2 auth flow (WhoAmI → Identity → Start)
│   ├── EncodingOperations       # Chunk encoding/decoding for multi-frame 365 packets
│   ├── MessageCoder             # Alarm flag and status byte decoders
│   ├── BinaryOperations         # Binary date/time encoding for DMS upload payloads
│   └── API/
│       ├── AuthenticationApi    # DMS OAuth token (login, refresh)
│       └── KeyVaultApi          # Fleet secret / transmitter certificate endpoint
│
├── Models/
│   ├── EversenseCGMState        # Full serializable state (RawRepresentable for LoopKit)
│   ├── ActiveAlarms             # Current alarm list
│   ├── TransmitterSettings      # All user-configurable alarm thresholds
│   ├── ScanItem                 # BLE scan result
│   └── ConnectFailure           # Typed connection error
│
└── Common/                      # Shared extensions (Data, Date, TimeInterval, OSLog…)

EversenseKitUI (framework)
├── EversenseCGMManager+UI       # LoopKit UI plugin conformance
├── EversenseUIController        # SwiftUI root view controller
└── Views + ViewModels/
    ├── Onboarding/              # Scan, pair, 365 account login
    └── Settings/                # Calibration, placement guide, alert history,
                                 #   calibration history, transmitter settings

EversenseKitPlugin              # LoopKit plugin entry point
EversenseKitTests               # Unit tests (crypto, packet parsing)
```

---

## BLE Protocol

### GATT Service & Characteristics

| UUID | Role |
|---|---|
| `c3230001-9308-47ae-ac12-3d030892a211` | Primary service |
| `6eb0f021-a7ba-7e7d-66c9-6d813f01d273` | E3 request (write) |
| `6eb0f024-bd60-7aaa-25a7-0029573f4f23` | E3 response (notify) |
| `c3230002-9308-47ae-ac12-3d030892a211` | 365 request (write, SecureV2) |
| `c3230003-9308-47ae-ac12-3d030892a211` | 365 response (notify, SecureV2) |

### E3 Packet Format

```
Request:  [requestId: 1B] [payload: NB] [crc16: 2B]
Response: [responseId: 1B] [data: NB]
          (flash-register reads start data at index 4)
```

### Eversense 365 SecureV2 Frame Format

**Request (chunked):**
```
Chunk 1:  [index: 1B] [total: 1B] [0x01: 1B] [data]
Chunk N:  [index: 1B] [total: 1B] [data]
Payload = AES-CCM-encrypt([requestId: 1B] [typeId: 1B] [data])
```

**Response:**
```
[3-byte prefix stripped] [responseId: 1B] [typeId: 1B] [AES-CCM-encrypted data]
Auth packets not decrypted; all others decrypted before parsing.
```

### SecureV2 Authentication Flow

```
1. GenerateKeyPairIfNotExists   — P256 long-term keypair + random clientId (persisted)
2. WhoAmI →                     — send clientId, receive serialNumber + nonce + flags
3. AuthenticationApi.login()    — DMS OAuth → access_token
4. KeyVaultApi.getFleetSecret() — transmitter certificate (server-signed, hex-encoded)
5. AuthIdentity →               — send certificate bytes
6. GenerateEphem()              — ephemeral P256 keypair, ECDSA-sign with long-term key
7. AuthStart →                  — send ephemeral pubkey + salt + signature
8. AuthStart ←                  — receive transmitter ephemeral public key
9. ECDH + HKDF-SHA256 →         — derive 16-byte AES-128 session key
10. All subsequent packets encrypted with AES-128-CCM (8-byte tag, 8-byte nonce)
```

**Shortcut path:** if `canUseShortcut = true` from a prior session, steps 2–5 are skipped on reconnect, going straight to step 6.

---

## Glucose Data Flow

```
Transmitter ──keep-alive notify──► PeripheralManager.onCharacteristicChanged()
                                          │
                              E3: isPushPacket?   365: isKeepAlivePacket?
                                          │
                              TransmitterE3/365.readGlucose()
                                          │
                              GetCurrentGlucosePacket / GetGlucoseDataPacket
                                          │
                              EselSmoothing (optional, configurable)
                                          │
                              GetGlucoseLogValuesPacket  ← backfill gap readings
                                          │
                              cgmManagerDelegate.cgmManager(_:hasNew:)
                                          │
                                     LoopKit / APS app
```

---

## Requirements

| | Minimum |
|---|---|
| iOS | 16.0 |
| macOS | 13.0 |
| Swift | 5.9 |
| Xcode | 15.0 |
| LoopKit | current `dev` branch |

### Dependencies

- **[LoopKit](https://github.com/LoopKit/LoopKit)** — `CGMManager` protocol and delegate infrastructure
- **[CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift)** — AES-CCM authenticated encryption for 365 SecureV2
- **CryptoKit** *(system)* — P256 ECDH, HKDF-SHA256, ECDSA signing

---

## Integration

EversenseKit is designed to be embedded in a LoopKit-compatible APS app as a CGM plugin.

### 1. Add as a dependency

```swift
// In your app's Package.swift:
.package(url: "https://github.com/bastiaanv/EversenseKit.git", branch: "dev")
```

Or add via **Xcode → File → Add Package Dependencies**.

### 2. Register the plugin

Add `EversenseKitPlugin` to your app's LoopKit plugin list so the framework is discoverable at runtime.

### 3. Eversense 365 credentials

Users with a 365 transmitter enter their Eversense DMS account credentials during onboarding. The `EversenseKitUI` framework provides the login flow. Credentials are used to fetch the transmitter's fleet certificate on every new BLE session — they are not used for any other purpose.

---

## Development

```bash
git clone https://github.com/bastiaanv/EversenseKit.git
cd EversenseKit
git checkout dev
open EversenseKit.xcodeproj
```

### Running Tests

```bash
xcodebuild test \
  -project EversenseKit.xcodeproj \
  -scheme EversenseKitTests \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

Tests cover AES-CCM encrypt/decrypt round-trips and E3/365 packet byte encoding.

---

## Porting Notes

EversenseKit was ported from the [CAPTCG/AndroidAPS-Eversense](https://github.com/CAPTCG/AndroidAPS-Eversense-) Kotlin/Android patch set.

| Android | iOS |
|---|---|
| `@EversensePacket` annotation | `var metadata: PacketMetadata` property |
| `BluetoothGattCallback` | `CBCentralManager` + `CBPeripheralDelegate` |
| `SharedPreferences` | `EversenseCGMState` (RawRepresentable, LoopKit-managed) |
| `Executors.newSingleThreadExecutor()` | `DispatchQueue` + `DispatchSemaphore` |
| `BouncyCastle CCMBlockCipher` | CryptoSwift AES-CCM |
| `BouncyCastle HKDFBytesGenerator` | CryptoKit HKDF-SHA256 |
| Android `ScanCallback` | `CBCentralManagerDelegate` |

---

## Known Limitations

- **E3 180-day variant** — inferred from MMA features byte; needs validation with 180-day hardware
- **DMS glucose upload** — binary payload implemented; end-to-end upload needs live device testing
- **Alert/calibration history UI** — packets implemented, not yet exposed in settings views
- **E3 repeat-interval settings** — day/night repeat packets exist but not wired to settings write
- **watchOS** — architecture is compatible but no watch target exists

---

## Contributing

Bug reports and PRs are welcome — please open an issue first for significant changes.

Bug reports should include transmitter model, iOS version, and a log export from the app's debug menu.

---

## License

Open source. See [LICENSE](LICENSE) for details.

---

## Eversense CGM: Getting Started

### Sensor Insertion (Done by Your Doctor)
1. Visit your trained healthcare provider for the procedure. Only physicians who have completed the Eversense CGM Insertion and Removal Training Program may perform the insertion.
2. The tiny sensor is placed just under the skin of your upper arm via a small incision, closed with Steri-Strips — usually no stitches required.

### Incision Care (First Few Days)
3. Avoid strenuous activities that may pull at the incision or cause heavy sweating while it heals. Remove the Steri-Strips within a few days.

### Warm-Up Phase
4. After insertion, the official Eversense app will show "Warm Up Phase." The sensor must complete this period before calibration is accepted. Do not attempt to calibrate during this phase.
5. Once the warm-up is complete, proceed to set up the AAPS plugin.

### Transmitter & AAPS Setup
6. Open the official Eversense app, go to Connections, tap your transmitter, and select Disconnect.
7. In AAPS, go to Config Builder and select Eversense as your BG source.
8. Open the Eversense plugin settings and enter your Eversense DMS account credentials (username and password). Both the E3 and E365 require credentials to authenticate with the Eversense cloud and retrieve your transmitter's security certificate at every new connection.
9. Tap Scan to find your transmitter and pair it via Bluetooth.

---

## Eversense Plugin Settings — Functions Explained

### Credentials
Enter your Eversense DMS account username and password. Both the E3 and E365 require credentials to authenticate with the Eversense cloud and retrieve your transmitter's security certificate at every new connection.

### Calibration
Displays your current calibration phase, the date of your last calibration, and when your next calibration is due. When the transmitter is ready, the Calibrate button becomes active — tap it, enter your fingerstick reading, and the value is sent directly to the transmitter over Bluetooth. Calibration is not accepted during the warm-up or initialization phase.

### Transmitter Placement Signal
Shows real-time signal strength between the transmitter and the sensor. Signal levels are:
- Excellent (>=75)
- Good (48-74)
- Low (30-47)
- Poor (25-29)
- Very Poor (1-24)

If the signal is poor for 3 or more consecutive readings, you will receive an urgent notification. Tap it to open the placement guide.

### Notifications & Alerts
The plugin provides the following system notifications:
- Transmitter not placed — urgent alert with a link to the placement guide.
- Firmware version — shown once per firmware version, prompting you to check for updates in the official Eversense app.
- Transmitter alarms — high/low glucose and other transmitter alerts are relayed as AAPS notifications.

### DMS Portal Sync
After every glucose reading, the plugin automatically uploads your data to the Eversense DMS web portal so your care team can view it in real time. Each sync uploads your latest glucose value, trend, signal strength, and battery level; your glucose history; and device diagnostic logs.

---

## Daily Use

10. Apply a fresh adhesive patch each morning and wear the transmitter over the sensor site on your upper arm.
11. Charge the transmitter daily — no glucose data is collected while it is charging.
12. Check AAPS for your glucose reading, trend arrows, and alerts.
13. Monitor placement signal in the plugin settings if readings seem inconsistent.
14. Calibrate when due — tap the Calibrate button and enter your fingerstick reading. Always do a fingerstick check if symptoms do not match your CGM reading.
15. If you need to switch back to the official Eversense app temporarily (e.g. to update firmware), go to AAPS Settings -> CGM and delete the CGM source, then reconnect in the official app.

---

> Note: This plugin is experimental. Always verify glucose readings independently before making treatment decisions.