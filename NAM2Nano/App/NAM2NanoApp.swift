import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.nam` files are JSON; declared as an imported type in Info.plist.
    static let namModel = UTType(importedAs: "com.neuralampmodeler.nam", conformingTo: .json)
}

@main
struct NAM2NanoApp: App {
    @State private var app = AppState()

    var body: some Scene {
        Window("NAM2Nano", id: "main") {
            WizardContainerView()
                .environment(app)
                .frame(width: 860, height: 640)
                .onAppear { app.onLaunch() }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Debug") {
                OpenWindowButton(title: "BLE Monitor", id: "ble-monitor")
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                OpenWindowButton(title: "USB Audio Monitor", id: "audio-monitor")
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }

        Window("BLE Monitor", id: "ble-monitor") {
            BLEMonitorView()
                .environment(app)
                .frame(minWidth: 640, minHeight: 420)
        }

        Window("USB Audio Monitor", id: "audio-monitor") {
            AudioMonitorView()
                .environment(app)
                .frame(minWidth: 420, minHeight: 360)
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

private struct OpenWindowButton: View {
    let title: String
    let id: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) { openWindow(id: id) }
    }
}
