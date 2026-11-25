import CoreBluetooth
import Foundation
import Observation

/// One line of the BLE debug monitor.
struct BLELogEntry: Identifiable, Hashable {
    enum Direction: String { case tx = "TX", rx = "RX", info = "··" }
    let id = UUID()
    let date: Date
    let direction: Direction
    let label: String
    let hex: String
}

/// CoreBluetooth transport + telemetry for the Nano Cortex.
///
/// Scans for a peripheral whose name matches /nano|cortex/i, connects, discovers the
/// A002/A003 service with C304 (write) / C305 (notify), enables notifications, reads the
/// firmware version from the state reply (protobuf field 24) and then decodes every
/// notification into `NanoEvent`s, which drive the capture flow.
@MainActor
@Observable
final class NanoBLEManager: NSObject {

    enum ConnectionState: Equatable {
        case idle
        case poweredOff
        case unauthorized
        case unsupported
        case scanning
        case connecting(String)
        case discovering(String)
        case ready
        case failed(String)

        var description: String {
            switch self {
            case .idle: return "Bluetooth idle"
            case .poweredOff: return "The Mac's Bluetooth is off"
            case .unauthorized: return "Bluetooth access denied (System Settings → Privacy)"
            case .unsupported: return "Bluetooth LE not supported"
            case .scanning: return "Searching for the Nano Cortex…"
            case .connecting(let name): return "Connecting to \(name)…"
            case .discovering(let what): return what
            case .ready: return "Connected"
            case .failed(let why): return "Error: \(why)"
            }
        }
    }

    // MARK: Observable state

    private(set) var state: ConnectionState = .idle
    private(set) var peripheralName: String?
    private(set) var firmwareVersion: String?

    /// True while the Nano reports capture mode (state field 23, or capture meters flowing).
    private(set) var captureMode = false
    /// Last CAPTURE IN / OUTPUT meter values (0...255) from message 64.
    private(set) var captureInMeter = 0
    private(set) var outputMeter = 0
    private(set) var lastMeterDate: Date?
    private(set) var captureInGainRaw: Int?
    private(set) var outputLevelRaw: Int?

    private(set) var log: [BLELogEntry] = []
    var logMeters = false

    var isReady: Bool { state == .ready }

    // MARK: Private

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeCharacteristic: CBCharacteristic?
    @ObservationIgnored private var notifyCharacteristic: CBCharacteristic?
    @ObservationIgnored private var reassembler = NanoReassembler()
    @ObservationIgnored private var writeQueue: [(data: Data, label: String)] = []
    @ObservationIgnored private var writeInFlight = false
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<NanoEvent>.Continuation] = [:]
    @ObservationIgnored private var waiters: [UUID: (predicate: (NanoEvent) -> Bool, continuation: CheckedContinuation<NanoEvent?, Never>)] = [:]

    private static let maxLogEntries = 3000

    // MARK: Lifecycle

    /// Starts (or resumes) scanning + auto-connect. First call triggers the Bluetooth permission prompt.
    func start() {
        wantsConnection = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: true])
            return // scanning starts in centralManagerDidUpdateState
        }
        if central?.state == .poweredOn, peripheral == nil { beginScan() }
    }

    func disconnect() {
        wantsConnection = false
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        resetConnection()
        state = .idle
    }

    func retry() {
        disconnect()
        start()
    }

    // MARK: Sending

    func send(_ data: Data, label: String) {
        writeQueue.append((data, label))
        pumpWrites()
    }

    /// Debug monitor: send arbitrary hex.
    @discardableResult
    func sendRawHex(_ hex: String) -> Bool {
        guard let data = NanoFrame.fromHex(hex), !data.isEmpty else { return false }
        send(data, label: "manual")
        return true
    }

    func requestState() { send(NanoCommand.stateRequest, label: "State request") }

    // MARK: Events

    /// Each call returns an independent stream of decoded events.
    func events() -> AsyncStream<NanoEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers[id] = nil }
            }
        }
    }

    /// Waits for the first event matching `predicate`, or `nil` after `timeout` seconds.
    func waitFor(timeout: TimeInterval, _ predicate: @escaping (NanoEvent) -> Bool) async -> NanoEvent? {
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<NanoEvent?, Never>) in
            waiters[id] = (predicate, continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resolveWaiter(id, with: nil)
            }
        }
    }

    private func resolveWaiter(_ id: UUID, with event: NanoEvent?) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: event)
    }

    func clearLog() { log.removeAll() }

    // MARK: Internals

    private func appendLog(_ direction: BLELogEntry.Direction, _ label: String, _ data: Data? = nil) {
        log.append(BLELogEntry(date: Date(), direction: direction, label: label, hex: data.map { NanoFrame.hex($0) } ?? ""))
        if log.count > Self.maxLogEntries { log.removeFirst(log.count - Self.maxLogEntries) }
    }

    private func beginScan() {
        guard let central else { return }
        let services = NanoBLEUUID.services
        if let known = central.retrieveConnectedPeripherals(withServices: services).first {
            appendLog(.info, "Peripheral already connected to the system: \(known.name ?? "?")")
            connect(known)
            return
        }
        state = .scanning
        appendLog(.info, "BLE scan started")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func connect(_ p: CBPeripheral) {
        central?.stopScan()
        peripheral = p
        p.delegate = self
        peripheralName = p.name
        state = .connecting(p.name ?? "Nano Cortex")
        central?.connect(p, options: nil)
    }

    private func resetConnection() {
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        writeQueue.removeAll()
        writeInFlight = false
        reassembler.reset()
        captureMode = false
        firmwareVersion = nil
    }

    private func pumpWrites() {
        guard !writeInFlight, let p = peripheral, let ch = writeCharacteristic, !writeQueue.isEmpty else { return }
        let job = writeQueue.removeFirst()
        appendLog(.tx, job.label, job.data)
        if ch.properties.contains(.write) {
            writeInFlight = true
            p.writeValue(job.data, for: ch, type: .withResponse)
        } else {
            p.writeValue(job.data, for: ch, type: .withoutResponse)
            pumpWrites()
        }
    }

    private func handleNotification(_ data: Data) {
        guard let message = reassembler.feed(data) else { return }
        let event = NanoEvent.decode(message)

        let isMeter: Bool
        if case .meter = event { isMeter = true } else { isMeter = false }
        if !isMeter || logMeters {
            let name = message.knownType.map { "\($0)" } ?? "type \(message.type)"
            appendLog(.rx, name, data.count > 2 && data[1] == 0xC0 ? data : message.payload)
        }

        switch event {
        case .state(let capture, let firmware, let gain, let level):
            captureMode = capture
            if let firmware, !firmware.isEmpty { firmwareVersion = firmware }
            if capture {
                captureInGainRaw = gain
                outputLevelRaw = level
            }
        case .meter(let channel, let raw):
            lastMeterDate = Date()
            captureMode = true
            if channel == 0 { captureInMeter = raw } else if channel == 1 { outputMeter = raw }
        case .captureValue(let which, let raw):
            if which == 1 { outputLevelRaw = raw } else { captureInGainRaw = raw }
        case .trainingProgress, .trainingDone, .captureState:
            captureMode = true
        case .presetChanged:
            send(NanoCommand.presetChangeAck, label: "Preset change ack")
        default:
            break
        }

        for (_, continuation) in subscribers { continuation.yield(event) }
        for (id, waiter) in waiters where waiter.predicate(event) {
            resolveWaiter(id, with: event)
        }
    }

    private func didBecomeNotifying() async {
        state = .discovering("Reading firmware version…")
        requestState()
        let reply = await waitFor(timeout: 6) { if case .state = $0 { return true } else { return false } }
        if reply == nil { appendLog(.info, "No reply to the state request (firmware unknown)") }
        state = .ready
    }
}

