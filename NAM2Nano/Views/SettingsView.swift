import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        let inCount = max(app.deviceMonitor.nano?.inputChannels ?? 8, 1)
        let outCount = max(app.deviceMonitor.nano?.outputChannels ?? 8, 1)

        Form {
            Section("USB routing (Nano Cortex)") {
                Picker("Test signal source (USB In)", selection: $settings.sourceChannel) {
                    ForEach(1...inCount, id: \.self) { Text("In \($0)").tag($0) }
                }
                Picker("Output to OUT 1L (USB Out)", selection: $settings.outputChannel) {
                    ForEach(1...outCount, id: \.self) { Text("Out \($0)").tag($0) }
                }
                Picker("Input mirroring OUT 1L", selection: $settings.loopMonitorChannel) {
                    ForEach(1...inCount, id: \.self) { Text("In \($0)").tag($0) }
                }
                Toggle("Auto-detect the source if the channel is silent", isOn: $settings.autoDetectSource)
                Picker("Buffer", selection: $settings.bufferFrames) {
                    ForEach(AppSettings.bufferChoices, id: \.self) { Text("\($0) samples").tag($0) }
                }
                Text("Defaults: In 4 (processed OUTPUT 2R = CAPTURE OUT), Out 1 (OUTPUT 1L). Verify on your pedal with Debug → USB Audio Monitor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Calibration") {
                Toggle("Input calibration from input_level_dbu", isOn: $settings.applyInputCalibration)
                LabeledContent("USB reference (dBu @ 0 dBFS)") {
                    TextField("", value: $settings.usbReferenceDBu, format: .number.precision(.fractionLength(1)))
                        .frame(width: 70)
                }
                LabeledContent("Loudness target (dB)") {
                    TextField("", value: $settings.targetLoudnessDB, format: .number.precision(.fractionLength(1)))
                        .frame(width: 70)
                }
                Toggle("Auto-level CAPTURE IN over Bluetooth", isOn: $settings.autoLevelCaptureIn)
                LabeledContent("Pilot tone (dBFS)") {
                    TextField("", value: $settings.pilotLevelDB, format: .number.precision(.fractionLength(0)))
                        .frame(width: 70)
                }
            }
            Section {
                HStack {
                    Button("Restore defaults") { settings.resetToDefaults() }
                    Spacer()
                    Button("Restart audio") { Task { await app.restartAudio() } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
        .onChange(of: settings.sourceChannel) { _, _ in app.applyRouting() }
        .onChange(of: settings.outputChannel) { _, _ in app.applyRouting() }
        .onChange(of: settings.bufferFrames) { _, _ in Task { await app.restartAudio() } }
        .onChange(of: settings.applyInputCalibration) { _, _ in app.recomputeGainStaging() }
        .onChange(of: settings.usbReferenceDBu) { _, _ in app.recomputeGainStaging() }
        .onChange(of: settings.targetLoudnessDB) { _, _ in app.recomputeGainStaging() }
    }
}
