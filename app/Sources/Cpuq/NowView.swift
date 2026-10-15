import Charts
import CpuqCore
import SwiftUI

/// The Now tab: the Mac's ten CPUs as glass cells that fill with each project's color, the jobs
/// waiting for room beside them, the last hour on the same 0-to-10 scale, and the jobs. Empty
/// glass is calm; empty glass while someone waits glows rose, the one case worth hunting.
/// Pointing at the hour replays that moment in the cells.
struct NowView: View {
    let model: GraphModel
    /// Runs a job action (`cpuq ACTION PID`), asking first where it costs something.
    var control: ((String, Int, String) -> Void)? = nil

    /// The moment under the pointer in the hour chart; nil for now.
    @State private var scrub: Date?
    @State private var cache = HourCache()
    @State private var motion = CellMotion()

    var body: some View {
        guard model.status != nil else {
            return AnyView(Text("Waiting for cpuq…").foregroundStyle(Alive.ink2).frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        let end = Date()
        let hour = cache.hour(model, end: end)
        // Mid-drag the page shows now: a moment replayed under the pointer would reshape it.
        let shown = (SplitDrag.shared.active ? nil : scrub).map { Moment.at($0, model) } ?? Moment.now(model)
        // One page per machine, top to bottom: now, the hour (both charts), the jobs, and
        // history; every section's height is the user's to drag.
        return AnyView(SplitColumn(key: "page.splits", defaults: [0.24, 0.38, 0.19, 0.19], minimums: [196, 230, 64, 96], bleed: 10, sections: [
            AnyView(HeroCard(model: model, moment: shown, motion: motion, control: control)),
            AnyView(HourCard(model: model, hour: hour, scrub: $scrub)),
            AnyView(JobsCard(model: model, control: control)),
            AnyView(HistoryCard(model: model)),
        ]))
    }
}

// MARK: - What the views show


/// Seconds as "4s", "1m 01s", "2h 03m".
func duration(_ s: TimeInterval) -> String {
    let s = max(Int(s.rounded()), 0)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m " + String(format: "%02ds", s % 60) }
    return "\(s / 3600)h " + String(format: "%02dm", s / 60 % 60)
}

/// A time to the minute, for an estimate: "<1m", "9m", "1h 05m".
func roughly(_ s: TimeInterval) -> String {
    let m = max(Int((s / 60).rounded()), 0)
    if m < 1 { return "<1m" }
    if m < 60 { return "\(m)m" }
    return "\(m / 60)h " + String(format: "%02dm", m % 60)
}

/// How far a running job is: "4,210 of 12,629 · 3 failing · ~9m left" from its own count,
/// or "usually 46m" from its label's history.
func progressText(_ h: Status.Holder) -> Text {
    if let p = h.progress, p.total > 0 {
        var t = Text("\(p.done.formatted()) of \(p.total.formatted())").foregroundStyle(Alive.ink)
        if p.failing > 0 { t = t + Text(" · \(p.failing.formatted()) failing").foregroundStyle(.red) }
        if let left = h.left, h.leftFrom == "progress" { t = t + Text(" · ~\(roughly(left)) left").foregroundStyle(Alive.ink2) }
        return t
    }
    if let typical = h.typical { return Text("usually \(roughly(typical))").foregroundStyle(Alive.ink3) }
    return Text("")
}

/// The Mac at one moment: the CPU each project kept busy, other work, and who waited.
struct Moment {
    struct Share { let project: String; let cpu: Double }
    struct Waiter: Identifiable {
        let id: String
        let pid: Int
        let label: String
        let project: String
        let asks: String
        let need: Int
        let since: Date
    }

    /// Nil for now, else the moment replayed.
    var at: Date?
    var shares: [Share] = []
    var outside = 0.0
    var waiters: [Waiter] = []
    /// Why cpuq's gate was shut, if it was.
    var gateShut: String?
    /// A timing window (`--exclusive`) holding the Mac, or first in line and waiting for it to
    /// empty: its label. Jobs waiting meanwhile wait on purpose.
    var window: String?
    /// The window holds the Mac now (else it waits for running work to end).
    var windowHolds = false
    /// The 1-minute load: threads running or ready to run, the demand on the CPUs.
    var load: Double?
    /// The machine's CPUs.
    var cpus = 1.0

    var total: Double { shares.reduce(0) { $0 + $1.cpu } + outside }
    var free: Double { max(cpus - total, 0) }
    /// The app was running then and measured the CPUs; before it was, jobs and waits are known
    /// from cpuq but how busy the CPUs were is not.
    var watched = true
    /// Jobs waited while CPUs sat idle with the gate open: the case to fix. Never judged from
    /// a moment the app did not watch: unknown CPU is not idle CPU.
    /// Free CPUs count as idle beside a waiter only when there are enough for the smallest one's
    /// minimum: a job asking for 4 beside 2 free waits fairly.
    var needless: Bool { watched && !waiters.isEmpty && free >= max(2, Double(waiters.map(\.need).min() ?? 2)) && gateShut == nil && window == nil }

    /// No more than the CPUs, whatever the readings say.
    mutating func fit() {
        let sum = total
        guard sum > cpus, sum > 0 else { return }
        let k = cpus / sum
        shares = shares.map { Share(project: $0.project, cpu: $0.cpu * k) }
        outside *= k
    }

    static func now(_ m: GraphModel) -> Moment {
        guard let s = m.status else { return Moment() }
        var by: [String: Double] = [:]
        for h in s.holders { by[GraphModel.group(h.label, h.note), default: 0] += h.using ?? 0 }
        var out = Moment()
        out.cpus = m.cpus
        out.shares = by.keys.sorted { (m.slot($0), $0) < (m.slot($1), $1) }.map { Share(project: $0, cpu: by[$0] ?? 0) }
        let jobs = out.total
        // The rest of what the Mac measured busy, beyond cpuq's jobs, is other work.
        if let busy = m.samples.last?.busy { out.outside = max(busy * m.cpus - jobs, 0) } else { out.outside = s.outside.reduce(0) { $0 + $1.using } }
        out.waiters = s.waiters.map {
            Waiter(id: "\($0.pid)-\($0.since)", pid: $0.pid, label: GraphModel.label($0.label, $0.command), project: GraphModel.group($0.label, $0.note),
                   asks: GraphModel.wants($0), need: $0.exclusive ? Int(m.cpus) : max($0.cores, 1), since: Date(timeIntervalSince1970: Double($0.since)))
        }
        out.gateShut = s.gate.state == "open" ? nil : s.gate.text
        out.load = s.load.first
        if let h = s.holders.first(where: \.exclusive) {
            out.window = GraphModel.label(h.label, h.command)
            out.windowHolds = true
        } else if let w = s.waiters.min(by: { $0.order < $1.order }), w.exclusive {
            out.window = GraphModel.label(w.label, w.command)
        }
        out.fit()
        return out
    }

    static func at(_ t: Date, _ m: GraphModel) -> Moment {
        var by: [String: Double] = [:]
        for b in m.blocks where b.from <= t && (b.to ?? .distantFuture) >= t {
            let near = b.active.min { abs($0.at.timeIntervalSince(t)) < abs($1.at.timeIntervalSince(t)) }
            by[b.project, default: 0] += near.flatMap { abs($0.at.timeIntervalSince(t)) < 15 ? $0.cores : nil } ?? b.average ?? 0
        }
        var out = Moment(at: t)
        out.cpus = m.cpus
        out.shares = by.keys.sorted { (m.slot($0), $0) < (m.slot($1), $1) }.map { Share(project: $0, cpu: by[$0] ?? 0) }
        let jobs = out.total
        let sample = m.samples.min { abs($0.at.timeIntervalSince(t)) < abs($1.at.timeIntervalSince(t)) }
            .flatMap { abs($0.at.timeIntervalSince(t)) < 15 ? $0 : nil }
        out.watched = sample != nil
        if let sample {
            out.load = sample.load
            out.outside = sample.busy.map { max($0 * m.cpus - jobs, 0) } ?? sample.outside
            if !sample.gateOpen { out.gateShut = sample.gateText }
        }
        if let b = m.blocks.first(where: { $0.exclusive && $0.from <= t && ($0.to ?? .distantFuture) >= t }) {
            out.window = b.label
            out.windowHolds = true
        } else if let w = m.waits.first(where: { $0.exclusive && $0.from <= t && ($0.to ?? .distantFuture) >= t }) {
            out.window = w.label
        }
        out.waiters = m.waits.filter { $0.from <= t && ($0.to ?? .distantFuture) >= t }.map {
            Waiter(id: $0.id, pid: 0, label: $0.label, project: $0.project, asks: $0.cores, need: $0.need, since: $0.from)
        }
        out.fit()
        return out
    }
}

/// The last hour (at most) in 120 equal columns, worked out once per poll rather than on every
/// movement of the pointer.
final class HourCache {
    struct Column {
        let from: Date
        let to: Date
        var mid: Date { from.addingTimeInterval(to.timeIntervalSince(from) / 2) }
        var shares: [String: Double] = [:]
        var outside = 0.0
        var waiting = 0
        /// The app was watching: there are machine readings.
        var watched = false
        var gateShut = false
        /// A timing window held the Mac or waited for it to empty: waiting then was on purpose.
        var window = false
        var perCPU: [Double]?
        /// The machine's CPUs.
        var cpus = 1.0
        var total: Double { shares.values.reduce(0, +) + outside }
        /// The fewest CPUs any job waiting then asked for.
        var minNeed = 2
        var needless: Bool { watched && waiting > 0 && cpus - total >= Double(max(2, minNeed)) && !gateShut && !window }
    }

    struct Hour {
        var span: TimeInterval = 300
        /// How long each column lasts.
        var step: TimeInterval = 2.5
        /// The moment it was worked out: now, for its time axis.
        var end = Date()
        var columns: [Column] = []
        /// Projects in the hour, in palette order: the stacking order.
        var projects: [String] = []
    }

    private var key = ""
    private var last = Hour()

    func hour(_ m: GraphModel, end: Date) -> Hour {
        let k = "\(m.samples.count)-\(m.samples.last?.at.timeIntervalSince1970 ?? 0)-\(m.blocks.count)-\(m.waits.count)"
        if k == key { return last }
        key = k
        last = Self.build(m, end: end)
        return last
    }

    static let count = 120

    static func build(_ m: GraphModel, end: Date) -> Hour {
        // Columns pinned to the clock: each covers the same seconds from one refresh to the
        // next, so a short wait never flickers between columns. The span grows in 5-minute
        // steps up to the hour, so the columns keep their length while it does.
        let raw = max(end.timeIntervalSince(m.oldest(now: end)), 300)
        let span = min((raw / 300).rounded(.up) * 300, GraphModel.keep)
        let step = span / Double(count)
        let start = Date(timeIntervalSince1970: (end.addingTimeInterval(-span).timeIntervalSince1970 / step).rounded(.down) * step)
        let total = Int((end.timeIntervalSince(start) / step).rounded(.up))
        var cols = (0..<total).map { c in
            Column(from: start.addingTimeInterval(Double(c) * step), to: start.addingTimeInterval(Double(c + 1) * step), cpus: m.cpus)
        }
        let index = { (t: Date) -> Int in Int((t.timeIntervalSince(start) / step).rounded(.down)) }
        // Each job's CPU in each column: its readings there, else (before the app watched) its
        // average from history, weighted by how much of the column it ran.
        for b in m.blocks {
            var sum = [Int: Double](), n = [Int: Int]()
            for r in b.active { let i = index(r.at); if i >= 0 && i < total { sum[i, default: 0] += r.cores; n[i, default: 0] += 1 } }
            let firstReading = b.active.first?.at
            let lo = max(index(b.from), 0), hi = min(index(b.to ?? end), total - 1)
            guard lo <= hi else { continue }
            for i in lo...hi {
                let c = cols[i]
                let o = max(0, min(c.to, b.to ?? end).timeIntervalSince(max(c.from, b.from))) / step
                guard o > 0 else { continue }
                let cpu: Double?
                // A job already running when the app started has no average yet: before its
                // first reading, count it at that reading rather than at nothing.
                if let s = sum[i], let k = n[i] { cpu = s / Double(k) } else if firstReading == nil || c.to <= firstReading! { cpu = b.average ?? b.active.first?.cores } else { cpu = nil }
                if let cpu { cols[i].shares[b.project, default: 0] += cpu * o }
            }
        }
        // The machine: what it measured busy beyond cpuq's jobs is other work.
        var busy = [Int: (Double, Int)](), shut = [Int: (Int, Int)](), per = [Int: ([Double], Int)]()
        for s in m.samples {
            let i = index(s.at)
            guard i >= 0 && i < total else { continue }
            if let b = s.busy { let e = busy[i] ?? (0, 0); busy[i] = (e.0 + b, e.1 + 1) }
            let g = shut[i] ?? (0, 0); shut[i] = (g.0 + (s.gateOpen ? 0 : 1), g.1 + 1)
            if let p = s.perCPU {
                var e = per[i] ?? (Array(repeating: 0, count: p.count), 0)
                if e.0.count == p.count { for j in p.indices { e.0[j] += p[j] }; e.1 += 1 }
                per[i] = e
            }
        }
        for i in 0..<total {
            if let (b, k) = busy[i] { cols[i].watched = true; cols[i].outside = max(b / Double(k) * m.cpus - cols[i].shares.values.reduce(0, +), 0) }
            if let (s, k) = shut[i] { cols[i].gateShut = s * 2 >= k }
            if let (p, k) = per[i], k > 0 { cols[i].perCPU = p.map { $0 / Double(k) } }
            // Never more than the CPUs.
            let t = cols[i].total
            if t > m.cpus { let f = m.cpus / t; cols[i].shares = cols[i].shares.mapValues { $0 * f }; cols[i].outside *= f }
            let waiting = m.waits.filter { $0.from < cols[i].to && ($0.to ?? end) > cols[i].from }
            cols[i].waiting = waiting.count
            cols[i].minNeed = waiting.map(\.need).min() ?? 2
            let c = cols[i]
            cols[i].window = m.blocks.contains { $0.exclusive && $0.from < c.to && ($0.to ?? end) > c.from }
                || m.waits.contains { $0.exclusive && $0.from < c.to && ($0.to ?? end) > c.from }
        }
        let projects = Set(cols.flatMap(\.shares.keys)).sorted { (m.slot($0), $0) < (m.slot($1), $1) }
        return Hour(span: span, step: step, end: end, columns: cols, projects: projects)
    }

    /// Runs of columns where `test` holds, allowing a one-column gap.
    static func runs(_ cols: [Column], _ test: (Column) -> Bool) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for (i, c) in cols.enumerated() where test(c) {
            if let last = out.last, i - last.upperBound <= 2 { out[out.count - 1] = last.lowerBound...i } else { out.append(i...i) }
        }
        return out
    }
}

// MARK: - Toolbar status

/// cpuq's gate, memory and load, at the right of the toolbar.
struct StatusChips: View {
    let model: GraphModel
    private var cpus: Double { model.cpus }
    var body: some View {
        if let s = model.status {
            HStack(spacing: 14) {
                Label(s.gate.state == "open" ? "Gate open" : "Gate shut", systemImage: s.gate.state == "open" ? "checkmark.circle" : "pause.circle.fill")
                    .foregroundStyle(s.gate.state == "open" ? Color.secondary : Color.orange)
                    .help(s.gate.text)
                if let m = s.memory {
                    HStack(spacing: 4) {
                        Text("RAM").foregroundStyle(Alive.ink2)
                        Text(Status.Memory.ofGB(m.used, m.total))
                            .fontWeight(.medium).monospacedDigit().foregroundStyle(s.memoryPressure == "high" ? Alive.rose : Alive.ink)
                    }
                    .help(s.memoryPressure == "high" ? "Memory in use, and the kernel reports memory pressure: cpuq's gate holds new work back." : "Memory in use: apps, the kernel's own, and compressed. The file cache counts as free.")
                    if m.swapTotal > 0 {
                        Text("•").foregroundStyle(Alive.ink2)
                        HStack(spacing: 4) {
                            Text("Swap").foregroundStyle(Alive.ink2)
                            Text(Status.Memory.ofGB(m.swapUsed, m.swapTotal))
                                .fontWeight(.medium).monospacedDigit().foregroundStyle(Alive.ink)
                        }
                        .help("Swap in use. Swap a machine filled earlier stays used until those pages are needed again, so a full swap with free RAM is history, not trouble; the pressure is what counts.")
                    }
                } else {
                    HStack(spacing: 4) {
                        Text("Memory").foregroundStyle(Alive.ink2)
                        Text(s.memoryPressure == "high" ? "high" : s.memoryPressure.isEmpty ? "–" : s.memoryPressure)
                            .fontWeight(.medium).foregroundStyle(s.memoryPressure == "high" ? Alive.rose : Alive.ink)
                    }
                }
                if let load = s.load.first {
                    HStack(spacing: 4) {
                        Text("Demand (1 min)").foregroundStyle(Alive.ink2)
                        Text(String(format: "%.1f", load)).fontWeight(.medium).monospacedDigit().foregroundStyle(Alive.ink)
                    }
                    .help("The load: threads running or ready to run, averaged over the last minute, on \(Int(cpus)) CPUs. It is demand, not work done, and lags: \"CPUs busy\" is the CPU time actually spent in the last few seconds. Above \(Int(cpus)) the machine is overbooked: every CPU busy, and threads waiting for one.")
                }
            }
            .font(.system(size: 12))
            .labelStyle(.titleAndIcon)
        }
    }
}

// MARK: - The hero: right now

struct HeroCard: View {
    let model: GraphModel
    private var cpus: Double { model.cpus }
    let moment: Moment
    let motion: CellMotion
    var control: ((String, Int, String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            summary.frame(width: 232, alignment: .leading)
            GeometryReader { geo in
                let tray = geo.size.width >= 470
                // Cells grow to 44 points wide; past that the waiting tray takes the extra width.
                let cells = cpus > Double(CellsCanvas.gridAbove) ? max(geo.size.width * 0.6, 300) : cpus * 44 + (cpus - 1) * 6
                let trayWidth = tray ? max(180, geo.size.width - cells - 36) : 0
                // The cells' canvas runs down behind the legend, so their glow has room to spread
                // out in full and fade before the card's edge.
                ZStack(alignment: .bottomTrailing) {
                    ZStack(alignment: .topLeading) {
                        // Keyed by the moment pointed at: the canvas's timeline redraws on its own
                        // tick, and the grid kept showing now beside a legend for then.
                        CellsCanvas(model: model, moment: moment, motion: motion, trayWidth: tray ? trayWidth + 6 : 0, below: 22)
                            .id(moment.at)
                        if tray { WaitingTray(model: model, moment: moment, control: control).frame(width: trayWidth) }
                    }
                    legend
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .card()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(moment.at == nil ? "RIGHT NOW" : "THEN").eyebrow()
                if let at = moment.at {
                    Text(Date().timeIntervalSince(at) < 5 ? "now" : duration(Date().timeIntervalSince(at)) + " ago")
                        .font(.caption).padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(Alive.glass)).overlay(Capsule().strokeBorder(Alive.glassEdge))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", moment.total)).font(.system(size: 66, weight: .semibold)).tracking(-2.3).monospacedDigit()
                Text("/ \(Int(cpus))").font(.system(size: 26, weight: .medium)).tracking(-0.26).foregroundStyle(Alive.ink3)
            }
            .padding(.top, 6)
            demandLine.font(.system(size: 13))
                .help("CPUs busy: how much of the \(Int(cpus)) CPUs is working. Demand: the threads running or ready to run (the load), over the CPUs; past 100% the CPUs are overbooked, some threads taking turns, which keeps every CPU busy.")
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 7) {
                capacityVerdict
                waitingVerdict
            }
        }
    }

