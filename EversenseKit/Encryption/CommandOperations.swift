enum FlashMemory: UInt32 {
    case sensorFieldCurrentRaw = 0x0000_049D
    case batteryPercentage = 0x0000_0406

    case transmitterModelNumber = 0x0000_0006
    case transmitterSoftwareVersion = 0x0000_000A
    case transmitterSoftwareVersionExt = 0x0000_00A2

    case isOneCalPhase = 0x0000_0496
    case calibrationsMadeInThisPhase = 0x0000_08A1
    case currentCalibrationPhase = 0x0000_089C
    case calibrationReadiness = 0x0000_0137
    case minCalibrationThreshold = 0x0000_0912
    case maxCalibrationThreshold = 0x0000_0914

    case vibrateMode = 0x0000_0902
    case lowGlucoseTarget = 0x0000_1102
    case highGlucoseTarget = 0x0000_1104
    case highGlucoseAlarmEnabled = 0x0000_1029
    case highGlucoseAlarmThreshold = 0x0000_110C
    case lowGlucoseAlarmThreshold = 0x0000_110A
    case predictiveAlert = 0x0000_1020
    case predictiveFallingTime = 0x0000_1021
    case predictiveRisingTime = 0x0000_1022
    case predictiveLowAlert = 0x0000_1027
    case predictiveHighAlert = 0x0000_1028
    case rateAlert = 0x0000_1010
    case rateFallingAlert = 0x0000_1025
    case rateRisingAlert = 0x0000_1026
    case rateFallingThreshold = 0x0000_1011
    case rateRisingThreshold = 0x0000_1012
    case bleDisconnect = 0x0000_08B2
    case lowGlucoseAlarmRepeatIntervalDay = 0x0000_1032
    case highGlucoseAlarmRepeatIntervalDay = 0x0000_1033
    case lowGlucoseAlarmRepeatIntervalNight = 0x0000_110E
    case highGlucoseAlarmRepeatIntervalNight = 0x0000_110F

    case warmUpDuration = 0x0000_0016
    case clinicalMode = 0x0000_0B49
    case clinicalModeDuration = 0x0000_0098
    case appVersion = 0x0000_0B4B
    case sensorGlucoseSamplingInterval = 0x0000_0012
    case atccalCrcAddress = 0x0000_048C

    case algorithmParameterFormatVersion = 0x0000_0480
    case communicationProtocolVersion = 0x0000_000E

    case mostRecentCalibrationDate = 0x0000_08A3
    case mostRecentCalibrationTime = 0x0000_08A5
    case nextCalibrationDate = 0x0000_0470
    case nextCalibrationTime = 0x0000_0472
    case startDateOfCalibrationPhase = 0x000089D
    case startTimeOfCalibrationPhase = 0x0000_089F
    case transmitterOperationStartDate = 0x0000_0490
    case transmitterOperationStartTime = 0x0000_049F
    case sensorInsertionDate = 0x0000_0890
    case sensorInsertionTime = 0x0000_0892
    case mostRecentGlucoseDate = 0x0000_0410
    case mostRecentGlucoseTime = 0x0000_0412
    case mostRecentGlucoseValue = 0x0000_0414

    case morningCalibrationTime = 0x0000_0898
    case eveningCalibrationTime = 0x0000_089A

    case accelerometerValues = 0x0000_042A
    case accelerometerTemp = 0x0000_0430

    case linkedSensorId = 0x0000_088C
    case unlinkedSensorId = 0x0000_0416

    case mmaFeatures = 0x0000_040C
    case dayStartTime = 0x0000_1110
    case nightStartTime = 0x0000_1112

    case mepSavedValue = 0x0000_00B3
    case mepSavedRefChannelMetric = 0x0000_00B7
    case mepSavedDriftMetric = 0x0000_00BB
    case mepSavedLowRefMetric = 0x0000_00BF
    case mepSavedSpike = 0x0000_00C3
    case eep24MSP = 0x0000_0A20

    case rawValue1 = 0x0000_041A
    case rawValue2 = 0x0000_041C
    case rawValue3 = 0x0000_041E
    case rawValue4 = 0x0000_0420
    case rawValue5 = 0x0000_0422
    case rawValue6 = 0x0000_0424
    case rawValue7 = 0x0000_0426
    case rawValue8 = 0x0000_0428
}

