import Charts
import CpuqCore
import SwiftUI

/// A machine whose cpuq the window shows: this Mac, or one of its remotes, reached over ssh.
struct Machine: Hashable, Identifiable {
    /// Where the window's "cleared before" mark is kept for it.
    var clearedKey: String { isLocal ? "clearedBefore" : "clearedBefore.\(id)" }

    /// "local", or the ssh name.
    let id: String
    var isLocal: Bool { id == "local" }
    /// The name shown: this Mac's host name (short, as `cpuq status` titles it), or the ssh name.
    var name: String {
        guard isLocal else { return id }
        // gethostname, as cpuq titles its status: ProcessInfo's hostName can be a network name
        // with a suffix ("pop-2") that is not the machine's own.
        var buf = [CChar](repeating: 0, count: 256)
        let full = gethostname(&buf, buf.count) == 0 ? String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        let host = full.split(separator: ".").first.map(String.init) ?? ""
        return host.isEmpty || host == "localhost" ? "This Mac" : host
    }
    /// How to start it when it is stopped (`remote_start.HOST` in cpuq's config), if it can be.
    var start: String? = nil

    static let local = Machine(id: "local")
}

/// What the activity window shows of one machine: its CPUs over the recent past, the jobs it
/// ran and waited for, and the jobs its `cpuq history` remembers.
@Observable
final class GraphModel {
    /// A job's hold on its cores.
    struct Block: Identifiable {
        /// Its cpuq pid and the second it started.
        let id: String
        let project: String
        let label: String
        /// Which of the budget's cores it holds, from 0.
        var lanes: [Int]
        var from: Date
        /// Nil while it runs.
        var to: Date?
        /// Cores active, measured at every poll while the app watched it.
        var active: [Reading] = []
        /// Its average active cores from history, for the stretch the app did not watch.
        var average: Double?
        /// A timing window (`--exclusive`): it held the Mac alone.
        var exclusive = false
    }

    struct Reading {
        let at: Date
        let cores: Double
    }

    /// A job waiting its turn.
    struct Wait: Identifiable {
        let id: String
        let project: String
        let label: String
        let cores: String
        /// The fewest cores it asked for.
        var need = 1
        var from: Date
        var to: Date?
        /// Waiting for a timing window of its own.
        var exclusive = false
    }

    /// The machine at one poll, for the top line when pointing at that moment.
    struct Sample {
        let at: Date
        /// CPU used by the busiest processes outside cpuq, in cores.
        let outside: Double
        let load: Double
        /// cpuq's gate then: open, or shut by memory pressure, the load valve or spacing (one
        /// admission per 10 s over the budget); jobs wait even beside free cores while it is shut.
        var gate = "open"
        var gateText = "open"
        var gateOpen: Bool { gate == "open" }
        /// How busy the Mac's CPUs were since the poll before, 0 to 1, measured by the app.
        var busy: Double? = nil
        /// The same for each CPU, in the kernel's order.
        var perCPU: [Double]? = nil
    }

    /// A project's finished jobs, summed.
    struct Totals: Identifiable {
        var id: String { project }
        let project: String
        let jobs: Int
        /// Core-hours held and used.
        let held: Double
        let used: Double
        var efficiency: Double { held > 0 ? used / held : 0 }
        let medianWait: Double
        let longestWait: Double
    }

    static let keep: TimeInterval = 3600

    private(set) var blocks: [Block] = []
    private(set) var waits: [Wait] = []
    private(set) var samples: [Sample] = []
    private(set) var status: Status?
    private(set) var started = Date()
    private(set) var totals: [Totals] = []
    private var seeded = false
    let machine: Machine
    private var ticks: CPUTicks?
    private var cpuTicks: [CPUTicks]?
    /// The performance cores: how many (the last CPUs) and their name; nil on one kind of core
    /// (and for another machine, whose kinds of core the app cannot see).
    let performance: (count: Int, name: String)?
    /// When the last status came, and why the last poll failed: nil while the machine answers.
    private(set) var problem: String?

