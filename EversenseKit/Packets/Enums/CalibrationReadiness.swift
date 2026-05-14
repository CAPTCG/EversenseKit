public enum CalibrationReadiness: UInt8 {
    case Ready = 0
    case NotEnoughData = 1
    case GlucoseRateTooHigh = 2
    case TooSoon = 3
    case DropoutPhase = 4
    case SensorEol = 5
    case NoSensorLinked = 6
    case UnsupportedMode = 7
    case WaitingPostCalibration = 8
    case LedDisconnectDetected = 9
    case TransmitterEol = 10
    case Unknown = 255

    var description: String {
        switch self {
        case .Ready:
            return LocalizedString("Ready for calibration", comment: "title for Ready")
        case .NotEnoughData:
            return LocalizedString("Not enough data", comment: "title for NotEnoughData")
        case .GlucoseRateTooHigh:
            return LocalizedString("Glucose rate of change too high", comment: "title for GlucoseRateTooHigh")
        case .TooSoon:
            return LocalizedString("Too soon", comment: "title for TooSoon")
        case .DropoutPhase:
            return LocalizedString("Dropout phase", comment: "title for DropoutPhase")
        case .SensorEol:
            return LocalizedString("Sensor is expired", comment: "title for SensorEol")
        case .NoSensorLinked:
            return LocalizedString("No sensor linked", comment: "title for NoSensorLinked")
        case .UnsupportedMode:
            return LocalizedString("Unsupported", comment: "title for UnsupportedMode")
        case .WaitingPostCalibration:
            return LocalizedString("Waiting after calibration", comment: "title for WaitingPostCalibration")
        case .LedDisconnectDetected:
            return LocalizedString("Disconnect detected", comment: "title for LedDisconnectDetected")
        case .TransmitterEol:
            return LocalizedString("Transmitter is expired", comment: "title for TransmitterEol")
        case .Unknown:
            return LocalizedString("Unknown", comment: "title for Unknown")
        }
    }
}
