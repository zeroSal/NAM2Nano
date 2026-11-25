import Foundation
import Observation

/// User-tunable routing and calibration settings (persisted in UserDefaults).
///
/// Channel numbers are 1-based as shown in Audio MIDI Setup. Defaults follow the
/// published Nano Cortex USB layout (In 1/2 = dry DI, In 3/4 = processed OUTPUT 1L/2R,
/// OUTPUT 2R doubling as CAPTURE OUT in capture mode) — verify on real hardware.
@MainActor
@Observable
final class AppSettings {

    private enum Key {
        static let sourceChannel = "sourceChannel"
        static let outputChannel = "outputChannel"
        static let autoDetectSource = "autoDetectSource"
        static let loopMonitorChannel = "loopMonitorChannel"
        static let bufferFrames = "bufferFrames"
        static let usbReferenceDBu = "usbReferenceDBu"
        static let applyInputCalibration = "applyInputCalibration"
        static let targetLoudnessDB = "targetLoudnessDB"
        static let autoLevelCaptureIn = "autoLevelCaptureIn"
        static let pilotLevelDB = "pilotLevelDB"
    }

    private let defaults: UserDefaults

    /// USB input carrying the Nano's capture test signal (CAPTURE OUT = OUTPUT 2R processed).
    var sourceChannel: Int { didSet { defaults.set(sourceChannel, forKey: Key.sourceChannel) } }
    /// USB output that reaches the OUTPUT 1L jack.
    var outputChannel: Int { didSet { defaults.set(outputChannel, forKey: Key.outputChannel) } }
    /// If the source channel stays silent once training starts, switch to the loudest other input.
    var autoDetectSource: Bool { didSet { defaults.set(autoDetectSource, forKey: Key.autoDetectSource) } }
    /// USB input mirroring OUTPUT 1L (our own output): never chosen by auto-detect (feedback).
    var loopMonitorChannel: Int { didSet { defaults.set(loopMonitorChannel, forKey: Key.loopMonitorChannel) } }
    var bufferFrames: Int { didSet { defaults.set(bufferFrames, forKey: Key.bufferFrames) } }
    /// dBu corresponding to 0 dBFS on the Nano's USB input. Not documented by Neural DSP:
    /// used only for NAM input-level calibration, adjust after measuring.
    var usbReferenceDBu: Double { didSet { defaults.set(usbReferenceDBu, forKey: Key.usbReferenceDBu) } }
    var applyInputCalibration: Bool { didSet { defaults.set(applyInputCalibration, forKey: Key.applyInputCalibration) } }
    /// Model output normalised to this loudness (like the NAM plugin's output normalisation).
    var targetLoudnessDB: Double { didSet { defaults.set(targetLoudnessDB, forKey: Key.targetLoudnessDB) } }
    /// Set the Nano's CAPTURE IN gain automatically (via BLE) before training.
    var autoLevelCaptureIn: Bool { didSet { defaults.set(autoLevelCaptureIn, forKey: Key.autoLevelCaptureIn) } }
    /// Pilot tone level for the cable test (dBFS peak).
    var pilotLevelDB: Double { didSet { defaults.set(pilotLevelDB, forKey: Key.pilotLevelDB) } }

    static let bufferChoices = [64, 128, 256, 512, 1024]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.sourceChannel: 4,
            Key.outputChannel: 1,
            Key.autoDetectSource: true,
            Key.loopMonitorChannel: 3,
            Key.bufferFrames: 256,
            Key.usbReferenceDBu: 12.0,
            Key.applyInputCalibration: true,
            Key.targetLoudnessDB: -18.0,
            Key.autoLevelCaptureIn: true,
            Key.pilotLevelDB: -18.0,
        ])
        sourceChannel = defaults.integer(forKey: Key.sourceChannel)
        outputChannel = defaults.integer(forKey: Key.outputChannel)
        autoDetectSource = defaults.bool(forKey: Key.autoDetectSource)
        loopMonitorChannel = defaults.integer(forKey: Key.loopMonitorChannel)
        bufferFrames = defaults.integer(forKey: Key.bufferFrames)
        usbReferenceDBu = defaults.double(forKey: Key.usbReferenceDBu)
        applyInputCalibration = defaults.bool(forKey: Key.applyInputCalibration)
        targetLoudnessDB = defaults.double(forKey: Key.targetLoudnessDB)
        autoLevelCaptureIn = defaults.bool(forKey: Key.autoLevelCaptureIn)
        pilotLevelDB = defaults.double(forKey: Key.pilotLevelDB)
    }

    func resetToDefaults() {
        sourceChannel = 4
        outputChannel = 1
        autoDetectSource = true
        loopMonitorChannel = 3
        bufferFrames = 256
        usbReferenceDBu = 12
        applyInputCalibration = true
        targetLoudnessDB = -18
        autoLevelCaptureIn = true
        pilotLevelDB = -18
    }
}
