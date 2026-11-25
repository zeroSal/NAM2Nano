import SwiftUI

struct Step3CablingView: View {
    @Environment(AppState.self) private var app

    private var diagramState: NanoDiagramView.CableState {
        switch app.cableCheck {
        case .notRun: return .idle
        case .running: return .testing
        case .skipped: return .ok
        case .finished(let r): return r.isSuccess ? .ok : .failed
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                StepHeader(title: "Audio cabling",
                           instructions: "Connect a short (TS) jack cable from the OUT 1L output straight into the CAPTURE IN input of the Nano Cortex. Unplug guitars, pedals or amps from INPUT and the outputs.")
                Card {
                    Label("The Mac sends the NAM-processed signal over USB → OUT 1L", systemImage: "arrow.right.circle")
                    Label("The cable brings it back into CAPTURE IN, where the Nano captures it", systemImage: "arrow.uturn.left.circle")
                    Label("Master volume not at zero, no monitor on the same loop", systemImage: "speaker.wave.2")
                }
                .font(.callout)

                status

                HStack {
                    Button {
                        app.runCableCheck()
                    } label: {
                        Label(app.cableCheck == .notRun ? "Check connection" : "Check again", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(app.cableCheckIsRunning || !app.bleReady || !app.usbReady)

                    if !app.cableCheck.passed {
                        Button("Skip check") { app.skipCableCheck() }
                            .help("For unusual setups: confirm manually that the cable is connected.")
                            .disabled(app.cableCheckIsRunning)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: 380)

            NanoDiagramView(mode: .cabling(diagramState))
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch app.cableCheck {
        case .notRun:
            StatusBadge(kind: .info, text: "Press \"Check connection\": the Nano briefly enters capture mode and the app sends a pilot tone at \(Int(app.settings.pilotLevelDB)) dBFS.")
        case .running(let message):
            StatusBadge(kind: .pending, text: message)
        case .skipped:
            StatusBadge(kind: .warning, text: "Check skipped: make sure OUT 1L → CAPTURE IN is connected.")
        case .finished(let result):
            switch result {
            case .verified: StatusBadge(kind: .ok, text: result.message)
            case .noTelemetry: StatusBadge(kind: .warning, text: result.message + " You can skip the check.")
            default: StatusBadge(kind: .error, text: result.message)
            }
        }
        if app.cableCheckIsRunning {
            LevelMeterView(title: "CAPTURE IN (Nano, via BLE)", nanoRaw: app.ble.captureInMeter)
            LevelMeterView(title: "Mac output → OUT 1L", value: app.audio.meters.outputDB)
        }
    }
}
