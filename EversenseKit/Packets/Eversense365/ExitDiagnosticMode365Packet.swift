// ExitDiagnosticMode365Packet.swift
// Ported from com.nightscout.eversense.packets.e365.ExitDiagnosticMode365Packet (Kotlin)
//
// Disables diagnostic mode on the 365 transmitter, restoring normal signal-strength
// update frequency. Called by PlacementGuideViewModel.stop().
// Kotlin source: OperationCommandId=0x01, OperationResponseId=0x41, ExitDiagnosticModeOperationId=0x09

extension Eversense365 {
    class ExitDiagnosticModeResponse {}

    class ExitDiagnosticModePacket: BasePacket {
        typealias T = ExitDiagnosticModeResponse

        var responseType: UInt8 { 0x41 }   // OperationResponseId
        var responseId: UInt8? { 0x09 }    // ExitDiagnosticModeOperationId

        func getRequestData() -> Data {
            // [OperationCommandId=0x01] [ExitDiagnosticModeOperationId=0x09]
            let data = Data([0x01, 0x09])
            return CryptoUtil.shared.encrypt(data: data)
        }

        func parseResponse(data _: Data) -> ExitDiagnosticModeResponse {
            ExitDiagnosticModeResponse()
        }
    }
}
