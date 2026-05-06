// EnterDiagnosticMode365Packet.swift
// Ported from com.nightscout.eversense.packets.e365.EnterDiagnosticMode365Packet (Kotlin)
//
// Enables diagnostic mode on the 365 transmitter, increasing signal-strength
// update frequency to ~500ms for accurate placement guide feedback.
// Kotlin source: OperationCommandId=0x01, OperationResponseId=0x41, EnterDiagnosticModeOperationId=0x08

extension Eversense365 {
    class EnterDiagnosticModeResponse {}

    class EnterDiagnosticModePacket: BasePacket {
        typealias T = EnterDiagnosticModeResponse

        var responseType: UInt8 { 0x41 }   // OperationResponseId
        var responseId: UInt8? { 0x08 }    // EnterDiagnosticModeOperationId

        func getRequestData() -> Data {
            // [OperationCommandId=0x01] [EnterDiagnosticModeOperationId=0x08]
            let data = Data([0x01, 0x08])
            return CryptoUtil.shared.encrypt(data: data)
        }

        func parseResponse(data _: Data) -> EnterDiagnosticModeResponse {
            EnterDiagnosticModeResponse()
        }
    }
}