    /// "CPUs busy · 100%", and while more threads want CPU than there are CPUs, "(demand 239%)".
    private var demandLine: Text {
        var t = Text("CPUs busy · ").foregroundColor(Alive.ink2) + Text("\(Int((moment.total / cpus * 100).rounded()))%").fontWeight(.semibold)
        if let load = moment.load, load > cpus * 1.05 {
            t = t + Text("  (demand \(Int((load / cpus * 100).rounded()))%)").fontWeight(.semibold).foregroundColor(Alive.rose)
        }
        return t
    }

    private func verdict(_ symbol: String, _ title: String, _ detail: String, tint: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint ?? Alive.ink2).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold).foregroundStyle(tint ?? .primary)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(tint.map { AnyShapeStyle($0.opacity(0.85)) } ?? AnyShapeStyle(Alive.ink2))
            }
        }
        .font(.system(size: 12.5))
        .lineLimit(2)
    }

    @ViewBuilder private var capacityVerdict: some View {
        let free = String(format: "%.1f", moment.free)
        if let w = moment.window {
            verdict("lock.fill", "Timing window", moment.windowHolds ? "\(w) has the Mac alone" : "\(w) waits for the Mac to empty",
                    tint: Alive.windowTint)
        } else if !moment.watched {
            verdict("eye.slash", "Not watched", "The app wasn't running then: how busy the CPUs were is unknown")
        } else if moment.needless {
            verdict("exclamationmark.triangle.fill", "\(moment.waiters.count) waiting while \(free) CPUs sit idle",
                    "Waiting with room to spare", tint: Alive.rose)
        } else if let shut = moment.gateShut {
            verdict("pause.circle.fill", "cpuq's gate is shut", shut.hasPrefix("closed: ") ? String(shut.dropFirst(8)) : shut, tint: .orange)
        } else if moment.total >= cpus * 0.8 {
            verdict("checkmark.circle", "Working at full capacity", "\(free) CPUs free")
        } else if moment.total < 1.5 && moment.waiters.isEmpty && moment.shares.allSatisfy({ $0.cpu < 0.05 }) {
            // Quiet only with no cpuq job at work: on a big machine one running job is a sliver.
            verdict("moon.zzz", "Quiet", "Nothing to run")
        } else {
            verdict("circle.lefthalf.filled", "Partly busy", "\(free) CPUs free")
        }
    }

    @ViewBuilder private var waitingVerdict: some View {
        let ref = moment.at ?? Date()
        if let longest = moment.waiters.map({ ref.timeIntervalSince($0.since) }).max() {
            if moment.window != nil {
                verdict("clock", "\(moment.waiters.count) waiting \(duration(longest))", "They start when the window ends")
            } else if !moment.watched {
                verdict("clock", "\(moment.waiters.count) waiting \(duration(longest))", "Whether CPUs were free is unknown")
            } else if moment.needless {
                verdict("clock.fill", "Longest wait \(duration(longest))", "This is the case to fix", tint: Alive.rose)
            } else if moment.gateShut != nil {
                verdict("clock", "\(moment.waiters.count) waiting \(duration(longest))", "They start when the gate opens")
            } else {
                verdict("clock", "\(moment.waiters.count) waiting \(duration(longest)) · fair", "CPUs are full: each starts when room opens")
            }
        } else {
            verdict("checkmark.circle", "Nobody waiting", moment.total < 1.5 ? "Queue empty" : "Every job that asked is running")
        }
    }

    /// The legend in full where it fits; in a narrow window, shorter names, then smaller type.
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            legendRow(outside: "outside cpuq", size: 11.5)
            legendRow(outside: "outside", size: 11.5)
            legendRow(outside: "outside", size: 10.5, spacing: 8)
            legendRow(outside: "out", size: 10, spacing: 6)
            legendRow(outside: nil, size: 10, spacing: 6)
        }
    }

    /// One way to lay the legend out; `outside` nil leaves out every name, the colors and
    /// numbers alone as a last resort in the narrowest window.
    private func legendRow(outside: String?, size: CGFloat, spacing: CGFloat = 11) -> some View {
        HStack(spacing: spacing) {
            ForEach(moment.shares, id: \.project) { s in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(model.color(s.project)).frame(width: 9, height: 9)
                    if outside != nil { Text(s.project).foregroundStyle(Alive.ink2) }
                    Text(String(format: "%.1f", s.cpu)).fontWeight(.medium).foregroundStyle(Alive.ink)
                }
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(Alive.out).frame(width: 9, height: 9)
                if let outside { Text(outside).foregroundStyle(Alive.ink2) }
                Text(String(format: "%.1f", moment.outside)).fontWeight(.medium).foregroundStyle(Alive.ink)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(moment.needless ? Alive.rose : Alive.glassEdge)
                    .background(RoundedRectangle(cornerRadius: 3).fill(moment.needless ? Alive.roseSoft : Alive.glass))
                    .frame(width: 9, height: 9)
                if outside != nil { Text(moment.needless ? "idle" : "free").foregroundStyle(moment.needless ? Alive.rose : Alive.ink2) }
                Text(String(format: "%.1f", moment.free)).fontWeight(.medium).foregroundStyle(moment.needless ? Alive.rose : Alive.ink)
            }
        }
        .font(.system(size: size))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}

