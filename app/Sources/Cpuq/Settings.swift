import ServiceManagement
import SwiftUI

/// The app's shape, as Settings sets it.
enum Prefs {
    /// The chip in the menu bar (default on).
    static var showInMenuBar: Bool { UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true }
    /// A Dock icon always, not only while the window is open (default off).
    static var dockAlways: Bool { UserDefaults.standard.bool(forKey: "dockAlways") }
}

/// Cpuq ▸ Settings: where the app shows itself, and whether it opens at login.
struct SettingsView: View {
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("dockAlways") private var dockAlways = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show in the menu bar", isOn: $showInMenuBar)
                Picker("Dock icon", selection: $dockAlways) {
                    Text("While the window is open").tag(false)
                    Text("Always").tag(true)
                }
                .disabled(!showInMenuBar)
                if !showInMenuBar {
                    Text("Without the menu bar item, Cpuq keeps its Dock icon, so it can always be reached.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("The menu bar item stays calm while all is well. It turns orange when jobs wait beside idle CPUs or cpuq's gate is shut, and shows ☁ while a cloud machine runs, and for how long.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: { on in setOpenAtLogin(on) }))
                if let loginProblem { Text(loginProblem).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginProblem = nil
        } catch {
            loginProblem = "macOS refused: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
