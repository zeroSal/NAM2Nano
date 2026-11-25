import SwiftUI

struct Step2BluetoothView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                StepHeader(title: "Bluetooth connection",
                           instructions: "Hold both footswitches on the Nano Cortex at the same time to turn on Bluetooth: the app connects by itself. Bluetooth is used to start the capture, set levels and save the metadata.")
                status
                if app.ble.isReady {
                    Card {
                        InfoRow(label: "Device", value: app.ble.peripheralName ?? "Nano Cortex")
                        InfoRow(label: "Firmware", value: app.ble.firmwareVersion ?? "not reported")
                    }
                }
                HStack {
                    switch app.ble.state {
                    case .failed, .idle:
                        Button("Retry") { app.ble.retry() }
                    case .scanning, .connecting, .discovering:
                        Button("Cancel search") { app.ble.disconnect() }
                    default:
                        EmptyView()
                    }
                }
                Text("If the Nano is connected to Cortex Cloud or another editor, close it: the pedal accepts only one Bluetooth connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: 360)

            NanoDiagramView(mode: .pairing(connected: app.ble.isReady))
                .frame(maxWidth: .infinity)
        }
        .onAppear { if !app.ble.isReady { app.ble.start() } }
    }

    @ViewBuilder
    private var status: some View {
        switch app.ble.state {
        case .ready:
            StatusBadge(kind: .ok, text: "Connected over Bluetooth (Firmware \(app.ble.firmwareVersion.map { "v\($0)" } ?? "unknown"))")
        case .failed(let why):
            StatusBadge(kind: .error, text: why)
        case .poweredOff, .unauthorized, .unsupported:
            StatusBadge(kind: .error, text: app.ble.state.description)
        case .idle:
            StatusBadge(kind: .info, text: "Bluetooth paused")
        default:
            StatusBadge(kind: .pending, text: app.ble.state.description)
        }
    }
}