/// The jobs waiting for room, beside the cells they will pour into.
struct WaitingTray: View {
    let model: GraphModel
    let moment: Moment
    var control: ((String, Int, String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("WAITING").eyebrow()
                Spacer()
                Text("\(moment.waiters.count)").font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(moment.needless ? Alive.rose : Alive.ink)
            }
            if moment.waiters.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Queue empty").font(.system(size: 13)).foregroundStyle(Alive.ink2)
                    Text("new jobs start at once").font(.system(size: 12)).foregroundStyle(Alive.ink3)
                }
                .padding(.top, 4)
            } else {
                let ref = moment.at ?? Date()
                let sorted = moment.waiters.sorted { $0.since < $1.since }
                ForEach(sorted.prefix(3)) { w in pill(w, ref: ref) }
                if sorted.count > 3 {
                    Text("+\(sorted.count - 3) more waiting").font(.caption.weight(.medium))
                        .foregroundStyle(moment.needless ? Alive.rose : Alive.ink2)
                }
            }
        }
    }

    private func pill(_ w: Moment.Waiter, ref: Date) -> some View {
        let bad = moment.needless
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle().strokeBorder(model.color(w.project), lineWidth: 2).frame(width: 8, height: 8)
                Text(w.label).lineLimit(1).truncationMode(.middle).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text(duration(ref.timeIntervalSince(w.since))).monospacedDigit()
                    .foregroundStyle(bad ? Alive.rose : Alive.ink2).fontWeight(bad ? .semibold : .regular)
            }
            .font(.caption)
            Text(moment.window != nil ? "asks \(w.asks) · timing window" : bad ? "asks \(w.asks) · CPUs idle" : "asks \(w.asks) · \(String(format: "%.1f", moment.free)) free")
                .font(.system(size: 10.5)).foregroundStyle(Alive.ink2).lineLimit(1).padding(.leading, 14)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(bad ? Alive.roseSoft : Alive.card))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(bad ? Alive.rose : Alive.glassEdge))
        .shadow(color: .black.opacity(bad ? 0 : 0.05), radius: 1, y: 1)
        .contextMenu { WaiterActions(pid: w.pid, label: w.label, model: model, control: control) }
    }
}

