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
            return LocalizedString("Please ensure your Transmitter is placed over the sensor, wait a few minutes, and try again.", comment: "title for NotEnoughData")
        case .GlucoseRateTooHigh:
            return LocalizedString("Your Sensor glucose is changing too quickly. Please wait 10 minutes and try again.", comment: "title for GlucoseRateTooHigh")
        case .TooSoon:
            return LocalizedString("It is not time for your scheduled calibration. Please try again when prompted.", comment: "title for TooSoon")
        case .DropoutPhase:
            return LocalizedString("Glucose data is currently unavailable. Please measure your glucose manually using your blood glucose meter.", comment: "title for DropoutPhase")
        case .SensorEol:
            return LocalizedString("Sensor is retired. Please contact your health care provider.", comment: "title for SensorEol")
        case .NoSensorLinked:
            return LocalizedString("Your Transmitter is not linked to a Sensor. Please link a Sensor and try again.", comment: "title for NoSensorLinked")
        case .UnsupportedMode:
            return LocalizedString("Your Transmitter is in a mode which does not support Calibration. Please contact your health care provider for further questions.", comment: "title for UnsupportedMode")
        case .WaitingPostCalibration:
            return LocalizedString("Waiting for post calibration sensor measurements. Please wait a few minutes and try again.", comment: "title for WaitingPostCalibration")
        case .LedDisconnectDetected:
            return LocalizedString("Sensor disconnect detected. Please ensure your Transmitter is placed correctly over the sensor.", comment: "title for LedDisconnectDetected")
        case .TransmitterEol:
            return LocalizedString("Your transmitter needs to be replaced. Contact your distributor to order a new transmitter.", comment: "title for TransmitterEol")
        case .Unknown:
            return LocalizedString("Calibration is not available. Please try again later.", comment: "title for Unknown")
        }
    }
}
