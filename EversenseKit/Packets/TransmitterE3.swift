import LoopKit

extension EversenseE3 {
    static let fakeAppVersion = "8.0.1"
    static let logger = EversenseLogger(category: "TransmitterStateE3")

    static func readGlucoseData(
        peripheralManager: PeripheralManager,
        cgmManager: EversenseCGMManager,
        lastGlucoseTimestamp: Date
    ) -> [NewGlucoseSample] {
        do {
            // Sync transmitter clock before reading glucose
            // Mirrors Android clock drift fix (June26).
            if let currentDT: GetCurrentDateTimeResponse = try? peripheralManager.write(GetCurrentDateTimePacket()) {
                let drift = abs(currentDT.datetime.timeIntervalSince1970 - Date.nowWithTimezone().timeIntervalSince1970)
                if drift >= 10 {
                    logger.info("[E3] Clock drift detected before glucose read — syncing transmitter clock")
                    let _: SetCurrentDateTimeResponse = try peripheralManager.write(SetCurrentDateTimePacket())
                }
            }

            let mostRecentGlucose = getRecentGlucose(peripheralManager: peripheralManager)

            logger.debug("Sending GetLogRangePacket...")
            let glucoseRange: GetLogRangeResponse = try peripheralManager.write(GetLogRangePacket(type: .bloodGlucose))
            let range = RangeCalculator.calculateGlucoseRange(
                rangeFrom: glucoseRange.rangeFrom,
                rangeTo: glucoseRange.rangeTo,
                lastGlucoseTimestamp: lastGlucoseTimestamp
            )

            let message =
                "GetLogValuePacket -  from: \(range.from), to: \(range.to), lastGlucoseTimestamp: \(lastGlucoseTimestamp)"
            logger.debug(message)

            var glucoseHistory: [GetGlucoseLogResponse] = []
            for index in range.from ... range.to {
                let pageResponse: GetGlucoseLogResponse = try peripheralManager.write(GetGlucoseLogPacket(index: index))

                logger.debug("Datetime: \(pageResponse.datetime), Glucose: \(pageResponse.glucoseInMgDl) mg/dl")
                glucoseHistory.append(pageResponse)
            }

            var samples = glucoseHistory.filter { $0.datetime > lastGlucoseTimestamp }.map {
                NewGlucoseSample(
                    cgmManager: cgmManager,
                    value: $0.glucoseInMgDl,
                    trend: nil,
                    dateTime: $0.datetime
                )
            }

            if let mostRecentGlucose = mostRecentGlucose,
               mostRecentGlucose.datetime > (cgmManager.state.recentGlucoseDateTime ?? Date.distantPast)
            {
                let rawValue = mostRecentGlucose.glucoseInMgDl
                cgmManager.state.recentGlucoseInMgDl = rawValue
                cgmManager.state.recentGlucoseDateTime = mostRecentGlucose.datetime

                samples.append(
                    NewGlucoseSample(
                        cgmManager: cgmManager,
                        value: rawValue,
                        trend: mostRecentGlucose.trend,
                        dateTime: mostRecentGlucose.datetime
                    )
                )
            } else if let recentGlucose = glucoseHistory.last,
                      recentGlucose.datetime > (cgmManager.state.recentGlucoseDateTime ?? Date.distantPast)
            {
                cgmManager.state.recentGlucoseInMgDl = recentGlucose.glucoseInMgDl
                cgmManager.state.recentGlucoseDateTime = recentGlucose.datetime
            }

            logger.info("[E3] Glucose data read  - timestamp: \(Date.now), count: \(samples.count)")
            return samples
        } catch {
            logger.error("[E3] Something went wrong during readGlucoseData: \(error)")
            return []
        }
    }