/// Move to Front, Start Now and Cancel, for a job waiting now.
struct WaiterActions: View {
    let pid: Int
    let label: String
    let model: GraphModel
    var control: ((String, Int, String) -> Void)?
    var body: some View {
        if let control, pid > 0, supportsControls(version: model.status?.version ?? "") {
            Button("Move to Front") { control("first", pid, label) }
            Button("Start Now…") { control("start", pid, label) }
            Button("Cancel") { control("cancel", pid, label) }
        }
    }
}

/// How lively the cells are. One decision says whether the water moves and bubbles rise: effects
/// are on and the Mac is not strained. Then they always do, at thirty frames a second while the
/// window is on screen (measured: about 6% of one CPU; fewer frames look jerky, sixty costs two to
/// five times as much). Otherwise they never do, hovering or not: the cells keep still, drawn once
/// a second, and ease smoothly to new readings only while the mouse moves in the window or it is
/// resized.
@MainActor
final class Liveliness: ObservableObject {
    static let shared = Liveliness()
    /// The mouse moved in the window, or it was resized, within the last second.
    @Published private(set) var lively = false
    /// Water and bubbles: the user's choice, kept between launches.
    @Published var effects = UserDefaults.standard.object(forKey: "visualEffects") as? Bool ?? true {
        didSet { UserDefaults.standard.set(effects, forKey: "visualEffects") }
    }
    /// The Mac is strained: more threads want to run than it has CPUs to spare for frames.
    @Published private(set) var strained = false
    /// Some of the window shows on screen.
    @Published var visible = true

    /// The one decision: the water moves and bubbles rise, or not at all.
    var showsEffects: Bool { effects && !strained }
    /// Effects run on their own while someone can see them.
    var ambient: Bool { showsEffects && visible }
    /// Seconds between frames.
    var interval: Double { lively || ambient ? 1.0 / 30 : 1 }

    private var until = Date.distantPast
    private var timer: Timer?

    /// Something moved: lively for the next second.
    func poke() {
        until = Date().addingTimeInterval(1)
        if !lively { lively = true }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date() >= self.until else { return }
                self.lively = false
                self.timer?.invalidate()
                self.timer = nil
            }
        }
    }

    /// A new 1-minute load from cpuq: strained once it passes the CPUs by half, eased once it
    /// falls back under them, so it does not flicker at the edge.
    func observe(load: Double?, cpus: Double) {
        guard let load else { return }
        let now = strained ? load >= cpus : load >= cpus * 1.5
        if now != strained { strained = now }
    }
}

/// The cells' animated state: each layer's fill eases toward its reading, and the rose glow
/// fades in and out, so a new poll pours rather than jumps.
final class CellMotion {
    var fill: [String: Double] = [:]
    var rose = 0.0
    /// Bubbles rising through busy cells: which cell, where, how fast, how big.
    var bubbles: [(cell: Int, x: Double, y: Double, speed: Double, r: Double)] = []
    var lastFrame = 0.0

    /// The first frame shows the reading as it is; later ones ease toward it.
    private var primed = false
    private var lastStep = 0.0

    /// Eases toward the reading by the time since the last frame (a third of a second to most
    /// of the way), so it looks the same at one frame a second as at thirty.
    func step(toward m: Moment, at t: Double, instantly: Bool) {
        let first = !primed
        primed = true
        let dt = lastStep == 0 ? 1 : min(max(t - lastStep, 0), 1)
        lastStep = t
        let k = instantly || first ? 1 : 1 - exp(-dt / 0.3)
        var target: [String: Double] = ["~outside": m.outside]
        for s in m.shares { target[s.project] = s.cpu }
        for key in Set(target.keys).union(fill.keys) {
            let v = fill[key] ?? 0
            fill[key] = v + ((target[key] ?? 0) - v) * k
            if (fill[key] ?? 0) < 0.001 && target[key] == nil { fill[key] = nil }
        }
        rose += ((m.needless ? 1 : 0) - rose) * k
    }
}

/// Ten glass cells, one per CPU, filled left to right with each project's CPU in palette order,
/// then other work, with a gentle wave on the surface. Drawn with Canvas and paused when motion
/// is reduced.
struct CellsCanvas: View {
    let model: GraphModel
    private var cpus: Double { model.cpus }
    let moment: Moment
    let motion: CellMotion
    let trayWidth: Double
    /// Room kept under the cell numbers for the legend drawn over the canvas.
    var below = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    @ObservedObject private var live = Liveliness.shared

    /// At the rate Liveliness sets: once a second at rest, more with effects or the mouse moving.
    var body: some View {
        TimelineView(.animation(minimumInterval: live.interval, paused: reduceMotion)) { tl in
            Canvas { gc, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                motion.step(toward: moment, at: t, instantly: reduceMotion)
                draw(&gc, size: size, t: reduceMotion || !live.showsEffects ? 0 : t)
            }
        }
    }

    /// More CPUs than glass cells fit (pup's 22, a cloud machine's 96): rows of flat tiles, filled
    /// in the same order and colors, with no waves or bubbles at that size.
    static let gridAbove = 16

