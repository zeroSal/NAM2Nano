import SwiftUI

struct WizardContainerView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator()
                .padding(.horizontal, 28)
                .padding(.top, 30)
                .padding(.bottom, 14)
            Divider()
            ZStack {
                switch app.step {
                case .usb: Step1USBView()
                case .bluetooth: Step2BluetoothView()
                case .cabling: Step3CablingView()
                case .nam: Step4DropNAMView()
                case .metadata: Step5MetadataView()
                case .capture: Step6CaptureView()
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: app.step)
            Divider()
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footer: some View {
        HStack {
            Button {
                app.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(app.step == .usb || app.capture.phase.isActive)
            .opacity(app.step == .usb ? 0 : 1)

            Spacer()
            hardwareStatus
            Spacer()

            if app.step != .capture {
                Button {
                    app.goNext()
                } label: {
                    Label("Continue", systemImage: "chevron.right").labelStyle(TrailingIconLabelStyle())
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!app.canContinue)
            } else {
                Color.clear.frame(width: 100, height: 1)
            }
        }
        .controlSize(.large)
    }

    private var hardwareStatus: some View {
        HStack(spacing: 14) {
            statusDot("USB", ok: app.usbReady)
            statusDot("BLE", ok: app.bleReady)
            statusDot("Cable", ok: app.cableCheck.passed)
            if app.audio.runState.isRunning {
                let m = app.audio.meters
                Text("DSP \(Int(m.cpuLoad * 100))% · XRUN \(m.totalDropouts)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(m.totalDropouts == 0 ? Color.secondary : Color.orange)
            }
        }
    }

    private func statusDot(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ok ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

/// Top progress bar with the 6 steps.
struct StepIndicator: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppState.Step.allCases) { step in
                let isCurrent = step == app.step
                let isDone = step < app.step && app.isSatisfied(step)
                Button {
                    app.go(to: step)
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(isCurrent ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(isDone ? Color.green.opacity(0.85) : Color.secondary.opacity(0.18)))
                                .frame(width: 34, height: 34)
                            Image(systemName: isDone ? "checkmark" : step.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(isCurrent || isDone ? Color.white : Color.secondary)
                        }
                        Text("\(step.rawValue + 1). \(step.title)")
                            .font(.caption.weight(isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!app.isReachable(step) || app.capture.phase.isActive)

                if step != AppState.Step.allCases.last {
                    Rectangle()
                        .fill(step < app.step ? Color.green.opacity(0.6) : Color.secondary.opacity(0.2))
                        .frame(height: 2)
                        .frame(maxWidth: 40)
                        .offset(y: -10)
                }
            }
        }
    }
}
