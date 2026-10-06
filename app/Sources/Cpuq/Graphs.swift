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
        let inUse: Int
        let active: Double
        let load: Double
        /// Cores in use per project (the label up to its first ':').
        let projects: [String: Int]
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
        let inUse: Double
        let active: Double
        let load: Double
        let projects: [String: Double]
    }

    struct ProjectPoint: Identifiable {
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
    private(set) var projects: [ProjectUse] = []
    private(set) var waits: [Wait] = []

    func add(_ s: Status, at now: Date = Date()) {
        var by: [String: Int] = [:]
        for h in s.holders { by[project(h.label), default: 0] += h.cores }
        let active = s.holders.reduce(0) { $0 + ($1.using ?? 0) }
        samples.append(Sample(at: now, budget: s.budget, inUse: s.held, active: active, load: s.load.first ?? 0, projects: by))
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
            var by: [String: Double] = [:]
            for s in group { for (k, v) in s.projects { by[k, default: 0] += Double(v) / n } }
            out.append(Point(
                at: Date(timeIntervalSince1970: group.reduce(0) { $0 + $1.at.timeIntervalSince1970 } / n),
                inUse: group.reduce(0) { $0 + Double($1.inUse) } / n,
                active: group.reduce(0) { $0 + $1.active } / n,
                load: group.reduce(0) { $0 + $1.load } / n,
                projects: by))
            i = j
        }
        return out
    }

    /// Every point's cores in use for every project seen in the window, 0
    /// where a project held nothing, so the stacked areas share every point
    /// and a project's band ends where it ended, rather than sloping to the
    /// next point that names it.
    static func projectSeries(_ points: [Point]) -> [ProjectPoint] {
        let names = Set(points.flatMap { $0.projects.keys }).sorted()
        return points.flatMap { p in names.map { ProjectPoint(project: $0, at: p.at, cores: p.projects[$0] ?? 0) } }
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

    private var live: some View {
        let points = model.points
        let span: ClosedRange<Date> = {
            guard let first = points.first?.at, let last = points.last?.at, first < last else { return Date().addingTimeInterval(-60)...Date() }
            return first...last
        }()
        return VStack(alignment: .leading, spacing: 16) {
            Text("Cores, the last hour").font(.headline)
            Chart {
                // Monotone curves: soft, yet never overshooting a point, so
                // they stay at 0 or above and peak where the data peaks.
                ForEach(points) { p in
                    AreaMark(x: .value("Time", p.at), y: .value("Cores", p.inUse))
                        .foregroundStyle(by: .value("Series", "in use"))
                        .interpolationMethod(.monotone)
                        .opacity(0.35)
                    LineMark(x: .value("Time", p.at), y: .value("Cores", p.active))
                        .foregroundStyle(by: .value("Series", "active"))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    LineMark(x: .value("Time", p.at), y: .value("Cores", p.load))
                        .foregroundStyle(by: .value("Series", "load"))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
                }
                if let last = model.samples.last {
                    RuleMark(y: .value("Budget", last.budget))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .trailing) { Text("budget \(last.budget)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .chartForegroundStyleScale(["in use": Color.teal, "active": Color.green, "load": Color.orange])
            .chartXScale(domain: span)
            .frame(minHeight: 200)

            Text("In use by project").font(.headline)
            Chart {
                ForEach(GraphModel.projectSeries(points)) { p in
                    AreaMark(x: .value("Time", p.at), y: .value("Cores", p.cores), stacking: .standard)
                        .foregroundStyle(by: .value("Project", p.project))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: span)
            .frame(minHeight: 160)
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
