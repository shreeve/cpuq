import Charts
import CpuqCore
import SwiftUI

/// What the activity window shows: the last hour of the queue, sampled with every poll, and
/// the jobs `cpuq history` remembers.
@Observable
final class GraphModel {
    struct Sample: Identifiable {
        var id: Date { at }
        let at: Date
        let budget: Int
        /// Cores held per project (the label up to its first ':').
        let held: [String: Int]
        /// CPU used by cpuq's jobs, in cores, measured.
        let used: Double
        /// CPU used by the busiest processes outside cpuq, in cores.
        let other: Double
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

    private(set) var samples: [Sample] = []
    private(set) var status: Status?
    private(set) var totals: [Totals] = []
    /// Each project's palette slot, assigned the first time it is seen and kept across launches,
    /// so a project's color never changes as others come and go.
    private var slots: [String: Int] = (UserDefaults.standard.dictionary(forKey: "projectColors") as? [String: Int]) ?? [:]

    func add(_ s: Status, at now: Date = Date()) {
        var held: [String: Int] = [:]
        for h in s.holders { held[Self.project(h.label), default: 0] += h.cores }
        for p in held.keys.sorted() where slots[p] == nil {
            slots[p] = slots.count
            UserDefaults.standard.set(slots, forKey: "projectColors")
        }
        status = s
        samples.append(Sample(
            at: now, budget: s.budget, held: held,
            used: s.holders.reduce(0) { $0 + ($1.using ?? 0) },
            other: s.outside.reduce(0) { $0 + $1.using },
            waiting: s.waiters.count))
        samples.removeAll { now.timeIntervalSince($0.at) > Self.keep }
    }

    func setHistory(_ jobs: [Job]) {
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

    func color(_ project: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .red, .teal, .yellow, .brown, .indigo, .pink, .mint, .cyan]
        return palette[(slots[project] ?? 0) % palette.count]
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
        (status?.waiters ?? []).map { w in
            Waiting(id: w.order, label: w.label.isEmpty ? w.command : w.label,
                    cores: w.exclusive ? "every core" : (w.max > w.cores ? "\(w.cores)–\(w.max) cores" : "\(w.cores) cores"),
                    since: w.since)
        }
    }

    static func project(_ label: String) -> String {
        label.isEmpty ? "unlabelled" : String(label.split(separator: ":", maxSplits: 1).first ?? "")
    }
}

/// The time axis: an hour, with the recent past wide on the right and the older past narrow on
/// the left. A moment `age` seconds ago sits at -√age, so the last minute takes an eighth of
/// the width and the last 15 minutes half.
enum TimeAxis {
    static func x(_ age: TimeInterval) -> Double { -max(age, 0).squareRoot() }
    static func age(_ x: Double) -> TimeInterval { x * x }
    static let start = x(GraphModel.keep)
    static let ticks: [(age: TimeInterval, label: String)] = [(3600, "1h ago"), (1800, "30m"), (900, "15m"), (300, "5m"), (60, "1m"), (0, "now")]
}

struct GraphsView: View {
    let model: GraphModel
    @State private var tab = 0
    @State private var hover: Double?

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

