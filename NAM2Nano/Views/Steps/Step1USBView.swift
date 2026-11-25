import SwiftUI

struct Step1USBView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                StepHeader(title: "USB-C connection",
                           instructions: "Connect the Nano Cortex to the Mac with a USB-C cable and power it on. No DAW or external audio interface needed: the Nano is the audio interface.")
                status
                if let nano = app.deviceMonitor.nano {
                    Card {
                        InfoRow(label: "Device", value: nano.name)
                        InfoRow(label: "Sample rate", value: "\(Int(nano.nominalSampleRate)) Hz",
                                highlight: nano.isAt48k ? .green : .orange)
                        InfoRow(label: "USB channels", value: "\(nano.inputChannels) in / \(nano.outputChannels) out")
                        if case .running(_, let frames) = app.audio.runState {
                            InfoRow(label: "Buffer", value: "\(frames) samples (\(String(format: "%.1f", Double(frames) / 48.0)) ms)")
                        }
                    }
                }
                Spacer()
            }
            .frame(maxWidth: 360)

            NanoDiagramView(mode: .usb(connected: app.usbReady))
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var status: some View {
        if let nano = app.deviceMonitor.nano {
            if let error = app.audioError {
                VStack(alignment: .leading, spacing: 8) {
                    StatusBadge(kind: .error, text: error)
                    Button("Retry") { Task { await app.restartAudio() } }
                }
            } else if !nano.isAt48k {
                StatusBadge(kind: .warning, text: app.deviceMonitor.lastError ?? "Setting the Nano to 48 kHz…")
            } else if app.audio.runState.isRunning {
                StatusBadge(kind: .ok, text: "Nano Cortex detected over USB (48 kHz)")
            } else {
                StatusBadge(kind: .pending, text: "Starting the USB audio stream…")
            }
        } else {
            StatusBadge(kind: .pending, text: "Waiting for the Nano Cortex on USB…")
        }
    }
}
