import Foundation
import Observation

/// Persisted record of a finished capture (keeps the fields the Nano cannot store:
/// gain character / level, notes, source .nam).
struct CaptureRecord: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var namFile: String
    var architecture: String
    var metadata: NanoCaptureMetadata
    var captureInRaw: Int?
    var savedToSlot: Int?
}

enum CaptureHistoryStore {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NAM2Nano", isDirectory: true).appendingPathComponent("history.json")
    }

    static func load() -> [CaptureRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CaptureRecord].self, from: data)) ?? []
    }

    static func append(_ record: CaptureRecord) {
        var all = load()
        all.append(record)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(all).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("NAM2Nano: history not saved: \(error)")
        }
    }
}

/// Mutable flags shared between the event listener task and the training loop.
@MainActor
private final class TrainingFlags {
    var done = false
    var sanity: Int?
    var exitPressed = false
}

/// Orchestrates step 6: capture mode → CAPTURE IN auto-level → training with the NAM model
/// in the loop → save (+ optional slot) → back to play mode.
@MainActor
@Observable
final class CaptureSession {

    enum Phase: Equatable {
        case idle
        case preparing(String)
        case levelling(String)
        case training
        case saving(String)
        case done(String)
        case failed(String)
        case cancelled

        var isActive: Bool {
            switch self {
            case .preparing, .levelling, .training, .saving: return true
            default: return false
            }
        }
    }

    private(set) var phase: Phase = .idle
    /// 0...1 from TrainingProgress (raw/255). The Nano reports done around raw ≈ 220.
    private(set) var progress: Double = 0
    private(set) var startedAt: Date?
    private(set) var warning: String?
    private(set) var captureInRaw: Int?

    /// UI label. The Nano only streams a single 0-255 progress value; the stage names
    /// are an approximation of what the pedal does over the ~5 minutes.
    var stageLabel: String {
        guard case .training = phase else { return "" }
        switch progress {
        case ..<0.04: return "Calibration"
        case ..<0.30: return "Profiling"
        case ..<0.82: return "Neural network training"
        default: return "Finalizing"
        }
    }

    @ObservationIgnored private var task: Task<Void, Never>?

