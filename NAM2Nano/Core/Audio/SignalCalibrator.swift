import Foundation

/// Digital gain staging derived from the `.nam` metadata (step 4 "pre-calibration").
struct GainStaging: Equatable {
    var inputTrimDB: Double
    var outputTrimDB: Double
    var notes: [String]

    /// Expected peak level leaving the Mac (very rough: loudness + trim + ~12 dB crest factor).
    var predictedPeakDBFS: Double?

    @MainActor
    static func compute(for model: NAMModelInfo, settings: AppSettings) -> GainStaging {
        var notes: [String] = []
        var inputTrim = 0.0
        if settings.applyInputCalibration, let modelIn = model.inputLevelDBu {
            inputTrim = max(-24, min(24, settings.usbReferenceDBu - modelIn))
            notes.append(String(format: "Input: model captured with 0 dBFS = %.1f dBu, Nano USB reference %.1f dBu → %+.1f dB.",
                                modelIn, settings.usbReferenceDBu, inputTrim))
        } else if model.inputLevelDBu == nil {
            notes.append("Input: the file has no input_level_dbu, no input calibration applied.")
        }

        var outputTrim = 0.0
        var predicted: Double?
        if let loudness = model.loudness {
            outputTrim = max(-30, min(24, settings.targetLoudnessDB - loudness))
            predicted = loudness + outputTrim + 12
            notes.append(String(format: "Output: model loudness %.1f dB → normalized to %.0f dB (%+.1f dB).",
                                loudness, settings.targetLoudnessDB, outputTrim))
        } else {
            notes.append("Output: no loudness data, the level will be set by the CAPTURE IN auto-level.")
        }
        if settings.autoLevelCaptureIn {
            notes.append("Before capturing, the Nano's CAPTURE IN gain is set over Bluetooth so peaks sit in the green/yellow zone, with no clipping.")
        }
        return GainStaging(inputTrimDB: inputTrim, outputTrimDB: outputTrim, notes: notes, predictedPeakDBFS: predicted)
    }
}

enum ContinuityResult: Equatable {
    case verified(baseline: Int, tone: Int)
    case noSignal(baseline: Int, tone: Int)
    case feedback(baseline: Int, after: Int)
    case noTelemetry(String)
    case failed(String)

    var isSuccess: Bool { if case .verified = self { return true } else { return false } }

    var message: String {
        switch self {
        case .verified(let b, let t):
            return "Audio loop verified (CAPTURE IN meter \(b) → \(t)/255)."
        case .noSignal(let b, let t):
            return "The pilot tone does not reach CAPTURE IN (meter \(b) → \(t)/255). Check the OUT 1L → CAPTURE IN cable and the master volume."
        case .feedback(let b, let a):
            return "The signal stays high after the tone stops (\(b) → \(a)/255): possible feedback loop (is OUT 1L monitoring CAPTURE IN?)."
        case .noTelemetry(let why):
            return "Automatic check unavailable: \(why)"
        case .failed(let why):
            return why
        }
    }
}

struct AutoLevelResult: Equatable {
    var captureInRaw: Int
    var peakRaw: Int
    var extraOutputTrimDB: Double
}

/// Cable continuity test (step 3) and automatic CAPTURE IN gain staging (step 6).
///
/// Both rely on the Nano's capture meters (BLE message 64), which the pedal only
/// streams while in capture mode, so each routine enters capture mode first.
@MainActor
final class SignalCalibrator {

    private let audio: NanoAudioEngine
    private let ble: NanoBLEManager
    private let settings: AppSettings

    /// Meter window regarded as "green/yellow" on CAPTURE IN (raw 0...255; > 240 shows red in Cortex Cloud).
    static let targetPeak = 165...215

    init(audio: NanoAudioEngine, ble: NanoBLEManager, settings: AppSettings) {
        self.audio = audio
        self.ble = ble
        self.settings = settings
    }

    // MARK: Capture mode

    func enterCaptureMode() async -> Bool {
        if ble.captureMode { return true }
        ble.send(NanoCommand.enterCaptureMode, label: "Enter capture mode")
        try? await Task.sleep(for: .milliseconds(500))
        ble.requestState()
        let event = await ble.waitFor(timeout: 4) { event in
            switch event {
            case .state(let capture, _, _, _): return capture
            case .meter, .captureState: return true
            default: return false
            }
        }
        return event != nil || ble.captureMode
    }

    /// Sends EXIT until the Nano reports play mode (or gives up after `maxExits`).
    func exitCaptureMode(maxExits: Int = 4) async {
        for _ in 0..<maxExits {
            guard ble.isReady else { return }
            ble.send(NanoCommand.exitStep, label: "Exit")
            try? await Task.sleep(for: .milliseconds(900))
            ble.requestState()
            let reply = await ble.waitFor(timeout: 1.5) { if case .state = $0 { return true } else { return false } }
            if case .state(let capture, _, _, _)? = reply, !capture { return }
            if reply == nil, let last = ble.lastMeterDate, Date().timeIntervalSince(last) > 1.2 { return }
        }
    }

    // MARK: Meter sampling

    struct MeterWindow {
        var maxRaw = 0
        var updates = 0
    }

