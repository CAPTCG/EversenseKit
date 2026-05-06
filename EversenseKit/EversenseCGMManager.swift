import HealthKit
import LoopKit

protocol StateObserver: AnyObject {
    func stateDidUpdate(_ state: EversenseCGMState)
}

public class EversenseCGMManager: CGMManager {
    public static var pluginIdentifier: String = "EversenseKit"

    private let logger = EversenseLogger(category: "CGMManager")
    internal let bluetoothManager: BluetoothManager

    public var state: EversenseCGMState
    public var rawState: RawStateValue {
        state.rawValue
    }

    public var managedDataInterval: TimeInterval? {
        .hours(3)
    }

    public var providesBLEHeartbeat: Bool {
        true
    }

    public var shouldSyncToRemoteService: Bool {
        true
    }

    public var glucoseDisplay: (any LoopKit.GlucoseDisplayable)? {
        GlucoseDisplay(state: state)
    }

    public var cgmManagerStatus: LoopKit.CGMManagerStatus {
        LoopKit.CGMManagerStatus(
            hasValidSensorSession: state.isOnboarded && state.recentGlucoseDateTime != nil,
            lastCommunicationDate: state.lastSynced,
            device: device
        )
    }

    internal var device: HKDevice {
        HKDevice(
            name: state.modelStr,
            manufacturer: "Senseonics",
            model: nil,
            hardwareVersion: nil,
            firmwareVersion: state.version,
            softwareVersion: state.extVersion,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        )
    }

    public weak var cgmManagerDelegate: CGMManagerDelegate? {
        get {
            delegate.delegate
        }
        set {
            delegate.delegate = newValue
        }
    }

    public var delegateQueue: DispatchQueue! {
        get {
            delegate.queue
        }
        set {
            delegate.queue = newValue
        }
    }

    private let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()
    private let stateObservers = WeakSynchronizedSet<StateObserver>()

    public let managerIdentifier: String = "EversenseCGMManager"

    public var localizedTitle: String {
        if state.is365 {
            return "Eversense 365"
        } else {
            return "Eversense E3"
        }
    }

    public required init?(rawState: RawStateValue) {
        guard let state = EversenseCGMState(rawValue: rawState) else {
            return nil
        }

        self.state = state
        bluetoothManager = BluetoothManager()
        bluetoothManager.cgmManager = self
    }

    func cleanup() {
        logger.info("Cleaning up CGMManager")
        state.bleNameString = nil

        bluetoothManager.stopScan()
        bluetoothManager.disconnect()
    }

    public var isOnboarded: Bool {
        state.isOnboarded
    }

    public var debugDescription: String {
        state.debugDescription
    }

    func addStateObserver(state: StateObserver, queue: DispatchQueue) {
        stateObservers.insert(state, queue: queue)
    }

    public func acknowledgeAlert(alertIdentifier _: LoopKit.Alert.AlertIdentifier, completion: @escaping ((any Error)?) -> Void) {
        completion(nil)
    }

    public func getSoundBaseURL() -> URL? {
        nil
    }

    public func getSounds() -> [LoopKit.Alert.Sound] {
        []
    }

    public func delete(completion: @escaping () -> Void) {
        cleanup()
        notifyDelegateOfDeletion(completion: completion)
    }
}

extension EversenseCGMManager {
    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        completion(.noData)
        heartbeathOperation { }
    }

    /// Responsible for handling fetching Glucose data when ready
    func heartbeathOperation(force: Bool = true, completion: (() -> Void)? = nil) {
        let lastGlucoseTimestamp = max(
            state.recentGlucoseDateTime ?? Date.distantPast,
            Date.now.addingTimeInterval(.hours(-4))
        )

        if !force, Date.now.timeIntervalSince(lastGlucoseTimestamp) < .minutes(4.5) {
            logger.warning("Skipping sync, glucose is still fresh - \(Date.now.timeIntervalSince(lastGlucoseTimestamp))s")
            return
        }

        bluetoothManager.ensureConnected { error in
            if let internalError = error {
                self.logger.error("Failed to connect to CGM: \(internalError.describe)")
                completion?()
                return
            }

            guard let peripheralManager = self.bluetoothManager.peripheralManager else {
                self.logger.error("No peripheralManager")
                completion?()
                return
            }

            var samples: [NewGlucoseSample] = []
            if !self.state.is365 {
                samples = EversenseE3.readGlucoseData(
                    peripheralManager: peripheralManager,
                    cgmManager: self,
                    lastGlucoseTimestamp: lastGlucoseTimestamp
                )
                if !samples.isEmpty {
                    EversenseE3.fullSync(peripheralManager: peripheralManager, cgmManager: self)
                }
            } else {
                samples = Eversense365.readGlucoseData(
                    peripheralManager: peripheralManager,
                    cgmManager: self,
                    lastGlucoseTimestamp: lastGlucoseTimestamp
                )
                if !samples.isEmpty {
                    Eversense365.fullSync(peripheralManager: peripheralManager, cgmManager: self)
                }
            }

            if !samples.isEmpty {
                self.delegate.notify { delegate in
                    delegate?.cgmManager(self, hasNew: .newData(samples))
                }
            }

            completion?()
        }
    }

    func notifyStateDidChange() {
        stateObservers.forEach { observer in
            observer.stateDidUpdate(self.state)
        }

        delegate.notify { cgmManagerDelegate in
            guard let cgmManagerDelegate = cgmManagerDelegate else {
                self.logger.warning("Skip notifying delegate as no delegate set...")
                return
            }

            cgmManagerDelegate.cgmManagerDidUpdateState(self)
        }
    }

    /// Forward a push alarm notification to state observers.
    /// Mirrors Kotlin: plugin.watchers.forEach { it.onAlarmReceived(alarm) }
    /// Called by PeripheralManager when a 365 PushAlarmWithData packet arrives.
    func notifyAlarmReceived(_ alarm: ActiveAlarm) {
        logger.info("Push alarm received: \(alarm.type)")
        stateObservers.forEach { observer in
            observer.stateDidUpdate(self.state)
        }
        delegate.notify { cgmManagerDelegate in
            cgmManagerDelegate?.cgmManagerDidUpdateState(self)
        }
    }

    /// Called by BluetoothManager when consecutive status-19 disconnects indicate
    /// the transmitter is not placed correctly on the sensor.
    /// Mirrors Kotlin: plugin.watchers.forEach { it.onTransmitterNotPlaced() }
    func notifyTransmitterNotPlaced() {
        logger.warning("Transmitter placement warning — repeated status-19 disconnects")
        // Surface the issue via state change so the UI can show a placement alert
        notifyStateDidChange()
    }
}
