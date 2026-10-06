import Charts
import CpuqCore
import SwiftUI

/// What the graphs window draws: the last hour of the queue, sampled with every poll, and the
/// jobs `cpuq history` remembers.
@Observable
final class GraphModel {
    struct Sample: Identifiable {
        let id = UUID()
        let at: Date
        let budget: Int
        let load: Double
        /// Per project (the label up to its first ':'): cores in use, and cores active.
        let inUse: [String: Int]
        let active: [String: Double]
    }

    struct ProjectUse: Identifiable {
        var id: String { project }
        let project: String
        let inUse: Double
        let active: Double
        let jobs: Int
    }

    /// The samples of one bucket, averaged: what the live charts draw.
    struct Point: Identifiable {
        var id: Date { at }
        let at: Date
        let load: Double
        let inUse: [String: Double]
        let active: [String: Double]
    }

    /// One project's slice of the stack at one point: from `low` to `high`
    /// cores, with `busy` its cores active per core in use (1 when they
    /// match, more when it runs more threads than it was given).
    struct Slice: Identifiable {
        var id: String { "\(project) \(at.timeIntervalSince1970)" }
        let project: String
        let at: Date
        let low: Double
        let high: Double
        let busy: Double?
    }

    /// One project's cores at one point, for a stacked chart.
    struct Band: Identifiable {
        var id: String { "\(project) \(at.timeIntervalSince1970)" }
        let project: String
        let at: Date
        let cores: Double
    }

    struct Wait: Identifiable {
        let id = UUID()
        let label: String
        let ended: Date
        let waited: Double
    }

    /// An hour at one sample per poll.
    static let keep: TimeInterval = 3600
    /// The live charts average the samples over this long: an hour in 120
    /// points, so a brief job or a one-poll spike blends into its
    /// neighbours instead of drawing a spike of its own.
    static let bucket: TimeInterval = 30

    private(set) var samples: [Sample] = []
    private(set) var budget = 0
    private(set) var projects: [ProjectUse] = []
    private(set) var waits: [Wait] = []

    func add(_ s: Status, at now: Date = Date()) {
        var inUse: [String: Int] = [:]
        var active: [String: Double] = [:]
        for h in s.holders {
            inUse[project(h.label), default: 0] += h.cores
            active[project(h.label), default: 0] += h.using ?? 0
        }
        budget = s.budget
        samples.append(Sample(at: now, budget: s.budget, load: s.load.first ?? 0, inUse: inUse, active: active))
        samples.removeAll { now.timeIntervalSince($0.at) > Self.keep }
    }

    func setHistory(_ jobs: [Job]) {
        var sums: [String: (inUse: Double, active: Double, n: Int)] = [:]
        for j in jobs where j.state == "done" && j.pool == "cores" {
            guard let cores = j.cores, let used = j.used else { continue }
            let key = project(j.label)
            var e = sums[key] ?? (0, 0, 0)
            e.inUse += Double(cores)
            e.active += used
            e.n += 1
            sums[key] = e
        }
        projects = sums.map { ProjectUse(project: $0.key, inUse: $0.value.inUse / Double($0.value.n), active: $0.value.active / Double($0.value.n), jobs: $0.value.n) }
            .sorted { $0.project < $1.project }
        waits = jobs.compactMap { j in
            guard let w = j.waited, let end = j.ended ?? j.started else { return nil }
            return Wait(label: j.label.isEmpty ? "-" : j.label, ended: Date(timeIntervalSince1970: end), waited: w)
        }.suffix(60)
    }

    /// The samples averaged per `bucket`, each point at its samples' mean
    /// time, so the newest one is never ahead of now.
    var points: [Point] {
        var out: [Point] = []
        var i = 0
        while i < samples.count {
            let key = (samples[i].at.timeIntervalSince1970 / Self.bucket).rounded(.down)
            var j = i
            while j < samples.count && (samples[j].at.timeIntervalSince1970 / Self.bucket).rounded(.down) == key { j += 1 }
            let group = samples[i..<j]
            let n = Double(group.count)
            var inUse: [String: Double] = [:]
            var active: [String: Double] = [:]
            for s in group {
                for (k, v) in s.inUse { inUse[k, default: 0] += Double(v) / n }
                for (k, v) in s.active { active[k, default: 0] += v / n }
            }
            out.append(Point(
                at: Date(timeIntervalSince1970: group.reduce(0) { $0 + $1.at.timeIntervalSince1970 } / n),
                load: group.reduce(0) { $0 + $1.load } / n,
                inUse: inUse, active: active))
            i = j
        }
        return out
    }

