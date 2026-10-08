import AppKit
import CpuqCore
import Sparkle
import SwiftUI

/// The cpuq menu-bar app: the chip in the menu bar fills a cell per quarter
/// of the budget held, and its menu shows the queue. It only reads
/// `cpuq status --json`; cpuq itself needs no app.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var menuOpen = false
    private var rebuildOnClose = false
    private var status: Status?
    private var problem: String?
    private var timer: Timer?
    private var polling = false
    private let graphs = GraphModel()
    private var graphsWindow: NSWindow?
    private var historyTimer: Timer?
    /// Sparkle, running only in a Cpuq.app bundle: a binary run from the build folder never offers
    /// to replace itself.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.bundleURL.pathExtension == "app",
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.image = chip(level: 0)
        item.button?.toolTip = "cpuq"
        menu.delegate = self
        item.menu = menu
        rebuild()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
        menuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
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
                case .failure(let e):
                    self.status = nil
                    self.problem = e.message
                }
                let s = self.status
                self.item.button?.image = self.chip(level: meterLevel(held: s?.held ?? 0, budget: s?.budget ?? 0))
                self.item.button?.toolTip = s.map { "cpuq: \($0.held) of \($0.budget) cores in use · gate \($0.gate.text)" } ?? "cpuq: \(self.problem ?? "")"
                if self.menu.highlightedItem != nil || self.menu.numberOfItems == 0 { return }
                self.rebuild()
            }
        }
    }

    struct Problem: Error { let message: String }

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

    /// Fills `m` with the status and the commands.
    private func fill(_ m: NSMenu) {
        guard let s = status else {
            m.addItem(text(problem ?? "reading cpuq status…", bold: false))
            m.addItem(.separator())
            m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            return
        }
        let now = Date().timeIntervalSince1970
        let controls = supportsControls(version: s.version)
        m.addItem(text("cpuq \(s.version)  ·  \(s.held) of \(s.budget) cores in use", bold: true))
        let load = s.load.first.map { String(format: "%.1f", $0) } ?? "?"
        m.addItem(text("load \(load)  ·  memory \(s.memoryPressure)  ·  gate \(s.gate.text)", bold: false))

        if !s.holders.isEmpty {
            m.addItem(.separator())
            m.addItem(section("Running"))
            for h in s.holders {
                let using = h.using.map { String(format: "%.1f", $0) } ?? "–"
                let item = text("\(name(h.label, h.command))   \(h.cores) in use · \(using) active · \(age(now - Double(h.since)))\(h.paused ? " · paused" : "")", bold: false)
                if controls && !h.exclusive {
                    item.submenu = jobMenu([
                        h.paused ? ("Resume", "resume") : ("Pause", "pause"),
                        ("Stop…", "stop"),
                    ], pid: h.pid, who: name(h.label, h.command))
                }
                m.addItem(item)
            }
        }
        if !s.waiters.isEmpty {
            m.addItem(.separator())
            m.addItem(section("Waiting"))
            for w in s.waiters {
                let cores = w.exclusive ? "exclusive" : (w.max > w.cores ? "\(w.cores)–\(w.max)" : "\(w.cores)")
                let eta = w.eta.map { $0 < 1 ? "next" : "~" + age($0) } ?? "?"
                let item = text("\(w.order). \(name(w.label, w.command))   \(cores) cores · ETA \(eta)", bold: false)
                if controls {
                    item.submenu = jobMenu([("Move to Front", "first"), ("Start Now…", "start"), ("Cancel", "cancel")], pid: w.pid, who: name(w.label, w.command))
                }
                m.addItem(item)
            }
        }
        if !s.leases.isEmpty {
            m.addItem(.separator())
            m.addItem(section("Leases"))
            for l in s.leases {
                let by = l.holders.map { name($0.label, $0.command) }.joined(separator: ", ")
                m.addItem(text("\(l.name)   \(by.isEmpty ? "free" : by) · \(l.waiters.count) waiting", bold: false))
            }
        }
        let outside = s.outside.reduce(0) { $0 + $1.using }
        if outside >= 1 {
            m.addItem(.separator())
            m.addItem(section(String(format: "Outside cpuq: %.1f cores active", outside)))
            for o in s.outside {
                m.addItem(text(String(format: "%@ (%d)   %.1f", o.name, o.pid, o.using), bold: false))
            }
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Show Graphs…", action: #selector(showGraphs), keyEquivalent: "g").target = self
        m.addItem(withTitle: "Open Live View in Terminal", action: #selector(openLiveView), keyEquivalent: "l").target = self
        if Bundle.main.bundleURL.pathExtension == "app" {
            let check = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            check.target = updater
            m.addItem(check)
        }
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
            // The window is the size it is given and no other: what is in it never grows or
            // shrinks it, and everything in it fits, the charts sharing what height there is.
            let host = NSHostingView(rootView: GraphsView(model: graphs, control: { [weak self] action, pid, who in self?.perform(action, pid: String(pid), who: who) }))
            host.sizingOptions = []
            window.contentView = host
            window.contentMinSize = GraphsView.minimumSize
            window.center()
            // Where it was and how big, kept from one opening to the next.
            window.setFrameAutosaveName("cpuq graphs")
            graphsWindow = window
            // History changes slowly: read it now and each minute while the window is open.
            historyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHistory() }
            }
        }
        refreshHistory()
        NSApp.activate()
        graphsWindow?.makeKeyAndOrderFront(nil)
    }

    private func refreshHistory() {
        guard graphsWindow?.isVisible ?? true else { return }
        Task.detached(priority: .utility) {
            let jobs = Self.readHistory()
            await MainActor.run { self.graphs.setHistory(jobs) }
        }
    }

    private func name(_ label: String, _ command: String) -> String {
        label.isEmpty ? String(command.split(separator: " ").first ?? "job") : label
    }

    /// A job's actions: each runs `cpuq ACTION PID`.
    private func jobMenu(_ actions: [(String, String)], pid: Int, who: String) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in actions {
            let item = NSMenuItem(title: title, action: #selector(control(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [action, String(pid), who]
            menu.addItem(item)
        }
        return menu
    }

    /// Runs a job action, asking first for the two that cost something: starting a job past the
    /// budget raises the load, and stopping one throws its work away.
    @objc private func control(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String], info.count == 3 else { return }
        perform(info[0], pid: info[1], who: info[2])
    }

    func perform(_ action: String, pid: String, who: String) {
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
        Task.detached(priority: .userInitiated) {
            _ = Self.run([action, pid])
            await MainActor.run { self.poll() }
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

    private func section(_ s: String) -> NSMenuItem {
        if #available(macOS 14, *) { return NSMenuItem.sectionHeader(title: s) }
        return text(s, bold: true)
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
    private func chip(level: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: 9, y: 9)
            ctx.scaleBy(x: 0.0321, y: 0.0321)
            ctx.translateBy(x: -444.5, y: -452)
            ctx.setStrokeColor(NSColor.black.cgColor)
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
                ctx.setFillColor(NSColor.black.withAlphaComponent(i < level ? 1 : 0.3).cgColor)
                ctx.addPath(CGPath(roundedRect: CGRect(origin: origin, size: CGSize(width: 110, height: 110)), cornerWidth: 24, cornerHeight: 24, transform: nil))
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// A menu-bar app: no Dock icon, no main window.
app.setActivationPolicy(.accessory)
app.run()