    init(machine: Machine = .local) {
        self.machine = machine
        performance = machine.isLocal ? CPUTicks.performanceCores() : nil
        if machine.isLocal {
            ticks = CPUTicks.now()
            cpuTicks = CPUTicks.perCPU()
        }
        cleared = {
            let t = UserDefaults.standard.double(forKey: machine.clearedKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }()
    }

    /// The machine's CPUs: this Mac's online, or what the other machine's cpuq reports.
    var cpus: Double {
        if machine.isLocal { return Double(ProcessInfo.processInfo.activeProcessorCount) }
        if let n = status?.activeCores, n > 0 { return Double(n) }
        return Double(max(status?.cpuTicks?.count ?? 1, 1))
    }

    /// Whether the past from `cpuq samples` has been read in (once per machine).
    var backfilled = false

    /// The hour before the app watched, from the machine's recorder: its readings go in ahead of
    /// the app's own, so the charts and the idle-wait judgement have the CPUs from before launch.
    func backfill(_ recorded: [RecordedSample], now: Date = Date()) {
        backfilled = true
        let first = samples.first?.at ?? now
        let since = max(now.addingTimeInterval(-Self.keep), cleared ?? .distantPast)
        let older = recorded.compactMap { r -> Sample? in
            let at = Date(timeIntervalSince1970: r.t)
            guard at >= since, at < first.addingTimeInterval(-1), !r.cpu.isEmpty else { return nil }
            let per = r.cpu.map { $0 / 100 }
            return Sample(at: at, outside: 0, load: r.load, gate: r.gate, gateText: r.gate == "open" ? "open" : r.gate.replacingOccurrences(of: "_", with: " "),
                          busy: per.reduce(0, +) / Double(per.count), perCPU: per)
        }
        guard !older.isEmpty else { return }
        samples = older.sorted { $0.at < $1.at } + samples
        if let oldest = older.first?.at, oldest < started { started = oldest }
    }

    /// The machine did not answer: why. The last status stays for the charts.
    func failed(_ why: String) {
        problem = why
        upSince = nil
    }

    /// Since when it has answered without a break, as the app saw it.
    private(set) var upSince: Date?

    /// Its running hours this month (a cloud machine's, from its boot journal), and when they
    /// were last counted.
    var monthHours: Double?
    var monthCheckedAt: Date?

    /// Hours: "1.9h" under ten, "14h" from there.
    static func hours(_ h: Double) -> String {
        h < 10 ? String(format: "%.1fh", h) : "\(Int(h.rounded()))h"
    }

    /// A cloud machine (one cpuq can start) that is up, and so costing money.
    var isCloudRunning: Bool { machine.start != nil && problem == nil && upSince != nil }

    /// How long it has been up: since it booted, else since the app first saw it answer. "23m",
    /// "1h 05m".
    var upFor: String {
        let since = status?.bootTime.map { Date(timeIntervalSince1970: $0) } ?? upSince ?? Date()
        let s = Int(Date().timeIntervalSince(since))
        return s < 3600 ? "\(max(s / 60, 1))m" : "\(s / 3600)h " + String(format: "%02dm", s / 60 % 60)
    }

    /// Its start command is running (the Start button), and what it last said.
    var starting = false
    var startNote: String?
    /// Each project's palette slot, assigned the first time it is seen and kept across launches,
    /// so a project's color never changes as others come and go.
    private var slots = (UserDefaults.standard.dictionary(forKey: "projectPalette") as? [String: Int]) ?? [:]

    var budget: Int { max(status?.capacity ?? 8, 1) }

    func add(_ s: Status, at now: Date = Date()) {
        status = s
        problem = nil
        if upSince == nil { upSince = now }
        var running: Set<String> = []
        for h in s.holders {
            let id = "\(h.pid)-\(h.since)"
            running.insert(id)
            if let i = blocks.firstIndex(where: { $0.id == id }) {
                if let u = h.using { blocks[i].active.append(Reading(at: now, cores: u)) }
            } else {
                let from = Date(timeIntervalSince1970: Double(h.since))
                blocks.append(Block(id: id, project: Self.group(h.label, h.note), label: Self.label(h.label, h.command),
                                    lanes: h.slots.isEmpty ? fit(h.cores, from: from) : h.slots, from: from,
                                    active: h.using.map { [Reading(at: now, cores: $0)] } ?? [], exclusive: h.exclusive))
                remember(Self.group(h.label, h.note))
            }
        }
        for i in blocks.indices where blocks[i].to == nil && !running.contains(blocks[i].id) { blocks[i].to = now }

        var queued: Set<String> = []
        for w in s.waiters {
            let id = "\(w.since)-\(w.label)-\(w.command)"
            queued.insert(id)
            if !waits.contains(where: { $0.id == id }) {
                waits.append(Wait(id: id, project: Self.group(w.label, w.note), label: Self.label(w.label, w.command), cores: Self.wants(w),
                                  need: w.exclusive ? budget : max(w.cores, 1), from: Date(timeIntervalSince1970: Double(w.since)), exclusive: w.exclusive))
                remember(Self.group(w.label, w.note))
            }
        }
        for i in waits.indices where waits[i].to == nil && !queued.contains(waits[i].id) { waits[i].to = now }

        // This Mac's CPUs are read here; another machine's come with its status.
        let remote = machine.isLocal ? nil : s.ticks
        let t = machine.isLocal ? CPUTicks.now() : remote?.all
        let busy = ticks.flatMap { a in t.flatMap { CPUTicks.busy(from: a, to: $0) } }
        ticks = t
        let each = machine.isLocal ? CPUTicks.perCPU() : remote?.each
        var perCPU: [Double]? = nil
        if let a = cpuTicks, let b = each, a.count == b.count {
            perCPU = zip(a, b).map { CPUTicks.busy(from: $0, to: $1) ?? 0 }
        }
        cpuTicks = each
        samples.append(Sample(at: now, outside: s.outside.reduce(0) { $0 + $1.using }, load: s.load.first ?? 0,
                              gate: s.gate.state, gateText: s.gate.text, busy: busy, perCPU: perCPU))
        let cutoff = now.addingTimeInterval(-Self.keep)
        samples.removeAll { $0.at < cutoff }
        blocks.removeAll { ($0.to ?? now) < cutoff }
        waits.removeAll { ($0.to ?? now) < cutoff }
    }

    func setHistory(_ jobs: [Job]) {
        if !seeded { seed(jobs) }
        // A job that ran before the app watched it gets its average from history once it ends,
        // for the stretch the app did not see.
        for i in blocks.indices where blocks[i].average == nil && blocks[i].to != nil {
            let b = blocks[i]
            if let j = jobs.first(where: { $0.pid.map { b.id.hasPrefix("\($0)-") } ?? false && abs(($0.started ?? 0) - b.from.timeIntervalSince1970) < 2 }) {
                blocks[i].average = j.used
            }
        }
        var by: [String: (jobs: Int, held: Double, used: Double, waits: [Double])] = [:]
        for j in jobs where j.state == "done" && j.pool == "cores" {
            guard let cores = j.cores, let ran = j.ran else { continue }
            var e = by[Self.project(j.label)] ?? (0, 0, 0, [])
            e.jobs += 1
            e.held += Double(cores) * ran / 3600
            e.used += (j.used ?? 0) * ran / 3600
            if let w = j.waited { e.waits.append(w) }
            by[Self.project(j.label)] = e
        }
        totals = by.map { k, v in
            let waits = v.waits.sorted()
            return Totals(project: k, jobs: v.jobs, held: v.held, used: v.used,
                          medianWait: waits.isEmpty ? 0 : waits[waits.count / 2], longestWait: waits.last ?? 0)
        }.sorted { $0.held > $1.held }
    }

    /// The hour before the app started watching, from `cpuq history`: each finished job on the
    /// cores it took (or the lowest that were free, when it names none), with its
    /// average active cores, and each wait from queueing to starting.
    private func seed(_ jobs: [Job], now: Date = Date()) {
        seeded = true
        let since = max(now.addingTimeInterval(-Self.keep), cleared ?? .distantPast).timeIntervalSince1970
        for j in jobs.sorted(by: { ($0.started ?? 0) < ($1.started ?? 0) }) where j.pool == "cores" && j.state != "active" {
            guard let start = j.started, let cores = j.cores, (j.ended ?? start) >= since else { continue }
            // A job the app saw start is a block already.
            if blocks.contains(where: { $0.id.hasPrefix("\(j.pid ?? -1)-") && abs($0.from.timeIntervalSince1970 - start) < 2 }) { continue }
            let from = Date(timeIntervalSince1970: max(start, since))
            let to = Date(timeIntervalSince1970: j.ended ?? start)
            blocks.append(Block(id: "\(j.pid ?? 0)-\(Int(start))", project: Self.group(j.label, j.note), label: j.label.isEmpty ? "-" : j.label,
                                lanes: j.slots ?? fit(cores, from: from, to: to), from: from, to: to, average: j.used, exclusive: j.exclusive))
            if let w = j.waited, w >= 1, start > since {
                waits.append(Wait(id: "h\(j.id)", project: Self.group(j.label, j.note), label: j.label, cores: "\(cores) cores",
                                  need: cores, from: Date(timeIntervalSince1970: start - w), to: from, exclusive: j.exclusive))
            }
            remember(Self.group(j.label, j.note))
        }
        blocks.sort { $0.from < $1.from }
    }

    /// The lowest `n` adjacent cores free from `from` to `to` (or on), else the lowest free ones.
    private func fit(_ n: Int, from: Date, to: Date? = nil) -> [Int] {
        var busy = Set<Int>()
        for b in blocks where b.from < (to ?? .distantFuture) && (b.to ?? .distantFuture) > from { busy.formUnion(b.lanes) }
        let width = max(budget, n)
        for start in 0...(width - n) where (start..<start + n).allSatisfy({ !busy.contains($0) }) { return Array(start..<start + n) }
        let free = (0..<width).filter { !busy.contains($0) }
        return free.count >= n ? Array(free.prefix(n)) : Array(0..<n)
    }

    private func remember(_ project: String) {
        // The lowest slot no other project seen in the last hour holds, so the projects on
        // screen together never share a color while the palette lasts. A project keeps its
        // slot unless another on screen now shares its color.
        let near = Set(blocks.map(\.project) + waits.map(\.project)).subtracting([project])
        let taken = Set(slots.filter { near.contains($0.key) }.map { $0.value % Self.palette.count })
        if let mine = slots[project], !taken.contains(mine % Self.palette.count) { return }
        slots[project] = (0..<Self.palette.count).first { !taken.contains($0) } ?? slots.count % Self.palette.count
        UserDefaults.standard.set(slots, forKey: "projectPalette")
    }

    /// A project's place in the palette, which also orders the stacked chart.
    func slot(_ project: String) -> Int { slots[project] ?? Int.max }

    /// Project colors, in the stacking order. The first six come from the theme (Theme.swift);
    /// the rest are the same in every theme. No grey: that is work outside cpuq.
    static let palette: [Color] = (0..<6).map { Alive.slot($0) } + [.mint, Color(red: 0.62, green: 0.82, blue: 0.08), .indigo, .teal]

    func color(_ project: String) -> Color {
        Self.palette[(slots[project] ?? 0) % Self.palette.count]
    }

    /// How far back there is anything to show.
    func oldest(now: Date) -> Date {
        max(([started] + blocks.map(\.from) + waits.map(\.from)).min() ?? now, cleared ?? .distantPast)
    }

    /// Where the window's data was cleared from, if it was: nothing older is shown, after a
    /// relaunch too (the seed from history skips it). cpuq's own history is untouched.
    private(set) var cleared: Date?

    /// Forgets everything older than `cutoff`: jobs and waits that ended before it go, those
    /// that span it are cut at it, and so are the readings.
    func clear(before cutoff: Date) {
        cleared = cutoff
        UserDefaults.standard.set(cutoff.timeIntervalSince1970, forKey: machine.clearedKey)
        blocks.removeAll { ($0.to ?? .distantFuture) <= cutoff }
        for i in blocks.indices where blocks[i].from < cutoff {
            blocks[i].from = cutoff
            blocks[i].active.removeAll { $0.at < cutoff }
        }
        waits.removeAll { ($0.to ?? .distantFuture) <= cutoff }
        for i in waits.indices where waits[i].from < cutoff { waits[i].from = cutoff }
        samples.removeAll { $0.at < cutoff }
        if started < cutoff { started = cutoff }
    }

    static func label(_ label: String, _ command: String) -> String {
        label.isEmpty ? String(command.prefix(40)) : label
    }

    static func wants(_ w: Status.Waiter) -> String {
        w.exclusive ? "every core" : (w.max > w.cores ? "\(w.cores)–\(w.max) cores" : w.cores == 1 ? "1 core" : "\(w.cores) cores")
    }

    /// What the charts split CPU by: the project, and with a note ("#881 markers") the project
    /// and the note, so one project's PRs show as bands of their own.
    static func group(_ label: String, _ note: String) -> String {
        note.isEmpty ? project(label) : "\(project(label)) \(note)"
    }

    static func project(_ label: String) -> String {
        label.isEmpty ? "unlabelled" : String(label.split(separator: ":", maxSplits: 1).first ?? "")
    }
}

struct GraphsView: View {
    /// This Mac first, then the remotes in cpuq's config.
    let models: [GraphModel]
    /// Runs a job action (`cpuq ACTION PID` on its machine), asking first where it costs something.
    var control: ((Machine, String, Int, String) -> Void)? = nil
    /// Starts a stopped machine with its `remote_start` command.
    var start: ((GraphModel) -> Void)? = nil
    /// The machine shown: ⌘1 for this Mac, ⌘2 and on for the remotes.
    @AppStorage("machine") private var shown = "local"