    private var now: some View {
        let end = model.samples.last?.at ?? Date()
        let samples = model.samples
        let budget = Double(max(model.status?.budget ?? 0, 1))
        let names = Set(samples.flatMap { $0.held.keys }).sorted()
        let top = max(budget, samples.map { Double($0.held.values.reduce(0, +)) }.max() ?? 0, samples.map(\.used).max() ?? 0) + 1
        let x = { (d: Date) in TimeAxis.x(end.timeIntervalSince(d)) }
        let spans = Self.spans(samples, end: end)
        let pointed = hover.map { h in end.addingTimeInterval(-TimeAxis.age(h)) }
            .flatMap { at in samples.min { abs($0.at.timeIntervalSince(at)) < abs($1.at.timeIntervalSince(at)) } }
        return VStack(alignment: .leading, spacing: 12) {
            summary(pointed, end: end)
            Chart {
                // Cores held: steps, as cores are handed out whole.
                ForEach(spans) { s in
                    ForEach(names, id: \.self) { name in
                        AreaMark(x: .value("Time", x(s.from)), y: .value("Cores", s.held[name] ?? 0), stacking: .standard)
                            .foregroundStyle(by: .value("Project", name))
                            .interpolationMethod(.stepEnd)
                    }
                }
                RuleMark(y: .value("Cores", budget))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) { Text("budget \(Int(budget))").font(.caption).foregroundStyle(.secondary) }
                // Someone waiting: a red bar just above the budget line.
                ForEach(Self.waits(samples, end: end), id: \.0) { from, to in
                    RectangleMark(xStart: .value("Time", x(from)), xEnd: .value("Time", x(to)),
                                  yStart: .value("Cores", budget + 0.25), yEnd: .value("Cores", budget + 0.55))
                        .foregroundStyle(.red.opacity(0.8))
                }
                // CPU used: measured, so lines, averaged over spans as wide on screen as each other.
                ForEach(spans) { p in
                    LineMark(x: .value("Time", x(p.at)), y: .value("Cores", p.used), series: .value("Line", "used"))
                        .foregroundStyle(Color.primary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    LineMark(x: .value("Time", x(p.at)), y: .value("Cores", p.other), series: .value("Line", "other"))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 3]))
                }
                if let hover {
                    RuleMark(x: .value("Time", hover)).foregroundStyle(.secondary.opacity(0.6))
                }
            }
            .chartForegroundStyleScale(domain: names, range: names.map(model.color))
            .chartLegend(.hidden)
            .chartXScale(domain: TimeAxis.start...0)
            .chartXAxis {
                AxisMarks(values: TimeAxis.ticks.map { TimeAxis.x($0.age) }) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = v.as(Double.self), let t = TimeAxis.ticks.first(where: { abs(TimeAxis.x($0.age) - d) < 0.01 }) { Text(t.label) }
                    }
                }
            }
            .chartYScale(domain: 0...top)
            .chartYAxisLabel("cores")
            .chartXSelection(value: $hover)
            .frame(minHeight: 220)
            key
            table
        }
    }

    /// One line on what the machine is doing now, or at the moment under the pointer.
    private func summary(_ at: GraphModel.Sample?, end: Date) -> some View {
        let s = model.status
        let held = at.map { $0.held.values.reduce(0, +) } ?? s?.held ?? 0
        let budget = at?.budget ?? s?.budget ?? 0
        let used = at?.used ?? s?.holders.reduce(0) { $0 + ($1.using ?? 0) } ?? 0
        let waiting = at?.waiting ?? s?.waiters.count ?? 0
        var line = Text(at.map { age(end.timeIntervalSince($0.at)) + " ago   " } ?? "")
        line = line + Text("\(held) of \(budget) cores in use").bold()
        line = line + Text(String(format: " · %.1f active", used))
        line = line + Text(" · \(waiting) waiting").foregroundColor(waiting > 0 ? .red : nil)
        if at == nil, let load = s?.load.first { line = line + Text(String(format: " · load %.1f", load)).foregroundColor(.secondary) }
        return line.font(.title3).monospacedDigit()
    }

    private var key: some View {
        HStack(spacing: 16) {
            Label { Text("cores in use, by project") } icon: { RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.5)).frame(width: 14, height: 9) }
            Label { Text("cores active in cpuq's jobs") } icon: { Rectangle().fill(Color.primary).frame(width: 14, height: 1.5) }
            Label { Text("active outside cpuq") } icon: { Rectangle().fill(Color.secondary).frame(width: 14, height: 1.5) }
            Label { Text("waiting") } icon: { Rectangle().fill(.red.opacity(0.8)).frame(width: 14, height: 4) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Who holds what now, and who waits: the legend and the numbers in one.
    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("Project")
                Text("In use").gridColumnAlignment(.trailing)
                Text("Active").gridColumnAlignment(.trailing)
                Text("Share").gridColumnAlignment(.trailing)
            }
            .font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(model.rows) { r in
                GridRow {
                    HStack(spacing: 6) { Circle().fill(model.color(r.project)).frame(width: 8, height: 8); Text(r.project) }
                    Text("\(r.held)")
                    Text(String(format: "%.1f", r.used))
                    Text(r.held > 0 ? "\(Int((r.used / Double(r.held) * 100).rounded()))%" : "–")
                        .foregroundStyle(r.used * 2 < Double(r.held) ? Color.orange : Color.secondary)
                }
            }
            ForEach(model.waiting) { w in
                GridRow {
                    HStack(spacing: 6) { Circle().strokeBorder(.red, lineWidth: 1.5).frame(width: 8, height: 8); Text(w.label) }
                    Text("waiting \(age(Date().timeIntervalSince1970 - Double(w.since))) for \(w.cores)")
                        .foregroundStyle(.red).gridCellColumns(3)
                }
            }
            if model.rows.isEmpty && model.waiting.isEmpty {
                GridRow { Text("Nothing running or waiting.").foregroundStyle(.secondary).gridCellColumns(4) }
            }
        }
        .font(.callout)
        .monospacedDigit()
    }

    /// The spans in which someone waited.
    static func waits(_ s: [GraphModel.Sample], end: Date) -> [(Date, Date)] {
        var out: [(Date, Date)] = []
        var from: Date?
        for (i, x) in s.enumerated() {
            if x.waiting > 0, from == nil { from = x.at }
            if x.waiting == 0, let f = from { out.append((f, x.at)); from = nil }
            if i == s.count - 1, let f = from { out.append((f, end)) }
        }
        return out
    }

    /// The samples averaged over spans about √age seconds wide: one sample (3 s) near now, a
    /// minute an hour ago, so each span takes about as much of the axis as the next. Near now a
    /// span's cores held are the whole numbers handed out; further back, a busy stretch of short
    /// jobs averages into one block rather than a sliver per job. The last span is repeated at
    /// `end`, so the steps reach the right edge.
    struct Span: Identifiable {
        var id: Date { from }
        let from: Date
        /// The mean time of its samples, where its measured values are drawn.
        let at: Date
        let held: [String: Double]
        let used: Double
        let other: Double
    }

    static func spans(_ s: [GraphModel.Sample], end: Date) -> [Span] {
        var out: [Span] = []
        var group: [GraphModel.Sample] = []
        func flush() {
            guard let first = group.first else { return }
            let n = Double(group.count)
            var held: [String: Double] = [:]
            for x in group { for (k, v) in x.held { held[k, default: 0] += Double(v) / n } }
            out.append(Span(from: first.at, at: Date(timeIntervalSince1970: group.reduce(0) { $0 + $1.at.timeIntervalSince1970 } / n),
                            held: held, used: group.reduce(0) { $0 + $1.used } / n, other: group.reduce(0) { $0 + $1.other } / n))
            group = []
        }
        // From the oldest: a span closes once it is as long as the square root of its age.
        for x in s {
            if let first = group.first, x.at.timeIntervalSince(first.at) >= max(end.timeIntervalSince(first.at).squareRoot(), 3) { flush() }
            group.append(x)
        }
        flush()
        if let last = out.last, last.from < end {
            out.append(Span(from: end, at: end, held: last.held, used: last.used, other: last.other))
        }
        return out
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
