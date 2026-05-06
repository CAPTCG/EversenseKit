import LoopKit

extension Eversense365 {
    static let fakeAppVersion = "8.0.4"
    static let logger = EversenseLogger(category: "TransmitterState365")
    static var sensorIdLength = 0x00

    static func readGlucoseData(
        peripheralManager: PeripheralManager,
        cgmManager: EversenseCGMManager,
        lastGlucoseTimestamp: Date
    ) -> [NewGlucoseSample] {
        do {
            logger.debug("sending GetRecentGlucosePacket...")
            let mostRecentGlucose = getRecentGlucose(peripheralManager: peripheralManager)

            logger.debug("sending GetGlucoseLogRangePacket...")
            let glucoseRange: GetLogRangeResponse = try peripheralManager
                .write(GetLogRangePacket(communicationVersion: cgmManager.state.communicationProtocol, logType: LogTypes.Glucose))

            let range = RangeCalculator.calculateGlucoseRange(
                rangeFrom: glucoseRange.rangeFrom,
                rangeTo: glucoseRange.rangeTo,
                lastGlucoseTimestamp: lastGlucoseTimestamp
            )

            let message =
                "GetLogValuePacket -  from: \(range.from), to: \(range.to), lastGlucoseTimestamp: \(lastGlucoseTimestamp)"
            logger.debug(message)
            let historyResponse: GetGlucoseLogValuesResponse = try peripheralManager
                .write(GetGlucoseLogValuesPacket(from: range.from, to: range.to), timeout: .seconds(15))

            if let mostRecentGlucose = mostRecentGlucose,
               mostRecentGlucose.glucoseDatetime > (cgmManager.state.recentGlucoseDateTime ?? Date.distantPast)
            {
                // Apply EselSmoothing if enabled — mirrors Kotlin Eversense365Communicator.readGlucose()
                let rawValue = mostRecentGlucose.glucoseInMgDl
                let smoothedValue: UInt16
                if cgmManager.state.useSmoothing,
                   let lastSmooth = cgmManager.state.recentGlucoseInMgDl,
                   cgmManager.state.lastGlucoseRaw > 0
                {
                    smoothedValue = UInt16(EselSmoothing.smooth(
                        currentRaw: Int(rawValue),
                        lastSmooth: Int(lastSmooth),
                        lastRaw: Int(cgmManager.state.lastGlucoseRaw)
                    ))
                } else {
                    smoothedValue = rawValue
                }
                cgmManager.state.lastGlucoseRaw = rawValue
                cgmManager.state.recentGlucoseInMgDl = smoothedValue
                cgmManager.state.recentGlucoseDateTime = mostRecentGlucose.glucoseDatetime
                // Store raw BLE data and sensor ID for DMS upload
                cgmManager.state.recentRawBLEHex = mostRecentGlucose.rawResponseHex
                cgmManager.state.sensorIdHex     = mostRecentGlucose.sensorIdHex
            } else if let recentGlucose = historyResponse.glucoseHistory.last,
                      recentGlucose.datetime > (cgmManager.state.recentGlucoseDateTime ?? Date.distantPast)
            {
                cgmManager.state.recentGlucoseInMgDl = recentGlucose.valueInMgDl
                cgmManager.state.recentGlucoseDateTime = recentGlucose.datetime
            }

            var samples = historyResponse.glucoseHistory.filter { $0.datetime > lastGlucoseTimestamp }.map {
                NewGlucoseSample(
                    cgmManager: cgmManager,
                    value: $0.valueInMgDl,
                    trend: $0.trend,
                    dateTime: $0.datetime
                )
            }

            if let mostRecentGlucose = mostRecentGlucose {
                // Use smoothed value if smoothing is on
                let deliveredValue = cgmManager.state.recentGlucoseInMgDl ?? mostRecentGlucose.glucoseInMgDl
                samples.append(
                    NewGlucoseSample(
                        cgmManager: cgmManager,
                        value: deliveredValue,
                        trend: mostRecentGlucose.trend,
                        dateTime: mostRecentGlucose.glucoseDatetime
                    )
                )
            }

            logger.info("[365] Glucose data read  - timestamp: \(Date.now), count: \(samples.count)")
            return samples
        } catch {
            logger.error("[365] Something went wrong during readGlucoseData: \(error)")
            return []
        }
    }

