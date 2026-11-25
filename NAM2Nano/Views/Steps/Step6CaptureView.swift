import SwiftUI

struct Step6CaptureView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        switch app.capture.phase {
        case .done(let summary):
            completion(summary)
        default:
            VStack(alignment: .leading, spacing: 14) {
                StepHeader(title: "Cattura", instructions: headerText)
                summaryCard
                phaseView
                meters
                Spacer(minLength: 0)
                actions
            }
        }
    }

    private var headerText: String {
        switch app.capture.phase {
        case .training: return "Do not unplug cables or quit the app: the Nano is capturing the NAM model in real time."
        default: return "All set. Press Start Capture: the Nano plays its test signal, the Mac processes it with NAM and sends it back into CAPTURE IN."
        }
    }

    // MARK: Summary

    private var summaryCard: some View {
        Card {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "File .nam", value: app.namInfo?.fileURL.lastPathComponent ?? "—")
                    InfoRow(label: "Architecture", value: app.namInfo.map { "\($0.displayArchitecture) · \($0.generation.label)" } ?? "—")
                    InfoRow(label: "Capture name", value: app.metadata.trimmedName)
                    InfoRow(label: "Type / destination", value: "\(app.metadata.category.title) · \(app.metadata.target.title)")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    routingText
                    if let raw = app.capture.captureInRaw {
                        Text(String(format: "CAPTURE IN %.1f dB", NanoCommand.captureInDB(raw: raw)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var routingText: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("USB In \(app.settings.sourceChannel) → NAM → USB Out \(app.settings.outputChannel)")
            Text("OUT 1L → cable → CAPTURE IN")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Phase

    @ViewBuilder
    private var phaseView: some View {
        switch app.capture.phase {
        case .idle:
            EmptyView()
        case .preparing(let msg), .levelling(let msg), .saving(let msg):
            StatusBadge(kind: .pending, text: msg)
        case .training:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(app.capture.stageLabel).font(.headline)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(elapsedText(now: ctx.date)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: app.capture.progress)
                    .tint(Brand.violet)
                HStack(spacing: 0) {
                    ForEach(["Calibration", "Profiling", "Neural network training", "Finalizing"], id: \.self) { stage in
                        Text(stage)
                            .font(.caption2)
                            .foregroundStyle(stage == app.capture.stageLabel ? .primary : .tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        case .failed(let msg):
            StatusBadge(kind: .error, text: msg)
        case .cancelled:
            StatusBadge(kind: .warning, text: "Capture cancelled.")
        case .done:
            EmptyView()
        }
        if let warning = app.capture.warning {
            StatusBadge(kind: .warning, text: warning)
        }
    }

    private func elapsedText(now: Date) -> String {
        guard let start = app.capture.startedAt else { return "" }
        let s = Int(now.timeIntervalSince(start))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Meters

    private var meters: some View {
        let m = app.audio.meters
        return Card {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 8) {
                    LevelMeterView(title: "USB input (test signal)", value: m.sourceDB)
                    LevelMeterView(title: "Output → OUT 1L", value: m.outputDB)
                }
                VStack(spacing: 8) {
                    LevelMeterView(title: "Nano · CAPTURE IN", nanoRaw: app.ble.captureInMeter)
                    LevelMeterView(title: "Nano · OUTPUT", nanoRaw: app.ble.outputMeter)
                }
            }
            HStack(spacing: 16) {
                dspStat("DSP", "\(Int(m.cpuLoad * 100)) %", ok: m.cpuLoad < 0.7)
                dspStat("XRUN", "\(m.xruns + m.deviceOverloads)", ok: m.xruns + m.deviceOverloads == 0)
                dspStat("Overload", "\(m.dspOverloads)", ok: m.dspOverloads == 0)
                dspStat("Clip", "\(m.clips)", ok: m.clips == 0)
                Spacer()
            }
        }
    }

    private func dspStat(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }

    // MARK: Actions

    private var actions: some View {
        HStack {
            if app.capture.phase.isActive {
                Button(role: .destructive) {
                    app.capture.cancel(app: app)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .controlSize(.large)
            }
            Spacer()
            Button {
                app.capture.start(app: app)
            } label: {
                Label(startTitle, systemImage: "record.circle.fill")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.pink)
            .controlSize(.large)
            .disabled(app.capture.phase.isActive || !app.hardwareReady || app.audio.loadedModel == nil || !app.metadata.isNameValid)
        }
    }

    private var startTitle: String {
        switch app.capture.phase {
        case .failed, .cancelled: return "Retry capture"
        default: return "Start Capture"
        }
    }

    // MARK: Completion

    private func completion(_ summary: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Brand.gradient)
            Text("Capture complete").font(.largeTitle.weight(.semibold))
            Text(summary)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            if let warning = app.capture.warning {
                StatusBadge(kind: .warning, text: warning).frame(maxWidth: 560)
            }
            HStack(spacing: 14) {
                Button {
                    app.captureAnother()
                } label: {
                    Label("Capture another .nam file", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.large)
            Text("USB, Bluetooth and cable stay verified: you restart from step 4.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
