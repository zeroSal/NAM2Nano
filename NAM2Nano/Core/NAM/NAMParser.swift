import Foundation

enum NAMParserError: LocalizedError {
    case unreadable(String)
    case notAJSONObject
    case missingKey(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "Could not read the file: \(why)"
        case .notAJSONObject: return "The file is not a valid .nam model (unrecognized JSON)."
        case .missingKey(let key): return "The .nam file is missing the required field \"\(key)\"."
        }
    }
}

/// Reads a `.nam` JSON file and extracts a technical summary (architecture family,
/// A1 vs A2 generation, sample rate, calibration levels, metadata). Never loads the
/// model into the DSP engine.
///
/// A2 detection mirrors NeuralAmpModelerCore's `wavenet::a2_fast::is_a2_shape`
/// (one layer array, 23 layers, per-layer `kernel_sizes`, 3 channels = A2-Lite,
/// 8 channels = A2-Full) and additionally flags WaveNets using the v0.6+ feature
/// set (bottleneck, gating_mode, FiLM, layer1x1/head1x1, condition_dsp, slimmable).
enum NAMParser {

    static func parse(url: URL) throws -> NAMModelInfo {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw NAMParserError.unreadable(error.localizedDescription)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NAMParserError.notAJSONObject
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? Int64(data.count)
        return try parse(root: root, url: url, fileSize: fileSize)
    }

    static func parse(root: [String: Any], url: URL, fileSize: Int64) throws -> NAMModelInfo {
        guard let architecture = root["architecture"] as? String else { throw NAMParserError.missingKey("architecture") }
        guard root["config"] is [String: Any] else { throw NAMParserError.missingKey("config") }
        let version = root["version"] as? String ?? "?"

        // Resolve containers to the "primary" model (largest slimmable submodel).
        var primary = root
        var isSlimmable = false
        var containerNote: String?
        if architecture == "SlimmableContainer",
           let config = root["config"] as? [String: Any],
           let subs = config["submodels"] as? [[String: Any]] {
            isSlimmable = true
            let best = subs.max { (($0["max_value"] as? Double) ?? 0) < (($1["max_value"] as? Double) ?? 0) }
            if let model = best?["model"] as? [String: Any] { primary = model }
            containerNote = "\(subs.count) submodels"
        }

        let primaryArch = primary["architecture"] as? String ?? architecture
        let config = primary["config"] as? [String: Any] ?? [:]
        let family = Self.family(for: primaryArch)

        var generation: NAMModelInfo.Generation = .notApplicable
        var detail = ""

        switch family {
        case .wavenet:
            let analysis = analyseWaveNet(config: config)
            generation = analysis.generation
            detail = analysis.detail
            isSlimmable = isSlimmable || analysis.slimmable
            if isSlimmable, case .a1 = generation {
                // Slimmable WaveNets are part of the A2-era feature set.
                generation = .a2(variant: "A2 (feature set)")
            }
        case .lstm:
            let hidden = intValue(config["hidden_size"]).map(String.init) ?? "?"
            let layers = intValue(config["num_layers"]).map(String.init) ?? "?"
            detail = "hidden \(hidden) · \(layers) layer"
            generation = .a1(size: nil)
        case .convnet:
            let ch = intValue(config["channels"]).map(String.init) ?? "?"
            let dil = (config["dilations"] as? [Any])?.count ?? 0
            detail = "\(ch) channels · \(dil) blocks"
            generation = .a1(size: nil)
        case .sequential:
            let models = (config["models"] as? [[String: Any]]) ?? []
            detail = models.compactMap { $0["architecture"] as? String }.joined(separator: " → ")
            let anyA2 = models.contains { child in
                guard (child["architecture"] as? String) == "WaveNet", let c = child["config"] as? [String: Any] else { return false }
                return analyseWaveNet(config: c).generation.isA2
            }
            generation = anyA2 ? .a2(variant: "A2 (Sequential)") : .a1(size: nil)
        case .linear:
            detail = "Impulse response"
        case .unknown:
            detail = primaryArch
        }
        if let note = containerNote { detail = detail.isEmpty ? note : "\(detail) · \(note)" }

        // Metadata: top level first, then the primary submodel.
        let topMeta = root["metadata"] as? [String: Any] ?? [:]
        let subMeta = primary["metadata"] as? [String: Any] ?? [:]
        func meta<T>(_ key: String, _ cast: (Any?) -> T?) -> T? { cast(topMeta[key]) ?? cast(subMeta[key]) }

        let fallbackName = url.deletingPathExtension().lastPathComponent
        let name = (meta("name") { $0 as? String }).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName

        let sampleRate = doubleValue(primary["sample_rate"]) ?? doubleValue(root["sample_rate"])
        let weightsCount = (primary["weights"] as? [Any])?.count ?? (root["weights"] as? [Any])?.count

        let training = (topMeta["training"] as? [String: Any]) ?? (subMeta["training"] as? [String: Any])
        let validationESR = doubleValue(training?["validation_esr"])
        let latency = ((training?["data"] as? [String: Any])?["latency"] as? [String: Any])
        let recommended = intValue((latency?["calibration"] as? [String: Any])?["recommended"])

        return NAMModelInfo(
            fileURL: url,
            fileSize: fileSize,
            name: name,
            fileVersion: version,
            rawArchitecture: architecture,
            family: family,
            generation: generation,
            isSlimmable: isSlimmable,
            architectureDetail: detail,
            declaredSampleRate: sampleRate.flatMap { $0 > 0 ? $0 : nil },
            parameterCount: weightsCount,
            inputLevelDBu: meta("input_level_dbu", doubleValue),
            outputLevelDBu: meta("output_level_dbu", doubleValue),
            loudness: meta("loudness", doubleValue),
            gain: meta("gain", doubleValue),
            modeledBy: meta("modeled_by") { $0 as? String },
            gearType: meta("gear_type") { $0 as? String },
            gearMake: meta("gear_make") { $0 as? String },
            gearModel: meta("gear_model") { $0 as? String },
            toneType: meta("tone_type") { $0 as? String },
            date: meta("date") { parseDate($0) },
            validationESR: validationESR,
            recommendedLatency: recommended
        )
    }

