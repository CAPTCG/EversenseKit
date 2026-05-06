// DMSUploadApi.swift
// Ported from com.nightscout.eversense.util.EversenseHttp365Util (Kotlin/Android)
//
// Handles all DMS cloud uploads after a glucose reading:
//   • getOrRefreshToken()        — cached token with 5-minute pre-expiry refresh
//   • uploadGlucoseReadings()    — POST /api/v1.0/DiagnosticLog/PostEssentialLogs
//   • putCurrentValues()         — POST /api/care/PutCurrentValues
//   • putDeviceEvents()          — POST /api/care/PutDeviceEvents (binary sg/mg/patient/alert blobs)
//
// All functions are synchronous (URLSession + semaphore) so they can be called
// from the BLE background queue without async/await plumbing.

import Foundation
import LoopKit

enum DMSUploadApi {

    // MARK: - Endpoints

    static var uploadBaseUrl = "https://usmobileappmsprod.eversensedms.com/"
    static var careBaseUrl   = "https://usapialpha.eversensedms.com/"

    private static let logger = EversenseLogger(category: "DMSUploadApi")

    // MARK: - Token Management

    /// Returns a valid access token, re-logging in if the cached one is within 5 minutes of expiry.
    /// Mirrors Kotlin EversenseHttp365Util.getOrRefreshToken().
    static func getOrRefreshToken(state: EversenseCGMState) -> String? {
        let nowMs = Date().timeIntervalSince1970 * 1000

        // Use cached token if more than 5 minutes remain
        if let token = state.accessToken,
           let expiry = state.accessTokenExpiration,
           nowMs < (expiry.timeIntervalSince1970 * 1000) - 300_000
        {
            return token
        }

        // Re-login
        guard let username = state.username, let password = state.password,
              !username.isEmpty, !password.isEmpty else {
            logger.error("Cannot refresh token — no credentials stored")
            return nil
        }

        guard let fresh = AuthenticationApi.loginSync(username: username, password: password) else {
            logger.error("Token refresh failed — login returned nil")
            return nil
        }

        return fresh.accessToken
    }

    // MARK: - uploadGlucoseReadings

    /// Upload glucose readings to the Eversense DMS portal (essential logs endpoint).
    /// Only readings with non-empty rawBLEData are uploaded.
    /// Mirrors Kotlin EversenseHttp365Util.uploadGlucoseReadings().
    @discardableResult
    static func uploadGlucoseReadings(
        state: EversenseCGMState,
        readings: [GlucoseReading],
        onTokenRefreshed: ((String, Date) -> Void)? = nil
    ) -> Bool {
        guard !readings.isEmpty else { return true }

        guard let token = getOrRefreshToken(state: state) else {
            logger.error("Cannot upload glucose — no valid access token")
            return false
        }

        // Only upload readings that carry raw BLE data
        let uploadable = readings.filter { !$0.rawBLEHex.isEmpty }
        guard !uploadable.isEmpty else {
            logger.info("No readings with raw BLE data — skipping upload")
            return true
        }

        logger.info("Uploading \(uploadable.count) reading(s) — tx='\(state.transmitterSerialNumber ?? "")'")

        let formatter = iso8601Formatter()
        let txId = state.transmitterSerialNumber ?? ""
        let fw   = state.version ?? ""

        let records = uploadable.map { r -> String in
            // portalSensorId: first 8 bytes of raw sensor ID, reversed, uppercase
            let portalSensorId = portalSensorIdFrom(r.sensorIdHex)
            // EssentialLog: base64-encoded raw BLE bytes (not hex string)
            let rawBytes = Data(hexString: r.rawBLEHex) ?? Data()
            let essentialLog = rawBytes.base64EncodedString()
            let ts = formatter.string(from: r.datetime)
            logger.info("  sensorId='\(portalSensorId)' glucose=\(r.glucoseInMgDl) ts=\(ts)")
            return """
            {"SensorId":"\(portalSensorId)","TransmitterId":"\(txId)","Timestamp":"\(ts)","CurrentGlucoseValue":\(r.glucoseInMgDl),"CurrentGlucoseDateTime":"\(ts)","FWVersion":"\(fw)","EssentialLog":"\(essentialLog)"}
            """
        }
        let body = "[" + records.joined(separator: ",") + "]"

        guard let url = URL(string: "\(uploadBaseUrl)api/v1.0/DiagnosticLog/PostEssentialLogs") else { return false }
        return performSyncPost(url: url, token: token, jsonBody: body, label: "uploadGlucoseReadings")
    }

    // MARK: - putCurrentValues