enum CommandOperations {
    static func readFourByteSerialFlashRegister(memoryAddress: FlashMemory) -> Data {
        var data =
            Data([
                EversenseE3.PacketIds.readFourByteSerialFlashRegisterCommandId.rawValue,
                UInt8((memoryAddress.rawValue & 0xFF0000) >> 16),
                UInt8((memoryAddress.rawValue & 0xFF00) >> 8),
                UInt8(memoryAddress.rawValue & 0xFF)
            ])
        let checksum = BinaryOperations.generateChecksumCRC16(data: data)
        data.append(BinaryOperations.dataFrom16Bits(value: checksum))

        return data
    }

    static func readTwoByteSerialFlashRegister(memoryAddress: FlashMemory) -> Data {
        var data =
            Data([
                EversenseE3.PacketIds.readTwoByteSerialFlashRegisterCommandId.rawValue,
                UInt8((memoryAddress.rawValue & 0xFF0000) >> 16),
                UInt8((memoryAddress.rawValue & 0xFF00) >> 8),
                UInt8(memoryAddress.rawValue & 0xFF)
            ])
        let checksum = BinaryOperations.generateChecksumCRC16(data: data)
        data.append(BinaryOperations.dataFrom16Bits(value: checksum))

        return data
    }

    static func readSingleByteSerialFlashRegister(memoryAddress: FlashMemory) -> Data {
        var data =
            Data([
                EversenseE3.PacketIds.readSingleByteSerialFlashRegisterCommandId.rawValue,
                UInt8((memoryAddress.rawValue & 0xFF0000) >> 16),
                UInt8((memoryAddress.rawValue & 0xFF00) >> 8),
                UInt8(memoryAddress.rawValue & 0xFF)
            ])
        let checksum = BinaryOperations.generateChecksumCRC16(data: data)
        data.append(BinaryOperations.dataFrom16Bits(value: checksum))

        return data
    }

    static func writeFourByteSerialFlashRegister(memoryAddress: FlashMemory, data: Data) -> Data {
        var data = Data([
            0x2F,
            UInt8(memoryAddress.rawValue & 0xFF),
            UInt8((memoryAddress.rawValue & 0xFF00) >> 8),
            UInt8((memoryAddress.rawValue & 0xFF0000) >> 16),
            data[0],
            data[1],
            data[2],
            data[3]
        ])
        let checksum = BinaryOperations.generateChecksumCRC16(data: data)
        data.append(BinaryOperations.dataFrom16Bits(value: checksum))

        return data
    }

    static func writeTwoByteSerialFlashRegister(memoryAddress: FlashMemory, data: Data) -> Data {
        var data =
            Data([
                0x2D,
                UInt8(memoryAddress.rawValue & 0xFF),
                UInt8((memoryAddress.rawValue & 0xFF00) >> 8),
                UInt8((memoryAddress.rawValue & 0xFF0000) >> 16),
                data[0],
                data[1]
            ])
        let checksum = BinaryOperations.generateChecksumCRC16(data: data)
        data.append(BinaryOperations.dataFrom16Bits(value: checksum))

        return data
    }

    static func writeSingleByteSerialFlashRegister(memoryAddress: FlashMemory, data: Data) -> Data {
        var data =
            Data([
                0x2B,
                UInt8(memoryAddress.rawValue & 0xFF),
                UInt8((memoryAddress.rawValue & 0xFF00) >> 8),
                UInt8((memoryAddress.rawValue & 0xFF0000) >> 16),
                data[0]
            ])
        let checksum = BinaryOperations.generateChecksumCRC16(data: data)
        data.append(BinaryOperations.dataFrom16Bits(value: checksum))

        return data
    }
}