    // MARK: - WaveNet analysis

    private static let a2FeatureKeys: Set<String> = [
        "bottleneck", "gating_mode", "head1x1", "layer1x1", "conv_pre_film", "conv_post_film",
        "input_mixin_pre_film", "input_mixin_post_film", "activation_pre_film", "activation_post_film",
        "layer1x1_post_film", "head1x1_post_film", "kernel_sizes", "groups_input", "groups_input_mixin", "slimmable",
    ]

    private static let a1Sizes: [[Int]: String] = [
        [16, 8]: "Standard",
        [12, 6]: "Lite",
        [8, 4]: "Feather",
        [4, 2]: "Nano",
    ]

    private struct WaveNetAnalysis {
        var generation: NAMModelInfo.Generation
        var detail: String
        var slimmable: Bool
    }

    private static func analyseWaveNet(config: [String: Any]) -> WaveNetAnalysis {
        let layers = config["layers"] as? [[String: Any]] ?? []
        let channels = layers.compactMap { intValue($0["channels"]) }
        let layerCounts = layers.map { arr -> Int in
            (arr["dilations"] as? [Any])?.count ?? (arr["kernel_sizes"] as? [Any])?.count ?? 0
        }
        let totalLayers = layerCounts.reduce(0, +)
        let slimmable = layers.contains { $0["slimmable"] != nil }
        let hasConditionDSP = !(config["condition_dsp"] == nil || config["condition_dsp"] is NSNull)

        let detail = "\(layers.count) layer array · channels \(channels.map(String.init).joined(separator: "/")) · \(totalLayers) layer"

        // Strict A2 shape (NeuralAmpModelerCore a2_fast::is_a2_shape).
        if layers.count == 1, let arr = layers.first,
           let ks = arr["kernel_sizes"] as? [Any], ks.count == 23,
           let ch = intValue(arr["channels"]), ch == 3 || ch == 8 {
            let variant = ch == 8 ? "A2-Full" : "A2-Lite"
            return WaveNetAnalysis(generation: .a2(variant: hasConditionDSP ? "\(variant) + condition DSP" : variant),
                                   detail: detail, slimmable: slimmable)
        }

        let usesA2Features = hasConditionDSP || layers.contains { arr in
            !a2FeatureKeys.isDisjoint(with: arr.keys) || !(arr["activation"] is String || arr["activation"] == nil)
        }
        if usesA2Features {
            return WaveNetAnalysis(generation: .a2(variant: "A2 (feature set)"), detail: detail, slimmable: slimmable)
        }
        return WaveNetAnalysis(generation: .a1(size: a1Sizes[channels] ?? "Custom"), detail: detail, slimmable: slimmable)
    }

    // MARK: - Helpers

    private static func family(for architecture: String) -> NAMModelInfo.Family {
        switch architecture {
        case "WaveNet": return .wavenet
        case "LSTM", "CatLSTM": return .lstm
        case "ConvNet", "CatConvNet": return .convnet
        case "Linear": return .linear
        case "Sequential": return .sequential
        default: return .unknown
        }
    }

    static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func intValue(_ any: Any?) -> Int? {
        (any as? NSNumber)?.intValue
    }

    private static func parseDate(_ any: Any?) -> Date? {
        guard let d = any as? [String: Any] else { return nil }
        var c = DateComponents()
        c.year = intValue(d["year"])
        c.month = intValue(d["month"])
        c.day = intValue(d["day"])
        c.hour = intValue(d["hour"])
        c.minute = intValue(d["minute"])
        c.second = intValue(d["second"])
        return Calendar(identifier: .gregorian).date(from: c)
    }
}