    private static func getRecentGlucose(peripheralManager: PeripheralManager) -> GetGlucoseDataResponse? {
        do {
            let response: GetGlucoseDataResponse = try peripheralManager.write(GetGlucoseDataPacket())
            guard response.glucoseInMgDl < 0x03E8 else {
                let message =
                    "Invalid Glucose data - value: \(response.glucoseInMgDl) mg/dl, timestamp: \(response.glucoseDatetime)"
                logger.warning(message)
                return nil
            }

            return response
        } catch {
            logger.error("Failed to fetch Glucose data - error: \(error.localizedDescription)")
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

            // Do Ping
            logger.debug("Sending PING")
            let _: PingResponse = try peripheralManager.write(PingPacket())

            // Get transmitter information
            logger.debug("Sending GetSensorInformationPacket")
            let sensorInformation: GetSensorInformationResponse = try peripheralManager
                .write(GetSensorInformationPacket())

            cgmManager.state.mmaFeatures = sensorInformation.mmaFeatures
            cgmManager.state.batteryPercentage = sensorInformation.batteryLevel
            cgmManager.state.version = sensorInformation.version
            cgmManager.state.extVersion = sensorInformation.extVersion
            cgmManager.state.communicationProtocol = sensorInformation.communicationProtocolVersion
            cgmManager.state.activatedAt = sensorInformation.insertionDate
            cgmManager.state.expiresAt = sensorInformation.insertionDate.addingTimeInterval(.days(365))
            sensorIdLength = sensorInformation.sensorIdLength

            let timeDifference = sensorInformation.transmitterDatetime.timeIntervalSince1970 - Date.nowWithTimezone()
                .timeIntervalSince1970
            if abs(timeDifference) >= TimeInterval.seconds(10) {
                logger.info("Updating transmitter datetime -> current date \(sensorInformation.transmitterDatetime)")
                let _: Eversense365.SetCurrentDateTimeResponse = try peripheralManager
                    .write(Eversense365.SetCurrentDateTimePacket())
            }

            // Fetch signal strength
            logger.debug("Sending GetSignalStrenghtPacket")
            let signalStrength: GetSignalStrenghtResponse = try peripheralManager.write(GetSignalStrenghtPacket())
            cgmManager.state.signalStrengthRaw = signalStrength.rawValue
            cgmManager.state.signalStrength = signalStrength.signalStrength

            logger.debug("Sending GetCalibrationInfoPacket")
            let calibrationInfo: GetCalibrationInfoResponse = try peripheralManager.write(GetCalibrationInfoPacket())
            cgmManager.state.calibrationCount = UInt16(calibrationInfo.countCalibrations)
            cgmManager.state.calibrationReadiness = calibrationInfo.calibrationReadiness
            cgmManager.state.calibrationMode = calibrationInfo.calibrationMode
            cgmManager.state.calibrationPhase = calibrationInfo.currentPhase
            cgmManager.state.lastCalibration = calibrationInfo.lastCalibration
            cgmManager.state.nextCalibration = calibrationInfo.nextCalibration

            logger.debug("Sending SetAppVersionPacket")
            let _: SetAppVersionResponse = try peripheralManager.write(SetAppVersionPacket(appVersion: fakeAppVersion))

            logger.debug("Sending GetPatientSettingsPacket")
            let patientSettings: GetPatientSettingsResponse = try peripheralManager.write(GetPatientSettingsPacket())
            cgmManager.state.vibrateMode = patientSettings.vibrateMode
            cgmManager.state.lowGlucoseAlarmInMgDl = patientSettings.lowGlucoseAlarmInMgDl
            cgmManager.state.isGlucoseHighAlarmEnabled = patientSettings.highGlucoseEnabled
            cgmManager.state.highGlucoseAlarmInMgDl = patientSettings.highGlucoseAlarmInMgDl
            cgmManager.state.isPredictionLowEnabled = patientSettings.predictionLowEnabled
            cgmManager.state.isPredictionHighEnabled = patientSettings.predictionHighEnabled
            cgmManager.state.predictionFallingInterval = patientSettings.predictionFallingInterval
            cgmManager.state.predictionRisingInterval = patientSettings.predictionRisingInterval
            cgmManager.state.predictionFallingThreshold = patientSettings.predictionFallingThreshold
            cgmManager.state.predictionRisingThreshold = patientSettings.predictionRisingThreshold
            cgmManager.state.isFallingRateEnabled = patientSettings.rateFallingEnabled
            cgmManager.state.isRisingRateEnabled = patientSettings.rateRisingEnabled
            cgmManager.state.rateFallingThreshold = patientSettings.rateFallingThreshold
            cgmManager.state.rateRisingThreshold = patientSettings.rateRisingThreshold
            cgmManager.state.bleDisconnectTimeout = patientSettings.disconnectTimeout
            cgmManager.state.repeatLowTimeout = patientSettings.repeatLowTimeout
            cgmManager.state.repeatHighTimeout = patientSettings.repeatHighTimeout

            logger.debug("Sending GetActiveAlarmsPacket")
            let activeAlarms: GetActiveAlarmsResponse = try peripheralManager.write(GetActiveAlarmsPacket())
            cgmManager.state.activeAlarms = activeAlarms.alarms

            logger.info("[365] Sync completed - timestamp: \(Date.now)")

        } catch {
            logger.error("[365] Something went wrong during full sync: \(error)")
        }

        cgmManager.state.isSyncing = false
        cgmManager.state.lastSynced = Date.now
        cgmManager.notifyStateDidChange()
    }