    private func draw(_ gc: inout GraphicsContext, size: CGSize, t: Double) {
        let n = Int(cpus)
        if n > Self.gridAbove { return drawGrid(&gc, size: size, n: n) }
        let gap = 6.0
        let x0 = trayWidth + (trayWidth > 0 ? 30 : 0)
        let top = 26.0, bottom = size.height - 16 - below
        let w = max((size.width - x0 - gap * Double(n - 1)) / Double(n), 6)
        let h = max(bottom - top, 20)
        let dark = scheme == .dark
        let pulse = 0.5 + 0.5 * sin(t * 2.4)
        // Layers as ranges on the 0-to-n scale: projects in palette order, then other work.
        var layers: [(Color, Double, Double)] = []
        var acc = 0.0
        let keys = moment.shares.map(\.project)
        for k in keys + motion.fill.keys.filter({ $0 != "~outside" && !keys.contains($0) }) {
            let v = motion.fill[k] ?? 0
            layers.append((model.color(k), acc, acc + v)); acc += v
        }
        let ov = motion.fill["~outside"] ?? 0
        layers.append((Alive.out, acc, acc + ov)); acc += ov
        let total = acc

        // A soft bloom of each project's color under the glass, wider the more it uses.
        for (color, a, b) in layers {
            let v = b - a
            guard v >= 0.05 else { continue }
            let mid = a + v / 2
            let cx = x0 + mid * (w + gap) - gap / 2, r = 24 + v * 22
            var g = gc
            g.translateBy(x: cx, y: bottom + 2)
            // Flattened into an ellipse no taller than the room under the cells, so it fades
            // out before the canvas's edge rather than being cut off at it.
            g.scaleBy(x: 1, y: min(0.38, (size.height - bottom - 3) / r))
            g.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)),
                   with: .radialGradient(Gradient(colors: [color.opacity(dark ? 0.34 : 0.22), color.opacity(0)]), center: .zero, startRadius: 0, endRadius: r))
        }
        // Bubbles: a few rise through each busy cell, more the busier it is; only while the
        // effects move (t is 0 when they keep still), as a bubble jumping once a second looks wrong.
        let dt = motion.lastFrame == 0 ? 0 : min(t - motion.lastFrame, 0.1)
        motion.lastFrame = t
        if t == 0 { motion.bubbles = [] }
        if t > 0 {
            for c in 0..<n {
                let level = min(max(total - Double(c), 0), 1)
                if level > 0.15 && Double.random(in: 0..<1) < 1.05 * level * dt {
                    motion.bubbles.append((c, Double.random(in: 4...max(w - 4, 5)), bottom - 2, Double.random(in: 10...26), Double.random(in: 0.7...1.8)))
                }
            }
            motion.bubbles = motion.bubbles.compactMap { b in
                let surface = bottom - min(max(total - Double(b.cell), 0), 1) * h + 3
                let y = b.y - b.speed * dt
                return y < surface ? nil : (b.cell, b.x, y, b.speed, b.r)
            }
        }

        for c in 0..<n {
            let x = x0 + Double(c) * (w + gap)
            let cell = CGRect(x: x, y: top, width: w, height: h)
            let shape = Path(roundedRect: cell, cornerRadius: min(10, w / 3))
            let level = min(max(total - Double(c), 0), 1)
            gc.fill(shape, with: .color(Alive.glass))
            var inner = gc
            inner.clip(to: shape)
            // Empty glass while someone waits needlessly glows rose.
            if motion.rose > 0.01 && level < 1 {
                let yTop = bottom - level * h
                inner.fill(Path(CGRect(x: x, y: top, width: w, height: yTop - top + 2)),
                           with: .linearGradient(Gradient(colors: [Alive.rose.opacity((0.30 + 0.14 * pulse) * motion.rose),
                                                                   Alive.rose.opacity((0.10 + 0.06 * pulse) * motion.rose)]),
                                                 startPoint: CGPoint(x: x, y: top), endPoint: CGPoint(x: x, y: yTop)))
            }
            for (color, a, b) in layers {
                let lo = min(max(a - Double(c), 0), 1), hi = min(max(b - Double(c), 0), 1)
                guard hi - lo > 0.004 else { continue }
                let yTop = bottom - hi * h, yBot = bottom - lo * h
                var p = Path()
                if hi >= level - 0.0001 && level < 0.999 {
                    // The surface: a slow wave, calmer as the layer thins.
                    p.move(to: CGPoint(x: x, y: yBot))
                    var k = 0.0
                    while k <= w {
                        let wave = 1.5 * sin(k * 0.2 + t * 2.1 + Double(c) * 1.7) + 0.7 * sin(k * 0.45 - t * 1.4 + Double(c))
                        p.addLine(to: CGPoint(x: x + k, y: yTop + wave * min(1, (hi - lo) * 8)))
                        k += 2
                    }
                    p.addLine(to: CGPoint(x: x + w, y: yBot))
                    p.closeSubpath()
                } else {
                    p.addRect(CGRect(x: x, y: yTop + (hi < 0.999 ? 1.2 : 0), width: w, height: yBot - yTop - (hi < 0.999 ? 1.2 : 0)))
                }
                // Lit from above: a touch of white at the top, a touch of shade at the bottom.
                inner.fill(p, with: .color(color))
                inner.fill(p, with: .linearGradient(Gradient(colors: [.white.opacity(dark ? 0.10 : 0.16), .black.opacity(dark ? 0.10 : 0.04)]),
                                                   startPoint: CGPoint(x: x, y: yTop), endPoint: CGPoint(x: x, y: yBot + 2)))
            }
            for b in motion.bubbles where b.cell == c {
                inner.fill(Path(ellipseIn: CGRect(x: x + b.x - b.r, y: b.y - b.r, width: 2 * b.r, height: 2 * b.r)), with: .color(.white.opacity(0.45)))
            }
            // Glass sheen.
            inner.fill(Path(cell), with: .linearGradient(Gradient(stops: [.init(color: .white.opacity(dark ? 0.10 : 0.28), location: 0),
                                                                        .init(color: .white.opacity(0), location: 0.3)]),
                                                        startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + w, y: 0)))
            let rimRose = motion.rose > 0.5 && level < 1
            gc.stroke(Path(roundedRect: cell.insetBy(dx: 0.5, dy: 0.5), cornerRadius: min(9.5, w / 3)),
                      with: .color(rimRose ? Alive.rose.opacity(0.55 + 0.3 * pulse) : Alive.glassEdge), lineWidth: 1)
            if motion.rose > 0.4 && level < 0.35 && w >= 24 {
                gc.draw(Text("idle").font(.system(size: 10, weight: .semibold)).foregroundColor(Alive.rose.opacity(motion.rose)),
                        at: CGPoint(x: x + w / 2, y: top + 18))
            }
            gc.draw(Text("\(c + 1)").font(.system(size: 10)).foregroundColor(Alive.ink3), at: CGPoint(x: x + w / 2, y: bottom + 9))
        }
    }
}

extension CellsCanvas {
    private func drawGrid(_ gc: inout GraphicsContext, size: CGSize, n: Int) {
        let x0 = trayWidth + (trayWidth > 0 ? 30 : 0)
        let top = 26.0, bottom = size.height - 16 - below
        let width = max(size.width - x0, 40), height = max(bottom - top, 20)
        let gap = 3.0
        // The fewest rows (at most 8) that keep a tile at least 12 points wide.
        var rows = 1
        while rows < 8 && (width - gap * Double((n + rows - 1) / rows - 1)) / Double((n + rows - 1) / rows) < 12 { rows += 1 }
        let perRow = (n + rows - 1) / rows
        let w = (width - gap * Double(perRow - 1)) / Double(perRow)
        let h = (height - gap * Double(rows - 1)) / Double(rows)
        // The reading itself, not the eased fill the glass cells use: tiles do not animate, and
        // easing let them lag the numbers (most of all while pointing at the hour).
        var layers: [(Color, Double, Double)] = []
        var acc = 0.0
        for share in moment.shares {
            layers.append((model.color(share.project), acc, acc + share.cpu)); acc += share.cpu
        }
        layers.append((Alive.out, acc, acc + moment.outside))
        for c in 0..<n {
            let x = x0 + Double(c % perRow) * (w + gap), y = top + Double(c / perRow) * (h + gap)
            let cell = CGRect(x: x, y: y, width: w, height: h)
            let shape = Path(roundedRect: cell, cornerRadius: min(4, w / 4))
            gc.fill(shape, with: .color(Alive.glass))
            var inner = gc
            inner.clip(to: shape)
            for (color, a, b) in layers {
                let lo = min(max(a - Double(c), 0), 1), hi = min(max(b - Double(c), 0), 1)
                guard hi - lo > 0.004 else { continue }
                inner.fill(Path(CGRect(x: x, y: y + h - hi * h, width: w, height: (hi - lo) * h)), with: .color(color))
            }
            gc.stroke(Path(roundedRect: cell.insetBy(dx: 0.5, dy: 0.5), cornerRadius: min(4, w / 4)), with: .color(Alive.glassEdge), lineWidth: 1)
        }
        gc.draw(Text("\(n) CPUs").font(.system(size: 10)).foregroundColor(Alive.ink3),
                at: CGPoint(x: x0 + width / 2, y: bottom + 9))
    }
}

// MARK: - The last hour

