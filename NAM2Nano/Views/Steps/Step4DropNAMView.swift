import SwiftUI

struct Step4DropNAMView: View {
    @Environment(AppState.self) private var app
    @State private var isTargeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                StepHeader(title: "Choose a .nam file",
                           instructions: "Drop a Neural Amp Modeler model here. The app reads its architecture, sample rate and calibration levels before loading it into the DSP engine.")
                dropZone
                loadStatus
                Spacer()
            }
            .frame(width: 320)

            ScrollView {
                if let info = app.namInfo {
                    inspector(info)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Drop zone

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(isTargeted ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.secondary))
            Text("Drop a .nam file")
                .font(.headline)
            Button("Choose file…") { app.chooseNAMWithPanel() }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 170)
        .background(isTargeted ? Brand.violet.opacity(0.10) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(isTargeted ? Brand.violet : Color.secondary.opacity(0.4))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "nam" }) else { return false }
            app.selectNAM(url: url)
            return true
        } isTargeted: { isTargeted = $0 }
        .disabled(app.capture.phase.isActive)
    }

    @ViewBuilder
    private var loadStatus: some View {
        switch app.modelLoad {
        case .none:
            EmptyView()
        case .parsing:
            StatusBadge(kind: .pending, text: "Analyzing the file…")
        case .loading:
            StatusBadge(kind: .pending, text: "Loading into NeuralAmpModelerCore (prewarm)…")
        case .loaded(let rate, let resampling, let latency):
            StatusBadge(kind: .ok, text: resampling
                ? String(format: "Model ready · resampling %.1f kHz ↔ 48 kHz (+%.1f ms)", rate / 1000, latency)
                : "Model ready at native 48 kHz")
        case .failed(let why):
            StatusBadge(kind: .error, text: "Cannot use this file: \(why)")
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("No model selected")
                .foregroundStyle(.secondary)
            Text("Supported: WaveNet, LSTM, ConvNet (A1) and A2 / Slimmable. 44.1 or 96 kHz models are resampled in real time.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    // MARK: Inspector

    private func inspector(_ info: NAMModelInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Text(info.name).font(.title3.weight(.semibold)).lineLimit(2)
                    Spacer()
                    generationBadge(info.generation)
                }
                InfoRow(label: "Architecture", value: info.displayArchitecture)
                InfoRow(label: "Format", value: info.generation.label, highlight: info.generation.isA2 ? Brand.violet : nil)
                if !info.architectureDetail.isEmpty {
                    InfoRow(label: "Structure", value: info.architectureDetail)
                }
                InfoRow(label: "Sample rate",
                        value: "\(Int(info.sampleRate)) Hz" + (info.declaredSampleRate == nil ? " (not declared, assumed)" : "")
                            + (info.needsResampling ? " → resampled to 48 kHz" : ""),
                        highlight: info.needsResampling ? .orange : .green)
                InfoRow(label: "File version", value: info.fileVersion)
                if let params = info.parameterCount {
                    InfoRow(label: "Parameters", value: params.formatted())
                }
                InfoRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))
            }

            Card {
                Text("Gain / Loudness").font(.headline)
                InfoRow(label: "input_level_dbu", value: info.inputLevelDBu.map { String(format: "%.1f dBu", $0) } ?? "—")
                InfoRow(label: "output_level_dbu", value: info.outputLevelDBu.map { String(format: "%.1f dBu", $0) } ?? "—")
                InfoRow(label: "loudness", value: info.loudness.map { String(format: "%.1f dB", $0) } ?? "—")
                InfoRow(label: "gain", value: info.gain.map { String(format: "%.2f", $0) } ?? "—")
                if let esr = info.validationESR {
                    InfoRow(label: "Validation ESR", value: String(format: "%.4f", esr))
                }
            }

            if let staging = app.gainStaging {
                Card {
                    Text("Digital gain pre-calibration").font(.headline)
                    InfoRow(label: "Input trim", value: String(format: "%+.1f dB", staging.inputTrimDB))
                    InfoRow(label: "Output trim", value: String(format: "%+.1f dB", staging.outputTrimDB))
                    if let peak = staging.predictedPeakDBFS {
                        InfoRow(label: "Estimated peak", value: String(format: "%.1f dBFS", peak),
                                highlight: peak > -1 ? .red : (peak > -6 ? .orange : .green))
                    }
                    ForEach(staging.notes, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if info.modeledBy != nil || info.gearDescription != nil || info.date != nil || info.toneType != nil {
                Card {
                    Text("Author / Notes").font(.headline)
                    if let by = info.modeledBy { InfoRow(label: "Modeled by", value: by) }
                    if let gear = info.gearDescription { InfoRow(label: "Gear", value: gear) }
                    if let type = info.gearType { InfoRow(label: "Type", value: type) }
                    if let tone = info.toneType { InfoRow(label: "Tone", value: tone) }
                    if let date = info.date { InfoRow(label: "Date", value: date.formatted(date: .abbreviated, time: .shortened)) }
                }
            }
        }
        .padding(.trailing, 4)
    }

    private func generationBadge(_ g: NAMModelInfo.Generation) -> some View {
        let isA2 = g.isA2
        return Text(isA2 ? "A2" : "A1")
            .font(.caption.weight(.heavy))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(isA2 ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.gray), in: Capsule())
    }
}