    func sampleCaptureIn(seconds: Double) async -> MeterWindow {
        var window = MeterWindow()
        let end = Date().addingTimeInterval(seconds)
        var lastStamp = ble.lastMeterDate
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(20))
            if ble.lastMeterDate != lastStamp {
                lastStamp = ble.lastMeterDate
                window.updates += 1
                window.maxRaw = max(window.maxRaw, ble.captureInMeter)
            }
        }
        return window
    }

    // MARK: Step 3 — continuity

    func runContinuityTest(progress: (String) -> Void) async -> ContinuityResult {
        guard ble.isReady else { return .failed("Bluetooth not connected.") }
        guard audio.runState.isRunning else { return .failed("Audio engine not running (Nano USB).") }
        let p = audio.processor

        progress("Putting the Nano into capture mode…")
        guard await enterCaptureMode() else {
            return .noTelemetry("the Nano did not enter capture mode over Bluetooth.")
        }
        ble.send(NanoCommand.setCaptureValue(.captureInGain, raw: 128), label: "CAPTURE IN = 128")
        try? await Task.sleep(for: .milliseconds(300))

        progress("Measuring the noise floor…")
        audio.goSilent()
        let baseline = await sampleCaptureIn(seconds: 0.7)
        guard baseline.updates > 0 else {
            await exitCaptureMode()
            return .noTelemetry("no meter data from the Nano (message 64).")
        }

        progress("Sending a 1 kHz pilot tone to OUT 1L…")
        p.toneFrequency = 1000
        p.generatorLevelDB = Float(settings.pilotLevelDB)
        p.processThroughModel = false
        p.inputGainDB = 0
        p.outputGainDB = 0
        p.sourceMode = .sine
        p.outputMuted = false
        try? await Task.sleep(for: .milliseconds(300))
        let tone = await sampleCaptureIn(seconds: 0.9)
        let sentDB = audio.meters.outputDB

        progress("Checking for feedback…")
        audio.goSilent()
        try? await Task.sleep(for: .milliseconds(400))
        let after = await sampleCaptureIn(seconds: 0.6)

        progress("Leaving capture mode…")
        await exitCaptureMode()

        if sentDB < Float(settings.pilotLevelDB) - 12 {
            return .failed("The Mac is not sending the tone (output \(Int(sentDB)) dBFS): check the output channel in Settings.")
        }
        let rise = tone.maxRaw - baseline.maxRaw
        if rise >= 25, tone.maxRaw >= 20 {
            if after.maxRaw > baseline.maxRaw + 25 { return .feedback(baseline: baseline.maxRaw, after: after.maxRaw) }
            return .verified(baseline: baseline.maxRaw, tone: tone.maxRaw)
        }
        return .noSignal(baseline: baseline.maxRaw, tone: tone.maxRaw)
    }

    // MARK: Step 6 — auto level

    /// Plays pink noise through the loaded model (same gains as the capture) and binary-searches
    /// the Nano's CAPTURE IN gain so the meter peaks inside `targetPeak`. Requires capture mode.
    func autoLevelCaptureIn(baseOutputTrimDB: Double, progress: (String) -> Void) async -> AutoLevelResult? {
        let p = audio.processor
        var extraTrim = 0.0
        p.generatorLevelDB = -20 // RMS: roughly a guitar DI played hard
        p.sourceMode = .pinkNoise
        p.processThroughModel = audio.loadedModel != nil
        p.outputMuted = false
        defer { audio.goSilent() }

        for attempt in 0..<3 {
            p.outputGainDB = Float(baseOutputTrimDB + extraTrim)
            var lo = 0, hi = 255
            var best: (raw: Int, peak: Int)?
            for _ in 0..<8 where lo <= hi {
                if Task.isCancelled { return nil }
                let mid = (lo + hi) / 2
                progress("Auto-level CAPTURE IN: gain \(Int(NanoCommand.captureInDB(raw: mid).rounded())) dB (attempt \(attempt + 1))")
                ble.send(NanoCommand.setCaptureValue(.captureInGain, raw: mid), label: "CAPTURE IN = \(mid)")
                try? await Task.sleep(for: .milliseconds(350))
                let w = await sampleCaptureIn(seconds: 0.6)
                guard w.updates > 0 else { return nil }
                if Self.targetPeak.contains(w.maxRaw) { return AutoLevelResult(captureInRaw: mid, peakRaw: w.maxRaw, extraOutputTrimDB: extraTrim) }
                if w.maxRaw > Self.targetPeak.upperBound { hi = mid - 1 } else { lo = mid + 1 }
                if best == nil || abs(w.maxRaw - 190) < abs(best!.peak - 190) { best = (mid, w.maxRaw) }
            }
            // Out of range at the gain limits: change our digital output and retry.
            if lo > 255 {
                // Too quiet even at max CAPTURE IN gain: raise output, but keep >= 3 dB headroom.
                let headroom = -3 - Double(audio.meters.outputDB)
                guard headroom > 1 else { break }
                extraTrim += min(6, headroom)
            } else if hi < 0 {
                extraTrim -= 6 // too hot even at 0 dB CAPTURE IN gain
            } else if let best {
                return AutoLevelResult(captureInRaw: best.raw, peakRaw: best.peak, extraOutputTrimDB: extraTrim)
            }
        }
        return nil
    }
}
