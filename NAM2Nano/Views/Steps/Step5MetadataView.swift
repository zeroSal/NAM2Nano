import SwiftUI

struct Step5MetadataView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StepHeader(title: "Capture metadata",
                           instructions: "This data is written to the Nano Cortex when the capture finishes (about 5 minutes).")

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Capture Name").font(.headline)
                        TextField("Capture name", text: $app.metadata.name)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: app.metadata.name) { _, newValue in
                                if newValue.count > NanoCaptureMetadata.nameMaxLength {
                                    app.metadata.name = String(newValue.prefix(NanoCaptureMetadata.nameMaxLength))
                                }
                            }
                        HStack {
                            if !app.metadata.isNameValid {
                                Text("\(NanoCaptureMetadata.nameMinLength) to \(NanoCaptureMetadata.nameMaxLength) characters.")
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Text("\(app.metadata.name.count)/\(NanoCaptureMetadata.nameMaxLength)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }

                Card {
                    Text("Device Type").font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(NanoDeviceCategory.allCases) { category in
                            categoryTile(category, selected: app.metadata.category == category) {
                                app.metadata.category = category
                            }
                        }
                    }
                    Text("The firmware knows: amp_head, amp_and_cab, cab, pedal. Combo → amp_and_cab, Preamp → amp_head.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card {
                    Text("Gain / Drive").font(.headline)
                    Picker("Character", selection: $app.metadata.gainCharacter) {
                        ForEach(GainCharacter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    HStack {
                        Text("Level")
                        Slider(value: $app.metadata.gainLevel, in: 1...10, step: 1)
                        Text("\(Int(app.metadata.gainLevel))").monospacedDigit().frame(width: 24)
                    }
                }

                Card {
                    Text("Description / Notes (optional)").font(.headline)
                    TextEditor(text: $app.metadata.notes)
                        .font(.body)
                        .frame(height: 64)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    Text("Gain/Drive and notes have no field in the Nano protocol: they are kept in the app's local history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card {
                    Text("Destination").font(.headline)
                    Picker("Destination", selection: $app.metadata.target) {
                        Text(CaptureTarget.library.title).tag(CaptureTarget.library)
                        Divider()
                        ForEach(Array(CaptureTarget.slotRange), id: \.self) { slot in
                            Text("Library + Slot \(CaptureTarget.bankSlotLabel(slot))").tag(CaptureTarget.slot(slot))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    if case .slot = app.metadata.target {
                        Text("The capture currently in the slot will be replaced (it stays in the library).")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.trailing, 6)
        }
        .onAppear {
            if app.metadata.name.isEmpty, let info = app.namInfo {
                app.metadata = .prefilled(from: info)
            }
        }
    }

    private func categoryTile(_ c: NanoDeviceCategory, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: c.symbol).font(.system(size: 20))
                Text(c.title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(selected ? Brand.violet.opacity(0.18) : Color.secondary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Brand.violet : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