struct HourCard: View {
    let model: GraphModel
    private var cpus: Double { model.cpus }
    let hour: HourCache.Hour
    @Binding var scrub: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).eyebrow()
                Spacer()
                summary.font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            // Both charts at once, on one time axis, Per Core's labels under both; the line
            // between them drags. One wait strip serves both.
            SplitColumn(key: "hour.splits", defaults: [0.5, 0.5], minimums: [56, 56], gap: 8, sections: [
                AnyView(stacked.contextMenu { clearMenu }),
                AnyView(cores.contextMenu { clearMenu }),
            ])
            .frame(maxHeight: .infinity)
            waitStrip.frame(height: 20)
                .contextMenu { clearMenu }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .card()
    }

    /// The charts' right-click menu: forget what is older than the moment under the pointer, or
    /// than five minutes ago. Only the window forgets; cpuq's history is untouched.
    @ViewBuilder private var clearMenu: some View {
        if let at = scrub, Date().timeIntervalSince(at) > 5 {
            Button("Clear Prior Data") {
                model.clear(before: at)
                scrub = nil
            }
        }
        Button("Keep Last Five Minutes") {
            model.clear(before: Date().addingTimeInterval(-300))
            scrub = nil
        }
    }

    private var title: String {
        hour.span >= GraphModel.keep - 60 ? "LAST HOUR" : "LAST \(Int((hour.span / 60).rounded())) MIN"
    }

    private var step: TimeInterval { hour.step }

    /// The labels left of every chart in the card, drawn here rather than by Charts (whose axis
    /// room varies with its labels and marks) in one column, the same for each chart and in both
    /// modes, so the plots start at the same x, share one time axis and stay put when the mode
    /// changes: wide enough for "wait" and "10", and Per Core's bolt and leaf with their counts.
    private let labelWidth: CGFloat = 26
    private var labelColumn: CGFloat { labelWidth + 6 }

    /// Draws `labels` (a value on the y scale, its text) right-aligned in the label column.
    private func yLabels(_ proxy: ChartProxy, _ labels: [(Double, String)], font: Font = .caption2) -> some View {
        yLabels(proxy, labels.map { ($0.0, Text($0.1)) }, font: font)
    }

    private func yLabels(_ proxy: ChartProxy, _ labels: [(Double, Text)], font: Font = .caption2) -> some View {
        GeometryReader { geo in
            if let frame = proxy.plotFrame {
                let plot = geo[frame]
                ForEach(Array(labels.enumerated()), id: \.offset) { _, l in
                    if let y = proxy.position(forY: l.0) {
                        l.1.font(font).foregroundStyle(.secondary).lineLimit(1)
                            .frame(width: labelWidth, alignment: .trailing)
                            .position(x: plot.minX - labelColumn + labelWidth / 2, y: plot.minY + y)
                    }
                }
            }
        }
    }

    private var summary: Text {
        let watched = hour.columns.filter(\.watched)
        let avg = watched.isEmpty ? 0 : watched.reduce(0) { $0 + $1.total } / Double(watched.count)
        var t = Text("avg ").foregroundColor(.secondary) + Text(String(format: "%.1f", avg)).bold() + Text(" of \(Int(cpus)) busy").foregroundColor(.secondary)
        let bad = HourCache.runs(hour.columns, \.needless)
        let minutes = Double(hour.columns.filter(\.needless).count) * step / 60
        if bad.isEmpty {
            t = t + Text(" · no needless waiting").foregroundColor(.secondary)
        } else {
            let last = bad.last!
            let end = hour.columns.last?.to ?? Date()
            let a = Int((end.timeIntervalSince(hour.columns[last.lowerBound].from) / 60).rounded())
            let b = Int((end.timeIntervalSince(hour.columns[last.upperBound].to) / 60).rounded())
            t = t + Text(" · waited with CPUs idle ").foregroundColor(.secondary)
                + Text(minutes < 1 ? "<1 min" : "\(Int(minutes.rounded())) min").foregroundColor(Alive.rose).bold()
                + Text(b < 1 ? ", ending \(a) min ago" : a == b ? ", \(a) min ago" : ", \(a)–\(b) min ago").foregroundColor(.secondary)
                + Text(" · otherwise waits were seconds").foregroundColor(.secondary)
        }
        return t
    }

    private var xDomain: ClosedRange<Date> {
        (hour.columns.first?.from ?? Date())...(hour.columns.last?.to ?? Date())
    }

    /// Ticks at quarters of the span, the oldest labelled with how long ago.
    /// Ticks at round times back from now: now, round minutes between, the oldest a whole span
    /// ago, each in minutes ("60 min"), with "now" at the other end, whatever second the clock-pinned columns start on.
    private var ticks: [Date] {
        guard let a = hour.columns.first?.from else { return [] }
        // Between them, round minutes: every 15 over an hour, every 5 over 25 minutes, about
        // five spaces in all, none crowding the oldest.
        let every = max(5, ((hour.span / 60 / 5) / 5).rounded(.up) * 5) * 60
        let between = stride(from: every, to: hour.span - every / 2, by: every).reversed().map { hour.end.addingTimeInterval(-$0) }
        return [max(hour.end.addingTimeInterval(-hour.span), a)] + between + [hour.end]
    }

    private func tickLabel(_ d: Date) -> String {
        if d == ticks.last { return "now" }
        if d == ticks.first { return "\(Int((hour.span / 60).rounded())) min" }
        return "\(Int((hour.end.timeIntervalSince(d) / 60).rounded())) min"
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: ticks) { v in
            AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
            AxisValueLabel(anchor: v.as(Date.self) == ticks.first ? .topLeading : v.as(Date.self) == ticks.last ? .topTrailing : .top) {
                if let d = v.as(Date.self) { Text(tickLabel(d)) }
            }
        }
    }

    private var stacked: some View {
        let cols = hour.columns
        let bad = HourCache.runs(cols, \.needless)
        let quiet = HourCache.runs(cols) { $0.watched && $0.total < 0.3 && $0.waiting == 0 }.filter { $0.count >= 10 }
        let layers = hour.projects + ["~outside"]
        return Chart {
            // The grid drawn as marks, with the axis hidden: an axis Charts draws, even without
            // labels, takes room at the left that Per Core's lacks, and the plot would shift.
            ForEach([0, cpus / 2, cpus], id: \.self) { v in
                RuleMark(y: .value("CPU", v)).foregroundStyle(Color.primary.opacity(0.06)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            // Waiting while CPUs sat idle: rose from the floor to the ceiling, under the stack, so
            // it shows wherever the stack is low and is never cut off by the stack's curves. From
            // the start of its first column to the end of its last, so a run of one column fills too.
            ForEach(Array(bad.enumerated()), id: \.offset) { _, run in
                RectangleMark(xStart: .value("Time", cols[run.lowerBound].from), xEnd: .value("Time", cols[run.upperBound].to),
                              yStart: .value("CPUs", 0), yEnd: .value("CPUs", cpus))
                    .foregroundStyle(LinearGradient(colors: [Alive.rose.opacity(0.55), Alive.rose.opacity(0.18)], startPoint: .top, endPoint: .bottom))
                RuleMark(xStart: .value("Time", cols[run.lowerBound].from), xEnd: .value("Time", cols[run.upperBound].to), y: .value("CPUs", cpus))
                    .foregroundStyle(Alive.rose).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            ForEach(layers, id: \.self) { p in
                ForEach(Array(cols.enumerated()), id: \.offset) { i, c in
                    let below = layers.prefix { $0 != p }.reduce(0.0) { $0 + value(c, $1) }
                    AreaMark(x: .value("Time", c.mid), yStart: .value("CPUs", below), yEnd: .value("CPUs", below + value(c, p)),
                             series: .value("Layer", p))
                        .foregroundStyle(p == "~outside" ? Alive.out : model.color(p))
                        .interpolationMethod(.monotone)
                }
            }
            // Depth: lit from above, shaded below.
            ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                AreaMark(x: .value("Time", c.mid), yStart: .value("CPUs", 0), yEnd: .value("CPUs", c.total), series: .value("Layer", "~depth"))
                    .foregroundStyle(LinearGradient(stops: [.init(color: .white.opacity(0.16), location: 0), .init(color: .white.opacity(0), location: 0.55),
                                                            .init(color: .black.opacity(0.10), location: 1)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            // The total: a soft line over it all.
            ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                LineMark(x: .value("Time", c.mid), y: .value("CPUs", c.total), series: .value("Edge", "~total"))
                    .foregroundStyle(Alive.ink.opacity(0.45)).lineStyle(StrokeStyle(lineWidth: 1.1, lineJoin: .round)).interpolationMethod(.monotone)
            }
            RuleMark(y: .value("CPUs", cpus)).foregroundStyle(Alive.ink3.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1))
            if let last = cols.last {
                PointMark(x: .value("Time", last.mid), y: .value("CPUs", last.total)).foregroundStyle(Alive.ink).symbolSize(26)
            }
            // Last of all, over everything else, a hairline in the card's color along each band's
            // top edge: a clean line between colors, drawn once, on top, not cut between them.
            ForEach(layers.dropLast(), id: \.self) { p in
                ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                    let top = layers.prefix { $0 != p }.reduce(0.0) { $0 + value(c, $1) } + value(c, p)
                    LineMark(x: .value("Time", c.mid), y: .value("CPUs", top), series: .value("Edge", "edge-" + p))
                        .foregroundStyle(Alive.card).lineStyle(StrokeStyle(lineWidth: 1)).interpolationMethod(.monotone)
                }
            }
            // The words go on last, over the stack and its lines.
            if let run = bad.max(by: { $0.count < $1.count }) {
                let mid = cols[(run.lowerBound + run.upperBound) / 2].mid
                let peak = run.map { cols[$0].waiting }.max() ?? 0
                let idle = run.map { cpus - cols[$0].total }.reduce(0, +) / Double(run.count)
                PointMark(x: .value("Time", mid), y: .value("CPUs", cpus * 0.78))
                    .opacity(0)
                    .annotation(position: .overlay, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 0) {
                            Text("\(peak) waiting").font(.system(size: 12, weight: .semibold))
                            Text("\(Int(idle.rounded())) CPUs idle").font(.system(size: 10.5)).opacity(0.85)
                        }
                        .fixedSize()
                        .halo()
                    }
            }
            ForEach(Array(quiet.enumerated()), id: \.offset) { _, run in
                PointMark(x: .value("Time", cols[(run.lowerBound + run.upperBound) / 2].mid), y: .value("CPUs", 1.2))
                    .opacity(0)
                    .annotation(position: .overlay, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text("quiet · nothing queued").font(.system(size: 11)).foregroundStyle(Alive.ink3).fixedSize().halo()
                    }
            }
            if let scrub { RuleMark(x: .value("Time", scrub)).foregroundStyle(Color.primary.opacity(0.5)) }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: xDomain, range: .plotDimension(padding: 0))
        .chartYScale(domain: 0...cpus)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartBackground { yLabels($0, [(0, "0"), (cpus / 2, "\(Int(cpus / 2))"), (cpus, "\(Int(cpus))")], font: .caption) }
        .chartOverlay { scrubber($0) }
        .padding(.leading, labelColumn)
        // The top and bottom labels, and "quiet · nothing queued", are centred on the plot's
        // edges: room for their other half, or the section's edge cuts them through.
        .padding(.vertical, 8)
    }

    private func value(_ c: HourCache.Column, _ layer: String) -> Double {
        layer == "~outside" ? c.outside : c.shares[layer] ?? 0
    }

    /// A lane per CPU, darker the busier: the performance cores on top, the efficiency cores
    /// under them; stretches of needless waiting shaded rose behind.
    private var cores: some View {
        let cols = hour.columns
        let n = cols.compactMap(\.perCPU).first?.count ?? Int(cpus)
        let p = min(model.performance?.count ?? 0, n)
        let e = n - p
        // Kernel order is efficiency first; shown performance first, from the top.
        let order = Array(e..<n) + Array(0..<e)
        let rowOf = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, Double(n - 1 - $0) + ($1 >= e && e > 0 ? 0.5 : 0)) })
        let top = Double(n) + (e > 0 && p > 0 ? 0.5 : 0)
        let bad = HourCache.runs(cols, \.needless)
        return Chart {
            ForEach(Array(bad.enumerated()), id: \.offset) { _, run in
                RectangleMark(xStart: .value("Time", cols[run.lowerBound].from), xEnd: .value("Time", cols[run.upperBound].to),
                              yStart: .value("CPU", 0), yEnd: .value("CPU", top))
                    .foregroundStyle(Alive.rose.opacity(0.14))
            }
            // The cells themselves are painted behind the plot (chartBackground): a mark per CPU
            // per column, 11,520 for a 96-CPU machine, made every redraw stutter.
            RuleMark(y: .value("CPU", 0)).foregroundStyle(.clear)
            if let scrub { RuleMark(x: .value("Time", scrub)).foregroundStyle(Color.primary.opacity(0.5)) }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: xDomain, range: .plotDimension(padding: 0))
        .chartYScale(domain: 0...top)
        .chartXAxis { xAxis }
        .chartYAxis(.hidden)
        .chartBackground { proxy in
            ZStack {
                heat(proxy, cols, rowOf: rowOf, top: top)
                yLabels(proxy, p > 0 ? [(top - Double(p) / 2, Text("\(p) ") + Text(Image(systemName: "bolt.fill"))),
                                        (Double(e) / 2, Text("\(e) ") + Text(Image(systemName: "leaf.fill")))] : [(top / 2, Text("CPU"))])
            }
        }
        .chartOverlay { scrubber($0) }
        .padding(.leading, labelColumn)
        .help(p > 0 ? "A row per CPU, darker the busier: the \(p) performance cores (bolt) on top, the \(e) efficiency cores (leaf) below." : "A row per CPU, darker the busier.")
    }

    /// Per Core's cells, a row per CPU, darker the busier, painted in one pass on the chart's own
    /// time scale, so they line up with its axis and the scrubber.
    private func heat(_ proxy: ChartProxy, _ cols: [HourCache.Column], rowOf: [Int: Double], top: Double) -> some View {
        GeometryReader { geo in
            if let frame = proxy.plotFrame {
                let plot = geo[frame]
                let rowHeight = plot.height / top
                let cells: [(CGRect, Double)] = cols.flatMap { c -> [(CGRect, Double)] in
                    guard let per = c.perCPU, let x0 = proxy.position(forX: c.from), let x1 = proxy.position(forX: c.to) else { return [] }
                    return per.enumerated().map { cpu, busy in
                        let r = rowOf[cpu] ?? 0
                        return (CGRect(x: plot.minX + x0, y: plot.minY + plot.height - (r + 0.9) * rowHeight,
                                       width: max(x1 - x0, 0.5), height: max(0.8 * rowHeight, 0.5)), busy)
                    }
                }
                Canvas { gc, _ in
                    for (rect, busy) in cells { gc.fill(Path(rect), with: .color(Color.primary.opacity(0.05 + 0.8 * busy))) }
                }
            }
        }
    }

    /// How many waited in each column: grey when the CPUs were full (fair), rose when they sat
    /// idle.
    private var waitStrip: some View {
        let cols = hour.columns
        return Chart {
            ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                if c.waiting > 0 {
                    RectangleMark(xStart: .value("Time", c.from), xEnd: .value("Time", c.to),
                                  yStart: .value("Jobs", 0), yEnd: .value("Jobs", Double(min(c.waiting, 9))))
                        .foregroundStyle(c.needless ? Alive.rose : Alive.ink3)
                }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: xDomain, range: .plotDimension(padding: 0))
        .chartYScale(domain: 0...9)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartBackground { yLabels($0, [(4.5, "wait")]) }
        .padding(.leading, labelColumn)
        .help("Jobs waiting: grey while the CPUs were full, a fair wait; rose while CPUs sat idle.")
    }

    private func scrubber(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    if SplitDrag.shared.active { scrub = nil; return }
                    switch phase {
                    case .active(let p):
                        guard let frame = proxy.plotFrame else { return }
                        let x = p.x - geo[frame].origin.x
                        if let d: Date = proxy.value(atX: x) { scrub = min(d, Date()) }
                    case .ended:
                        scrub = nil
                    }
                }
        }
    }
}

