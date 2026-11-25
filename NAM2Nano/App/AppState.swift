import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Centralised wizard state machine.
@MainActor
@Observable
final class AppState {

    enum Step: Int, CaseIterable, Identifiable, Comparable {
        case usb, bluetooth, cabling, nam, metadata, capture

        var id: Int { rawValue }
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .usb: return "USB-C"
            case .bluetooth: return "Bluetooth"
            case .cabling: return "Cabling"
            case .nam: return ".nam file"
            case .metadata: return "Metadata"
            case .capture: return "Capture"
            }
        }

        var symbol: String {
            switch self {
            case .usb: return "cable.connector"
            case .bluetooth: return "dot.radiowaves.left.and.right"
            case .cabling: return "point.3.connected.trianglepath.dotted"
            case .nam: return "waveform.path.ecg"
            case .metadata: return "tag"
            case .capture: return "record.circle"
            }
        }
    }

    enum CableCheck: Equatable {
        case notRun
        case running(String)
        case finished(ContinuityResult)
        case skipped

        var passed: Bool {
            switch self {
            case .finished(let r): return r.isSuccess
            case .skipped: return true
            default: return false
            }
        }
    }

    enum ModelLoad: Equatable {
        case none
        case parsing
        case loading
        case loaded(sampleRate: Double, resampling: Bool, latencyMs: Double)
        case failed(String)
    }

    // MARK: State

    var step: Step = .usb
    let settings: AppSettings
    let deviceMonitor = AudioDeviceMonitor()
    let audio: NanoAudioEngine
    let ble: NanoBLEManager
    let capture = CaptureSession()
    let calibrator: SignalCalibrator

    var cableCheck: CableCheck = .notRun
    private(set) var audioError: String?

    private(set) var namInfo: NAMModelInfo?
    private(set) var modelLoad: ModelLoad = .none
    private(set) var gainStaging: GainStaging?
    var metadata = NanoCaptureMetadata()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var audioStartTask: Task<Bool, Never>?

    init() {
        let settings = AppSettings()
        let audio = NanoAudioEngine()
        let ble = NanoBLEManager()
        self.settings = settings
        self.audio = audio
        self.ble = ble
        self.calibrator = SignalCalibrator(audio: audio, ble: ble, settings: settings)
    }

    // MARK: Derived

    var usbReady: Bool { (deviceMonitor.nano?.isAt48k ?? false) && audio.runState.isRunning }
    var bleReady: Bool { ble.isReady }
    var hardwareReady: Bool { usbReady && bleReady && cableCheck.passed }

    func isSatisfied(_ s: Step) -> Bool {
        switch s {
        case .usb: return usbReady
        case .bluetooth: return bleReady
        case .cabling: return cableCheck.passed
        case .nam: if case .loaded = modelLoad { return namInfo != nil } else { return false }
        case .metadata: return metadata.isNameValid
        case .capture: if case .done = capture.phase { return true } else { return false }
        }
    }

    var canContinue: Bool { isSatisfied(step) && step != .capture }

    /// A step is reachable when every previous step is satisfied.
    func isReachable(_ s: Step) -> Bool {
        Step.allCases.filter { $0 < s }.allSatisfy(isSatisfied)
    }

    // MARK: Lifecycle

    func onLaunch() {
        guard !started else { return }
        started = true
        deviceMonitor.start()
        applyRouting()
        observeDevice()
        Task { await deviceChanged() }
    }

    /// Reacts to the Nano appearing / disappearing on USB.
    private func observeDevice() {
        withObservationTracking {
            _ = deviceMonitor.nano
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeDevice()
                await self.deviceChanged()
            }
        }
    }

    private func deviceChanged() async {
        guard let nano = deviceMonitor.nano else {
            if audio.runState.isRunning {
                if capture.phase.isActive { capture.cancel(app: self) }
                audio.stop()
            }
            return
        }
        if audio.device?.id != nano.id || !audio.runState.isRunning {
            _ = await ensureAudioRunning()
        }
    }

    /// Starts the AUHAL on the Nano if needed. Concurrent callers share one start attempt.
    @discardableResult
    func ensureAudioRunning() async -> Bool {
        if audio.runState.isRunning { return true }
        if let pending = audioStartTask { return await pending.value }
        guard let nano = deviceMonitor.nano else { audioError = "Nano Cortex not connected."; return false }
        let task = Task { @MainActor () -> Bool in
            do {
                self.applyRouting()
                try await self.audio.start(device: nano, bufferFrames: UInt32(self.settings.bufferFrames))
                self.audioError = nil
                return true
            } catch {
                self.audioError = error.localizedDescription
                return false
            }
        }
        audioStartTask = task
        let ok = await task.value
        audioStartTask = nil
        return ok
    }

    func restartAudio() async {
        audio.stop()
        _ = await ensureAudioRunning()
    }

    func applyRouting() {
        audio.setRouting(sourceChannel: max(0, settings.sourceChannel - 1), outputChannel: max(0, settings.outputChannel - 1))
    }

    // MARK: Navigation

    func goNext() {
        guard canContinue, let next = Step(rawValue: step.rawValue + 1) else { return }
        go(to: next)
    }

    func goBack() {
        guard !capture.phase.isActive, let prev = Step(rawValue: step.rawValue - 1) else { return }
        go(to: prev)
    }

    func go(to target: Step) {
        guard isReachable(target), !capture.phase.isActive else { return }
        step = target
        switch target {
        case .bluetooth:
            if !ble.isReady { ble.start() }
        case .cabling:
            Task { await ensureAudioRunning() }
        case .metadata:
            if metadata.name.isEmpty, let info = namInfo { metadata = .prefilled(from: info) }
        case .capture:
            switch capture.phase {
            case .failed, .cancelled: capture.reset()
            default: break
            }
        default:
            break
        }
    }

    /// "Capture another .nam file": keep USB, BLE and cable verification, restart from step 4.
    func captureAnother() {
        capture.reset()
        audio.goSilent()
        audio.unloadModel()
        namInfo = nil
        modelLoad = .none
        gainStaging = nil
        metadata = NanoCaptureMetadata()
        step = .nam
    }

    // MARK: Step 3

    func runCableCheck() {
        guard !(cableCheckIsRunning) else { return }
        cableCheck = .running("Preparing…")
        Task {
            guard await ensureAudioRunning() else {
                cableCheck = .finished(.failed(audioError ?? "Audio unavailable"))
                return
            }
            let result = await calibrator.runContinuityTest { [weak self] message in
                self?.cableCheck = .running(message)
            }
            cableCheck = .finished(result)
        }
    }

    var cableCheckIsRunning: Bool { if case .running = cableCheck { return true } else { return false } }

    func skipCableCheck() { cableCheck = .skipped }

    // MARK: Step 4

    func selectNAM(url: URL) {
        guard !capture.phase.isActive else { return }
        modelLoad = .parsing
        namInfo = nil
        gainStaging = nil
        metadata = NanoCaptureMetadata()
        Task {
            do {
                let info = try await Task.detached(priority: .userInitiated) { try NAMParser.parse(url: url) }.value
                namInfo = info
                gainStaging = GainStaging.compute(for: info, settings: settings)
                modelLoad = .loading
                audio.goSilent()
                let result = try await audio.loadModel(at: url)
                modelLoad = .loaded(sampleRate: result.modelSampleRate, resampling: result.resampling,
                                    latencyMs: result.resamplerLatencyMs)
            } catch {
                modelLoad = .failed(error.localizedDescription)
            }
        }
    }

    func recomputeGainStaging() {
        if let info = namInfo { gainStaging = GainStaging.compute(for: info, settings: settings) }
    }

    func chooseNAMWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nam") ?? .namModel]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Choose a Neural Amp Modeler model"
        if panel.runModal() == .OK, let url = panel.url { selectNAM(url: url) }
    }
}