    private static func getRecentGlucose(peripheralManager: PeripheralManager) -> GetCurrentGlucoseResponse? {
        do {
            logger.debug("Sending GetCurrentGlucosePacket...")
            let glucoseData: GetCurrentGlucoseResponse = try peripheralManager.write(GetCurrentGlucosePacket())

            guard glucoseData.glucoseInMgDl < 0x03E8 else { // 1000 mg/dl
                let message =
                    "Received invalid Glucose data - value: \(glucoseData.glucoseInMgDl) mg/dl, timestamp sample: \(glucoseData.datetime)"
                logger.error(message)
                return nil
            }

            return glucoseData
        } catch {
            logger.error("[E3] Failed to get recent glucose: \(error.localizedDescription)")
            return nil
        }
    }

    static func fullSync(
        peripheralManager: PeripheralManager,
        cgmManager: EversenseCGMManager
    ) {
        do {
            cgmManager.state.isSyncing = true
            cgmManager.notifyStateDidChange()

            let currentDateTime: GetCurrentDateTimeResponse = try peripheralManager
                .write(GetCurrentDateTimePacket())
            let timeDifference = currentDateTime.datetime.timeIntervalSince1970 - Date.nowWithTimezone().timeIntervalSince1970
            if abs(timeDifference) >= TimeInterval.minutes(2) {
                logger.info("Updating transmitter datetime -> current date \(currentDateTime.datetime)")
                let _: SetCurrentDateTimeResponse = try peripheralManager
                    .write(SetCurrentDateTimePacket())
            }

            // Get MMA Features
            let mmaResponse: GetMmaFeaturesResponse = try peripheralManager
                .write(GetMmaFeaturesPacket())
            cgmManager.state.mmaFeatures = mmaResponse.value

            // Get battery percentage
            let batteryPercentage: GetBatteryPercentageResponse = try peripheralManager
                .write(GetBatteryPercentagePacket())
            cgmManager.state.batteryPercentage = batteryPercentage.value.percentage()

            // Do Ping
            let _: PingResponse = try peripheralManager.write(PingPacket())

            // Get Transmitter version & extended Version
            let versionResponse: GetVersionResponse = try peripheralManager
                .write(GetVersionPacket())
            let versionExtendedResponse: GetVersionExtendedResponse = try peripheralManager
                .write(GetVersionExtendedPacket())
            cgmManager.state.version = versionResponse.version
            cgmManager.state.extVersion = versionExtendedResponse.extVersion

            // Get last calibration datetime
            // Range validation: reject implausible dates (garbage during NOT_ENOUGH_DATA)
            let minCalDate = Date(timeIntervalSince1970: 1577836800) // 2020-01-01
            let maxCalDate = Date(timeIntervalSince1970: 1893456000) // 2030-01-01
            let lastCalibrationDate: GetLastCalibrationDateResponse = try peripheralManager
                .write(GetLastCalibrationDatePacket())
            let lastCalibrationTime: GetLastCalibrationTimeResponse = try peripheralManager
                .write(GetLastCalibrationTimePacket())
            let newLastCal = Date.fromComponents(
                date: lastCalibrationDate.date,
                time: lastCalibrationTime.time
            )
            if newLastCal >= minCalDate && newLastCal <= maxCalDate {
                cgmManager.state.lastCalibration = newLastCal
            } else {
                logger.warning("[E3] lastCalibration out of plausible range, ignoring")
            }

            // Get next calibration datetime
            let nextCalibrationDate: GetNextCalibrationDateResponse = try peripheralManager
                .write(GetNextCalibrationDatePacket())
            let nextCalibrationTime: GetNextCalibrationTimeResponse = try peripheralManager
                .write(GetNextCalibrationTimePacket())
            let newNextCal = Date.fromComponents(
                date: nextCalibrationDate.date,
                time: nextCalibrationTime.time
            )
            if newNextCal >= minCalDate && newNextCal <= maxCalDate {
                cgmManager.state.nextCalibration = newNextCal
            } else {
                logger.warning("[E3] nextCalibration out of plausible range, ignoring")
            }
            // Get current calibration phase
            let calibrationMode: CalibrationMode
            do {
                let isOneCalPhase: GetIsOneCalPhaseResponse = try peripheralManager
                    .write(GetIsOneCalPhasePacket())

                calibrationMode = isOneCalPhase.value ? .DailySingle : .DailyDual
                cgmManager.state.calibrationMode = calibrationMode
            } catch {
                calibrationMode = .Default
                cgmManager.state.calibrationMode = .Default
            }

            let calibrationCount: GetCompletedCalibrationsCountResponse = try peripheralManager
                .write(GetCompletedCalibrationsCountPacket())
            let calibrationPhase: GetCurrentCalibrationPhaseResponse = try peripheralManager
                .write(GetCurrentCalibrationPhasePacket())
            let calibrationReadiness: GetCalibrationReadinessResponse = try peripheralManager
                .write(GetCalibrationReadinessPacket())
            cgmManager.state.calibrationCount = calibrationCount.value
            cgmManager.state.calibrationPhase = calibrationPhase.phase
            cgmManager.state.calibrationReadiness = calibrationReadiness.calibrationReadiness

            let insertionDate: GetInsertionDateResponse = try peripheralManager.write(GetInsertionDatePacket())
            let insertionTime: GetInsertionTimeResponse = try peripheralManager.write(GetInsertionTimePacket())
            cgmManager.state.activatedAt = Date.fromComponents(
                date: insertionDate.insertionDate,
                time: insertionTime.insertionTime
            )
            cgmManager.state.expiresAt = cgmManager.state.activatedAt.addingTimeInterval(.days(180))

            // Write the fake app version
            if let appVersion = SetAppVersionPacket.parseAppVersion(version: fakeAppVersion) {
                let _: SetAppVersionResponse = try peripheralManager
                    .write(SetAppVersionPacket(appVersion: appVersion))
            }

            // Get glucose alarms & status
            let glucoseAlarmsStatus: GetGlucoseAlertsAndStatusPacketResonse = try peripheralManager
                .write(GetGlucoseAlertsAndStatusPacket())
            cgmManager.state.activeAlarms = glucoseAlarmsStatus.alarms

            let vibrateMode: GetVibrateModeResponse = try peripheralManager
                .write(GetVibrateModePacket())
            cgmManager.state.vibrateMode = vibrateMode.value

            // Get glucose alarm enabled & thresholds
            let isGlucoseAlarmEnabled: GetHighGlucoseAlarmEnabledResponse = try peripheralManager
                .write(GetHighGlucoseAlarmEnabledPacket())
            let lowGlucoseAlarm: GetLowGlucoseAlarmResponse = try peripheralManager
                .write(GetLowGlucoseAlarmPacket())
            let highGlucoseAlarm: GetHighGlucoseAlarmResponse = try peripheralManager
                .write(GetHighGlucoseAlarmPacket())
            cgmManager.state.isGlucoseHighAlarmEnabled = isGlucoseAlarmEnabled.value
            cgmManager.state.lowGlucoseAlarmInMgDl = lowGlucoseAlarm.valueInMgDl
            cgmManager.state.highGlucoseAlarmInMgDl = highGlucoseAlarm.valueInMgDl

            // Get predictive values
            let isPredictionLowEnabled: GetPredictiveLowAlertsResponse = try peripheralManager
                .write(GetPredictiveLowAlertsPacket())
            let isPredictionHighEnabled: GetPredictiveHighAlertsResponse = try peripheralManager
                .write(GetPredictiveHighAlertsPacket())
            let predictionFallingInterval: GetPredictiveFallingTimeIntervalResponse = try peripheralManager
                .write(GetPredictiveFallingTimeIntervalPacket())
            let predictionRisingInterval: GetPredictiveRisingTimeIntervalResponse = try peripheralManager
                .write(GetPredictiveRisingTimeIntervalPacket())
            let predictionFallingThreshold: GetPredictiveFallingThresholdResponse = try peripheralManager
                .write(GetPredictiveFallingThresholdPacket())
            let predictionRisingThreshold: GetPredictiveRisingThresholdResponse = try peripheralManager
                .write(GetPredictiveRisingThresholdPacket())
            cgmManager.state.isPredictionLowEnabled = isPredictionLowEnabled.value
            cgmManager.state.isPredictionHighEnabled = isPredictionHighEnabled.value
            cgmManager.state.predictionFallingInterval = predictionFallingInterval.value
            cgmManager.state.predictionRisingInterval = predictionRisingInterval.value
            cgmManager.state.predictionFallingThreshold = predictionFallingThreshold.value
            cgmManager.state.predictionRisingThreshold = predictionRisingThreshold.value

            // Get rate values
            let isFallingRateEnabled: GetRateFallingAlertResponse = try peripheralManager
                .write(GetRateFallingAlertPacket())
            let isRisingRateEnabled: GetRateRisingAlertResponse = try peripheralManager
                .write(GetRateRisingAlertPacket())
            let rateFallingThreshold: GetRateFallingThresholdResponse = try peripheralManager
                .write(GetRateFallingThresholdPacket())
            let rateRisingThreshold: GetRateRisingThresholdResponse = try peripheralManager
                .write(GetRateRisingThresholdPacket())
            cgmManager.state.isFallingRateEnabled = isFallingRateEnabled.value
            cgmManager.state.isRisingRateEnabled = isRisingRateEnabled.value
            cgmManager.state.rateFallingThreshold = rateFallingThreshold.value
            cgmManager.state.rateRisingThreshold = rateRisingThreshold.value

            // Get interval values
            let bleDisconnect: GetBleDisconnectResponse = try peripheralManager.write(GetBleDisconnectPacket())
            let lowGlucoseInterval: GetLowGlucoseRepeatIntervalResponse = try peripheralManager
                .write(GetLowGlucoseRepeatIntervalPacket())
            let highGlucoseInterval: GetHighGlucoseRepeatIntervalResponse = try peripheralManager
                .write(GetHighGlucoseRepeatIntervalPacket())
            cgmManager.state.repeatLowTimeout = lowGlucoseInterval.interval
            cgmManager.state.repeatHighTimeout = highGlucoseInterval.interval
            cgmManager.state.bleDisconnectTimeout = bleDisconnect.interval

            // Get signal strength
            let rawSignalStrength: GetSignalStrengthRawResponse = try peripheralManager
                .write(GetSignalStrengthRawPacket())
            cgmManager.state.signalStrength = rawSignalStrength.signalStrength
            cgmManager.state.signalStrengthRaw = rawSignalStrength.rawValue

            logger.info("[E3] Sync completed - timestamp: \(Date.now)")

        } catch {
            logger.error("[E3] Something went wrong during full sync: \(error)")
        }

        cgmManager.state.isSyncing = false
        cgmManager.state.lastSynced = Date.now
        cgmManager.notifyStateDidChange()
    }

