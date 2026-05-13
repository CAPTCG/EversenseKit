// DMSUploadApi.swift
// Ported from:
//   com.nightscout.eversense.util.EversenseHttp365Util  (E365 — US endpoints)
//   com.nightscout.eversense.util.EversenseHttpE3Util   (E3   — EU/OUS endpoints)
//
// Handles all DMS cloud uploads after a glucose reading:
//   • getOrRefreshToken()        — cached token with 5-minute pre-expiry refresh
//   • uploadGlucoseReadings()    — POST /api/v1.0/DiagnosticLog/PostEssentialLogs
//                                  (E365 only — raw BLE data not available from E3)
//   • putCurrentValues()         — POST /api/care/PutCurrentValues  (both E3 and E365)
//   • putDeviceEvents()          — POST /api/care/PutDeviceEvents   (both E3 and E365)
//
// E3  transmitters use EU/OUS DMS servers (ousiamapialpha / ousalphaapiservices)
// E365 transmitters use US DMS servers    (usiamapi / usmobileappmsprod / usapialpha)
//
// All functions are synchronous (URLSession + semaphore) so they can be called
// from the BLE background queue without async/await plumbing.

import Foundation
import LoopKit

enum DMSUploadApi {

    // MARK: - Endpoints (US — Eversense 365)

    static var uploadBaseUrlUS = "https://usmobileappmsprod.eversensedms.com/"
    static var careBaseUrlUS   = "https://usapialpha.eversensedms.com/"

    // MARK: - Endpoints (EU/OUS — Eversense E3)
    // Confirmed from decompiled Eversense EU app v7.1.1 (SAP build)

    static var careBaseUrlEU   = "https://ousalphaapiservices.eversensedms.com/"

    private static let logger = EversenseLogger(category: "DMSUploadApi")

    // MARK: - Token Management

    /// Returns a valid access token, re-logging in if the cached one is within 5 minutes of expiry.
    /// Routes to EU or US login endpoint based on transmitter type.
    /// Mirrors Kotlin EversenseHttpE3Util / EversenseHttp365Util .getOrRefreshToken().
    static func getOrRefreshToken(state: EversenseCGMState) -> String? {
        let nowMs = Date().timeIntervalSince1970 * 1000

        if let token = state.accessToken,
           let expiry = state.accessTokenExpiration,
           nowMs < (expiry.timeIntervalSince1970 * 1000) - 300_000
        {
            return token
        }

        guard let username = state.username, let password = state.password,
              !username.isEmpty, !password.isEmpty else {
            logger.error("Cannot refresh token — no credentials stored")
            return nil
        }

        guard let fresh = AuthenticationApi.loginSync(
            username: username,
            password: password,
            isE3: !state.is365
        ) else {
            logger.error("Token refresh failed — login returned nil")
            return nil
        }

        return fresh.accessToken
    }

    // MARK: - uploadGlucoseReadings (E365 only)

    /// Upload glucose readings to the Eversense DMS portal (essential logs endpoint).
    /// E3 does NOT call this — raw BLE data is not available from the E3 transmitter.
    /// Mirrors Kotlin EversenseHttp365Util.uploadGlucoseReadings().
    @discardableResult
    static func uploadGlucoseReadings(
        state: EversenseCGMState,
        readings: [GlucoseReading],
        onTokenRefreshed: ((String, Date) -> Void)? = nil
    ) -> Bool {
        guard !readings.isEmpty else { return true }
        guard state.is365 else {
            logger.info("uploadGlucoseReadings: skipped for E3 (no raw BLE data available)")
            return true
        }

        guard let token = getOrRefreshToken(state: state) else {
            logger.error("Cannot upload glucose — no valid access token")
            return false
        }

        let uploadable = readings.filter { !$0.rawBLEHex.isEmpty }
        guard !uploadable.isEmpty else {
            logger.info("No readings with raw BLE data — skipping upload")
            return true
        }

        logger.info("Uploading \(uploadable.count) reading(s) — tx='\(state.bleNameString ?? "")'")

        let formatter = iso8601Formatter()
        let txId = state.bleNameString ?? ""
        let fw   = state.version ?? ""

        let records = uploadable.map { r -> String in
            let portalSensorId = portalSensorIdFrom(r.sensorIdHex)
            let rawBytes = Data(hexString: r.rawBLEHex) ?? Data()
            let essentialLog = rawBytes.base64EncodedString()
            let ts = formatter.string(from: r.datetime)
            logger.info("  sensorId='\(portalSensorId)' glucose=\(r.glucoseInMgDl) ts=\(ts)")
            return """
            {"SensorId":"\(portalSensorId)","TransmitterId":"\(txId)","Timestamp":"\(ts)","CurrentGlucoseValue":\(r.glucoseInMgDl),"CurrentGlucoseDateTime":"\(ts)","FWVersion":"\(fw)","EssentialLog":"\(essentialLog)"}
            """
        }
        let body = "[" + records.joined(separator: ",") + "]"

        guard let url = URL(string: "\(uploadBaseUrlUS)api/v1.0/DiagnosticLog/PostEssentialLogs") else { return false }
        return performSyncPost(url: url, token: token, jsonBody: body, label: "uploadGlucoseReadings")
    }

