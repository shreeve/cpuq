import AppKit
import CpuqCore

/// The cpuq menu-bar app: the chip in the menu bar fills a cell per quarter
/// of the budget held, and its menu shows the queue. It only reads
/// `cpuq status --json`; cpuq itself needs no app.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var status: Status?
    private var problem: String?
    private var timer: Timer?
    private var polling = false

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
                case .failure(let e):
                    self.status = nil
                    self.problem = e.message
                }
                let s = self.status
                self.item.button?.image = self.chip(level: meterLevel(held: s?.held ?? 0, budget: s?.budget ?? 0))
                self.item.button?.toolTip = s.map { "cpuq: \($0.held) of \($0.budget) cores held · gate \($0.gate.text)" } ?? "cpuq: \(self.problem ?? "")"
                if self.menu.highlightedItem != nil || self.menu.numberOfItems == 0 { return }
                self.rebuild()
            }
        }
    }

    struct Problem: Error { let message: String }

    nonisolated private static func readStatus() -> Result<Status, Problem> {
        guard let path = findCpuq() else {
            return .failure(Problem(message: "cpuq is not installed (~/.local/bin, /opt/homebrew/bin or /usr/local/bin)"))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["status", "--json"]
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
        guard p.terminationStatus == 0 else { return .failure(Problem(message: "cpuq status failed (\(p.terminationStatus))")) }
        do {
            return .success(try Status.decode(data))
        } catch {
            return .failure(Problem(message: "cannot read cpuq status: \(error.localizedDescription)"))
        }
    }

    // MARK: - The menu

    private func rebuild() {
        menu.removeAllItems()
        guard let s = status else {
            menu.addItem(text(problem ?? "reading cpuq status…", bold: false))
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            return
        }
        let now = Date().timeIntervalSince1970
        menu.addItem(text("cpuq \(s.version)  ·  \(s.held) of \(s.budget) cores held", bold: true))
        let load = s.load.first.map { String(format: "%.1f", $0) } ?? "?"
        menu.addItem(text("load \(load)  ·  memory \(s.memoryPressure)  ·  gate \(s.gate.text)", bold: false))

        if !s.holders.isEmpty {
            menu.addItem(.separator())
            menu.addItem(section("Running"))
            for h in s.holders {
                let using = h.using.map { String(format: "%.1f", $0) } ?? "–"
                menu.addItem(text("\(name(h.label, h.command))   \(h.cores) granted · \(using) using · \(age(now - Double(h.since)))", bold: false))
            }
        }
        if !s.waiters.isEmpty {
            menu.addItem(.separator())
            menu.addItem(section("Waiting"))
            for w in s.waiters {
                let cores = w.exclusive ? "exclusive" : (w.max > w.cores ? "\(w.cores)–\(w.max)" : "\(w.cores)")
                let eta = w.eta.map { $0 < 1 ? "next" : "~" + age($0) } ?? "?"
                menu.addItem(text("\(w.order). \(name(w.label, w.command))   \(cores) cores · ETA \(eta)", bold: false))
            }
        }
        if !s.leases.isEmpty {
            menu.addItem(.separator())
            menu.addItem(section("Leases"))
            for l in s.leases {
                let by = l.holders.map { name($0.label, $0.command) }.joined(separator: ", ")
                menu.addItem(text("\(l.name)   \(by.isEmpty ? "free" : by) · \(l.waiters.count) waiting", bold: false))
            }
        }
        let outside = s.outside.reduce(0) { $0 + $1.using }
        if outside >= 1 {
            menu.addItem(.separator())
            menu.addItem(section(String(format: "Outside cpuq: %.1f cores", outside)))
            for o in s.outside {
                menu.addItem(text(String(format: "%@ (%d)   %.1f", o.name, o.pid, o.using), bold: false))
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Live View in Terminal", action: #selector(openLiveView), keyEquivalent: "l").target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func name(_ label: String, _ command: String) -> String {
        label.isEmpty ? String(command.split(separator: " ").first ?? "job") : label
    }

    private func text(_ s: String, bold: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        let font = bold ? NSFont.menuFont(ofSize: 0).bold : NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.attributedTitle = NSAttributedString(string: s, attributes: [.font: font])
        item.isEnabled = false
        return item
    }

    private func section(_ s: String) -> NSMenuItem {
        if #available(macOS 14, *) { return NSMenuItem.sectionHeader(title: s) }
        return text(s, bold: true)
    }

    @objc private func openLiveView() {
        guard let path = findCpuq() else { return }
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(path) status --watch\"\nend tell"
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
