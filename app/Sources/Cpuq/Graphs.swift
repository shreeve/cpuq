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
        /// Which of the budget's cores it holds, from 0.
        let lanes: [Int]
        var from: Date
        /// Nil while it runs.
        var to: Date?
        /// Cores active, measured at every poll while the app watched it.
        var active: [Reading] = []
        /// Its average active cores from history, for the stretch the app did not watch.
        var average: Double?
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
    /// Each project's palette slot, assigned the first time it is seen and kept across launches,
    /// so a project's color never changes as others come and go.
    private var slots: [String: Int] = (UserDefaults.standard.dictionary(forKey: "projectPalette") as? [String: Int]) ?? [:]

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
                                    active: h.using.map { [Reading(at: now, cores: $0)] } ?? []))
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
                                  need: w.exclusive ? budget : max(w.cores, 1), from: Date(timeIntervalSince1970: Double(w.since))))
                remember(Self.project(w.label))
            }
        }
        for i in waits.indices where waits[i].to == nil && !queued.contains(waits[i].id) { waits[i].to = now }

        let t = CPUTicks.now()
        let busy = ticks.flatMap { a in t.flatMap { CPUTicks.busy(from: a, to: $0) } }
        ticks = t
        samples.append(Sample(at: now, inUse: s.held, active: s.holders.reduce(0) { $0 + ($1.using ?? 0) },
                              outside: s.outside.reduce(0) { $0 + $1.using }, load: s.load.first ?? 0, waiting: s.waiters.count,
                              gate: s.gate.state, gateText: s.gate.text, trip: s.gate.trip, memory: s.memoryPressure, busy: busy))
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
                                lanes: j.slots ?? fit(cores, from: from, to: to), from: from, to: to, average: j.used))
            if let w = j.waited, w >= 1, start > since {
                waits.append(Wait(id: "h\(j.id)", project: Self.project(j.label), label: j.label, cores: "\(cores) cores",
                                  need: cores, from: Date(timeIntervalSince1970: start - w), to: from))
            }
            remember(Self.project(j.label))
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
        guard slots[project] == nil else { return }
        // The lowest slot no project seen in the last hour holds, so the projects on screen
        // together never share a color while the palette lasts.
        let near = Set(blocks.map(\.project) + waits.map(\.project))
        let taken = Set(slots.filter { near.contains($0.key) }.map(\.value))
        slots[project] = (0..<Self.palette.count).first { !taken.contains($0) } ?? slots.count % Self.palette.count
        UserDefaults.standard.set(slots, forKey: "projectPalette")
    }

    /// A project's place in the palette, which also orders the stacked chart.
    func slot(_ project: String) -> Int { slots[project] ?? Int.max }

    /// Project colors: distinct hues with no red or orange (they mean waiting and a shut gate)
    /// and one blue; grey means work outside cpuq.
    static let palette: [Color] = [
        Color(red: 0.31, green: 0.47, blue: 0.65),  // blue
        Color(red: 0.35, green: 0.63, blue: 0.31),  // green
        Color(red: 0.69, green: 0.48, blue: 0.63),  // purple
        Color(red: 0.93, green: 0.79, blue: 0.28),  // yellow
        Color(red: 0.46, green: 0.72, blue: 0.70),  // teal
        Color(red: 0.61, green: 0.46, blue: 0.37),  // brown
        Color(red: 1.00, green: 0.62, blue: 0.65),  // pink
    ]

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
        w.exclusive ? "every core" : (w.max > w.cores ? "\(w.cores)–\(w.max) cores" : "\(w.cores) cores")
    }

    static func project(_ label: String) -> String {
        label.isEmpty ? "unlabelled" : String(label.split(separator: ":", maxSplits: 1).first ?? "")
    }
}

/// The time axis over `span` seconds (5 minutes to an hour): one unit per column, every column
/// the same width on screen. How long a column lasts sets the squeeze: 5 seconds for the last 2
/// minutes, then 15 and 30 seconds, and a minute beyond half an hour.
struct TimeAxis {
    let span: TimeInterval
    let end: Date
    let columns: [(from: Date, to: Date)]

    init(span: TimeInterval, end: Date) {
        self.span = span
        self.end = end
        columns = GraphsView.columns(end: end, from: end.addingTimeInterval(-span))
    }

    var count: Double { Double(columns.count) }

    /// A moment's place: its column, plus how far through it.
    func x(_ at: Date) -> Double {
        guard let i = columns.firstIndex(where: { at <= $0.to }) else { return count }
        let c = columns[i]
        let length = c.to.timeIntervalSince(c.from)
        return Double(i) + (length > 0 ? min(max(at.timeIntervalSince(c.from) / length, 0), 1) : 1)
    }

    /// The moment at a place.
    func time(_ x: Double) -> Date {
        guard !columns.isEmpty else { return end }
        let i = min(max(Int(x), 0), columns.count - 1)
        let c = columns[i]
        return c.from.addingTimeInterval(c.to.timeIntervalSince(c.from) * min(max(x - Double(i), 0), 1))
    }

    /// Ticks at round ages, none crowding the next, with the left edge and now.
    var ticks: [(x: Double, label: String)] {
        var out: [(x: Double, label: String)] = [(count, "now")]
        for a in [30.0, 60, 120, 300, 600, 900, 1800, 3600] where a < span * 0.92 {
            let at = x(end.addingTimeInterval(-a))
            if (out.last?.x ?? count) - at > count * 0.08 { out.append((at, Self.short(a))) }
        }
        if let last = out.last, last.x < count * 0.08 { out.removeLast() }
        out.append((0, Self.short(span) + " ago"))
        return out
    }

    static func short(_ s: TimeInterval) -> String {
        s >= 3600 ? "\(Int(s / 3600))h" : s >= 60 ? "\(Int((s / 60).rounded()))m" : "\(Int(s))s"
    }
}

