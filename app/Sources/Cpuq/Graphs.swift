import Charts
import CpuqCore
import SwiftUI

/// What the activity window shows: the budget's cores as lanes over the recent past, each cell
/// empty, held or busy, and the jobs `cpuq history` remembers.
@Observable
final class GraphModel {
    /// A job's hold on its cores.
    struct Block: Identifiable {
        /// Its cpuq pid and the second it started.
        let id: String
        let project: String
        let label: String
        /// Which of the budget's cores it holds, from 0 (in the jobs view, its row).
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
        let inUse: Int
        let active: Double
        /// CPU used by the busiest processes outside cpuq, in cores.
        let outside: Double
        let load: Double
        let waiting: Int
        /// cpuq's gate then: open, or shut by memory pressure, the load valve or spacing (one
        /// admission per 10 s over the budget); jobs wait even beside free cores while it is shut.
        var gate = "open"
        var gateText = "open"
        var gateOpen: Bool { gate == "open" }
        /// The load valve's trip level then, when cpuq reports it.
        var trip: Double? = nil
        /// Memory pressure as cpuq saw it: normal or high.
        var memory = ""
        /// How busy the Mac's CPUs were since the poll before, 0 to 1, measured by the app.
        var busy: Double? = nil
        /// The same for each CPU, in the kernel's order.
        var perCPU: [Double]? = nil
    }

    /// A project running now: what it holds and what it uses.
    struct Row: Identifiable {
        var id: String { project }
        let project: String
        let held: Int
        let used: Double
    }

    struct Waiting: Identifiable {
        let id: Int
        var pid = 0
        let label: String
        let cores: String
        let since: Int
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
    private var ticks = CPUTicks.now()
    private var cpuTicks = CPUTicks.perCPU()
    /// The performance cores: how many (the last CPUs) and their name; nil on one kind of core.
    let performance = CPUTicks.performanceCores()
    /// Each project's palette slot, assigned the first time it is seen and kept across launches,
    /// so a project's color never changes as others come and go.
    private var slots: [String: Int] = {
        migratePalette()
        return (UserDefaults.standard.dictionary(forKey: "projectPalette") as? [String: Int]) ?? [:]
    }()

    var budget: Int { max(status?.budget ?? 8, 1) }

    func add(_ s: Status, at now: Date = Date()) {
        status = s
        var running: Set<String> = []
        for h in s.holders {
            let id = "\(h.pid)-\(h.since)"
            running.insert(id)
            if let i = blocks.firstIndex(where: { $0.id == id }) {
                if let u = h.using { blocks[i].active.append(Reading(at: now, cores: u)) }
            } else {
                let from = Date(timeIntervalSince1970: Double(h.since))
                blocks.append(Block(id: id, project: Self.project(h.label), label: Self.label(h.label, h.command),
                                    lanes: h.slots.isEmpty ? fit(h.cores, from: from) : h.slots, from: from,
                                    active: h.using.map { [Reading(at: now, cores: $0)] } ?? [], exclusive: h.exclusive))
                remember(Self.project(h.label))
            }
        }
        for i in blocks.indices where blocks[i].to == nil && !running.contains(blocks[i].id) { blocks[i].to = now }

        var queued: Set<String> = []
        for w in s.waiters {
            let id = "\(w.since)-\(w.label)-\(w.command)"
            queued.insert(id)
            if !waits.contains(where: { $0.id == id }) {
                waits.append(Wait(id: id, project: Self.project(w.label), label: Self.label(w.label, w.command), cores: Self.wants(w),
                                  need: w.exclusive ? budget : max(w.cores, 1), from: Date(timeIntervalSince1970: Double(w.since)), exclusive: w.exclusive))
                remember(Self.project(w.label))
            }
        }
        for i in waits.indices where waits[i].to == nil && !queued.contains(waits[i].id) { waits[i].to = now }

        let t = CPUTicks.now()
        let busy = ticks.flatMap { a in t.flatMap { CPUTicks.busy(from: a, to: $0) } }
        ticks = t
        let each = CPUTicks.perCPU()
        var perCPU: [Double]? = nil
        if let a = cpuTicks, let b = each, a.count == b.count {
            perCPU = zip(a, b).map { CPUTicks.busy(from: $0, to: $1) ?? 0 }
        }
        cpuTicks = each
        samples.append(Sample(at: now, inUse: s.held, active: s.holders.reduce(0) { $0 + ($1.using ?? 0) },
                              outside: s.outside.reduce(0) { $0 + $1.using }, load: s.load.first ?? 0, waiting: s.waiters.count,
                              gate: s.gate.state, gateText: s.gate.text, trip: s.gate.trip, memory: s.memoryPressure, busy: busy,
                              perCPU: perCPU))
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
    /// cores it took (or, from a cpuq older than 0.4.5, the lowest that were free), with its
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
            blocks.append(Block(id: "\(j.pid ?? 0)-\(Int(start))", project: Self.project(j.label), label: j.label.isEmpty ? "-" : j.label,
                                lanes: j.slots ?? fit(cores, from: from, to: to), from: from, to: to, average: j.used, exclusive: j.exclusive))
            if let w = j.waited, w >= 1, start > since {
                waits.append(Wait(id: "h\(j.id)", project: Self.project(j.label), label: j.label, cores: "\(cores) cores",
                                  need: cores, from: Date(timeIntervalSince1970: start - w), to: from, exclusive: j.exclusive))
            }
            remember(Self.project(j.label))
        }
        blocks.sort { $0.from < $1.from }
    }

