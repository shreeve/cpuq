import ServiceManagement
import SwiftUI

/// The app's shape, as Settings sets it.
enum Prefs {
    /// The chip in the menu bar (default on).
    static var showInMenuBar: Bool { UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true }
    /// A Dock icon always, not only while the window is open (default off).
    static var dockAlways: Bool { UserDefaults.standard.bool(forKey: "dockAlways") }
    /// Notifications when something goes wrong and stays so (default on).
    static var notify: Bool { UserDefaults.standard.object(forKey: "notify") as? Bool ?? true }
    /// The command that texts the owner a line (default ~/bin/send-imessage, when it is there).
    static var textCommand: String { UserDefaults.standard.string(forKey: "textCommand") ?? "~/bin/send-imessage" }
    /// Text the owner what needs them (default on, when the text command is there).
    static var text: Bool {
        (UserDefaults.standard.object(forKey: "text") as? Bool ?? true)
            && FileManager.default.isExecutableFile(atPath: (textCommand as NSString).expandingTildeInPath)
    }
}

/// Cpuq ▸ Settings: where the app shows itself, and whether it opens at login.
struct SettingsView: View {
    /// Shows or hides the chip and the Dock icon as the toggles say.
    let shape: () -> Void
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("dockAlways") private var dockAlways = false
    @AppStorage("notify") private var notify = true
    @AppStorage("text") private var text = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show in the menu bar", isOn: $showInMenuBar)
                    .onChange(of: showInMenuBar) { shape() }
                Picker("Dock icon", selection: $dockAlways) {
                    Text("While the window is open").tag(false)
                    Text("Always").tag(true)
                }
                .disabled(!showInMenuBar)
                .onChange(of: dockAlways) { shape() }
                if !showInMenuBar {
                    Text("Without the menu bar item, Cpuq keeps its Dock icon, so it can always be reached.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("The menu bar item stays calm while all is well. It turns orange when jobs wait beside idle CPUs or cpuq's gate is shut, and shows ☁ while a cloud machine runs, and for how long.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Text me what needs me", isOn: $text)
                    .disabled(!FileManager.default.isExecutableFile(atPath: (Prefs.textCommand as NSString).expandingTildeInPath))
            } footer: {
                Text("At most once every 30 minutes, with \(Prefs.textCommand): a machine overloaded while another has room, a job that looks stuck, a cloud machine billing with nothing to do, or --opaque jobs holding cores while others wait.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Notify when something goes wrong", isOn: $notify)
            } footer: {
                Text("Once each time it happens and lasts, on any machine watched: cpuq's gate shut (30 seconds); jobs waiting beside idle CPUs (a minute); --opaque jobs holding cores while others wait (2 minutes); heavy work outside cpuq (3 minutes); a job that looks stuck, or a machine overloaded while another has room (10 minutes); a cloud machine up with nothing to do (15 minutes: its idle stop failed, and it is billing), with a button to stop it.")
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