    /// Every project seen in these points, in the order the charts stack and color them.
    static func names(_ points: [Point]) -> [String] {
        Set(points.flatMap { $0.inUse.keys }).sorted()
    }

    /// Every point's cores for every project, 0 where a project had none, so
    /// the stacked areas share every point and a project's band ends where
    /// it ended rather than sloping to the next point that names it.
    static func bands(_ points: [Point], _ names: [String], _ value: (Point) -> [String: Double]) -> [Band] {
        points.flatMap { p in names.map { Band(project: $0, at: p.at, cores: value(p)[$0] ?? 0) } }
    }

    /// The cores in use stacked by hand, project on project in `names`
    /// order, so each project's band can carry a style of its own.
    static func slices(_ points: [Point], _ names: [String]) -> [Slice] {
        points.flatMap { p -> [Slice] in
            var low = 0.0
            return names.map { n in
                let cores = p.inUse[n] ?? 0
                defer { low += cores }
                return Slice(project: n, at: p.at, low: low, high: low + cores, busy: cores >= 0.05 ? (p.active[n] ?? 0) / cores : nil)
            }
        }
    }

    private func project(_ label: String) -> String {
        label.isEmpty ? "unlabelled" : String(label.split(separator: ":", maxSplits: 1).first ?? "")
    }
}