    private var model: GraphModel { models.first { $0.machine.id == shown } ?? models[0] }

    private var act: ((String, Int, String) -> Void)? {
        guard let control else { return nil }
        let machine = model.machine
        return { action, pid, who in control(machine, action, pid, who) }
    }
    /// Read here so that a new theme draws the whole window again.
    @AppStorage("theme") private var theme = "alive"
    @AppStorage("appearance") private var appearance = "auto"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if models.count > 1 { machinePicker }
                themeMenu
                modeMenu
                Spacer(minLength: 8)
                // The chips give way first when the window is narrow.
                ViewThatFits(in: .horizontal) { StatusChips(model: model); Color.clear.frame(width: 0, height: 0) }
            }
            if model.status == nil, let problem = model.problem {
                unreachable(problem)
            } else {
                NowView(model: model, control: act).id(model.machine.id)
            }
        }
        .padding(16)
        .frame(minWidth: Self.minimumSize.width, maxWidth: .infinity, minHeight: Self.minimumSize.height, maxHeight: .infinity, alignment: .topLeading)
        .background(Alive.window)
        .background(WindowAppearance(name: appearance))
        .id(theme)
    }

    /// The machines, ⌘1 to ⌘9 in order.
    private var machinePicker: some View {
        Picker("", selection: $shown) {
            ForEach(Array(models.enumerated()), id: \.element.machine.id) { i, m in
                (Text(m.machine.name + " ") + Text("⌘\(i + 1)").foregroundStyle(Alive.ink3)).tag(m.machine.id)
            }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help("The machine shown: this Mac, then the remotes in cpuq's config")
        .background {
            ZStack {
                ForEach(Array(models.prefix(9).enumerated()), id: \.element.machine.id) { i, m in
                    Button("") { shown = m.machine.id }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// A machine that does not answer: stopped, asleep or unreachable.
    private func unreachable(_ problem: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "powersleep").font(.system(size: 34)).foregroundStyle(Alive.ink3)
            Text("\(model.machine.name) is not answering").font(.title3.weight(.semibold))
            Text(problem).font(.callout).foregroundStyle(Alive.ink2).multilineTextAlignment(.center).frame(maxWidth: 420)
            if model.machine.start != nil {
                Text("cpuq starts it when this Mac and the others are full; it stops itself when idle.")
                    .font(.caption).foregroundStyle(Alive.ink3)
                if let start {
                    Button(model.starting ? "Starting \(model.machine.name)…" : "Start \(model.machine.name)") { start(model) }
                        .disabled(model.starting)
                        .padding(.top, 6)
                        .help("Runs its start command (remote_start.\(model.machine.id) in cpuq's config); it bills from now until it stops.")
                }
                if let note = model.startNote { Text(note).font(.caption).foregroundStyle(Alive.ink2).multilineTextAlignment(.center).frame(maxWidth: 420) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Watches Liveliness itself, so the window is not drawn again each time the mouse moves.
    private struct EffectsToggle: View {
        @ObservedObject private var live = Liveliness.shared
        var body: some View { Toggle("Visual Effects", isOn: $live.effects) }
    }

    static let modes = [("auto", "Automatic"), ("light", "Light"), ("dark", "Dark")]

    /// The theme, from a drop-down or ⌘T for the next one.
    private var themeMenu: some View {
        Menu {
            ForEach(Theme.all, id: \.id) { t in
                Toggle(t.name, isOn: Binding(get: { t.id == theme }, set: { _ in Theme.use(t.id) }))
            }
            Divider()
            EffectsToggle()
        } label: {
            Text((Theme.all.first { $0.id == theme } ?? Theme.all[0]).name + "  ") + Text("⌘T").foregroundStyle(Alive.ink3)
        }
        .menuStyle(.button).controlSize(.small).fixedSize()
        .help("The window's colors. ⌘T: the next theme")
        .background {
            Button("") {
                let i = Theme.all.firstIndex { $0.id == theme } ?? 0
                Theme.use(Theme.all[(i + 1) % Theme.all.count].id)
            }
            .keyboardShortcut("t", modifiers: .command).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// Automatic, Light or Dark, from a drop-down or ⌘M for the next one.
    private var modeMenu: some View {
        Menu {
            ForEach(Self.modes, id: \.0) { m in
                Toggle(m.1, isOn: Binding(get: { m.0 == appearance }, set: { _ in appearance = m.0 }))
            }
        } label: {
            Text((Self.modes.first { $0.0 == appearance } ?? Self.modes[0]).1 + "  ") + Text("⌘M").foregroundStyle(Alive.ink3)
        }
        .menuStyle(.button).controlSize(.small).fixedSize()
        .help("Automatic follows macOS; Light and Dark keep to one. ⌘M: the next")
        .background {
            Button("") {
                let i = Self.modes.firstIndex { $0.0 == appearance } ?? 0
                appearance = Self.modes[(i + 1) % Self.modes.count].0
            }
            .keyboardShortcut("m", modifiers: .command).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// The smallest the window goes: at this size everything in it still fits.
    static let minimumSize = CGSize(width: 560, height: 620)

}

/// A machine's finished jobs by project, from its `cpuq history`.
struct HistoryCard: View {
    let model: GraphModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("HISTORY").eyebrow()
                Text("finished jobs by project, from cpuq history").font(.caption).foregroundStyle(Alive.ink3)
                Spacer()
            }
            if model.totals.isEmpty {
                Text("cpuq history has no finished jobs yet.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Table(model.totals) {
                    TableColumn("Project") { t in
                        HStack(spacing: 6) { Circle().fill(model.color(t.project)).frame(width: 8, height: 8); Text(t.project) }
                    }
                    TableColumn("Jobs") { t in Text("\(t.jobs)").monospacedDigit() }.width(50)
                    TableColumn("Core-hours in use") { t in Text(String(format: "%.2f", t.held)).monospacedDigit() }
                    TableColumn("Active") { t in Text(String(format: "%.2f", t.used)).monospacedDigit() }
                    TableColumn("Share") { t in
                        // Used of held: noise for a project with next to nothing held.
                        if t.held < 0.01 {
                            Text("–").foregroundStyle(.secondary)
                        } else {
                            Text("\(Int((t.efficiency * 100).rounded()))%").monospacedDigit()
                                .foregroundStyle(t.efficiency < 0.5 ? Color.orange : Color.primary)
                        }
                    }
                    TableColumn("Median wait") { t in Text(age(t.medianWait)).monospacedDigit() }
                    TableColumn("Longest wait") { t in Text(age(t.longestWait)).monospacedDigit() }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .card()
    }
}

/// Sets the window's appearance: Automatic (follow macOS), Light or Dark.
struct WindowAppearance: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let name = name
        DispatchQueue.main.async {
            view.window?.appearance = name == "light" ? NSAppearance(named: .aqua) : name == "dark" ? NSAppearance(named: .darkAqua) : nil
        }
    }
}