struct GraphsView: View {
    let model: GraphModel
    /// Runs a job action (`cpuq ACTION PID`), asking first where it costs something.
    var control: ((String, Int, String) -> Void)? = nil
    @State private var tab = 0
    @State private var hover: CGPoint?
    /// Which chart the pointer is in: `hover` is in that chart's units.
    @State private var hoverIn = Pane.lanes
    enum Pane { case stack, lanes, waiting, mac }
    /// Which of the views over time are on: each can be turned off, the waiting row stays.
    @AppStorage("showStacked") private var showStacked = true
    @AppStorage("showLanes") private var showLanes = true
    @AppStorage("showMac") private var showMac = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                Text("Now").tag(0)
                Text("History").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)
            if tab == 0 { now } else { history }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 600)
    }

    // MARK: Now

    /// The time columns the lanes are cut into: stretches of the clock, 5 seconds long for the
    /// last 2 minutes, then 15 seconds to 10 minutes, 30 seconds to 30, and a minute beyond, each
    /// starting on a multiple of its length. A column covers the same seconds from one refresh
    /// to the next, so what it shows never changes as it moves left; it only narrows, and
    /// merges with its neighbors into a longer one as it ages.
    static func columns(end: Date, from oldest: Date) -> [(from: Date, to: Date)] {
        var out: [(from: Date, to: Date)] = []
        var t = end.timeIntervalSince1970
        let stop = oldest.timeIntervalSince1970
        while t > stop {
            let age = end.timeIntervalSince1970 - t
            let length: Double = age < 120 ? 5 : age < 600 ? 15 : age < 1800 ? 30 : 60
            let from = max(((t - 0.001) / length).rounded(.down) * length, stop)
            out.append((Date(timeIntervalSince1970: from), Date(timeIntervalSince1970: t)))
            t = from
        }
        return out.reversed()
    }

    /// One core over one column: free (nil project), held, or busy by `busy` (0 to 1); not
    /// `measured` where the job ran before the app watched and history has no average for it.
    struct Cell: Identifiable {
        var id: Int { column * 1000 + lane }
        let column: Int
        let lane: Int
        let project: String?
        let busy: Double
        let block: String?
        var measured = true
        /// Set when the core belongs to another job, which leaves it idle and has lent it: the
        /// lender's project and job.
        var lender: String? = nil
        var lenderBlock: String? = nil
    }

    /// Lending puts more cores in use than the budget, but the Mac has only its own: the work
    /// over the budget runs on the cores their holders leave idle. So each column's cells over
    /// the budget are drawn on the idle cells of that column, as borrowed, or once their lenders
    /// are gone, on free lanes; no lane beyond the budget is shown unless both run out.
    static func borrowed(_ cells: [Cell], budget: Int) -> [Cell] {
        var out: [Cell] = []
        for column in Dictionary(grouping: cells, by: \.column).values {
            var over = column.filter { $0.lane >= budget && $0.project != nil }.sorted { $0.lane < $1.lane }
            // Idle, or not yet measured (the newest column has no reading yet).
            var idle = column.filter { $0.lane < budget && $0.project != nil && (!$0.measured || $0.busy < 0.5) }.sorted { $0.lane > $1.lane }
            var taken = Set<Int>()
            while !over.isEmpty, let lent = idle.first {
                let b = over.removeFirst()
                idle.removeFirst()
                taken.insert(lent.lane)
                out.append(Cell(column: lent.column, lane: lent.lane, project: b.project, busy: b.busy, block: b.block,
                                measured: b.measured, lender: lent.project, lenderBlock: lent.block))
            }
            // Over the budget with nobody idle to borrow from: the work runs on a CPU nobody
            // holds, so it goes on a free lane, the highest first.
            var free = column.filter { $0.lane < budget && $0.project == nil }.sorted { $0.lane > $1.lane }
            while !over.isEmpty, let spot = free.first {
                let b = over.removeFirst()
                free.removeFirst()
                taken.insert(spot.lane)
                out.append(Cell(column: spot.column, lane: spot.lane, project: b.project, busy: b.busy, block: b.block, measured: b.measured))
            }
            let unplaced = Set(over.map(\.lane))
            out += column.filter { !taken.contains($0.lane) && ($0.lane < budget || unplaced.contains($0.lane)) }
        }
        return out
    }

    struct WaitCell: Identifiable {
        var id: Int { column }
        let column: Int
        let count: Int
        /// The fewest cores they asked for, together.
        var cores = 0
        /// cpuq's gate was shut for most of the column: the wait was the gate's, not a full budget.
        var gated = false
        /// Whether it carries the count of its stretch: the middle of a run of more than one.
        var label = false
    }

    private var now: some View {
        let end = Date()
        let axis = TimeAxis(span: min(max(end.timeIntervalSince(model.oldest(now: end)), 300), GraphModel.keep), end: end)
        let held = max(model.budget, (model.blocks.flatMap(\.lanes).max() ?? 0) + 1)
        let (all, waitCells) = Self.grid(model, columns: axis.columns, end: end, lanes: held)
        let cells = Self.borrowed(all, budget: model.budget)
        let lanes = max(model.budget, (cells.filter { $0.project != nil }.map(\.lane).max() ?? 0) + 1)
        let machine = Self.machine(model, columns: axis.columns)
        // The topmost view shown names each stretch the gate was shut.
        let top: Pane = showMac ? .mac : showStacked ? .stack : showLanes ? .lanes : .waiting
        // Views of one thing over one time axis, widest first, each of which can be turned off:
        // all the CPUs, cpuq's jobs and other work; cpuq's cores by project; which cores; and,
        // always, who waits. Stretches the gate was shut are shaded through all of them.
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                verdict().font(.title3).monospacedDigit().lineLimit(1)
                Spacer()
                HStack(spacing: 2) {
                    Toggle("All CPUs", isOn: $showMac)
                    Toggle("Stacked", isOn: $showStacked)
                    Toggle("Lanes", isOn: $showLanes)
                }
                .toggleStyle(.button).controlSize(.small)
            }
            // What is under the pointer, on a line of its own, so the verdict never moves.
            ((hover.flatMap { describe($0, axis: axis, cells: cells) })
                ?? Text("Point at the charts for what was there; right-click a job to pause or stop it.").foregroundColor(.secondary))
                .font(.callout).monospacedDigit().lineLimit(1)
                .frame(height: 18, alignment: .leading)
            // Air between the views, so each reads as its own; the waiting row sits under the
            // lanes, and carries the time labels.
            VStack(spacing: 4) {
                if showMac {
                    macChart(axis: axis, machine: machine, labelGate: top == .mac)
                        .frame(height: 92)
                        .padding(.bottom, 14)
                }
                if showStacked {
                    stackChart(axis: axis, machine: machine, labelGate: top == .stack)
                        .frame(minHeight: 150, maxHeight: .infinity)
                        .padding(.bottom, 18)
                }
                if showLanes {
                    lanesChart(axis: axis, lanes: lanes, cells: cells, machine: machine, labelGate: top == .lanes)
                        .frame(minHeight: 170, maxHeight: .infinity)
                        .padding(.bottom, 14)
                }
                waitingChart(axis: axis, waits: waitCells, machine: machine, labelGate: top == .waiting)
                    .frame(height: 70)
            }
            if !showStacked && !showLanes { Spacer(minLength: 0) }
            key
            table
        }
    }

    /// A project's held but idle cores: its color in diagonal stripes over a pale wash, so waste
    /// stands apart from free cores and from busy ones.
    @MainActor private static var hatches: [Int: ImagePaint] = [:]
    static func hatch(_ color: Color) -> ImagePaint {
        let key = color.hashValue
        if let h = hatches[key] { return h }
        let n = 7.0
        let image = NSImage(size: NSSize(width: n, height: n), flipped: false) { r in
            NSColor(color).withAlphaComponent(0.16).setFill()
            r.fill()
            NSColor(color).withAlphaComponent(0.85).setStroke()
            let p = NSBezierPath()
            p.lineWidth = 1.4
            for o in [-n, 0, n] {
                p.move(to: NSPoint(x: o, y: 0))
                p.line(to: NSPoint(x: o + n, y: n))
            }
            p.stroke()
            return true
        }
        let paint = ImagePaint(image: Image(nsImage: image))
        hatches[key] = paint
        return paint
    }

    /// Stretches the gate was shut (by memory pressure or the load valve; spacing, a pause of
    /// seconds between admissions, is left out), shaded across a chart from `low` to `high`, and
    /// named at their start in the topmost chart.
    @ChartContentBuilder
    private func gateBands(_ machine: [MachineColumn?], low: Double, high: Double, label: Bool) -> some ChartContent {
        ForEach(Array(machine.enumerated()), id: \.offset) { c, m in
            if let m, let shut = m.shut {
                RectangleMark(xStart: .value("Time", Double(c)), xEnd: .value("Time", Double(c) + 1),
                              yStart: .value("y", low), yEnd: .value("y", high))
                    .foregroundStyle(Color.orange.opacity(0.13))
                    .annotation(position: .overlay, alignment: .topLeading, spacing: 0) {
                        if label && (c == 0 || machine[c - 1]?.shut != shut) {
                            Text(shut).font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange).fixedSize().offset(x: 3, y: 9)
                        }
                    }
            }
        }
    }

    /// A leading axis label, the same width in every chart so their plots line up.
    private func axisLabel(_ text: Text) -> some View {
        text.frame(width: 64, alignment: .trailing)
    }

    /// What the marks mean. States are drawn in grey here, since every project has its own
    /// color: solid where busy, striped where held but idle.
    private var key: some View {
        let swatch = { (c: Color, h: CGFloat) in RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 14, height: h) }
        let grey = Color(white: 0.45)
        let cores = Group {
            Label { Text("busy") } icon: { swatch(grey, 10) }
            Label { Text("held, idle") } icon: { RoundedRectangle(cornerRadius: 2).fill(Self.hatch(grey)).frame(width: 14, height: 10) }
            Label { Text("held, not measured") } icon: { swatch(grey.opacity(0.6), 3) }
            Label { Text("borrowed (edge: owner)") } icon: { VStack(spacing: 0) { swatch(.primary.opacity(0.8), 3); swatch(grey.opacity(0.7), 7) } }
            Label { Text("free") } icon: { swatch(.secondary.opacity(0.12), 10) }
        }
        let machine = Group {
            Label { Text("other work") } icon: { swatch(.secondary.opacity(0.3), 10) }
            Label { Text("load") } icon: { swatch(.primary.opacity(0.75), 2) }
            Label { Text("valve") } icon: {
                HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in swatch(.orange.opacity(0.8), 2).frame(width: 3) } }.frame(width: 14)
            }
            Label { Text("memory pressure") } icon: { swatch(.red.opacity(0.75), 4) }
            Label { Text("gate shut") } icon: { swatch(.orange.opacity(0.18), 10) }
            Label { Text("cores waiting") } icon: { swatch(.red.opacity(0.75), 8) }
        }
        let note = Text("recent time is widest").foregroundStyle(.tertiary)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { cores; machine; Spacer(); note }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) { cores; Spacer(); note }
                HStack(spacing: 14) { machine }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// The machine over one column, while the app watched.
    struct MachineColumn {
        /// cpuq's jobs' active cores and the work outside cpuq, averaged.
        let active: Double
        let outside: Double
        /// The 1-minute load, averaged, and the valve's trip level.
        let load: Double
        let trip: Double?
        /// How busy the CPUs were, 0 to 1, when measured.
        let busy: Double?
        /// Why the gate was shut for most of the column ("memory" or "load"), if it was.
        let shut: String?
        /// Memory pressure was high at any poll.
        let memoryHigh: Bool
    }

    /// The machine in each column; nil before the app watched.
    static func machine(_ m: GraphModel, columns: [(from: Date, to: Date)]) -> [MachineColumn?] {
        columns.map { column in
            let here = m.samples.filter { $0.at >= column.from && $0.at <= column.to }
            guard !here.isEmpty else { return nil }
            let n = Double(here.count)
            // No more than the CPUs can do: a bad reading never flattens the chart.
            let cpus = Double(ProcessInfo.processInfo.activeProcessorCount)
            let active = min(here.reduce(0) { $0 + $1.active } / n, cpus)
            let busy = here.compactMap(\.busy)
            let shut = here.filter { $0.gate == "pressure" || $0.gate == "load" }
            let reason = shut.count * 2 >= here.count ? (shut.filter { $0.gate == "pressure" }.count * 2 >= shut.count ? "memory" : "load") : nil
            return MachineColumn(active: active, outside: min(here.reduce(0) { $0 + $1.outside } / n, cpus - active),
                                 load: here.reduce(0) { $0 + $1.load } / n, trip: here.last?.trip,
                                 busy: busy.isEmpty ? nil : busy.reduce(0, +) / Double(busy.count),
                                 shut: reason.map { "gate shut: \($0)" }, memoryHigh: here.contains { $0.memory == "high" })
        }
    }

    /// The time axis the charts share: ticks at round ages, labeled under the lowest chart,
    /// the edge labels inside it.
    private func timeAxis(_ axis: TimeAxis, labels: Bool = true, grid: Bool = false) -> some AxisContent {
        AxisMarks(values: axis.ticks.map(\.x)) { v in
            let d = v.as(Double.self) ?? 0
            if grid { AxisGridLine().foregroundStyle(.secondary.opacity(0.12)) }
            if labels {
                AxisValueLabel(anchor: d == axis.count ? .topTrailing : d == 0 ? .topLeading : .top) {
                    if let t = axis.ticks.first(where: { abs($0.x - d) < 0.0001 }) { Text(t.label) }
                }
            }
        }
    }

    /// The chart's right-click menu: forget what is older than the point clicked, or than five
    /// minutes ago.
    @ViewBuilder private func clearMenu(_ axis: TimeAxis) -> some View {
        if let job = runningJobUnderPointer(axis), let control, supportsControls(version: model.status?.version ?? "") {
            let paused = model.status?.holders.first { $0.pid == job.pid }?.paused ?? false
            Button(paused ? "Resume \(job.label)" : "Pause \(job.label)") { control(paused ? "resume" : "pause", job.pid, job.label) }
            Button("Stop \(job.label)…") { control("stop", job.pid, job.label) }
            Divider()
        }
        if let h = hover {
            let at = axis.time(Double(h.x))
            Button("Clear Data Older Than \(age(axis.end.timeIntervalSince(at))) Ago") { model.clear(before: at); hover = nil }
        }
        Button("Keep Only the Last 5 Minutes") { model.clear(before: Date().addingTimeInterval(-300)); hover = nil }
    }

    /// The running job whose core is under the pointer, if any (lanes only).
    private func runningJobUnderPointer(_ axis: TimeAxis) -> (pid: Int, label: String)? {
        guard hoverIn == .lanes, let h = hover, h.y >= 0 else { return nil }
        let at = axis.time(Double(h.x))
        let lane = Int(h.y)
        guard let b = model.blocks.first(where: { $0.to == nil && $0.lanes.contains(lane) && $0.from <= at }),
              let pid = Int(b.id.split(separator: "-").first ?? "") else { return nil }
        return (pid, b.label)
    }

    /// The pointer, in the units of the chart it is in.
    private func hovering(_ proxy: ChartProxy, _ pane: Pane) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case .active(let p) = phase, let frame = proxy.plotFrame else {
                        if hoverIn == pane { hover = nil }
                        return
                    }
                    let origin = geo[frame].origin
                    if let hx = proxy.value(atX: p.x - origin.x, as: Double.self), let hy = proxy.value(atY: p.y - origin.y, as: Double.self) {
                        hoverIn = pane
                        hover = CGPoint(x: hx, y: hy)
                    }
                }
        }
    }

    // MARK: Lanes

    /// The lanes, one per core of the budget: a held core striped in its project's color,
    /// filled in as far as the job keeps it busy.
    private func lanesChart(axis: TimeAxis, lanes: Int, cells: [Cell], machine: [MachineColumn?], labelGate: Bool) -> some View {
        Chart {
            gateBands(machine, low: 0, high: Double(lanes), label: labelGate)
            ForEach(cells) { c in
                let x0 = Double(c.column) + 0.08, x1 = Double(c.column) + 0.92
                if let p = c.project, c.measured {
                    RectangleMark(xStart: .value("Time", x0), xEnd: .value("Time", x1),
                                  yStart: .value("Core", Double(c.lane) + 0.1), yEnd: .value("Core", Double(c.lane) + 0.9))
                        .foregroundStyle(Self.hatch(model.color(p)))
                    if c.busy > 0.02 {
                        RectangleMark(xStart: .value("Time", x0), xEnd: .value("Time", x1),
                                      yStart: .value("Core", Double(c.lane) + 0.1), yEnd: .value("Core", Double(c.lane) + 0.9))
                            .foregroundStyle(model.color(p).opacity(min(1, 0.15 + c.busy)))
                    }
                } else if let p = c.project {
                    RectangleMark(xStart: .value("Time", x0), xEnd: .value("Time", x1),
                                  yStart: .value("Core", Double(c.lane) + 0.4), yEnd: .value("Core", Double(c.lane) + 0.6))
                        .foregroundStyle(model.color(p).opacity(0.7))
                } else {
                    RectangleMark(xStart: .value("Time", x0), xEnd: .value("Time", x1),
                                  yStart: .value("Core", Double(c.lane) + 0.1), yEnd: .value("Core", Double(c.lane) + 0.9))
                        .foregroundStyle(Color.secondary.opacity(0.08))
                }
                // A borrowed core: the borrower's work, edged in the color of the job that lent it.
                if let lender = c.lender {
                    RectangleMark(xStart: .value("Time", x0), xEnd: .value("Time", x1),
                                  yStart: .value("Core", Double(c.lane) + 0.66), yEnd: .value("Core", Double(c.lane) + 0.9))
                        .foregroundStyle(model.color(lender))
                }
            }
            if let h = hover { RuleMark(x: .value("Time", Double(h.x))).foregroundStyle(.secondary.opacity(0.6)) }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(axis.count, 1))
        .chartXAxis { timeAxis(axis, labels: false) }
        .chartYScale(domain: 0...Double(lanes))
        .chartYAxis {
            AxisMarks(position: .leading, values: (0..<lanes).map { Double($0) + 0.5 }) { v in
                AxisValueLabel { if let d = v.as(Double.self) { axisLabel(Text("\(Int(d) + 1)")) } }
            }
        }
        .chartOverlay { hovering($0, .lanes) }
        .contextMenu { clearMenu(axis) }
    }

    /// Waiting: the cores the waiting jobs ask for, hanging down from the line, red, or orange
    /// while the gate is shut; the number of jobs written once over each stretch of more than one.
    private func waitingChart(axis: TimeAxis, waits: [WaitCell], machine: [MachineColumn?], labelGate: Bool) -> some View {
        let deepest = Double(max(waits.map(\.cores).max() ?? 0, 4))
        return Chart {
            gateBands(machine, low: -deepest * 1.3, high: 0, label: labelGate)
            ForEach(waits.filter { $0.count > 0 }) { c in
                RectangleMark(xStart: .value("Time", Double(c.column) + 0.06), xEnd: .value("Time", Double(c.column) + 0.94),
                              yStart: .value("Cores", 0), yEnd: .value("Cores", -Double(max(c.cores, 1))))
                    .foregroundStyle((c.gated ? Color.orange : Color.red).opacity(0.75))
                    .annotation(position: .bottom, spacing: 1) {
                        if c.label { Text("\(c.count) jobs").font(.system(size: 9, weight: .bold)).foregroundStyle(c.gated ? .orange : .red).fixedSize() }
                    }
            }
            RuleMark(y: .value("Cores", 0)).foregroundStyle(.secondary.opacity(0.3))
            if let h = hover { RuleMark(x: .value("Time", Double(h.x))).foregroundStyle(.secondary.opacity(0.6)) }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(axis.count, 1))
        .chartXAxis { timeAxis(axis) }
        .chartYScale(domain: (-deepest * 1.3)...0.2)
        .chartYAxis {
            AxisMarks(position: .leading, values: [-deepest * 0.45]) { _ in AxisValueLabel { axisLabel(Text("waiting").foregroundColor(.red)) } }
        }
        .chartOverlay { hovering($0, .waiting) }
        .contextMenu { clearMenu(axis) }
    }

    /// All the CPUs: busy with cpuq's jobs (dark) and with other work (pale), the 1-minute load
    /// over them with the load valve's trip level dashed, and a red edge while memory pressure is
    /// high.
    private func macChart(axis: TimeAxis, machine: [MachineColumn?], labelGate: Bool) -> some View {
        let cpus = Double(ProcessInfo.processInfo.activeProcessorCount)
        let budget = Double(model.budget)
        let trip = machine.last??.trip ?? model.status?.gate.trip
        let cap = max(12, cpus + 2, (trip ?? 0) + 1)
        return Chart {
            gateBands(machine, low: 0, high: cap, label: labelGate)
            ForEach(Array(machine.enumerated()), id: \.offset) { c, m in
                if let m {
                    RectangleMark(xStart: .value("Time", Double(c) + 0.06), xEnd: .value("Time", Double(c) + 0.94),
                                  yStart: .value("CPUs", 0), yEnd: .value("CPUs", min(m.active, cap)))
                        .foregroundStyle(Color.primary.opacity(0.5))
                    RectangleMark(xStart: .value("Time", Double(c) + 0.06), xEnd: .value("Time", Double(c) + 0.94),
                                  yStart: .value("CPUs", min(m.active, cap)), yEnd: .value("CPUs", min(m.active + m.outside, cap)))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                    if m.memoryHigh {
                        RectangleMark(xStart: .value("Time", Double(c)), xEnd: .value("Time", Double(c) + 1),
                                      yStart: .value("CPUs", cap - cap * 0.06), yEnd: .value("CPUs", cap))
                            .foregroundStyle(Color.red.opacity(0.75))
                    }
                }
            }
            ForEach(Array(machine.enumerated()).filter { $0.element != nil }, id: \.offset) { c, m in
                LineMark(x: .value("Time", Double(c) + 0.5), y: .value("CPUs", min(m!.load, cap)), series: .value("Series", "load"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let trip {
                RuleMark(y: .value("CPUs", trip)).foregroundStyle(Color.orange.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            RuleMark(y: .value("CPUs", budget)).foregroundStyle(Color.primary.opacity(0.25))
            if let h = hover { RuleMark(x: .value("Time", Double(h.x))).foregroundStyle(.secondary.opacity(0.6)) }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(axis.count, 1))
        .chartXAxis { timeAxis(axis, labels: false, grid: true) }
        .chartYScale(domain: 0...cap)
        .chartYAxis {
            AxisMarks(position: .leading, values: [budget]) { _ in
                AxisValueLabel { axisLabel(Text(abs(budget - cpus) < 0.5 ? "\(Int(cpus)) = budget" : "budget \(Int(budget))").font(.caption2)) }
            }
            if let trip {
                AxisMarks(position: .leading, values: [trip]) { _ in
                    AxisValueLabel { axisLabel(Text("valve \(String(format: "%g", trip))").font(.caption2).foregroundColor(.orange)) }
                }
            }
            AxisMarks(position: .leading, values: [cap * 0.3]) { _ in AxisValueLabel { axisLabel(Text("all CPUs").foregroundColor(.secondary)) } }
        }
        .chartOverlay { hovering($0, .mac) }
        .contextMenu { clearMenu(axis) }
    }

    // MARK: Stacked

    /// One project's piece of a stacked column: its busy cores, its idle ones, or (before the
    /// app watched, with no average in history) all it held, not knowing how busy.
    struct Band: Identifiable {
        enum Kind { case busy, idle, unmeasured }
        var id: String { "\(column) \(project) \(kind)" }
        let column: Int
        let project: String
        let kind: Kind
        let low: Double
        let high: Double
    }

    /// Each column's cores held, stacked: every project's busy cores first, from the floor, in
    /// palette order, so the busy total reads off one edge; then every project's idle cores
    /// above them, striped, so the waste sits on top where it shows.
    static func bands(_ m: GraphModel, columns: [(from: Date, to: Date)], end: Date) -> [Band] {
        var out: [Band] = []
        for (c, column) in columns.enumerated() {
            let t1 = column.from, t2 = column.to
            let length = max(t2.timeIntervalSince(t1), 0.001)
            var held: [String: Double] = [:], busy: [String: Double] = [:], known: [String: Bool] = [:]
            for b in m.blocks {
                let o = max(0, min(t2, b.to ?? end).timeIntervalSince(max(t1, b.from))) / length
                guard o > 0 else { continue }
                let cores = Double(b.lanes.count)
                held[b.project, default: 0] += o * cores
                let readings = b.active.filter { $0.at >= t1 && $0.at <= t2 }
                let active = readings.isEmpty ? (b.active.isEmpty || b.from < (b.active.first?.at ?? end) ? b.average : nil)
                    : readings.reduce(0) { $0 + $1.cores } / Double(readings.count)
                busy[b.project, default: 0] += o * min(active ?? 0, cores)
                known[b.project] = (known[b.project] ?? true) && active != nil
            }
            let projects = held.keys.sorted { (m.slot($0), $0) < (m.slot($1), $1) }
            var y = 0.0
            for p in projects {
                let h = held[p] ?? 0
                let k = known[p] ?? false
                let part = k ? min(busy[p] ?? 0, h) : h
                if part > 0.001 { out.append(Band(column: c, project: p, kind: k ? .busy : .unmeasured, low: y, high: y + part)) }
                y += part
            }
            for p in projects where known[p] ?? false {
                let idle = (held[p] ?? 0) - min(busy[p] ?? 0, held[p] ?? 0)
                if idle > 0.001 { out.append(Band(column: c, project: p, kind: .idle, low: y, high: y + idle)) }
                y += idle
            }
        }
        return out
    }

    /// The cores held, stacked (busy solid from the floor, idle striped above), with the
    /// budget. It shares the time axis of the views around it.
    private func stackChart(axis: TimeAxis, machine: [MachineColumn?], labelGate: Bool) -> some View {
        let cpus = Double(ProcessInfo.processInfo.activeProcessorCount)
        let budget = Double(model.budget)
        let bands = Self.bands(model, columns: axis.columns, end: axis.end)
        let peak = bands.map(\.high).max() ?? 0
        let top = max(max(cpus, budget) + 1, peak.rounded(.up) + 0.5)
        return Chart {
            gateBands(machine, low: 0, high: top, label: labelGate)
            ForEach(bands) { b in
                RectangleMark(xStart: .value("Time", Double(b.column) + 0.06), xEnd: .value("Time", Double(b.column) + 0.94),
                              yStart: .value("Cores", b.low), yEnd: .value("Cores", b.high))
                    .foregroundStyle(b.kind == .idle ? AnyShapeStyle(Self.hatch(model.color(b.project)))
                                     : AnyShapeStyle(model.color(b.project).opacity(b.kind == .busy ? 0.95 : 0.5)))
            }
            RuleMark(y: .value("Cores", budget)).foregroundStyle(Color.primary.opacity(0.35))
            if abs(budget - cpus) >= 0.5 {
                RuleMark(y: .value("Cores", cpus)).foregroundStyle(Color.primary.opacity(0.2)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let h = hover { RuleMark(x: .value("Time", Double(h.x))).foregroundStyle(.secondary.opacity(0.6)) }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(axis.count, 1))
        .chartXAxis { timeAxis(axis, labels: false, grid: true) }
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(stride(from: 0.0, through: max(cpus, budget), by: 2)).filter { abs($0 - budget) > 1.1 }) { v in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel { if let d = v.as(Double.self) { axisLabel(Text("\(Int(d))")) } }
            }
            AxisMarks(position: .leading, values: [budget]) { _ in
                AxisValueLabel { axisLabel(Text("budget \(Int(budget))")) }
            }
            if abs(budget - cpus) >= 0.5 {
                AxisMarks(position: .leading, values: [cpus]) { _ in AxisValueLabel { axisLabel(Text("\(Int(cpus)) CPUs").font(.caption2)) } }
            }
        }
        .chartOverlay { hovering($0, .stack) }
        .contextMenu { clearMenu(axis) }
    }

    /// Every core in every column: the job holding it longest there, and how busy; and how many
    /// waited. A job keeps its lowest cores busy first: with 2.5 active of 4, its first two
    /// cores are solid, the third half, the fourth pale.
    static func grid(_ m: GraphModel, columns: [(from: Date, to: Date)], end: Date, lanes: Int) -> ([Cell], [WaitCell]) {
        var cells: [Cell] = []
        var waits: [WaitCell] = []
        for (c, column) in columns.enumerated() {
            let t1 = column.from, t2 = column.to
            let length = max(t2.timeIntervalSince(t1), 0.001)
            func overlap(_ from: Date, _ to: Date?) -> Double {
                max(0, min(t2, to ?? end).timeIntervalSince(max(t1, from))) / length
            }
            let here = m.blocks.compactMap { b -> (GraphModel.Block, Double)? in
                let o = overlap(b.from, b.to)
                return o >= 0.3 ? (b, o) : nil
            }
            for lane in 0..<lanes {
                guard let (b, _) = here.filter({ $0.0.lanes.contains(lane) }).max(by: { $0.1 < $1.1 }) else {
                    cells.append(Cell(column: c, lane: lane, project: nil, busy: 0, block: nil))
                    continue
                }
                let readings = b.active.filter { $0.at >= t1 && $0.at <= t2 }
                let active = readings.isEmpty ? (b.active.isEmpty || b.from < (b.active.first?.at ?? end) ? b.average : nil)
                    : readings.reduce(0) { $0 + $1.cores } / Double(readings.count)
                let rank = Double(b.lanes.sorted().firstIndex(of: lane) ?? 0)
                cells.append(Cell(column: c, lane: lane, project: b.project, busy: min(max((active ?? 0) - rank, 0), 1), block: b.id,
                                  measured: active != nil))
            }
            let polls = m.samples.filter { $0.at >= t1 && $0.at <= t2 }
            let waiting = m.waits.filter { overlap($0.from, $0.to) > 0 }
            waits.append(WaitCell(column: c, count: waiting.count, cores: waiting.reduce(0) { $0 + $1.need },
                                  gated: !polls.isEmpty && polls.filter { !$0.gateOpen }.count * 2 >= polls.count))
        }
        var i = 0
        while i < waits.count {
            var j = i
            while j < waits.count && waits[j].count == waits[i].count { j += 1 }
            if waits[i].count > 1 { waits[(i + j - 1) / 2].label = true }
            i = j
        }
        return (cells, waits)
    }

    /// The top line, always: whether cpuq is admitting work, and if not why and for how long;
    /// then what is in use and waiting, and how near each gate is.
    private func verdict() -> Text {
        guard let s = model.status else { return Text("waiting for cpuq…").foregroundColor(.secondary) }
        var line: Text
        if s.gate.state == "open" {
            line = Text("● admitting").foregroundColor(.green).bold()
        } else {
            let reason = s.gate.text.hasPrefix("closed: ") ? String(s.gate.text.dropFirst(8)) : s.gate.text
            let since = model.samples.last(where: { $0.gateOpen }).map { Date().timeIntervalSince($0.at) }
            line = Text("● gate shut: \(reason)").foregroundColor(.orange).bold()
            if let since, since >= 10 { line = line + Text(" for \(age(since))").foregroundColor(.orange) }
        }
        let active = s.holders.reduce(0) { $0 + ($1.using ?? 0) }
        line = line + Text("  ·  \(s.held) of \(s.budget) cores in use").bold() + Text(String(format: ", %.1f active", active))
        line = line + Text(" · \(s.waiters.count) waiting").foregroundColor(s.waiters.isEmpty ? nil : .red)
        if let load = s.load.first {
            let hot = s.gate.reopen.map { load > $0 } ?? false
            line = line + Text(" · load ").foregroundColor(.secondary) + Text(String(format: "%.1f", load)).foregroundColor(hot ? .orange : .secondary)
            if let trip = s.gate.trip { line = line + Text(String(format: " / valve %g", trip)).foregroundColor(.secondary) }
        }
        if let busy = model.samples.last?.busy {
            let hot = busy >= (s.gate.busyTrip ?? 0.9)
            line = line + Text(" · CPUs ").foregroundColor(.secondary) + Text("\(Int((busy * 100).rounded()))% busy").foregroundColor(hot ? .orange : .secondary)
        }
        line = line + Text(" · memory ").foregroundColor(.secondary)
            + Text(s.memoryPressure.isEmpty ? "–" : s.memoryPressure).foregroundColor(s.memoryPressure == "high" ? .red : .secondary)
        let outside = s.outside.reduce(0) { $0 + $1.using }
        if outside >= 0.3 { line = line + Text(String(format: " · %.1f outside cpuq", outside)).foregroundColor(.secondary) }
        return line
    }

    /// The top line for the cell under the pointer: the job holding that core then, or who
    /// waited then.
    private func describe(_ p: CGPoint, axis: TimeAxis, cells: [Cell]) -> Text? {
        let end = axis.end
        let at = axis.time(Double(p.x))
        let a = end.timeIntervalSince(at)
        // The machine then, when the app was watching: cpuq's cores in use and active, and the load.
        let then = model.samples.min { abs($0.at.timeIntervalSince(at)) < abs($1.at.timeIntervalSince(at)) }
            .flatMap { abs($0.at.timeIntervalSince(at)) < 30 ? $0 : nil }
        let machine = then.map {
            Text("   cpuq \($0.inUse) in use, ").foregroundColor(.secondary)
                + Text(String(format: "%.1f active", $0.active)).foregroundColor(.secondary)
                + Text(String(format: " · load %.1f", $0.load)).foregroundColor(.secondary)
        } ?? Text("")
        let column = min(max(Int(p.x), 0), max(axis.columns.count - 1, 0))
        return describeJob(p, column: column, at: at, a: a, end: end, cells: cells).map { $0 + machine }
    }

    private func describeJob(_ p: CGPoint, column: Int, at: Date, a: TimeInterval, end: Date, cells: [Cell]) -> Text? {
        let when = Text(a < 5 ? "now   " : age(a) + " ago   ").foregroundColor(.secondary)
        if hoverIn == .mac {
            let then = model.samples.min { abs($0.at.timeIntervalSince(at)) < abs($1.at.timeIntervalSince(at)) }
                .flatMap { abs($0.at.timeIntervalSince(at)) < 30 ? $0 : nil }
            guard let then else { return when + Text("the app was not watching then").foregroundColor(.secondary) }
            var t = when + Text("all CPUs").bold() + Text(String(format: " · %.1f busy with cpuq's jobs, %.1f with other work · load %.1f", then.active, then.outside, then.load))
            if let busy = then.busy { t = t + Text(" · CPUs \(Int((busy * 100).rounded()))% busy") }
            if !then.gateOpen { t = t + Text(" · \(then.gateText)").foregroundColor(.orange) }
            if then.memory == "high" { t = t + Text(" · memory pressure high").foregroundColor(.red) }
            return t
        }
        if hoverIn == .stack {
            // The project whose band is under the pointer in that column.
            let columns = TimeAxis(span: min(max(end.timeIntervalSince(model.oldest(now: end)), 300), GraphModel.keep), end: end).columns
            let here = Self.bands(model, columns: columns, end: end).filter { $0.column == column }
            guard let band = here.first(where: { $0.low <= p.y && p.y < $0.high })
            else { return when + Text("no job here").foregroundColor(.secondary) }
            let mine = here.filter { $0.project == band.project }
            let held = mine.reduce(0) { $0 + $1.high - $1.low }
            var t = when + Text(band.project).bold() + Text(String(format: " · %.1f cores in use", held))
            if !mine.contains(where: { $0.kind == .unmeasured }) {
                let busy = mine.filter { $0.kind == .busy }.reduce(0) { $0 + $1.high - $1.low }
                t = t + Text(String(format: ", %.1f active, %.1f idle", busy, held - busy))
            }
            return t
        }
        if hoverIn == .lanes {
            let lane = Int(p.y)
            guard let cell = cells.first(where: { $0.column == column && $0.lane == lane }), let id = cell.block,
                  let b = model.blocks.first(where: { $0.id == id }) else { return when + Text("core \(lane + 1) free").foregroundColor(.secondary) }
            if let lent = cell.lenderBlock, let owner = model.blocks.first(where: { $0.id == lent }) {
                return when + Text("core \(lane + 1): ").foregroundColor(.secondary) + Text(owner.label).bold()
                    + Text(" leaves it idle; ").foregroundColor(.secondary) + Text(b.label).bold() + Text(" has borrowed it").foregroundColor(.secondary)
            }
            let cores = runs(b.lanes).map { $0.count == 1 ? "\($0.lowerBound + 1)" : "\($0.lowerBound + 1)–\($0.upperBound)" }.joined(separator: ", ")
            let near = b.active.min { abs($0.at.timeIntervalSince(at)) < abs($1.at.timeIntervalSince(at)) }
            let active = near.flatMap { abs($0.at.timeIntervalSince(at)) < 30 ? $0.cores : nil } ?? b.average
            var t = when + Text(b.label).bold() + Text(" · cores \(cores)")
            if let active { t = t + Text(String(format: " · %.1f of %d active", active, b.lanes.count)) }
            return t + Text(" · \(b.to == nil ? "running" : "ran") \(age((b.to ?? end).timeIntervalSince(b.from)))").foregroundColor(.secondary)
        }
        let waiting = model.waits.filter { $0.from <= at && at <= ($0.to ?? end) }
        if waiting.isEmpty { return when + Text("nobody waiting").foregroundColor(.secondary) }
        return when + Text("\(waiting.count) waiting: ").foregroundColor(.red)
            + Text(waiting.map { "\($0.label) (\($0.cores))" }.joined(separator: ", ")).foregroundColor(.red)
    }

    /// Runs of adjacent lanes.
    func runs(_ lanes: [Int]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for l in lanes.sorted() {
            if let last = out.last, last.upperBound == l { out[out.count - 1] = last.lowerBound..<l + 1 } else { out.append(l..<l + 1) }
        }
        return out
    }

    /// Who holds what now, and who waits: the legend and the numbers in one.
    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            // Fixed widths, so nothing shifts as the numbers change.
            GridRow {
                Text("Project").frame(width: 220, alignment: .leading)
                Text("In use").frame(width: 64, alignment: .trailing)
                Text("Active").frame(width: 64, alignment: .trailing)
                Text("Efficiency").frame(width: 72, alignment: .trailing)
            }
            .font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(model.rows) { r in
                GridRow {
                    HStack(spacing: 6) { Circle().fill(model.color(r.project)).frame(width: 8, height: 8); Text(r.project).lineLimit(1) }
                        .frame(width: 220, alignment: .leading)
                    Text("\(r.held)").frame(width: 64, alignment: .trailing)
                    Text(String(format: "%.1f", r.used)).frame(width: 64, alignment: .trailing)
                    Text(r.held > 0 ? "\(Int((r.used / Double(r.held) * 100).rounded()))%" : "–")
                        .foregroundStyle(r.used * 2 < Double(r.held) ? Color.orange : Color.secondary)
                        .frame(width: 72, alignment: .trailing)
                }
            }
            ForEach(model.waiting) { w in
                GridRow {
                    HStack(spacing: 6) { Circle().strokeBorder(.red, lineWidth: 1.5).frame(width: 8, height: 8); Text(w.label).lineLimit(1).truncationMode(.middle) }
                        .frame(width: 220, alignment: .leading)
                    Text("waiting \(age(Date().timeIntervalSince1970 - Double(w.since))) for \(w.cores)")
                        .foregroundStyle(.red).lineLimit(1).frame(width: 224, alignment: .leading).gridCellColumns(3)
                }
                .contextMenu {
                    if let control, supportsControls(version: model.status?.version ?? "") {
                        Button("Move to Front") { control("first", w.pid, w.label) }
                        Button("Start Now…") { control("start", w.pid, w.label) }
                        Button("Cancel") { control("cancel", w.pid, w.label) }
                    }
                }
            }
            if model.rows.isEmpty && model.waiting.isEmpty {
                GridRow { Text("Nothing running or waiting.").foregroundStyle(.secondary).gridCellColumns(4) }
            }
        }
        .font(.callout)
        .monospacedDigit()
    }

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