// MARK: - CBCentralManagerDelegate

extension NanoBLEManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let cbState = central.state
        MainActor.assumeIsolated {
            switch cbState {
            case .poweredOn:
                if wantsConnection, peripheral == nil { beginScan() }
            case .poweredOff:
                state = .poweredOff
                resetConnection()
            case .unauthorized:
                state = .unauthorized
            case .unsupported:
                state = .unsupported
            default:
                state = .idle
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        MainActor.assumeIsolated {
            let name = advName ?? peripheral.name
            guard self.peripheral == nil, NanoBLEUUID.nameMatches(name) else { return }
            appendLog(.info, "Found \(name ?? "?") (RSSI \(RSSI))")
            connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            appendLog(.info, "Connected, discovering services A002/A003")
            state = .discovering("Discovering GATT services…")
            peripheral.discoverServices(NanoBLEUUID.services)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "connection failed"
        MainActor.assumeIsolated {
            guard self.peripheral == nil || self.peripheral === peripheral else { return }
            appendLog(.info, "Connection failed: \(message)")
            resetConnection()
            state = .failed(message)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            guard self.peripheral == nil || self.peripheral === peripheral else { return } // stale callback
            appendLog(.info, "Disconnected" + (message.map { ": \($0)" } ?? ""))
            resetConnection()
            if wantsConnection {
                state = .scanning
                beginScan()
            } else {
                state = .idle
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension NanoBLEManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = peripheral.services ?? []
            let matching = services.filter { NanoBLEUUID.services.contains($0.uuid) }
            if matching.isEmpty {
                appendLog(.info, "Services found: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")
                state = .failed("Service A002/A003 not found. Is this really a Nano Cortex?")
                return
            }
            for service in matching {
                peripheral.discoverCharacteristics([NanoBLEUUID.write, NanoBLEUUID.notify], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            for ch in service.characteristics ?? [] {
                if ch.uuid == NanoBLEUUID.write, writeCharacteristic == nil {
                    writeCharacteristic = ch
                    pumpWrites() // flush anything queued before discovery finished
                }
                if ch.uuid == NanoBLEUUID.notify, notifyCharacteristic == nil { notifyCharacteristic = ch }
            }
            if let notify = notifyCharacteristic, writeCharacteristic != nil, !notify.isNotifying {
                state = .discovering("Enabling notifications…")
                peripheral.setNotifyValue(true, for: notify)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        let message = error?.localizedDescription
        let notifying = characteristic.isNotifying
        MainActor.assumeIsolated {
            if let message {
                // Typical when the pedal has not been put in pairing mode / pairing was refused.
                state = .failed("Could not enable notifications (\(message)). Repeat pairing on the pedal.")
                return
            }
            guard notifying else { return }
            appendLog(.info, "C305 notifications enabled")
            Task { await self.didBecomeNotifying() }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        MainActor.assumeIsolated { handleNotification(data) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if let message { appendLog(.info, "Write failed: \(message)") }
            writeInFlight = false
            pumpWrites()
        }
    }
}
