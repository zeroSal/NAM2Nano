import Foundation

/// Technical summary of a `.nam` file, produced by `NAMParser` without touching the audio thread.
struct NAMModelInfo: Equatable, Sendable {

    enum Family: String, Sendable {
        case wavenet = "WaveNet"
        case lstm = "LSTM"
        case convnet = "ConvNet"
        case linear = "Linear (IR)"
        case sequential = "Sequential"
        case unknown = "Unknown"
    }

    enum Generation: Equatable, Sendable {
        /// Classic NAM trainer architectures. `size` = Standard / Lite / Feather / Nano when recognised.
        case a1(size: String?)
        /// A2 family. `variant` = "A2-Full", "A2-Lite" or "A2 (feature set)".
        case a2(variant: String)
        case notApplicable

        var label: String {
            switch self {
            case .a1(let size): return size.map { "Standard A1 · \($0)" } ?? "Standard A1"
            case .a2(let variant): return variant
            case .notApplicable: return "—"
            }
        }

        var isA2: Bool { if case .a2 = self { return true } else { return false } }
    }

    var fileURL: URL
    var fileSize: Int64
    var name: String
    var fileVersion: String
    /// Raw top-level `architecture` string (e.g. "SlimmableContainer").
    var rawArchitecture: String
    var family: Family
    var generation: Generation
    var isSlimmable: Bool
    var architectureDetail: String
    /// `nil` when the file does not declare it (very old files: NAM assumes 48 kHz).
    var declaredSampleRate: Double?
    var parameterCount: Int?

    var inputLevelDBu: Double?
    var outputLevelDBu: Double?
    var loudness: Double?
    var gain: Double?

    var modeledBy: String?
    var gearType: String?
    var gearMake: String?
    var gearModel: String?
    var toneType: String?
    var date: Date?
    var validationESR: Double?
    var recommendedLatency: Int?

    // MARK: Derived

    static let nanoSampleRate: Double = 48_000

    var sampleRate: Double { declaredSampleRate ?? Self.nanoSampleRate }
    var needsResampling: Bool { abs(sampleRate - Self.nanoSampleRate) > 0.5 }

    var displayArchitecture: String {
        isSlimmable ? "\(family.rawValue) (Slimmable)" : family.rawValue
    }

    var gearDescription: String? {
        let parts = [gearMake, gearModel].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Text suggested for the capture's notes.
    var suggestedNotes: String {
        var parts = ["NAM \(displayArchitecture)", generation.label]
        if let gear = gearDescription { parts.append(gear) }
        if let by = modeledBy, !by.isEmpty { parts.append("by \(by)") }
        return parts.joined(separator: " · ")
    }
}