// MARK: - Jobs

private struct JobsScrollKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct JobsCard: View {
    let model: GraphModel
    private var cpus: Double { model.cpus }
    var control: ((String, Int, String) -> Void)?
    /// The list's visible height and how far it is scrolled: what's below the card's edge.
    @State private var listHeight: CGFloat = 0
    @State private var scrolled: CGFloat = 0
    private let rowHeight: CGFloat = 21

    var body: some View {
        let s = model.status
        let holders = (s?.holders ?? []).sorted { ($0.using ?? 0) > ($1.using ?? 0) }
        let waiters = s?.waiters ?? []
        let free = Moment.now(model).free
        let scale = max(4, holders.map { $0.using ?? 0 }.max() ?? 0).rounded(.up)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("JOBS").eyebrow()
                Text("· \(holders.count) running · \(waiters.count) waiting").font(.system(size: 13, weight: .medium)).foregroundStyle(Alive.ink)
                Spacer()
                ViewThatFits(in: .horizontal) {
                    Text("bar = how far a job is, when it says; else CPU used (0–\(Int(scale))) · CPU used of the cores reserved")
                    Text("bar = CPU used (0–\(Int(scale)))")
                    Color.clear.frame(width: 0, height: 0)
                }
                .font(.system(size: 11)).foregroundStyle(Alive.ink3).lineLimit(1)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(holders, id: \.pid) { h in running(h, scale: scale) }
                    ForEach(waiters, id: \.pid) { w in waiting(w, free: free) }
                    if holders.isEmpty && waiters.isEmpty {
                        Text("Nothing running or waiting.").foregroundStyle(Alive.ink2).frame(maxWidth: .infinity, alignment: .leading).frame(height: 21)
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: JobsScrollKey.self, value: -g.frame(in: .named("jobs")).minY)
                })
            }
            .coordinateSpace(name: "jobs")
            .onPreferenceChange(JobsScrollKey.self) { scrolled = $0 }
            .background(GeometryReader { g in
                Color.clear.onAppear { listHeight = g.size.height }.onChange(of: g.size.height) { _, h in listHeight = h }
            })
            // macOS hides an idle scroller, so rows past the card's edge say so: "4 running" with
            // three rows in sight looked like a job had gone missing.
            .overlay(alignment: .bottomTrailing) {
                let below = holders.count + waiters.count - Int(((listHeight + scrolled) / rowHeight).rounded(.down))
                if below > 0 {
                    Text("+\(below) more ↓").font(.system(size: 11, weight: .medium)).foregroundStyle(Alive.ink2)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Alive.glass)).overlay(Capsule().strokeBorder(Alive.glassEdge))
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .card()
    }

    private func running(_ h: Status.Holder, scale: Double) -> some View {
        let project = GraphModel.group(h.label, h.note)
        let use = h.using ?? 0
        // How far it is, when it says (DONE of TOTAL); else the bar is its CPU.
        let done: Double? = h.progress.flatMap { $0.total > 0 ? min(Double($0.done) / Double($0.total), 1) : nil }
        return HStack(spacing: 10) {
            Circle().fill(model.color(project)).frame(width: 8, height: 8)
            // The note after the label, quieter: "rig:corpus  #224 markers".
            (Text(GraphModel.label(h.label, h.command)).fontWeight(.medium).foregroundStyle(Alive.ink)
                + Text(h.note.isEmpty ? "" : "  \(h.note)").foregroundStyle(Alive.ink2))
                .lineLimit(1).truncationMode(.middle).frame(width: 230, alignment: .leading)
            HStack(spacing: 8) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Alive.track)
                        Capsule().fill(model.color(project)).frame(width: g.size.width * (done ?? min(use / scale, 1)))
                    }
                }
                .frame(maxWidth: 300).frame(height: 8)
                if h.paused {
                    Text("paused").foregroundStyle(.orange).frame(width: 52, alignment: .leading)
                } else if let done {
                    Text("\(Int((done * 100).rounded(.down)))%").fontWeight(.medium).foregroundStyle(Alive.ink).frame(width: 52, alignment: .leading)
                } else if h.using == nil {
                    Text("starting").foregroundStyle(Alive.ink2).frame(width: 52, alignment: .leading)
                } else {
                    Text(String(format: "%.1f", use)).fontWeight(.medium).foregroundStyle(Alive.ink).frame(width: 52, alignment: .leading)
                }
            }
            progressText(h).lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
            Text(h.exclusive ? "timing window" : h.using.map { String(format: "%.1f of %d", $0, h.cores) } ?? "\(h.cores) reserved").font(.system(size: 11.5))
                .foregroundStyle(h.exclusive ? Alive.windowTint : Alive.ink3).frame(width: 100, alignment: .trailing)
            Text(duration(Date().timeIntervalSince1970 - Double(h.since))).foregroundStyle(Alive.ink2).frame(width: 64, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 12)).monospacedDigit()
        .frame(height: 21)
        .contentShape(Rectangle())
        .contextMenu {
            if let control, supportsControls(version: model.status?.version ?? "") {
                let name = GraphModel.label(h.label, h.command)
                Button(h.paused ? "Resume \(name)" : "Pause \(name)") { control(h.paused ? "resume" : "pause", h.pid, name) }
                Button("Stop \(name)…") { control("stop", h.pid, name) }
            }
        }
    }

    private func waiting(_ w: Status.Waiter, free: Double) -> some View {
        let project = GraphModel.group(w.label, w.note)
        let name = GraphModel.label(w.label, w.command)
        let need = w.exclusive ? cpus : Double(max(w.cores, 1))
        let gate = model.status?.gate.state ?? "open"
        let window = Moment.now(model).window
        let needless = free >= max(2, need) && gate == "open" && window == nil
        let why = w.exclusive ? "timing window: waits for the Mac to empty" : window != nil ? "waits for the timing window" : gate != "open" ? "the gate is shut" : needless ? "CPUs idle" : free >= need ? "starting" : "\(String(format: "%.1f", free)) free, so it holds"
        return HStack(spacing: 10) {
            Circle().strokeBorder(model.color(project), lineWidth: 2).frame(width: 8, height: 8)
            (Text(name).fontWeight(.medium).foregroundStyle(Alive.ink)
                + Text(w.note.isEmpty ? "" : "  \(w.note)").foregroundStyle(Alive.ink2))
                .lineLimit(1).truncationMode(.middle).frame(width: 230, alignment: .leading)
            Text("waiting · asks \(GraphModel.wants(w)) · \(why)").foregroundStyle(needless ? Alive.rose : Alive.ink2)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(duration(Date().timeIntervalSince1970 - Double(w.since))).foregroundStyle(needless ? Alive.rose : Alive.ink2)
                .frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 12)).monospacedDigit()
        .frame(height: 21)
        .contentShape(Rectangle())
        .contextMenu { WaiterActions(pid: w.pid, label: name, model: model, control: control) }
    }
}