struct GraphsView: View {
    let model: GraphModel
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                Text("Live").tag(0)
                Text("History").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            if tab == 0 { live } else { history }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 520)
    }

    // MARK: Live

    /// The projects' colors, and what the shades of a band in use mean.
    private func legend(_ names: [String]) -> some View {
        let colors = Self.colors(names.count)
        return HStack(spacing: 12) {
            ForEach(Array(names.enumerated()), id: \.element) { i, name in
                HStack(spacing: 4) {
                    Circle().fill(colors[i]).frame(width: 8, height: 8)
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !names.isEmpty {
                Text("lighter: less active than its cores · darker: more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A project's band in use, shaded along time by how busy its cores are:
    /// its color where cores active match cores in use, lighter toward idle,
    /// darker toward twice as busy. The gradient runs across the band's
    /// extent, which is the whole span, since every point has a slice.
    static func shading(_ slices: [GraphModel.Slice], base: Color, span: ClosedRange<Date>) -> LinearGradient {
        let width = span.upperBound.timeIntervalSince(span.lowerBound)
        let stops: [Gradient.Stop] = slices.compactMap { sl in
            guard let busy = sl.busy, width > 0 else { return nil }
            return .init(color: shade(base, busy), location: sl.at.timeIntervalSince(span.lowerBound) / width)
        }
        return LinearGradient(stops: stops.isEmpty ? [.init(color: base, location: 0)] : stops, startPoint: .leading, endPoint: .trailing)
    }

    static func shade(_ base: Color, _ busy: Double) -> Color {
        let c = NSColor(base).usingColorSpace(.sRGB) ?? .gray
        if busy < 1 { return Color(nsColor: c.blended(withFraction: 0.65 * (1 - max(busy, 0)), of: .white) ?? c) }
        return Color(nsColor: c.blended(withFraction: 0.5 * min(busy - 1, 1), of: .black) ?? c)
    }

    /// Distinct colors for the projects, in order, repeating only past a dozen.
    static func colors(_ n: Int) -> [Color] {
        let palette: [Color] = [.blue, .orange, .green, .purple, .red, .teal, .yellow, .brown, .indigo, .pink, .mint, .gray]
        return (0..<max(n, 1)).map { palette[$0 % palette.count] }
    }

    /// Two charts, each a stack of one band per project in the same colors: the cores cpuq has
    /// handed out against the budget, and the cores those jobs keep busy with the machine's load
    /// over them. Monotone curves are soft yet never overshoot a point, so a band stays at 0 or
    /// above and peaks where the data peaks.
    private var live: some View {
        let points = model.points
        let names = GraphModel.names(points)
        let span: ClosedRange<Date> = {
            guard let first = points.first?.at, let last = points.last?.at, first < last else { return Date().addingTimeInterval(-60)...Date() }
            return first...last
        }()
        let top = Double(max(model.budget, 1))
        let loadTop = points.map(\.load).max() ?? 0
        let slices = GraphModel.slices(points, names)
        return VStack(alignment: .leading, spacing: 16) {
            Text("Cores in use, by project").font(.headline)
            Chart {
                ForEach(Array(names.enumerated()), id: \.element) { i, name in
                    let mine = slices.filter { $0.project == name }
                    ForEach(mine) { sl in
                        AreaMark(x: .value("Time", sl.at), yStart: .value("Cores", sl.low), yEnd: .value("Cores", sl.high), series: .value("Project", name))
                            .foregroundStyle(Self.shading(mine, base: Self.colors(names.count)[i], span: span))
                            .interpolationMethod(.monotone)
                    }
                }
                RuleMark(y: .value("Budget", top))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) { Text("budget \(model.budget)").font(.caption).foregroundStyle(.secondary) }
            }
            .chartXScale(domain: span)
            .chartYScale(domain: 0...top + 1)
            .frame(minHeight: 170)
            legend(names)

            Text("Cores active, by project").font(.headline)
            Chart {
                ForEach(GraphModel.bands(points, names, \.active)) { b in
                    AreaMark(x: .value("Time", b.at), y: .value("Cores", b.cores), stacking: .standard)
                        .foregroundStyle(by: .value("Project", b.project))
                        .interpolationMethod(.monotone)
                }
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.at), y: .value("Cores", p.load), series: .value("Series", "load"))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
                }
                if let last = points.last {
                    PointMark(x: .value("Time", last.at), y: .value("Cores", last.load))
                        .opacity(0)
                        .annotation(position: .top, alignment: .trailing) { Text("load").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .chartForegroundStyleScale(domain: names, range: Self.colors(names.count))
            .chartXScale(domain: span)
            .chartYScale(domain: 0...max(top, loadTop) + 1)
            .chartLegend(.hidden)
            .frame(minHeight: 170)
            if model.samples.isEmpty {
                Text("Samples appear every 3 seconds while Cpuq runs; the charts average them over 30 seconds.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Active of in use, per project (average per job)").font(.headline)
            Chart {
                ForEach(model.projects) { p in
                    // Active drawn over in use, both from 0: overlaid, not stacked.
                    BarMark(xStart: .value("Cores", 0), xEnd: .value("Cores", p.inUse), y: .value("Project", p.project), height: .ratio(0.6))
                        .foregroundStyle(Color.teal.opacity(0.35))
                        .annotation(position: .trailing) {
                            Text(String(format: "%.1f of %.1f · %d %@", p.active, p.inUse, p.jobs, p.jobs == 1 ? "job" : "jobs")).font(.caption).foregroundStyle(.secondary)
                        }
                    BarMark(xStart: .value("Cores", 0), xEnd: .value("Cores", p.active), y: .value("Project", p.project), height: .ratio(0.6))
                        .foregroundStyle(p.active * 2 < p.inUse ? Color.yellow : Color.green)
                }
            }
            .frame(minHeight: 160)

            Text("Waits, the latest jobs").font(.headline)
            Chart {
                ForEach(model.waits) { w in
                    BarMark(x: .value("Ended", w.ended), y: .value("Seconds", w.waited))
                        .foregroundStyle(by: .value("Label", w.label))
                }
            }
            .chartLegend(.hidden)
            .frame(minHeight: 160)
            if model.projects.isEmpty && model.waits.isEmpty {
                Text("cpuq history has no finished jobs yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