    /// Post current glucose state to the DMS portal, updating "Last Sync Date".
    /// Mirrors Kotlin EversenseHttp365Util.putCurrentValues().
    @discardableResult
    static func putCurrentValues(
        state: EversenseCGMState,
        glucose: Int,
        timestamp: Date,
        trend: GlucoseTrend?,
        signalStrengthPercent: Int,
        batteryPercent: Int
    ) -> Bool {
        guard let token = getOrRefreshToken(state: state) else {
            logger.error("Cannot post current values — no valid access token")
            return false
        }

        let ts = iso8601Formatter().string(from: timestamp)
        let body = """
        {"CurrentGlucose":\(glucose),"CGTime":"\(ts)","GlucoseTrend":\(trendOrdinal(trend)),"SignalStrength":\(signalStrengthOrdinal(signalStrengthPercent)),"BatteryStrength":\(max(batteryPercent, 0)),"IsTransmitterConnected":1}
        """

        guard let url = URL(string: "\(careBaseUrl)api/care/PutCurrentValues") else { return false }
        return performSyncPost(url: url, token: token, jsonBody: body, label: "putCurrentValues")
    }

    // MARK: - putDeviceEvents

    /// Post device events (sensor glucose binary blobs) to the DMS portal.
    /// Populates the Sensor Glucose history table in the portal.
    /// Mirrors Kotlin EversenseHttp365Util.putDeviceEvents().
    @discardableResult
    static func putDeviceEvents(
        state: EversenseCGMState,
        readings: [GlucoseReading]
    ) -> Bool {
        guard !readings.isEmpty else { return true }

        guard let token = getOrRefreshToken(state: state) else {
            logger.error("Cannot post device events — no valid access token")
            return false
        }

        let txId     = state.transmitterSerialNumber ?? ""
        let sensorId = readings.first(where: { !$0.sensorIdHex.isEmpty })?.sensorIdHex ?? ""
        let tzOffsetSec = TimeZone.current.secondsFromGMT()
        let offsetBytes = int32LE(tzOffsetSec).base64EncodedString()
        let sgBytes      = buildSgBytes(readings)
        let mgBytes      = buildEmptyMgBytes()
        let patientBytes = buildEmptyPatientBytes()
        let alertBytes   = buildAlertBytes(sensorIdHex: sensorId)

        logger.info("PutDeviceEvents: \(readings.count) reading(s), tx='\(txId)'")

        let body = """
        {"deviceType":"SMSIMeter","deviceName":"Smart Transmitter (Android)","deviceID":"\(txId)","offsetBytes":"\(offsetBytes)","sgBytes":"\(sgBytes)","mgBytes":"\(mgBytes)","patientBytes":"\(patientBytes)","alertBytes":"\(alertBytes)","algorithmVersion":"10"}
        """

        guard let url = URL(string: "\(careBaseUrl)api/care/PutDeviceEvents") else { return false }
        return performSyncPost(url: url, token: token, jsonBody: body, label: "putDeviceEvents")
    }

    // MARK: - Binary Blob Builders

    /// Build the sgBytes base64 blob.
    /// Header: 8C 00 01 00 00 + 3-byte LE count. One record per reading.
    /// Mirrors Kotlin buildSgBytes().
    static func buildSgBytes(_ readings: [GlucoseReading]) -> String {
        var data = Data()
        data.append(contentsOf: [0x8C, 0x00, 0x01, 0x00, 0x00])
        data.append(int24LE(readings.count))

        for (idx, r) in readings.enumerated() {
            let sensorIdBytes: Data
            if !r.sensorIdHex.isEmpty, let parsed = Data(hexString: r.sensorIdHex) {
                sensorIdBytes = parsed
            } else {
                sensorIdBytes = Data(repeating: 0, count: 10)
            }
            data.append(int24LE(idx + 1))           // record number (1-based)
            data.append(calcDateBytes(r.datetime))   // 2-byte date
            data.append(calcTimeBytes(r.datetime))   // 2-byte time
            data.append(int16LE(r.glucoseInMgDl))    // 2-byte glucose LE
            data.append(0x00)                         // padding
            data.append(sensorIdBytes)                // sensor ID (10 bytes)
            // RAW_DATA_INDEX 1, 2, 3, 7, 8 — zeroed (no raw ADC available)
            for _ in 0..<5 { data.append(int16LE(0)) }
            // Accel (2 bytes) — zeroed
            data.append(int16LE(0))
            // AccelTemp (1 byte) — zeroed
            data.append(0x00)
            // RAW_DATA_INDEX 4, 5, 6 — zeroed
            for _ in 0..<3 { data.append(int16LE(0)) }
        }
        return data.base64EncodedString()
    }

    /// Build the mgBytes base64 blob (zero BGM/calibration records).
    /// Header: 98 01 00 + count(2 bytes LE) + 00 → 0 records.
    static func buildEmptyMgBytes() -> String {
        Data([0x98, 0x01, 0x00, 0x00, 0x00, 0x00]).base64EncodedString()
    }

    /// Build the patientBytes base64 blob (zero patient event records).
    /// Header: 9E 01 00 + count(2 bytes LE) → 0 events.
    static func buildEmptyPatientBytes() -> String {
        Data([0x9E, 0x01, 0x00, 0x00, 0x00]).base64EncodedString()
    }

