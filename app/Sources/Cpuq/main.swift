import AppKit
import CpuqCore
import Sparkle
import SwiftUI
import UserNotifications

/// Cpuq.app: a window with a page per machine, and a chip in the menu bar that stays calm while
/// all is well. While the window is open it is an ordinary app (Dock icon, menu bar, ⌘Tab); closed,
/// only the chip remains (Settings can keep the Dock icon, or drop the chip). It only reads
/// `cpuq status --json`; cpuq itself needs no app.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var menuOpen = false
    private var rebuildOnClose = false
    private var status: Status?
    private var problem: String?
    private var timer: Timer?
    private var polling = false
    private let graphs = GraphModel()
    /// The spill hosts in cpuq's config, each a page of the window beside this Mac's.
    private var remotes: [GraphModel] = []
    private var remotePolling: Set<String> = []
    private var graphsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    /// The View menu (machines, theme, live view), its checkmarks set as it opens.
    private var viewMenu: NSMenu?
    /// Ticks of the 3-second timer, for the once-a-minute look at cloud machines.
    private var ticks = 0
    /// What has gone wrong and since when, for the notifications: one each time a thing goes
    /// wrong and stays so, none again until it has come right.
    private var gateShut = Episode()
    private var idleWait = Episode()
    private var cloudIdle: [String: Episode] = [:]
    private let sizeGuard = MinimumSize()
    private var historyTimer: Timer?
    /// Sparkle, running only in a Cpuq.app bundle: a binary run from the build folder never offers
    /// to replace itself.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.bundleURL.pathExtension == "app",
        updaterDelegate: AppDelegate.relaunch,
        userDriverDelegate: nil
    )
    /// Sparkle holds its delegate weakly.
    private static let relaunch = UpdateRelaunch()

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.image = chip(level: 0)
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "cpuq"
        menu.delegate = self
        item.menu = menu
        loadMachines()
        rebuild()
        // One window: macOS's tab bar items would only clutter View.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = mainMenu()
        applyShape()
        // Settings changes the shape as it is toggled.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyShape() }
        }
        setUpNotifications()
        poll()
        pollClouds()
        // An update relaunched the app with the graphs window open: open it again. A menu-bar
        // app otherwise comes back as only its chip, and the update looks as if it never relaunched.
        AppDelegate.relaunch.graphsOpen = { [weak self] in self?.graphsWindow?.isVisible ?? false }
        let reopen = UserDefaults.standard.bool(forKey: UpdateRelaunch.key)
        UserDefaults.standard.removeObject(forKey: UpdateRelaunch.key)
        // For testing a build: open the graphs window at launch.
        if reopen || ProcessInfo.processInfo.environment["CPUQ_SHOW_GRAPHS"] != nil { showGraphs() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.poll()
                self.pollRemotes()
                self.ticks += 1
                if self.ticks % 20 == 0 { self.pollClouds() }
            }
        }
    }

    /// The Dock icon clicked (or the app opened again from the Finder): the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showGraphs()
        return true
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        if m === viewMenu { markView(m) }
    }

    func menuWillOpen(_ m: NSMenu) {
        guard m === menu else { return }
        rebuild()
        menuOpen = true
    }

    func menuDidClose(_ m: NSMenu) {
        guard m === menu else { return }
        menuOpen = false
        if rebuildOnClose {
            rebuildOnClose = false
            rebuild()
        }
    }

    /// Reads `cpuq status --json` off the main thread, then updates the icon
    /// and the menu.
    private func poll() {
        guard !polling else { return }
        polling = true
        Task.detached(priority: .utility) {
            let result = Self.readStatus()
            await MainActor.run {
                self.polling = false
                switch result {
                case .success(let s):
                    self.status = s
                    self.problem = nil
                    self.graphs.add(s)
                    Liveliness.shared.observe(load: s.load.first, cpus: Double(ProcessInfo.processInfo.activeProcessorCount))
                case .failure(let e):
                    self.status = nil
                    self.problem = e.message
                }
                self.updateChip()
                if self.menu.highlightedItem != nil || self.menu.numberOfItems == 0 { return }
                self.rebuild()
            }
        }
    }

    /// The spill hosts named in cpuq's config (`spill`, `spill_start.HOST`).
    private func loadMachines() {
        let path = ProcessInfo.processInfo.environment["CPUQ_CONFIG"] ?? NSHomeDirectory() + "/.config/cpuq/config"
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        remotes = spillHosts(config: text).map { GraphModel(machine: Machine(id: $0.host, start: $0.start)) }
    }

    /// Each spill host's status over ssh, while the window is open: nobody watches it otherwise,
    /// and a stopped cloud machine need not be dialed every 3 seconds for the menu.
    private func pollRemotes() {
        guard graphsWindow?.isVisible ?? false else { return }
        for m in remotes { pollRemote(m) }
    }

    /// The cloud machines (those cpuq can start) once a minute even with the window closed: one
    /// running costs money, and the chip says so whether anyone is looking or not.
    private func pollClouds() {
        guard !(graphsWindow?.isVisible ?? false) else { return }
        for m in remotes where m.machine.start != nil { pollRemote(m) }
    }

    private func pollRemote(_ m: GraphModel) {
        let host = m.machine.id
        guard !remotePolling.contains(host) else { return }
        remotePolling.insert(host)
        Task.detached(priority: .utility) {
            let result = Self.remote(host, ["status", "--json"])
            await MainActor.run {
                self.remotePolling.remove(host)
                switch result {
                case .success(let data):
                    if let s = try? Status.decode(data) { m.add(s) } else { m.failed("its cpuq answered in a form this app cannot read") }
                case .failure(let e): m.failed(e.message)
                }
                self.updateChip()
                self.countMonth(m)
            }
        }
    }

    /// A running cloud machine's hours this month, from its boot journal, every 5 minutes.
    private func countMonth(_ m: GraphModel) {
        guard m.isCloudRunning, Date().timeIntervalSince(m.monthCheckedAt ?? .distantPast) > 300 else { return }
        m.monthCheckedAt = Date()
        let host = m.machine.id
        let since = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        Task.detached(priority: .utility) {
            guard case .success(let data) = Self.remoteCommand(host, "journalctl --list-boots -o json --no-pager"),
                  let seconds = runningSeconds(boots: data, since: since) else { return }
            await MainActor.run {
                m.monthHours = seconds / 3600
                self.updateChip()
            }
        }
    }

    /// Runs a stopped machine's `spill_start` command (a cloud VM's start script), then polls it.
    private func startMachine(_ m: GraphModel) {
        guard let command = m.machine.start, !m.starting else { return }
        m.starting = true
        m.startNote = nil
        Task.detached(priority: .userInitiated) {
            let (ok, last) = Self.shell(command)
            await MainActor.run {
                m.starting = false
                m.startNote = ok ? nil : "Its start command failed: \(last)"
                self.pollRemotes()
            }
        }
    }

    /// Runs `command` with sh, with Homebrew's directories on PATH (an app opened from the Finder
    /// gets only the system's, and a cloud machine's start script needs gcloud): whether it
    /// succeeded, and the last line it printed.
    nonisolated private static func shell(_ command: String) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        // The scripts color their lines; keep the words.
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let last = plain.split(separator: "\n").last.map(String.init) ?? ""
        return (p.terminationStatus == 0, last)
    }

    struct Problem: Error { let message: String }

    /// Runs cpuq on `host` over ssh and returns what it printed; a failure carries ssh's or
    /// cpuq's first line of complaint.
    nonisolated private static func remote(_ host: String, _ arguments: [String]) -> Result<Data, Problem> {
        remoteCommand(host, (["cpuq"] + arguments).joined(separator: " "))
    }

    nonisolated private static func remoteCommand(_ host: String, _ command: String) -> Result<Data, Problem> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, command]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(Problem(message: "cannot run ssh: \(error.localizedDescription)")) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let complaint = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let line = String(decoding: complaint, as: UTF8.self).split(separator: "\n").first.map(String.init)
            return .failure(Problem(message: line ?? "ssh \(host) failed (\(p.terminationStatus))"))
        }
        return .success(data)
    }

    nonisolated private static func readStatus() -> Result<Status, Problem> {
        switch run(["status", "--json"]) {
        case .success(let data):
            do { return .success(try Status.decode(data)) } catch {
                return .failure(Problem(message: "cannot read cpuq status: \(error.localizedDescription)"))
            }
        case .failure(let e): return .failure(e)
        }
    }

    nonisolated private static func readHistory() -> [Job] {
        guard case .success(let data) = run(["history", "--json", "--limit", "500"]) else { return [] }
        return (try? Job.decodeList(data)) ?? []
    }

    /// Runs cpuq with `arguments` and returns what it printed.
    nonisolated private static func run(_ arguments: [String]) -> Result<Data, Problem> {
        guard let path = findCpuq() else {
            return .failure(Problem(message: "cpuq is not installed (~/.local/bin, /opt/homebrew/bin or /usr/local/bin)"))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return .failure(Problem(message: "cannot run \(path): \(error.localizedDescription)"))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return .failure(Problem(message: "cpuq \(arguments.first ?? "") failed (\(p.terminationStatus))")) }
        return .success(data)
    }

    // MARK: - The menu

    /// Rebuilds the menu. While it is open, its items are only retitled in place when their
    /// number is unchanged: an open menu does not shrink when items go, which would leave blank
    /// rows. Otherwise the rebuild waits for it to close.
    private func rebuild() {
        let fresh = NSMenu()
        fill(fresh)
        if menuOpen {
            guard fresh.numberOfItems == menu.numberOfItems else { rebuildOnClose = true; return }
            for (old, new) in zip(menu.items, fresh.items) where !old.isSeparatorItem {
                old.title = new.title
                old.attributedTitle = new.attributedTitle
            }
            return
        }
        menu.removeAllItems()
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }

    /// Fills the chip's menu: the versions, one line of how it stands, a line for each thing
    /// wrong (and only then), and the commands. The jobs, the theme and the details live in the
    /// window.
    private func fill(_ m: NSMenu) {
        m.addItem(versions())
        if let s = status {
            let waiting = s.waiters.count
            m.addItem(text("\(s.held) of \(s.capacity) cores in use" + (waiting > 0 ? " · \(waiting) waiting" : ""), bold: true))
        } else {
            m.addItem(text(problem ?? "reading cpuq status…", bold: false))
        }
        for line in alerts() { m.addItem(text(line, bold: false)) }
        m.addItem(.separator())
        m.addItem(withTitle: "Open Cpuq", action: #selector(showGraphs), keyEquivalent: "g").target = self
        m.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        if Bundle.main.bundleURL.pathExtension == "app" {
            let check = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            check.target = updater
            m.addItem(check)
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Cpuq", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// What is wrong, a line each: the gate shut, jobs waiting beside idle CPUs, a cloud machine
    /// running (and costing money). Empty while all is well.
    private func alerts() -> [String] {
        var out: [String] = []
        if let s = status {
            if s.gate.state != "open" { out.append("⚠︎ cpuq's gate is \(s.gate.text)") }
            let now = Moment.now(graphs)
            if now.needless { out.append("⚠︎ \(now.waiters.count) waiting beside idle CPUs") }
        }
        for m in remotes where m.isCloudRunning {
            let held = m.status.map { " · \($0.held) of \(Int(m.cpus)) cores in use" } ?? ""
            let month = m.monthHours.map { " · " + GraphModel.hours($0) + " this month" } ?? ""
            out.append("☁︎ \(m.machine.name) running · up \(m.upFor)\(month)\(held)")
        }
        return out
    }

    /// The chip: calm while all is well; orange while something is wrong (the gate shut, or jobs
    /// waiting beside idle CPUs); struck through when cpuq cannot be read; and "☁ 23m" beside it
    /// while a cloud machine runs.
    private func updateChip() {
        let s = status
        let wrong = s.map { $0.gate.state != "open" || Moment.now(graphs).needless } ?? false
        item.button?.image = chip(level: meterLevel(held: s?.held ?? 0, budget: s?.capacity ?? 0), tint: wrong ? .systemOrange : nil, broken: s == nil)
        let clouds = remotes.filter(\.isCloudRunning)
        // "☁ 23m / 14h": up since it booted, and its hours this month.
        item.button?.title = clouds.isEmpty ? "" : " ☁ " + clouds.map { $0.upFor + ($0.monthHours.map { " / " + GraphModel.hours($0) } ?? "") }.joined(separator: "  ")
        var tip = s.map { "cpuq: \($0.held) of \($0.capacity) cores in use" + ($0.waiters.isEmpty ? "" : " · \($0.waiters.count) waiting") } ?? "cpuq: \(problem ?? "cannot read cpuq")"
        for line in alerts() { tip += "\n" + line }
        item.button?.toolTip = tip
        checkAlerts()
    }

    // MARK: - Notifications

    private struct Episode {
        var since: Date?
        var told = false
    }

    /// Asks once to notify; a Stop It button on the cloud notification.
    private func setUpNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let stop = UNNotificationAction(identifier: "stop", title: "Stop It", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: "cloud", actions: [stop], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Three things worth an interruption, each once it has lasted: cpuq's gate shut (30 s), jobs
    /// waiting beside idle CPUs (a minute), and a cloud machine up with nothing to do for 15
    /// minutes, which means its own 10-minute idle stop failed and it is still billing.
    private func checkAlerts() {
        guard Prefs.notify else { return }
        let now = Date()
        if let s = status {
            track(&gateShut, s.gate.state != "open", after: 30, now) {
                notify("gate", "cpuq's gate is shut", "\(s.gate.text.prefix(1).uppercased() + s.gate.text.dropFirst()). New jobs wait until it opens.")
            }
            let m = Moment.now(graphs)
            track(&idleWait, m.needless, after: 60, now) {
                notify("idle", "\(m.waiters.count) waiting beside idle CPUs",
                       String(format: "%.1f CPUs free on %@, and nothing starts: a job may be stuck, or asking for more than there is.", m.free, graphs.machine.name))
            }
        }
        for c in remotes where c.machine.start != nil {
            let idle = c.isCloudRunning && (c.status.map { $0.holders.isEmpty && $0.waiters.isEmpty } ?? false)
            var e = cloudIdle[c.machine.id] ?? Episode()
            track(&e, idle, after: 15 * 60, now) {
                notify("cloud-\(c.machine.id)", "\(c.machine.name) is running with nothing to do",
                       "Idle 15 minutes and still billing; it should have stopped itself after 10.", stop: stopCommand(for: c.machine))
            }
            cloudIdle[c.machine.id] = e
        }
    }

    private func track(_ e: inout Episode, _ wrong: Bool, after: TimeInterval, _ now: Date, tell: () -> Void) {
        guard wrong else { e = Episode(); return }
        if e.since == nil { e.since = now }
        if !e.told, let since = e.since, now.timeIntervalSince(since) >= after {
            e.told = true
            tell()
        }
    }

    /// The command that stops a cloud machine: its start command's `stop` beside it (the
    /// runbook's start and stop scripts), if there is one.
    private func stopCommand(for machine: Machine) -> String? {
        guard let start = machine.start, start.hasSuffix("/start") else { return nil }
        let stop = String(start.dropLast("start".count)) + "stop"
        let path = (stop as NSString).expandingTildeInPath
        return FileManager.default.isExecutableFile(atPath: path) ? stop : nil
    }

    private func notify(_ id: String, _ title: String, _ body: String, stop: String? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let stop {
            content.categoryIdentifier = "cloud"
            content.userInfo = ["stop": stop]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Shown even while Cpuq is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Stop It runs the machine's stop command; clicking the notification opens the window.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let stop = response.notification.request.content.userInfo["stop"] as? String
        Task { @MainActor in
            if action == "stop", let stop {
                Task.detached(priority: .userInitiated) {
                    _ = Self.shell(stop)
                    await MainActor.run { self.pollClouds() }
                }
            } else {
                self.showGraphs()
            }
        }
        completionHandler()
    }

    /// "Cpuq 0.14.3 · cpuq 0.13.0", in grey: the app's version and the cpuq it reads.
    private func versions() -> NSMenuItem {
        var s = "Cpuq \(appVersion)"
        if let cli = status?.version, !cli.isEmpty { s += " · cpuq \(cli)" }
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        return item
    }

    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    // MARK: - The app's shape

    /// An ordinary app (Dock icon, menu bar, ⌘Tab) while the window is open, or always if Settings
    /// says so, or whenever the chip is hidden (else nothing would reach it); otherwise only the
    /// chip.
    private func applyShape() {
        let chip = Prefs.showInMenuBar
        if item.isVisible != chip { item.isVisible = chip }
        let open = graphsWindow?.isVisible ?? false
        let want: NSApplication.ActivationPolicy = open || Prefs.dockAlways || !chip ? .regular : .accessory
        guard NSApp.activationPolicy() != want else { return }
        NSApp.setActivationPolicy(want)
        if want == .regular && open { NSApp.activate() }
    }

    /// The menu bar while Cpuq is an ordinary app: Cpuq, View (the machines, the theme, the live
    /// view) and Window.
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Cpuq")
        appMenu.addItem(withTitle: "About Cpuq", action: #selector(showAbout), keyEquivalent: "").target = self
        if Bundle.main.bundleURL.pathExtension == "app" {
            let check = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            check.target = updater
            appMenu.addItem(check)
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Cpuq", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cpuq", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Cpuq", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let view = NSMenu(title: "View")
        view.delegate = self
        for (i, m) in ([graphs] + remotes).enumerated() {
            let pick = NSMenuItem(title: m.machine.name, action: #selector(pickMachine(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
            pick.target = self
            pick.representedObject = m.machine.id
            view.addItem(pick)
        }
        view.addItem(.separator())
        view.addItem(themeItem())
        view.addItem(.separator())
        view.addItem(withTitle: "Open Live View in Terminal", action: #selector(openLiveView), keyEquivalent: "l").target = self
        viewMenu = view
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        return main
    }

    /// The View menu's checkmarks as it opens: the machine shown, and the theme's.
    private func markView(_ view: NSMenu) {
        let shown = UserDefaults.standard.string(forKey: "machine") ?? "local"
        for item in view.items where item.action == #selector(pickMachine(_:)) {
            item.state = item.representedObject as? String == shown ? .on : .off
        }
        if let theme = view.items.first(where: { $0.title == "Theme" }) { theme.submenu = themeItem().submenu }
    }

    @objc private func pickMachine(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "machine")
        showGraphs()
    }

    @objc private func showAbout() {
        NSApp.activate()
        var credits = "Reads cpuq"
        if let cli = status?.version, !cli.isEmpty { credits += " \(cli)" }
        if let path = findCpuq() { credits += " at \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))" }
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Cpuq",
            .applicationVersion: appVersion,
            .version: "",
            .credits: NSAttributedString(string: credits, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Cpuq Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Themes

    /// Theme ▸ the themes, each with its colors, then Automatic, Light and Dark.
    private func themeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let dark = (graphsWindow?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for theme in Theme.all {
            let t = NSMenuItem(title: theme.name, action: #selector(pickTheme(_:)), keyEquivalent: "")
            t.target = self
            t.representedObject = theme.id
            t.image = theme.swatch(dark: dark)
            t.state = theme.id == Theme.current.id ? .on : .off
            sub.addItem(t)
        }
        sub.addItem(.separator())
        for (id, title) in [("auto", "Automatic"), ("light", "Light"), ("dark", "Dark")] {
            let a = NSMenuItem(title: title, action: #selector(pickAppearance(_:)), keyEquivalent: "")
            a.target = self
            a.representedObject = id
            a.state = id == Theme.appearanceName ? .on : .off
            sub.addItem(a)
        }
        sub.addItem(.separator())
        let fx = NSMenuItem(title: "Visual Effects", action: #selector(toggleEffects), keyEquivalent: "")
        fx.target = self
        fx.state = Liveliness.shared.effects ? .on : .off
        sub.addItem(fx)
        item.submenu = sub
        return item
    }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Theme.use(id)
        // GraphsView redraws itself on the stored theme; the window's frame and border too.
        graphsWindow?.contentView?.needsDisplay = true
        graphsWindow?.invalidateShadow()
    }

    @objc private func toggleEffects() {
        Liveliness.shared.effects.toggle()
    }

    @objc private func pickAppearance(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Theme.appearanceName = id
        graphsWindow?.appearance = Theme.appearance
    }

    // MARK: - The graphs window

    @objc private func showGraphs() {
        if graphsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 780),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "cpuq"
            window.isReleasedWhenClosed = false
            // The cells animate smoothly only while the mouse moves in the window or it is
            // resized (Liveliness); otherwise once a second.
            window.acceptsMouseMovedEvents = true
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]) { [weak window] event in
                if let window, event.window === window { Liveliness.shared.poke() }
                return event
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { Liveliness.shared.poke() }
            }
            // Covered, minimized or on another space: no frames for effects nobody sees.
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { Liveliness.shared.visible = window?.occlusionState.contains(.visible) ?? false }
            }
            window.appearance = Theme.appearance
            // The window is the size it is given and no other: what is in it never grows or
            // shrinks it, and everything in it fits, the charts sharing what height there is.
            let host = NSHostingView(rootView: GraphsView(models: [graphs] + remotes, control: { [weak self] machine, action, pid, who in
                self?.perform(action, pid: String(pid), who: who, on: machine)
            }, start: { [weak self] model in self?.startMachine(model) }))
            host.sizingOptions = []
            // The minimum as constraints the window cannot break: contentMinSize alone let a
            // drag, a tile or an accessibility resize take the window down to a sliver.
            let content = NSView()
            host.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                host.topAnchor.constraint(equalTo: content.topAnchor),
                host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                content.widthAnchor.constraint(greaterThanOrEqualToConstant: GraphsView.minimumSize.width),
                content.heightAnchor.constraint(greaterThanOrEqualToConstant: GraphsView.minimumSize.height),
            ])
            window.contentView = content
            window.contentMinSize = GraphsView.minimumSize
            window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: GraphsView.minimumSize)).size
            window.delegate = sizeGuard
            window.center()
            // Where it was and how big, kept from one opening to the next; a frame saved smaller
            // than the minimum grows to it.
            window.setFrameAutosaveName("cpuq graphs")
            var frame = window.frame
            if frame.width < window.minSize.width || frame.height < window.minSize.height {
                frame.size = NSSize(width: max(frame.width, window.minSize.width), height: max(frame.height, window.minSize.height))
                window.setFrame(frame, display: false)
            }
            graphsWindow = window
            // Closed, the app goes back to being the chip (unless Settings keeps the Dock icon).
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyShape() } }
            }
            // History changes slowly: read it now and each minute while the window is open.
            historyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHistory() }
            }
        }
        NSApp.activate()
        graphsWindow?.makeKeyAndOrderFront(nil)
        applyShape()
        // Once it is on screen: refreshHistory skips a window nobody sees, so read before
        // this, the history waited a minute for the next refresh.
        refreshHistory()
        pollRemotes()
    }

    private func refreshHistory() {
        guard graphsWindow?.isVisible ?? true else { return }
        Task.detached(priority: .utility) {
            let jobs = Self.readHistory()
            await MainActor.run { self.graphs.setHistory(jobs) }
        }
        for m in remotes {
            let host = m.machine.id
            Task.detached(priority: .utility) {
                guard case .success(let data) = Self.remote(host, ["history", "--json", "--limit", "500"]),
                      let jobs = try? Job.decodeList(data) else { return }
                await MainActor.run { m.setHistory(jobs) }
            }
        }
    }

    private func name(_ label: String, _ command: String) -> String {
        label.isEmpty ? String(command.split(separator: " ").first ?? "job") : label
    }

    func perform(_ action: String, pid: String, who: String, on machine: Machine = .local) {
        let ask: (String, String)? = switch action {
        case "start": ("Start \(who) now?", "It starts past the queue and the budget, so the load goes up until other jobs finish.")
        case "stop": ("Stop \(who)?", "Its work so far is lost; it gets SIGTERM and can clean up.")
        default: nil
        }
        if let (title, detail) = ask {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            alert.addButton(withTitle: action == "start" ? "Start Now" : "Stop")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let host: String? = machine.isLocal ? nil : machine.id
        Task.detached(priority: .userInitiated) {
            if let host { _ = Self.remote(host, [action, pid]) } else { _ = Self.run([action, pid]) }
            await MainActor.run {
                self.poll()
                self.pollRemotes()
            }
        }
    }

    /// A line of the status. It opens the graphs when chosen, which also keeps it in full color:
    /// a menu draws an item that does nothing grayed out.
    private func text(_ s: String, bold: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: #selector(showGraphs), keyEquivalent: "")
        item.target = self
        let font = bold ? NSFont.menuFont(ofSize: 0).bold : NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.attributedTitle = NSAttributedString(string: s, attributes: [.font: font])
        return item
    }

    @objc private func openLiveView() {
        guard let path = findCpuq() else { return }
        // `status --watch` is cpuq 0.4.0's; an older cpuq gets the same view
        // redrawn by the shell.
        let command = supportsWatch(version: status?.version ?? "")
            ? "\(path) status --watch"
            : "while :; do clear; \(path) status; sleep 2; done"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    // MARK: - The icon

    /// The chip, 18 pt: the app icon's geometry (assets/menubar/cpuqTemplate-N.svg),
    /// pins and body stroked, the four cores filled, `level` of them solid and
    /// the rest at 30%. A template image, so the system tints it.
    private func chip(level: Int, tint: NSColor? = nil, broken: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let ink = tint ?? .black
            ctx.translateBy(x: 9, y: 9)
            ctx.scaleBy(x: 0.0321, y: 0.0321)
            ctx.translateBy(x: -444.5, y: -452)
            ctx.setStrokeColor(ink.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineWidth(40)
            for x in [382.0, 472, 562] {
                ctx.move(to: CGPoint(x: x, y: 212)); ctx.addLine(to: CGPoint(x: x, y: 270))
            }
            for y in [362.0, 452, 542] {
                ctx.move(to: CGPoint(x: 232, y: y)); ctx.addLine(to: CGPoint(x: 290, y: y))
            }
            for x in [382.0, 472] {
                ctx.move(to: CGPoint(x: x, y: 634)); ctx.addLine(to: CGPoint(x: x, y: 692))
            }
            ctx.strokePath()
            ctx.setLineWidth(48)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 292, y: 272, width: 360, height: 360), cornerWidth: 72, cornerHeight: 72, transform: nil))
            ctx.strokePath()
            let cells = [CGPoint(x: 348, y: 328), CGPoint(x: 486, y: 328), CGPoint(x: 348, y: 466), CGPoint(x: 486, y: 466)]
            for (i, origin) in cells.enumerated() {
                ctx.setFillColor(ink.withAlphaComponent(i < level ? 1 : 0.3).cgColor)
                ctx.addPath(CGPath(roundedRect: CGRect(origin: origin, size: CGSize(width: 110, height: 110)), cornerWidth: 24, cornerHeight: 24, transform: nil))
                ctx.fillPath()
            }
            if broken {
                // Struck through: cpuq cannot be read, which an empty chip would hide.
                ctx.setLineWidth(56)
                ctx.move(to: CGPoint(x: 240, y: 660)); ctx.addLine(to: CGPoint(x: 660, y: 240))
                ctx.strokePath()
            }
            return true
        }
        // A template image takes the menu bar's own color; a tinted one keeps its orange.
        image.isTemplate = tint == nil
        return image
    }
}

extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}

/// Notes, as Sparkle relaunches the app after an update, whether the graphs window was open.
final class UpdateRelaunch: NSObject, SPUUpdaterDelegate {
    static let key = "graphsOpenAtUpdate"
    var graphsOpen: () -> Bool = { false }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        UserDefaults.standard.set(graphsOpen(), forKey: Self.key)
        UserDefaults.standard.synchronize()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// The chip at first; applyShape makes it an ordinary app while the window is open.
app.setActivationPolicy(.accessory)
app.run()


/// Keeps the graphs window from being made smaller than its minimum, however it is resized.
final class MinimumSize: NSObject, NSWindowDelegate {
    func windowWillResize(_ window: NSWindow, to size: NSSize) -> NSSize {
        NSSize(width: max(size.width, window.minSize.width), height: max(size.height, window.minSize.height))
    }
}