// MARK: - Style

/// The window's colors, light and dark, from the design.
enum Alive {
    static func color(_ light: UInt32, _ dark: UInt32, _ la: Double = 1, _ da: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let d = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = d ? dark : light
            return NSColor(srgbRed: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255, alpha: d ? da : la)
        })
    }
    /// A color of the theme in use, light or dark as the appearance asks.
    static func tone(_ value: @escaping (Theme.Tones) -> UInt32, alpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let theme = Theme.current
            let d = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return Theme.nsColor(value(d ? theme.dark : theme.light), alpha: alpha)
        })
    }
    /// The theme's color for palette slot `i`.
    static func slot(_ i: Int) -> Color { tone { $0.palette[i] } }
    static let window = tone(\.window)
    static let card = tone(\.card)
    static let cardEdge = color(0x000000, 0xffffff, 0.06, 0.06)
    static let ink = tone(\.ink)
    static let ink2 = tone(\.ink2)
    static let ink3 = tone(\.ink3)
    static let glass = color(0x141e3c, 0xffffff, 0.045, 0.045)
    static let glassEdge = color(0x141e3c, 0xffffff, 0.11, 0.11)
    static let track = color(0x000000, 0xffffff, 0.06, 0.08)
    static let rose = tone(\.rose)
    static let roseSoft = Color(nsColor: NSColor(name: nil) { appearance in
        let d = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return Theme.nsColor((d ? Theme.current.dark : Theme.current.light).rose, alpha: d ? 0.14 : 0.10)
    })
    static let out = tone(\.out)
    /// A timing window: calm, deliberate, not an alarm.
    static let windowTint = color(0x5856d6, 0x7d7aff)
}

extension View {
    /// A card: the window's raised surface.
    func card() -> some View {
        background(RoundedRectangle(cornerRadius: 12).fill(Alive.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Alive.cardEdge))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.05), radius: 9, y: 6)
    }
}

extension View {
    /// A soft rim in the card's color around text drawn over the chart, so it reads over any
    /// band or line beneath it, as a map's labels do.
    func halo() -> some View {
        shadow(color: Alive.card, radius: 0.6).shadow(color: Alive.card, radius: 0.6)
            .shadow(color: Alive.card, radius: 1.2).shadow(color: Alive.card, radius: 1.8)
    }
}

extension Text {
    /// A small capitalized label over a group.
    func eyebrow() -> some View {
        font(.system(size: 11, weight: .semibold)).tracking(0.66).foregroundStyle(Alive.ink2)
    }
}
