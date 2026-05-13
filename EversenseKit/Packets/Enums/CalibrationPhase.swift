public enum CalibrationPhase: UInt8 {
    case WARM_UP = 1
    case INITIALIZATION = 2
    case DAILY_CALIBRATION = 3
    case SUSPICIOUS = 4
    case UNKNOWN = 5
    case DEBUG = 6
    case DROPOUT = 7

    func getTitle(calibrationMode: CalibrationMode) -> String {
        switch self {
        case .WARM_UP:
            return LocalizedString("Warming up", comment: "phase warming up")
        case .DAILY_CALIBRATION:
            switch calibrationMode {
            case .DailySingle:
                return LocalizedString("Daily single calibration", comment: "phase daily calibration")
            case .DailyDual:
                return LocalizedString("Daily dual calibration", comment: "phase daily calibration")
            case .WeeklySingle:
                return LocalizedString("Weekly calibration", comment: "phase weekly calibration")
            case .Default:
                return LocalizedString("Daily calibration", comment: "phase daily calibration")
            }
        case .INITIALIZATION:
            return LocalizedString("Initialization", comment: "phase init")
        case .SUSPICIOUS:
            return LocalizedString("Suspicious fingerstick", comment: "phase suspicious")
        case .DROPOUT:
            return LocalizedString("Dropout", comment: "phase dropout")
        case .DEBUG:
            return LocalizedString("Debug/test", comment: "phase debug")
        default:
            return LocalizedString("Unknown", comment: "phase unknown")
        }
    }

    static func from365(rawValue: UInt8) -> CalibrationPhase {
        switch rawValue {
        case 0: return .UNKNOWN
        case 1: return .WARM_UP
        case 2,
             3: return .DAILY_CALIBRATION
        case 4: return .SUSPICIOUS
        case 5: return .DROPOUT
        case 6: return .DEBUG
        default: return .UNKNOWN
        }
    }
}
