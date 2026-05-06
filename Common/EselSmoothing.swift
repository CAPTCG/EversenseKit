// EselSmoothing.swift
// Ported from com.nightscout.eversense.util.EselSmoothing (Kotlin)
//
// Exponential smoothing algorithm for CGM glucose readings, matching the
// algorithm used in the ESEL Android companion app. Applied when useSmoothing
// is enabled in EversenseCGMState.
//
// Reference: https://en.wikipedia.org/wiki/Exponential_smoothing
//
// Parameters:
//   factor        (α = 0.3): weight on the new raw value. 0 = constant, 1 = no smoothing.
//   correction    (0.5):     blends the delta between raw and smoothed values back in.
//   descentFactor (0.0):     suppresses descent artefacts; disabled by default.

import Foundation

enum EselSmoothing {
    private static let factor: Double = 0.3
    private static let correction: Double = 0.5
    private static let descentFactor: Double = 0.0

    /// Returns a smoothed glucose value in mg/dL.
    /// - Parameters:
    ///   - currentRaw:  The latest raw glucose reading from the transmitter.
    ///   - lastSmooth:  The previous smoothed value (stored in state).
    ///   - lastRaw:     The previous raw value (stored in state).
    static func smooth(currentRaw: Int, lastSmooth: Int, lastRaw: Int) -> Int {
        let value = Double(currentRaw)

        // Exponential smoothing: y'[t] = y'[t-1] + α*(y - y'[t-1])
        var smooth = Double(lastSmooth) + (factor * (value - Double(lastSmooth)))

        // Correction: blends average delta between raw and smoothed values
        smooth += correction * ((Double(lastRaw) - Double(lastSmooth)) + (value - smooth)) / 2.0

        // Descent factor: suppresses artefacts on rapid descent (disabled, descentFactor=0)
        smooth -= descentFactor * (smooth - min(value, smooth))

        return Int(smooth.rounded())
    }
}
