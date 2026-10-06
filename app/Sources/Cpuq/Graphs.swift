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

    struct Wait: Identifiable {
        let id = UUID()
        let label: String
        let ended: Date
        let waited: Double
    }

    /// An hour at one sample per poll.
    static let keep: TimeInterval = 3600

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
        VStack(alignment: .leading, spacing: 16) {
            Text("Cores, the last hour").font(.headline)
            Chart {
                ForEach(model.samples) { s in
                    AreaMark(x: .value("Time", s.at), y: .value("Cores", s.inUse))
                        .foregroundStyle(by: .value("Series", "in use"))
                        .opacity(0.35)
                    LineMark(x: .value("Time", s.at), y: .value("Cores", s.active))
                        .foregroundStyle(by: .value("Series", "active"))
                    LineMark(x: .value("Time", s.at), y: .value("Cores", s.load))
                        .foregroundStyle(by: .value("Series", "load"))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if let last = model.samples.last {
                    RuleMark(y: .value("Budget", last.budget))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .trailing) { Text("budget \(last.budget)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .chartForegroundStyleScale(["in use": Color.teal, "active": Color.green, "load": Color.orange])
            .frame(minHeight: 200)

            Text("In use by project").font(.headline)
            Chart {
                ForEach(model.samples) { s in
                    ForEach(s.projects.sorted(by: { $0.key < $1.key }), id: \.key) { project, cores in
                        AreaMark(x: .value("Time", s.at), y: .value("Cores", cores), stacking: .standard)
                            .foregroundStyle(by: .value("Project", project))
                    }
                }
            }
            .frame(minHeight: 160)
            if model.samples.isEmpty {
                Text("Samples appear every 3 seconds while Cpuq runs.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Active of in use, per project (average per job)").font(.headline)
            Chart {
                ForEach(model.projects) { p in
                    BarMark(x: .value("Cores", p.inUse), y: .value("Project", p.project))
                        .foregroundStyle(Color.teal.opacity(0.35))
                    BarMark(x: .value("Cores", p.active), y: .value("Project", p.project))
                        .foregroundStyle(p.active * 2 < p.inUse ? Color.yellow : Color.green)
                        .annotation(position: .trailing) {
                            Text(String(format: "%.1f of %.1f · %d jobs", p.active, p.inUse, p.jobs)).font(.caption).foregroundStyle(.secondary)
                        }
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