    static func writeTransmitterSettings(
        peripheralManager: PeripheralManager,
        data: TransmitterSettings
    ) {
        do {
            logger.debug("Write vibration")
            let _: SetDoNotDisturbResponse = try peripheralManager.write(SetDoNotDisturbRequest(silenced: data.vibrationMode))

            logger.debug("Write glucose alerts")
            let _: SetHighGlucoseAlarmEnabledResponse = try peripheralManager
                .write(SetHighGlucoseAlarmEnabledPacket(enabled: data.glucoseHighEnabled))
            let _: SetHighGlucoseAlarmResponse = try peripheralManager
                .write(SetHighGlucoseAlarmPacket(value: data.glucoseHighInMgDl))
            let _: SetLowGlucoseAlarmResponse = try peripheralManager
                .write(SetLowGlucoseAlarmPacket(value: data.glucoseLowInMgDl))

            logger.debug("Write rate alerts")
            let _: SetRateRisingEnabledResponse = try peripheralManager
                .write(SetRateRisingEnabledPacket(enabled: data.rateRisingEnabled))
            let _: SetRateRisingThresholdResponse = try peripheralManager
                .write(SetRateRisingThresholdPacket(value: data.rateRisingThreshold))
            let _: SetRateFallingEnabledResponse = try peripheralManager
                .write(SetRateFallingEnabledPacket(enabled: data.rateFallingEnabled))
            let _: SetRateFallingThresholdResponse = try peripheralManager
                .write(SetRateFallingThresholdPacket(value: data.rateFallingThreshold))

            logger.debug("Write prediction alerts")
            let _: SetPredictionLowEnabledResponse = try peripheralManager
                .write(SetPredictionLowEnabledPacket(enabled: data.predictiveLowEnabled))
            let _: SetPredictionLowIntervalResponse = try peripheralManager
                .write(SetPredictionLowIntervalPacket(time: data.predictiveLowTime))
            let _: SetPredictionLowThresholdResponse = try peripheralManager
                .write(SetPredictionLowThresholdPacket(value: data.predictiveLowThreshold))
            let _: SetPredictionHighEnabledResponse = try peripheralManager
                .write(SetPredictionHighEnabledPacket(enabled: data.predictiveHighEnabled))
            let _: SetPredictionHighIntervalResponse = try peripheralManager
                .write(SetPredictionHighIntervalPacket(time: data.predictiveHighTime))
            let _: SetPredictionHighThresholdResponse = try peripheralManager
                .write(SetPredictionHighThresholdPacket(value: data.predictiveHighThreshold))

            logger.debug("Write timeouts")
            let _: SetBleDisconnectResponse = try peripheralManager.write(SetBleDisconnectPacket(interval: data.bleDisconnect))
            let _: SetRepeatLowGlucoseResponse = try peripheralManager
                .write(SetRepeatLowGlucosePacket(interval: data.repeatAlarmLow))
            let _: SetRepeatHighGlucoseResponse = try peripheralManager
                .write(SetRepeatHighGlucosePacket(interval: data.repeatAlarmHigh))

            logger.info("[365] Transmitter settings have been written - timestamp: \(Date.now)")
        } catch {
            logger.error("[365] Something went wrong setting transmitter settings: \(error)")
        }
    }

