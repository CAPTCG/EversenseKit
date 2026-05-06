

class PlacementGuideViewModel: ObservableObject {
    @Published var strength: SignalStrength = .NoSignal
    @Published var strengthRaw: UInt16 = 0
    @Published var lastUpdate = ""

    private var running = true

    private let dateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    private let cgmManager: EversenseCGMManager?
    init(cgmManager: EversenseCGMManager?) {
        self.cgmManager = cgmManager

        guard let cgmManager = cgmManager else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // Enter diagnostic mode for faster signal updates (~500ms) during placement
            if cgmManager.state.is365 {
                Eversense365.setDiagnosticMode(cgmManager: cgmManager, enabled: true)
            }
            self.updateSignalStrength(cgmManager: cgmManager)
        }
    }

    public func stop() {
        running = false
        // Exit diagnostic mode to restore normal signal-strength update frequency
        if let cgmManager = cgmManager, cgmManager.state.is365 {
            DispatchQueue.global(qos: .userInitiated).async {
                Eversense365.setDiagnosticMode(cgmManager: cgmManager, enabled: false)
            }
        }
    }

    private func updateSignalStrength(cgmManager: EversenseCGMManager) {
        guard running else {
            return
        }

        if cgmManager.state.is365 {
            if let response = Eversense365.updateSignalStrength(cgmManager: cgmManager) {
                DispatchQueue.main.async {
                    self.lastUpdate = self.dateFormatter.string(from: Date.now)
                    self.strength = response.signalStrength
                    self.strengthRaw = min(response.rawValue, 100)
                }
            }
        } else {
            if let response = EversenseE3.updateSignalStrength(cgmManager: cgmManager) {
                DispatchQueue.main.async {
                    self.lastUpdate = self.dateFormatter.string(from: Date.now)
                    self.strength = response.signalStrength
                    self.strengthRaw = response.rawValue / 20
                }
            }
        }

        Thread.sleep(forTimeInterval: .seconds(0.2))
        updateSignalStrength(cgmManager: cgmManager)
    }
}
