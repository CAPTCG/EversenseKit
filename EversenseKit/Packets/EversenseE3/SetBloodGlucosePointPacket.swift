extension EversenseE3 {
    class SetBloodGlucosePointResponse {}

    class SetBloodGlucosePointPacket: BasePacket {
        typealias T = SetBloodGlucosePointResponse

        var responseType: UInt8 {
            PacketIds.sendBloodGlucoseDataResponseId.rawValue
        }

        var responseId: UInt8? {
            nil
        }

        private let sampleTime: Date
        private let glucoseInMgDl: UInt16

        /// - Parameters:
        ///   - glucoseInMgDl: Blood glucose value in mg/dL
        ///   - timestamp:     Time the BG reading was taken (defaults to now)
        init(glucoseInMgDl: UInt16, timestamp: Date = .now) {
            self.glucoseInMgDl = glucoseInMgDl
            self.sampleTime = timestamp
        }

        /// Builds the calibration packet matching the official Eversense app exactly.
        ///
        /// Packet layout verified against official app (operationToSendBloodGlucoseValueToTransmitter):
        ///
        ///  [0]    0x15  — SendBloodGlucoseDataCommandId
        ///  [1-2]  sampleDate  — FAT-packed date of BG reading (2 bytes, GMT)
        ///  [3-4]  sampleTime  — FAT-packed time of BG reading (2 bytes, GMT)
        ///  [5-6]  currentTime — FAT-packed TIME of submission = now (2 bytes, GMT, NOT date)
        ///  [7]    bgLSB  — glucose LSB
        ///  [8]    bgMSB  — glucose MSB
        ///  [9]    bgLSB  — glucose LSB repeated
        ///  [10]   0x00   — rolling cal disabled; official app only enables (0x55) for US+protocolVersion>=4.0
        ///  [11-12] CRC16 little-endian
        func getRequestData() -> Data {
            let now = Date.now
            let bgLsb = UInt8(glucoseInMgDl & 0xFF)
            let bgMsb = UInt8((glucoseInMgDl >> 8) & 0xFF)

            var data = Data([PacketIds.sendBloodGlucoseDataCommandId.rawValue])
            data.append(BinaryOperations.toDateArray(date: sampleTime.toGmt()))  // [1-2] sample date
            data.append(BinaryOperations.toTimeArray(date: sampleTime.toGmt()))  // [3-4] sample time
            data.append(BinaryOperations.toTimeArray(date: now.toGmt()))          // [5-6] current TIME (not date)
            data.append(contentsOf: [bgLsb, bgMsb, bgLsb])                       // [7-9] BG bytes
            data.append(0x00)                                                     // [10]  rolling cal disabled — matches non-US official app

            let checksum = BinaryOperations.generateChecksumCRC16(data: data)
            data.append(BinaryOperations.dataFrom16Bits(value: checksum))         // [11-12] CRC16

            return data
        }

        func parseResponse(data _: Data) -> SetBloodGlucosePointResponse {
            SetBloodGlucosePointResponse()
        }
    }
}