    func start(app: AppState) {
        guard !phase.isActive else { return }
        warning = nil
        progress = 0
        captureInRaw = nil
        startedAt = nil
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(app: app)
        }
    }

    func cancel(app: AppState) {
        guard phase.isActive else { return }
        task?.cancel()
        task = nil
        app.audio.goSilent()
        phase = .cancelled
        Task { await app.calibrator.exitCaptureMode() }
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        progress = 0
        warning = nil
        startedAt = nil
    }

    // MARK: - Flow

    private func fail(_ message: String, app: AppState) async {
        app.audio.goSilent()
        phase = .failed(message)
        await app.calibrator.exitCaptureMode()
    }

    private func run(app: AppState) async {
        let audio = app.audio
        let ble = app.ble
        let settings = app.settings
        let p = audio.processor

        // 1) Audio + model
        phase = .preparing("Configuring the audio engine…")
        guard await app.ensureAudioRunning() else {
            phase = .failed("Audio engine unavailable: \(audio.runState)")
            return
        }
        guard audio.loadedModel != nil, let staging = app.gainStaging else {
            phase = .failed("No .nam model loaded.")
            return
        }
        guard ble.isReady else {
            phase = .failed("Bluetooth not connected to the Nano Cortex.")
            return
        }
        audio.goSilent()
        app.applyRouting()
        p.inputGainDB = Float(staging.inputTrimDB)
        p.outputGainDB = Float(staging.outputTrimDB)
        var outputTrim = staging.outputTrimDB

        // 2) Capture mode
        phase = .preparing("Putting the Nano into capture mode…")
        guard await app.calibrator.enterCaptureMode() else {
            await fail("The Nano did not enter capture mode. Try again or use the BLE Monitor (Debug menu).", app: app)
            return
        }
        if Task.isCancelled { return }

        // 3) CAPTURE IN auto-level
        if settings.autoLevelCaptureIn {
            phase = .levelling("Auto-level CAPTURE IN…")
            if let result = await app.calibrator.autoLevelCaptureIn(baseOutputTrimDB: outputTrim, progress: { [weak self] in
                self?.phase = .levelling($0)
            }) {
                captureInRaw = result.captureInRaw
                outputTrim += result.extraOutputTrimDB
                p.outputGainDB = Float(outputTrim)
            } else {
                warning = "Auto-level failed: adjust CAPTURE IN on the pedal if the Nano reports a wrong level."
            }
        }
        if Task.isCancelled { return }

        // 4) Training with the model in the loop
        p.sourceMode = .usbInput
        p.processThroughModel = true
        p.outputMuted = false

        let flags = TrainingFlags()
        let listener = Task { @MainActor [weak self] in
            for await event in ble.events() {
                switch event {
                case .trainingProgress(let raw):
                    self?.progress = min(1, Double(raw) / 255)
                case .captureState(let step, let raw):
                    if step == 2 { self?.progress = min(1, Double(raw) / 255) }
                    if step == 3 { flags.done = true }
                case .trainingDone: flags.done = true
                case .sanity(let status): flags.sanity = status
                case .button(0): flags.exitPressed = true
                default: break
                }
                if flags.done || flags.sanity != nil || flags.exitPressed { break }
            }
        }
        defer { listener.cancel() }

        ble.send(NanoCommand.startTraining, label: "Start training")
        startedAt = Date()
        phase = .training

        var sourceChecked = false
        while !flags.done {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            if let s = flags.sanity {
                await fail(s == 1
                    ? "The Nano reports the CAPTURE IN signal is too hot. Lower the gain and try again."
                    : "The Nano reports no signal or too low a signal on CAPTURE IN. Check cable/channels and try again.", app: app)
                return
            }
            if flags.exitPressed {
                audio.goSilent()
                phase = .cancelled
                return
            }
            if !ble.isReady {
                audio.goSilent()
                phase = .failed("Bluetooth connection lost during the capture.")
                return
            }
            let elapsed = Date().timeIntervalSince(startedAt ?? Date())
            if !sourceChecked, elapsed > 3 {
                sourceChecked = true
                checkSourceChannel(app: app)
            }
            if elapsed > 12 * 60 {
                await fail("Timeout: not completed after 12 minutes.", app: app)
                return
            }
        }

        // 5) Save
        audio.goSilent()
        progress = 1
        let meta = app.metadata
        phase = .saving("Saving to My Neural Captures…")
        ble.send(NanoCommand.saveCapture(name: meta.trimmedName, firmwareType: meta.category.firmwareType), label: "Save capture")
        let saveReply = await ble.waitFor(timeout: 12) { if case .saveResponse = $0 { return true } else { return false } }
        guard case .saveResponse(let ok, let captureID, let reason)? = saveReply else {
            await fail("The Nano did not confirm the save (no reply). You can save on the pedal by holding SAVE.", app: app)
            return
        }
        guard ok else {
            await fail("The Nano rejected the save" + (reason.map { " (\($0))" } ?? "") + ". Name already in use or library full?", app: app)
            return
        }

        var savedSlot: Int?
        var summary = "\"\(meta.trimmedName)\" saved to My Neural Captures"
        if case .slot(let slot) = meta.target {
            if let captureID {
                phase = .saving("Loading into slot \(CaptureTarget.bankSlotLabel(slot))…")
                ble.send(NanoCommand.setCaptureSlot(slot, captureID: captureID), label: "Capture → slot \(slot)")
                let slotReply = await ble.waitFor(timeout: 8) { if case .slotResponse = $0 { return true } else { return false } }
                if case .slotResponse(true)? = slotReply {
                    savedSlot = slot
                    summary += " and loaded into slot \(CaptureTarget.bankSlotLabel(slot))"
                } else {
                    summary += " (slot unchanged: the Nano did not confirm)"
                }
            } else {
                summary += " (slot unchanged: no capture id in the reply)"
            }
        }

        // 6) Back to play mode + history
        await app.calibrator.exitCaptureMode()
        CaptureHistoryStore.append(CaptureRecord(
            date: Date(),
            namFile: app.namInfo?.fileURL.lastPathComponent ?? "?",
            architecture: app.namInfo.map { "\($0.displayArchitecture) · \($0.generation.label)" } ?? "?",
            metadata: meta,
            captureInRaw: captureInRaw,
            savedToSlot: savedSlot))
        phase = .done(summary + ".")
    }

    /// If the configured USB source stays silent after training started, optionally switch to
    /// the loudest other input (never the channel that mirrors our own output: feedback).
    private func checkSourceChannel(app: AppState) {
        let audio = app.audio
        let settings = app.settings
        let levels = audio.inputChannelDB
        let current = settings.sourceChannel - 1
        guard current >= 0, current < levels.count else { return }
        if levels[current] > -60 { return }

        let excluded: Set<Int> = [current, settings.loopMonitorChannel - 1]
        let candidate = levels.enumerated()
            .filter { !excluded.contains($0.offset) && $0.element > -50 }
            .max { $0.element < $1.element }

        if settings.autoDetectSource, let candidate {
            settings.sourceChannel = candidate.offset + 1
            app.applyRouting()
            warning = "No signal on USB channel \(current + 1): switched automatically to channel \(candidate.offset + 1)."
        } else {
            warning = "No test signal on USB channel \(current + 1). Check the routing in Settings (⌘,)."
        }
    }
}