    static func updateSignalStrength(cgmManager: EversenseCGMManager) -> GetSignalStrenghtResponse? {
        do {
            logger.debug("sending GetSignalStrenghtResponse...")
            let signalStrength: GetSignalStrenghtResponse = try cgmManager.bluetoothManager.write(GetSignalStrenghtPacket())
            cgmManager.state.signalStrengthRaw = signalStrength.rawValue
            cgmManager.state.signalStrength = signalStrength.signalStrength

            return signalStrength
        } catch {
            logger.error("Failed to update signal strength - error: \(error)")
            return nil
        }
    }

    static func calibrateSensors(cgmManager: EversenseCGMManager, glucoseInMgDl: UInt16, timestamp: Date) throws {
        do {
            logger.info("Sending SetBloodGlucosePointPacket - glucose: \(glucoseInMgDl)mg/dl, timestamp: \(timestamp)")

            let _: SetBloodGlucosePointResponse = try cgmManager.bluetoothManager
                .write(SetBloodGlucosePointPacket(glucoseInMgDl: glucoseInMgDl, timestamp: timestamp))

            logger.info("[365] Calibation has been send - timestamp: \(Date.now)")
        } catch {
            logger.error("[365] Something went wrong during calibration: \(error)")
            throw error
        }
    }

    /// Enable or disable diagnostic mode on the 365 transmitter.
    /// Diagnostic mode increases signal-strength update frequency to ~500ms,
    /// enabling accurate placement feedback in PlacementGuideViewModel.
    /// Ported from EversenseCGMPlugin.setDiagnosticMode() (Kotlin).
    static func setDiagnosticMode(cgmManager: EversenseCGMManager, enabled: Bool) {
        do {
            if enabled {
                let _: EnterDiagnosticModeResponse = try cgmManager.bluetoothManager
                    .write(EnterDiagnosticModePacket())
                logger.info("[365] Diagnostic mode enabled")
            } else {
                let _: ExitDiagnosticModeResponse = try cgmManager.bluetoothManager
                    .write(ExitDiagnosticModePacket())
                logger.info("[365] Diagnostic mode disabled")
            }
        } catch {
            logger.warning("[365] setDiagnosticMode(\(enabled)) failed: \(error)")
        }
    }

    static func handleError(data: Data) {
        // TODO: Emit error
        logger.warning("Received error from transmitter - data: \(data.hexString())")
    }
}
