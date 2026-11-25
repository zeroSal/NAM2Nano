import Foundation

/// Device category shown in the UI. The Nano Cortex firmware only knows four capture
/// types (`amp_head`, `amp_and_cab`, `cab`, `pedal` — as decoded from Cortex Cloud by
/// the nano-cortex-editor project), so the richer UI categories map onto those.
enum NanoDeviceCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case ampHead
    case ampAndCab
    case combo
    case pedal
    case preamp
    case cab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ampHead: return "Amp Head"
        case .ampAndCab: return "Amp + Cab"
        case .combo: return "Combo"
        case .pedal: return "Pedal / Overdrive"
        case .preamp: return "Preamp"
        case .cab: return "Cab"
        }
    }

    var symbol: String {
        switch self {
        case .ampHead: return "rectangle.split.3x1"
        case .ampAndCab: return "square.stack"
        case .combo: return "hifispeaker"
        case .pedal: return "slider.horizontal.below.square.filled.and.square"
        case .preamp: return "dial.medium"
        case .cab: return "speaker.wave.2"
        }
    }

    /// Value written into the SaveCapture record (field 6).
    var firmwareType: String {
        switch self {
        case .ampHead, .preamp: return "amp_head"
        case .ampAndCab, .combo: return "amp_and_cab"
        case .pedal: return "pedal"
        case .cab: return "cab"
        }
    }

    /// Best guess from the `.nam` metadata `gear_type` field.
    static func from(namGearType: String?) -> NanoDeviceCategory {
        switch namGearType?.lowercased() {
        case "amp": return .ampHead
        case "amp_cab", "amp_and_cab": return .ampAndCab
        case "pedal", "pedal_amp": return .pedal
        case "preamp": return .preamp
        case "studio": return .preamp
        default: return .ampAndCab
        }
    }
}

enum GainCharacter: String, CaseIterable, Identifiable, Codable, Sendable {
    case clean, crunch, highGain

    var id: String { rawValue }
    var title: String {
        switch self {
        case .clean: return "Clean"
        case .crunch: return "Crunch"
        case .highGain: return "High Gain"
        }
    }

    static func from(namToneType: String?) -> GainCharacter {
        switch namToneType?.lowercased() {
        case "clean": return .clean
        case "crunch", "overdrive": return .crunch
        case "hi_gain", "high_gain", "fuzz", "distortion": return .highGain
        default: return .crunch
        }
    }
}

/// Where the finished capture goes.
enum CaptureTarget: Hashable, Codable, Sendable {
    /// Only "My Neural Captures" (the Nano's internal library).
    case library
    /// Library + loaded into capture slot 1...25 (bank 1-5 × slot 1-5).
    case slot(Int)

    var title: String {
        switch self {
        case .library: return "Capture Library only"
        case .slot(let s): return "Slot \(CaptureTarget.bankSlotLabel(s))"
        }
    }

    static func bankSlotLabel(_ slot: Int) -> String {
        "\((slot - 1) / 5 + 1)–\((slot - 1) % 5 + 1)"
    }

    static let slotRange = 1...25
}

/// Metadata the user fills in at step 5 and that is written to the Nano at the end.
struct NanoCaptureMetadata: Equatable, Codable, Sendable {
    /// The nano-cortex-editor enforces >= 4 characters (the Nano rejects shorter names).
    static let nameMinLength = 4
    /// Firmware limit not documented; 32 is a conservative cap (Cortex Cloud UI).
    static let nameMaxLength = 32

    var name: String = ""
    var category: NanoDeviceCategory = .ampAndCab
    var gainCharacter: GainCharacter = .crunch
    var gainLevel: Double = 5
    var notes: String = ""
    var target: CaptureTarget = .library

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isNameValid: Bool {
        let n = trimmedName
        return n.count >= Self.nameMinLength && n.count <= Self.nameMaxLength
    }

    /// Prefill from a parsed `.nam`.
    static func prefilled(from info: NAMModelInfo) -> NanoCaptureMetadata {
        var m = NanoCaptureMetadata()
        var name = info.name
        if name.count > nameMaxLength { name = String(name.prefix(nameMaxLength)) }
        while name.count < nameMinLength { name += " NAM" }
        m.name = name
        m.category = .from(namGearType: info.gearType)
        m.gainCharacter = .from(namToneType: info.toneType)
        m.gainLevel = m.gainCharacter == .clean ? 2 : (m.gainCharacter == .crunch ? 5 : 8)
        m.notes = info.suggestedNotes
        return m
    }
}
