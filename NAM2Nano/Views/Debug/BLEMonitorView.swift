import SwiftUI
import AppKit

/// Debug window (menu Debug → Monitor BLE): live GATT traffic + manual hex sender,
/// to adapt the reverse-engineered protocol during the first tests on real hardware.
struct BLEMonitorView: View {
    @Environment(AppState.self) private var app
    @State private var hexToSend = ""
    @State private var filter = ""
    @State private var autoScroll = true

    private var entries: [BLELogEntry] {
        let all = app.ble.log
        guard !filter.isEmpty else { return all }
        return all.filter { $0.label.localizedCaseInsensitiveContains(filter) || $0.hex.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        @Bindable var ble = app.ble
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                StatusBadge(kind: ble.isReady ? .ok : .pending, text: ble.state.description)
                if let fw = ble.firmwareVersion { Text("FW \(fw)").font(.caption).foregroundStyle(.secondary) }
                Text(ble.captureMode ? "capture mode" : "play mode").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $filter).frame(width: 140)
                Toggle("Meter", isOn: $ble.logMeters).toggleStyle(.checkbox)
                Toggle("Auto-scroll", isOn: $autoScroll).toggleStyle(.checkbox)
                Button("Copy") { copyLog() }
                Button("Clear") { ble.clearLog() }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                List(entries) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(e.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                            .foregroundStyle(.secondary)
                        Text(e.direction.rawValue)
                            .fontWeight(.bold)
                            .foregroundStyle(e.direction == .tx ? Brand.orange : (e.direction == .rx ? Brand.cyan : .secondary))
                        Text(e.label).frame(width: 190, alignment: .leading).lineLimit(1)
                        Text(e.hex).textSelection(.enabled).lineLimit(3)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .id(e.id)
                }
                .onChange(of: app.ble.log.count) { _, _ in
                    if autoScroll, let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                TextField("Hex to send on C304 (e.g. 0C C0 08 03 18 01 20 01 28 01 01 00 00 00)", text: $hexToSend)
                    .font(.system(.body, design: .monospaced))
                Button("Send") {
                    if ble.sendRawHex(hexToSend) { hexToSend = "" }
                }
                .disabled(!ble.isReady || hexToSend.isEmpty)
                Menu("Commands") {
                    Button("State request") { ble.requestState() }
                    Button("Enter capture mode") { ble.send(NanoCommand.enterCaptureMode, label: "Enter capture mode") }
                    Button("Capture state request") { ble.send(NanoCommand.captureStateRequest, label: "Capture state request") }
                    Button("Exit (back one step)") { ble.send(NanoCommand.exitStep, label: "Exit") }
                }
                .frame(width: 110)
                .disabled(!ble.isReady)
            }
            .padding(10)
        }
    }

    private func copyLog() {
        let text = entries.map { "\($0.date.ISO8601Format()) \($0.direction.rawValue) \($0.label) \($0.hex)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Debug window: per-channel USB input peaks (to identify which channel carries the capture signal).
struct AudioMonitorView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nano USB inputs").font(.headline)
            if app.audio.inputChannelDB.isEmpty {
                Text("Audio engine not running.").foregroundStyle(.secondary)
            }
            ForEach(Array(app.audio.inputChannelDB.enumerated()), id: \.offset) { index, db in
                LevelMeterView(title: channelTitle(index), value: db)
            }
            Divider()
            LevelMeterView(title: "Output → USB Out \(app.settings.outputChannel)", value: app.audio.meters.outputDB)
            Text("During a capture the test signal should be on In \(app.settings.sourceChannel). Change it in Settings (⌘,) if needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
    }

    private func channelTitle(_ index: Int) -> String {
        let n = index + 1
        var tags: [String] = []
        if n == app.settings.sourceChannel { tags.append("NAM source") }
        if n == app.settings.loopMonitorChannel { tags.append("monitor OUT 1L") }
        return "In \(n)" + (tags.isEmpty ? "" : " · " + tags.joined(separator: ", "))
    }
}