    static func updateSignalStrength(cgmManager: EversenseCGMManager) -> GetSignalStrengthRawResponse? {
        do {
            let rawSignalStrength: GetSignalStrengthRawResponse = try cgmManager.bluetoothManager
                .write(GetSignalStrengthRawPacket())
            cgmManager.state.signalStrength = rawSignalStrength.signalStrength
            cgmManager.state.signalStrengthRaw = rawSignalStrength.rawValue

            return rawSignalStrength
        } catch {
            logger.error("Failed to update signal strength - error: \(error)")
            return nil
        }
    }

    static func writeTransmitterSettings(
        peripheralManager: PeripheralManager,
        data: TransmitterSettings
    ) {
        do {
            let _: SetVibrateModeResponse = try peripheralManager.write(SetVibrateModePacket(enabled: data.vibrationMode))

            let _: SetHighGlucoseAlarmEnabledResponse = try peripheralManager
                .write(SetHighGlucoseAlarmEnabledPacket(enabled: data.glucoseHighEnabled))
            let _: SetHighGlucoseAlarmResponse = try peripheralManager
                .write(SetHighGlucoseAlarmPacket(value: data.glucoseHighInMgDl))
            let _: SetLowGlucoseAlarmResponse = try peripheralManager
                .write(SetLowGlucoseAlarmPacket(value: data.glucoseLowInMgDl))

            let _: SetRateRisingEnabledResponse = try peripheralManager
                .write(SetRateRisingEnabledPacket(enabled: data.rateRisingEnabled))
            let _: SetRateRisingThresholdResponse = try peripheralManager
                .write(SetRateRisingThresholdPacket(value: data.rateRisingThreshold))
            let _: SetRateFallingEnabledResponse = try peripheralManager
                .write(SetRateFallingEnabledPacket(enabled: data.rateFallingEnabled))
            let _: SetRateFallingThresholdResponse = try peripheralManager
                .write(SetRateFallingThresholdPacket(value: data.rateFallingThreshold))

            let _: SetPredictionHighEnabledResponse = try peripheralManager
                .write(SetPredictionHighEnabledPacket(enabled: data.predictiveHighEnabled))
            let _: SetPredictionHighTimeResponse = try peripheralManager
                .write(SetPredictionHighTimePacket(time: data.predictiveHighTime))
            let _: SetPredictionHighThresholdResponse = try peripheralManager
                .write(SetPredictionHighThresholdPacket(value: data.predictiveHighThreshold))
            let _: SetPredictionLowEnabledResponse = try peripheralManager
                .write(SetPredictionLowEnabledPacket(enabled: data.predictiveLowEnabled))
            let _: SetPredictionLowTimeResponse = try peripheralManager
                .write(SetPredictionLowTimePacket(time: data.predictiveLowTime))
            let _: SetPredictionLowThresholdResponse = try peripheralManager
                .write(SetPredictionLowThresholdPacket(value: data.predictiveLowThreshold))

            let _: SetBleDisconnectResponse = try peripheralManager.write(SetBleDisconnectPacket(interval: data.bleDisconnect))
            let _: SetLowGlucoseRepeatIntervalResponse = try peripheralManager
                .write(SetLowGlucoseRepeatIntervalDayPacket(interval: data.repeatAlarmLow))
            let _: SetLowGlucoseRepeatIntervalResponse = try peripheralManager
                .write(SetLowGlucoseRepeatIntervalNightPacket(interval: data.repeatAlarmLow))
            let _: SetHighGlucoseRepeatIntervalResponse = try peripheralManager
                .write(SetHighGlucoseRepeatIntervalDayPacket(interval: data.repeatAlarmHigh))
            let _: SetHighGlucoseRepeatIntervalResponse = try peripheralManager
                .write(SetHighGlucoseRepeatIntervalNightPacket(interval: data.repeatAlarmHigh))

            logger.info("[E3] Transmitter settings have been written - timestamp: \(Date.now)")
        } catch {
            logger.error("[E3] Something went wrong during setting transmitter settings: \(error)")
        }
    }

    static func handleError(data: Data) {
        guard data.count >= 4 else {
            logger.error("Invalid error response length - length: \(data.count), data: \(data.hexString())")
            return
        }

        let code = (UInt16(data[3]) << 8) | UInt16(data[2])
        guard let error = CommandError(rawValue: code) else {
            logger.error("Received unknown error - code: \(code), data: \(data.hexString())")
            return
        }

        // TODO: Emit error
        logger.warning("Received error from transmitter - error: \(error), data: \(data.hexString())")
    }

    static func calibrateSensors(cgmManager: EversenseCGMManager, glucoseInMgDl: UInt16, timestamp: Date) throws {
        do {
            logger.info("Sending SetBloodGlucosePointPacket - glucose: \(glucoseInMgDl)mg/dl, timestamp: \(timestamp)")

            let _: SetBloodGlucosePointResponse = try cgmManager.bluetoothManager
                .write(SetBloodGlucosePointPacket(glucoseInMgDl: glucoseInMgDl, timestamp: timestamp), timeout: .seconds(15))

            logger.info("[E3] Calibation has been send - timestamp: \(Date.now)")
        } catch {
            logger.error("[E3] Something went wrong during calibration: \(error)")
            throw error
        }
    }
}