    /// Build the alertBytes base64 blob (zero alert records).
    /// Header: 93 01 00 + count(2 bytes LE) + sensorIdBytes + 00.
    static func buildAlertBytes(sensorIdHex: String) -> String {
        var data = Data([0x93, 0x01, 0x00, 0x00, 0x00])
        if !sensorIdHex.isEmpty, let sensorBytes = Data(hexString: sensorIdHex) {
            data.append(sensorBytes)
        }
        data.append(0x00)
        return data.base64EncodedString()
    }

    // MARK: - Ordinal Mappers

    /// Map signal strength percentage to DMS SIGNAL_STRENGTH ordinal.
    /// Mirrors Kotlin signalStrengthOrdinal(): NO_SIGNAL=0, POOR=1, VERY_LOW=2, LOW=3, GOOD=4, EXCELLENT=5
    static func signalStrengthOrdinal(_ percent: Int) -> Int {
        switch percent {
        case 75...:    return 5  // EXCELLENT
        case 48..<75:  return 4  // GOOD
        case 30..<48:  return 3  // LOW
        case 28..<30:  return 2  // VERY_LOW
        case 25..<28:  return 1  // POOR
        default:       return 0  // NO_SIGNAL
        }
    }

    /// Map LoopKit GlucoseTrend to DMS ARROW_TYPE ordinal.
    /// Mirrors Kotlin trendOrdinal(): STALE=0, FALLING_FAST=1, FALLING=2, FLAT=3, RISING=4, RISING_FAST=5
    static func trendOrdinal(_ trend: GlucoseTrend?) -> Int {
        switch trend {
        case .none, nil:          return 0  // STALE / NONE
        case .down:               return 1  // SINGLE_DOWN / FALLING_FAST
        case .downDown:           return 1  // extra down
        case .downSlowly:         return 2  // FORTY_FIVE_DOWN / FALLING
        case .flat:               return 3  // FLAT
        case .upSlowly:           return 4  // FORTY_FIVE_UP / RISING
        case .up:                 return 5  // SINGLE_UP / RISING_FAST
        case .upUp:               return 5  // extra up
        @unknown default:         return 3
        }
    }

    // MARK: - Binary Encoding Helpers (from com.senseonics.bluetoothle.BinaryOperations)

    static func int16LE(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    static func int24LE(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF)])
    }

    static func int32LE(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    /// Eversense 2-byte date encoding (UTC). Mirrors Kotlin calcDateBytes().
    static func calcDateBytes(_ date: Date) -> Data {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let year  = (comps.year ?? 2000) - 2000
        let month = comps.month ?? 1
        let day   = comps.day ?? 1
        var b1 = year << 1
        if month > 7 { b1 += 1 }
        let b0 = ((month & 7) << 5) | day
        return Data([UInt8(b0 & 0xFF), UInt8(b1 & 0xFF)])
    }

    /// Eversense 2-byte time encoding (UTC). Mirrors Kotlin calcTimeBytes().
    static func calcTimeBytes(_ date: Date) -> Data {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.hour, .minute, .second], from: date)
        let hour   = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0
        let b0 = ((minute & 7) << 5) | (second / 2)
        let b1 = (hour << 3) | ((minute & 56) >> 3)
        return Data([UInt8(b0 & 0xFF), UInt8(b1 & 0xFF)])
    }

    // MARK: - Networking

    private static func performSyncPost(url: URL, token: String, jsonBody: String, label: String) -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody.data(using: .utf8)

        var success = false
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sema.signal() }
            if let error = error {
                self.logger.error("\(label) error: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse {
                if http.statusCode >= 400 {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    self.logger.error("\(label) failed — status: \(http.statusCode), body: \(body)")
                } else {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    self.logger.info("\(label) success — status: \(http.statusCode), body: \(body)")
                    success = true
                }
            }
        }.resume()
        sema.wait()
        return success
    }

    // MARK: - Utilities

    private static func iso8601Formatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// portalSensorId: first 8 bytes of raw sensor ID, reversed byte order, uppercase.
    /// Matches what the DMS portal indexes readings by.
    static func portalSensorIdFrom(_ hex: String) -> String {
        let bytes = stride(from: 0, to: hex.count, by: 2).compactMap { i -> String? in
            let s = hex.index(hex.startIndex, offsetBy: i)
            let e = hex.index(s, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            return String(hex[s..<e])
        }
        return bytes.prefix(8).reversed().joined().uppercased()
    }
}

// MARK: - GlucoseReading (bridge type for DMS upload)

/// Lightweight bridge carrying the fields needed for DMS upload.
/// Populated from NewGlucoseSample + state after each glucose read.
struct GlucoseReading {
    let glucoseInMgDl: Int
    let datetime: Date
    let trend: GlucoseTrend?
    let sensorIdHex: String
    let rawBLEHex: String    // raw BLE packet hex — required for PostEssentialLogs
}

// MARK: - Data helpers

private extension Data {
    init?(hexString: String) {
        let hex = hexString.filter { $0.isHexDigit }
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b); idx = next
        }
        self.init(bytes)
    }
}