    /// Each job on a row of its own, for the jobs view: the lowest row free when it started, so
    /// there are as many rows as jobs ever ran at once, never more.
    func jobBlocks() -> [Block] {
        var ends: [Date] = []
        var out: [Block] = []
        for b in blocks.sorted(by: { ($0.from, $0.id) < ($1.from, $1.id) }) {
            let row = ends.firstIndex { $0 <= b.from } ?? ends.count
            if row == ends.count { ends.append(.distantFuture) }
            ends[row] = b.to ?? .distantFuture
            var j = b
            j.lanes = [row]
            out.append(j)
        }
        return out
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

    /// Project colors: the system's bright hues and a lime, the most distinct first. No red or
    /// pink (red means waiting), no grey (work outside cpuq), no brown (pale, it reads as the
    /// gate shut).
    /// In the design's order, which is also the stacking order: blue, green, purple, orange, teal.
    static let palette: [Color] = [Alive.color(0x2f7cf6, 0x3d86f5), Alive.color(0x2fb457, 0x2db052), Alive.color(0x9b5de5, 0xa070ee),
                                   Alive.color(0xf08a00, 0xcc7404), Alive.color(0x14a9b8, 0x16a0af), .yellow, .mint,
                                   Color(red: 0.62, green: 0.82, blue: 0.08), .indigo, .teal]

    /// Slots saved by an app older than the design's palette moved to it: each keeps its color
    /// where the palette still has it, and the projects the design shows take its colors.
    private static func migratePalette() {
        let d = UserDefaults.standard
        guard d.integer(forKey: "paletteVersion") < 2 else { return }
        var slots = (d.dictionary(forKey: "projectPalette") as? [String: Int]) ?? [:]
        // Old order: blue, orange, green, purple, yellow, teal, mint, lime, indigo, system teal.
        let moved = [0: 0, 1: 3, 2: 1, 3: 2, 4: 5, 5: 4, 6: 6, 7: 7, 8: 8, 9: 9]
        slots = slots.mapValues { moved[$0 % 10] ?? $0 }
        for (project, slot) in ["em": 0, "nexis": 1, "emdb": 2, "rig": 3, "cpuq": 4] { slots[project] = slot }
        d.set(slots, forKey: "projectPalette")
        d.set(2, forKey: "paletteVersion")
    }

    func color(_ project: String) -> Color {
        Self.palette[(slots[project] ?? 0) % Self.palette.count]
    }

    /// How far back there is anything to show.
    func oldest(now: Date) -> Date {
        max(([started] + blocks.map(\.from) + waits.map(\.from)).min() ?? now, cleared ?? .distantPast)
    }

    /// Where the window's data was cleared from, if it was: nothing older is shown, after a
    /// relaunch too (the seed from history skips it). cpuq's own history is untouched.
    private(set) var cleared: Date? = {
        let t = UserDefaults.standard.double(forKey: "clearedBefore")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()

    /// Forgets everything older than `cutoff`: jobs and waits that ended before it go, those
    /// that span it are cut at it, and so are the readings.
    func clear(before cutoff: Date) {
        cleared = cutoff
        UserDefaults.standard.set(cutoff.timeIntervalSince1970, forKey: "clearedBefore")
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

    /// The projects running now, the most cores first.
    var rows: [Row] {
        guard let s = status else { return [] }
        var held: [String: Int] = [:]
        var used: [String: Double] = [:]
        for h in s.holders {
            held[Self.project(h.label), default: 0] += h.cores
            used[Self.project(h.label), default: 0] += h.using ?? 0
        }
        return held.map { Row(project: $0.key, held: $0.value, used: used[$0.key] ?? 0) }
            .sorted { $0.held != $1.held ? $0.held > $1.held : $0.project < $1.project }
    }

    var waiting: [Waiting] {
        (status?.waiters ?? []).map { Waiting(id: $0.order, pid: $0.pid, label: Self.label($0.label, $0.command), cores: Self.wants($0), since: $0.since) }
    }

    static func label(_ label: String, _ command: String) -> String {
        label.isEmpty ? String(command.prefix(40)) : label
    }

    static func wants(_ w: Status.Waiter) -> String {
        w.exclusive ? "every core" : (w.max > w.cores ? "\(w.cores)–\(w.max) cores" : w.cores == 1 ? "1 core" : "\(w.cores) cores")
    }

    static func project(_ label: String) -> String {
        label.isEmpty ? "unlabelled" : String(label.split(separator: ":", maxSplits: 1).first ?? "")
    }
}

struct GraphsView: View {
    let model: GraphModel
    /// Runs a job action (`cpuq ACTION PID`), asking first where it costs something.
    var control: ((String, Int, String) -> Void)? = nil
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Now").tag(0)
                    Text("History").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 200)
                Spacer()
                if tab == 0 { StatusChips(model: model) }
            }
            if tab == 0 { NowView(model: model, control: control) } else { history }
        }
        .padding(16)
        .frame(minWidth: Self.minimumSize.width, maxWidth: .infinity, minHeight: Self.minimumSize.height, maxHeight: .infinity, alignment: .topLeading)
        .background(Alive.window)
    }

    /// The smallest the window goes: at this size everything in it still fits.
    static let minimumSize = CGSize(width: 560, height: 620)

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finished jobs by project, from cpuq history").font(.headline)
            Table(model.totals) {
                TableColumn("Project") { t in
                    HStack(spacing: 6) { Circle().fill(model.color(t.project)).frame(width: 8, height: 8); Text(t.project) }
                }
                TableColumn("Jobs") { t in Text("\(t.jobs)").monospacedDigit() }.width(50)
                TableColumn("Core-hours in use") { t in Text(String(format: "%.2f", t.held)).monospacedDigit() }
                TableColumn("Active") { t in Text(String(format: "%.2f", t.used)).monospacedDigit() }
                TableColumn("Share") { t in
                    Text("\(Int((t.efficiency * 100).rounded()))%").monospacedDigit()
                        .foregroundStyle(t.efficiency < 0.5 ? Color.orange : Color.primary)
                }
                TableColumn("Median wait") { t in Text(age(t.medianWait)).monospacedDigit() }
                TableColumn("Longest wait") { t in Text(age(t.longestWait)).monospacedDigit() }
            }
            if model.totals.isEmpty {
                Text("cpuq history has no finished jobs yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