    // MARK: - putCurrentValues

    /// Post current glucose state to the DMS portal, updating "Last Sync Date".
    /// Routes to EU endpoint for E3, US endpoint for E365.
    /// Mirrors Kotlin EversenseHttpE3Util / EversenseHttp365Util .putCurrentValues().
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

        let careBase = state.is365 ? careBaseUrlUS : careBaseUrlEU
        guard let url = URL(string: "\(careBase)api/care/PutCurrentValues") else { return false }
        return performSyncPost(url: url, token: token, jsonBody: body, label: "putCurrentValues (\(state.is365 ? "US" : "EU"))")
    }

    // MARK: - putDeviceEvents

    /// Post device events (sensor glucose binary blobs) to the DMS portal.
    /// Routes to EU endpoint for E3, US endpoint for E365.
    /// Mirrors Kotlin EversenseHttpE3Util / EversenseHttp365Util .putDeviceEvents().
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

        let txId     = state.bleNameString ?? ""
        let sensorId = readings.first(where: { !$0.sensorIdHex.isEmpty })?.sensorIdHex ?? ""
        let tzOffsetSec = TimeZone.current.secondsFromGMT()
        let offsetBytes = int32LE(tzOffsetSec).base64EncodedString()
        let sgBytes      = buildSgBytes(readings)
        let mgBytes      = buildEmptyMgBytes()
        let patientBytes = buildEmptyPatientBytes()
        let alertBytes   = buildAlertBytes(sensorIdHex: sensorId)

        logger.info("PutDeviceEvents (\(state.is365 ? "US" : "EU")): \(readings.count) reading(s), tx='\(txId)'")

        let body = """
        {"deviceType":"SMSIMeter","deviceName":"Smart Transmitter (Android)","deviceID":"\(txId)","offsetBytes":"\(offsetBytes)","sgBytes":"\(sgBytes)","mgBytes":"\(mgBytes)","patientBytes":"\(patientBytes)","alertBytes":"\(alertBytes)","algorithmVersion":"10"}
        """

        let careBase = state.is365 ? careBaseUrlUS : careBaseUrlEU
        guard let url = URL(string: "\(careBase)api/care/PutDeviceEvents") else { return false }
        return performSyncPost(url: url, token: token, jsonBody: body, label: "putDeviceEvents (\(state.is365 ? "US" : "EU"))")
    }

    // MARK: - Binary Blob Builders

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
            data.append(int24LE(idx + 1))
            data.append(calcDateBytes(r.datetime))
            data.append(calcTimeBytes(r.datetime))
            data.append(int16LE(r.glucoseInMgDl))
            data.append(0x00)
            data.append(sensorIdBytes)
            for _ in 0..<5 { data.append(int16LE(0)) }
            data.append(int16LE(0))
            data.append(0x00)
            for _ in 0..<3 { data.append(int16LE(0)) }
        }
        return data.base64EncodedString()
    }

    static func buildEmptyMgBytes() -> String {
        Data([0x98, 0x01, 0x00, 0x00, 0x00, 0x00]).base64EncodedString()
    }

    static func buildEmptyPatientBytes() -> String {
        Data([0x9E, 0x01, 0x00, 0x00, 0x00]).base64EncodedString()
    }

    static func buildAlertBytes(sensorIdHex: String) -> String {
        var data = Data([0x93, 0x01, 0x00, 0x00, 0x00])
        if !sensorIdHex.isEmpty, let sensorBytes = Data(hexString: sensorIdHex) {
            data.append(sensorBytes)
        }
        data.append(0x00)
        return data.base64EncodedString()
    }

    // MARK: - Ordinal Mappers

    static func signalStrengthOrdinal(_ percent: Int) -> Int {
        switch percent {
        case 75...:    return 5
        case 48..<75:  return 4
        case 30..<48:  return 3
        case 28..<30:  return 2
        case 25..<28:  return 1
        default:       return 0
        }
    }

    static func trendOrdinal(_ trend: GlucoseTrend?) -> Int {
        switch trend {
        case .none, nil:   return 0
        case .downDown:    return 1
        case .down:        return 2
        case .flat:        return 3
        case .up:          return 4
        case .upUp:        return 5
        @unknown default:  return 3
        }
    }

    // MARK: - Binary Encoding Helpers

    static func int16LE(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    static func int24LE(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF)])
    }

    static func int32LE(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

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

    static func portalSensorIdFrom(_ hex: String) -> String {
        let bytes = stride(from: 0, to: hex.count, by: 2).compactMap { i -> String? in
            let s = hex.index(hex.startIndex, offsetBy: i)
            let e = hex.index(s, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            return String(hex[s..<e])
        }
        return bytes.prefix(8).reversed().joined().uppercased()
    }
}

// MARK: - GlucoseReading

struct GlucoseReading {
    let glucoseInMgDl: Int
    let datetime: Date
    let trend: GlucoseTrend?
    let sensorIdHex: String
    let rawBLEHex: String
}
