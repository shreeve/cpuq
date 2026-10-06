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
        let from: Date
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
        let from: Date
        var to: Date?
    }

    /// The machine at one poll, for the top line when pointing at that moment.
    struct Sample {
        let at: Date
        let inUse: Int
        let active: Double
        let load: Double
        let waiting: Int
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
    /// Each project's palette slot, assigned the first time it is seen and kept across launches,
    /// so a project's color never changes as others come and go.
    private var slots: [String: Int] = (UserDefaults.standard.dictionary(forKey: "projectColors") as? [String: Int]) ?? [:]

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
                                  from: Date(timeIntervalSince1970: Double(w.since))))
                remember(Self.project(w.label))
            }
        }
        for i in waits.indices where waits[i].to == nil && !queued.contains(waits[i].id) { waits[i].to = now }

        samples.append(Sample(at: now, inUse: s.held, active: s.holders.reduce(0) { $0 + ($1.using ?? 0) },
                              load: s.load.first ?? 0, waiting: s.waiters.count))
        let cutoff = now.addingTimeInterval(-Self.keep)
        samples.removeAll { $0.at < cutoff }
        blocks.removeAll { ($0.to ?? now) < cutoff }
        waits.removeAll { ($0.to ?? now) < cutoff }
    }

    func setHistory(_ jobs: [Job]) {
        if !seeded { seed(jobs) }
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
        let since = now.addingTimeInterval(-Self.keep).timeIntervalSince1970
        for j in jobs.sorted(by: { ($0.started ?? 0) < ($1.started ?? 0) }) where j.pool == "cores" && j.state != "active" {
            guard let start = j.started, let cores = j.cores, (j.ended ?? start) >= since else { continue }
            // A job the app saw start is a block already.
            if blocks.contains(where: { $0.id.hasPrefix("\(j.pid ?? -1)-") && abs($0.from.timeIntervalSince1970 - start) < 2 }) { continue }
            let from = Date(timeIntervalSince1970: start)
            let to = Date(timeIntervalSince1970: j.ended ?? start)
            blocks.append(Block(id: "\(j.pid ?? 0)-\(Int(start))", project: Self.project(j.label), label: j.label.isEmpty ? "-" : j.label,
                                lanes: j.slots ?? fit(cores, from: from, to: to), from: from, to: to, average: j.used))
            if let w = j.waited, w >= 1 {
                waits.append(Wait(id: "h\(j.id)", project: Self.project(j.label), label: j.label, cores: "\(cores) cores",
                                  from: Date(timeIntervalSince1970: start - w), to: from))
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
        slots[project] = slots.count
        UserDefaults.standard.set(slots, forKey: "projectColors")
    }

    func color(_ project: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .red, .teal, .yellow, .brown, .indigo, .pink, .mint, .cyan]
        return palette[(slots[project] ?? 0) % palette.count]
    }

    /// How far back there is anything to show.
    func oldest(now: Date) -> Date {
        ([started] + blocks.map(\.from) + waits.map(\.from)).min() ?? now
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
        (status?.waiters ?? []).map { Waiting(id: $0.order, label: Self.label($0.label, $0.command), cores: Self.wants($0), since: $0.since) }
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

/// The time axis over `span` seconds (5 minutes to an hour): nearly even near now, then
/// compressed toward the left. A moment `age` seconds ago sits at -ln(1 + age/k), even for ages
/// well under k and squeezed beyond it; k is 6 minutes, or the whole span when it is shorter.
struct TimeAxis {
    let span: TimeInterval
    var k: TimeInterval { min(span, 360) }
    func x(_ age: TimeInterval) -> Double { -log(1 + max(age, 0) / k) }
    func age(_ x: Double) -> TimeInterval { k * (exp(-x) - 1) }
    var start: Double { x(span) }

    /// Ticks at round ages, none crowding the next, with the left edge and now.
    var ticks: [(x: Double, label: String)] {
        var out: [(x: Double, label: String)] = [(0, "now")]
        // x runs from `start` (negative) to 0; a tick keeps a tenth of the width from the last.
        for a in [15.0, 30, 60, 120, 300, 600, 900, 1800, 3600] where a < span * 0.92 && (out.last?.x ?? 0) - x(a) > -start * 0.1 {
            out.append((x(a), Self.short(a)))
        }
        if let last = out.last, last.x - start < -start * 0.1 { out.removeLast() }
        out.append((start, Self.short(span) + " ago"))
        return out
    }

    static func short(_ s: TimeInterval) -> String {
        s >= 3600 ? "\(Int(s / 3600))h" : s >= 60 ? "\(Int((s / 60).rounded()))m" : "\(Int(s))s"
    }
}

struct GraphsView: View {
    let model: GraphModel
    @State private var tab = 0
    @State private var hover: CGPoint?

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
        .frame(minWidth: 560, minHeight: 480)
    }

    // MARK: Now

    /// The time columns the lanes are cut into, all equally wide on screen.
    static let columns = 90

    /// One core over one column: free (nil project), held, or busy by `busy` (0 to 1).
    struct Cell: Identifiable {
        var id: Int { column * 1000 + lane }
        let column: Int
        let lane: Int
        let project: String?
        let busy: Double
        let block: String?
    }

    struct WaitCell: Identifiable {
        var id: Int { column }
        let column: Int
        let count: Int
    }

    private var now: some View {
        let end = Date()
        let axis = TimeAxis(span: min(max(end.timeIntervalSince(model.oldest(now: end)), 300), GraphModel.keep))
        let lanes = max(model.budget, (model.blocks.flatMap(\.lanes).max() ?? 0) + 1)
        let (cells, waitCells) = Self.grid(model, axis: axis, end: end, lanes: lanes)
        let w = -axis.start / Double(Self.columns)
        let gap = w * 0.1
        let left = { (c: Int) in axis.start + Double(c) * w }
        return VStack(alignment: .leading, spacing: 12) {
            ((hover.flatMap { describe($0, axis: axis, end: end, cells: cells) }) ?? summary())
                .font(.title3).monospacedDigit().lineLimit(1)
            Chart {
                ForEach(cells) { c in
                    RectangleMark(xStart: .value("Time", left(c.column) + gap), xEnd: .value("Time", left(c.column + 1) - gap),
                                  yStart: .value("Core", Double(c.lane) + 0.1), yEnd: .value("Core", Double(c.lane) + 0.9))
                        .foregroundStyle(c.project.map { model.color($0).opacity(0.2 + 0.75 * c.busy) } ?? Color.secondary.opacity(0.08))
                }
                ForEach(waitCells) { c in
                    RectangleMark(xStart: .value("Time", left(c.column) + gap), xEnd: .value("Time", left(c.column + 1) - gap),
                                  yStart: .value("Core", -1.15), yEnd: .value("Core", -0.35))
                        .foregroundStyle(c.count == 0 ? Color.secondary.opacity(0.08) : Color.red.opacity(min(0.35 + 0.2 * Double(c.count), 0.9)))
                        .annotation(position: .overlay) {
                            if c.count > 1 { Text("\(c.count)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                        }
                }
                if let h = hover {
                    RuleMark(x: .value("Time", Double(h.x))).foregroundStyle(.secondary.opacity(0.6))
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: axis.start...0)
            .chartXAxis {
                AxisMarks(values: axis.ticks.map(\.x)) { v in
                    let d = v.as(Double.self) ?? 0
                    // The edge labels sit inside the chart: now ends at the right, the oldest starts at the left.
                    AxisValueLabel(anchor: d == 0 ? .topTrailing : d == axis.start ? .topLeading : .top) {
                        if let t = axis.ticks.first(where: { abs($0.x - d) < 0.0001 }) { Text(t.label) }
                    }
                }
            }
            .chartYScale(domain: -1.25...Double(lanes))
            .chartYAxis {
                AxisMarks(position: .leading, values: (0..<lanes).map { Double($0) + 0.5 }) { v in
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d) + 1)") } }
                }
                AxisMarks(position: .leading, values: [-0.75]) { _ in
                    AxisValueLabel { Text("waiting").foregroundStyle(.red) }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let p) = phase, let frame = proxy.plotFrame else { hover = nil; return }
                            let origin = geo[frame].origin
                            if let hx = proxy.value(atX: p.x - origin.x, as: Double.self), let hy = proxy.value(atY: p.y - origin.y, as: Double.self) {
                                hover = CGPoint(x: hx, y: hy)
                            }
                        }
                }
            }
            .frame(minHeight: 240)
            Text("Each lane is one of the budget's cores: empty when free, pale when a job holds it, solid while it is busy. Recent time is widest, on the right.")
                .font(.caption).foregroundStyle(.secondary)
            table
        }
    }

    /// Every core in every column: the job holding it longest there, and how busy; and how many
    /// waited. A job keeps its lowest cores busy first: with 2.5 active of 4, its first two
    /// cores are solid, the third half, the fourth pale.
    static func grid(_ m: GraphModel, axis: TimeAxis, end: Date, lanes: Int) -> ([Cell], [WaitCell]) {
        var cells: [Cell] = []
        var waits: [WaitCell] = []
        let w = -axis.start / Double(columns)
        for c in 0..<columns {
            let t1 = end.addingTimeInterval(-axis.age(axis.start + Double(c) * w))
            let t2 = end.addingTimeInterval(-axis.age(axis.start + Double(c + 1) * w))
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
                cells.append(Cell(column: c, lane: lane, project: b.project, busy: min(max((active ?? 0) - rank, 0), 1), block: b.id))
            }
            waits.append(WaitCell(column: c, count: m.waits.filter { overlap($0.from, $0.to) > 0 }.count))
        }
        return (cells, waits)
    }

    /// The top line: what the machine is doing now.
    private func summary() -> Text {
        let s = model.status
        let waiting = s?.waiters.count ?? 0
        var line = Text("\(s?.held ?? 0) of \(s?.budget ?? 0) cores in use").bold()
        line = line + Text(String(format: " · %.1f active", s?.holders.reduce(0) { $0 + ($1.using ?? 0) } ?? 0))
        line = line + Text(" · \(waiting) waiting").foregroundColor(waiting > 0 ? .red : nil)
        let outside = s?.outside.reduce(0) { $0 + $1.using } ?? 0
        if outside >= 0.3 { line = line + Text(String(format: " · %.1f outside cpuq", outside)).foregroundColor(.secondary) }
        if let load = s?.load.first { line = line + Text(String(format: " · load %.1f", load)).foregroundColor(.secondary) }
        return line
    }

    /// The top line for the cell under the pointer: the job holding that core then, or who
    /// waited then.
    private func describe(_ p: CGPoint, axis: TimeAxis, end: Date, cells: [Cell]) -> Text? {
        let a = axis.age(p.x)
        let at = end.addingTimeInterval(-a)
        // The machine then, when the app was watching: cpuq's cores in use and active, and the load.
        let then = model.samples.min { abs($0.at.timeIntervalSince(at)) < abs($1.at.timeIntervalSince(at)) }
            .flatMap { abs($0.at.timeIntervalSince(at)) < 30 ? $0 : nil }
        let machine = then.map {
            Text("   cpuq \($0.inUse) in use, ").foregroundColor(.secondary)
                + Text(String(format: "%.1f active", $0.active)).foregroundColor(.secondary)
                + Text(String(format: " · load %.1f", $0.load)).foregroundColor(.secondary)
        } ?? Text("")
        return describeJob(p, axis: axis, at: at, a: a, end: end, cells: cells).map { $0 + machine }
    }

    private func describeJob(_ p: CGPoint, axis: TimeAxis, at: Date, a: TimeInterval, end: Date, cells: [Cell]) -> Text? {
        let when = Text(a < 5 ? "now   " : age(a) + " ago   ").foregroundColor(.secondary)
        let column = min(max(Int((p.x - axis.start) / (-axis.start / Double(Self.columns))), 0), Self.columns - 1)
        if p.y >= 0 {
            let lane = Int(p.y)
            guard let cell = cells.first(where: { $0.column == column && $0.lane == lane }), let id = cell.block,
                  let b = model.blocks.first(where: { $0.id == id }) else { return when + Text("core \(lane + 1) free").foregroundColor(.secondary) }
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
                Text("Share").frame(width: 64, alignment: .trailing)
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
                        .frame(width: 64, alignment: .trailing)
                }
            }
            ForEach(model.waiting) { w in
                GridRow {
                    HStack(spacing: 6) { Circle().strokeBorder(.red, lineWidth: 1.5).frame(width: 8, height: 8); Text(w.label).lineLimit(1).truncationMode(.middle) }
                        .frame(width: 220, alignment: .leading)
                    Text("waiting \(age(Date().timeIntervalSince1970 - Double(w.since))) for \(w.cores)")
                        .foregroundStyle(.red).lineLimit(1).frame(width: 224, alignment: .leading).gridCellColumns(3)
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
