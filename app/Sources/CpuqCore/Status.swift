import Foundation

/// `cpuq status --json`, schema 1. Every field has a default, so a cpuq that
/// leaves one out still decodes.
public struct Status: Decodable, Sendable, Equatable {
    public var schema = 1
    public var version = ""
    public var budget = 0
    public var held = 0
    public var free = 0
    public var load: [Double] = [0, 0, 0]
    public var memoryPressure = ""
    /// How cpuq admits jobs: "measured" (by the CPU they use, up to `target` CPUs) or "cores" (by
    /// the cores they hold, up to `budget`).
    public var admit = ""
    public var target: Double?
    /// The CPUs online (`active_cores`).
    public var activeCores = 0
    /// Each CPU's time so far, `[busy, total]`, cumulative (`cpu_ticks`):
    /// another machine's CPUs, drawn from the difference between two statuses.
    public var cpuTicks: [[UInt64]]?
    /// When the machine booted, Unix seconds (`boot_time`): how long a cloud
    /// machine has been up.
    public var bootTime: Double?
    /// Memory and swap in bytes: `used` is Activity Monitor's Memory Used on
    /// macOS, the total less MemAvailable on Linux.
    public var memory: Memory?
    public var gate = Gate()
    public var holders: [Holder] = []
    public var waiters: [Waiter] = []
    public var leases: [Lease] = []
    public var outside: [Outside] = []
    /// CPUs busy outside every cpuq job, in all.
    public var outsideTotal: Double?

    public struct Gate: Decodable, Sendable, Equatable {
        /// open, pressure, low_memory, low_disk, load or spacing.
        public var state = "open"
        public var load: Double?
        public var text = "open"
        /// The load valve's thresholds (with the load check on): it trips
        /// above `trip` while the CPUs are at least `busyTrip` busy, and reopens at `reopen`.
        public var trip: Double?
        public var reopen: Double?
        public var busyTrip: Double?
    }

    public struct Holder: Decodable, Sendable, Equatable {
        public var pid = 0
        public var cores = 0
        /// Which of the budget's cores it holds, by number from 0.
        public var slots: [Int] = []
        /// Paused by hand.
        public var paused = false
        public var using: Double?
        public var priority = ""
        public var exclusive = false
        /// Its work runs where cpuq can't see it (`--opaque`: a container, a VM).
        public var opaque = false
        public var label = ""
        /// What the job is for (`--note`): shown beside the label, a band of its own in the charts.
        public var note = ""
        public var command = ""
        public var since = 0
        /// How far it is, as it reports through `CPUQ_PROGRESS`.
        public var progress: Progress?
        /// Seconds left: from its progress, or else from its label's usual time.
        public var left: Double?
        /// Where `left` comes from: "progress" or "history".
        public var leftFrom = ""
        /// Its label's usual run time, in seconds, from history.
        public var typical: Double?
    }

    /// A job's own count: `DONE TOTAL FAILING`.
    public struct Progress: Decodable, Sendable, Equatable {
        public var done = 0
        public var total = 0
        public var failing = 0
    }

    public struct Waiter: Decodable, Sendable, Equatable {
        public var order = 0
        public var pid = 0
        public var cores = 0
        public var max = 0
        public var exclusive = false
        public var label = ""
        /// What the job is for (`--note`): shown beside the label, a band of its own in the charts.
        public var note = ""
        public var command = ""
        public var since = 0
        public var eta: Double?
    }

    public struct Lease: Decodable, Sendable, Equatable {
        public var name = ""
        public var holders: [Holder] = []
        public var waiters: [Waiter] = []
    }

    public struct Outside: Decodable, Sendable, Equatable {
        public var pid = 0
        public var name = ""
        public var using = 0.0
        /// Its command line and working directory: who started it.
        public var command: String?
        public var cwd: String?

        /// "python3 -I model.py 4 p2on": the program's own name, not its path, then its arguments.
        public var shortCommand: String {
            guard let c = command, !c.isEmpty else { return name }
            let first = c.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let prog = first.first.map { ($0 as Substring).split(separator: "/").last.map(String.init) ?? String($0) } ?? name
            return first.count > 1 ? prog + " " + first[1] : prog
        }
    }

    public init() {}

    public static func decode(_ data: Data) throws -> Status {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Status.self, from: data)
    }
}

extension Status {
    public struct Memory: Decodable, Sendable, Equatable {
        public var total: UInt64
        public var used: UInt64
        public var swapTotal: UInt64
        public var swapUsed: UInt64

        public init(total: UInt64, used: UInt64, swapTotal: UInt64, swapUsed: UInt64) {
            self.total = total
            self.used = used
            self.swapTotal = swapTotal
            self.swapUsed = swapUsed
        }

        /// "97 of 128 GB": a decimal when the total is below 10 GB ("1.3 of 2.0 GB").
        public static func ofGB(_ used: UInt64, _ total: UInt64) -> String {
            let u = Double(used) / 1_073_741_824, t = Double(total) / 1_073_741_824
            return t < 9.95 ? String(format: "%.1f of %.1f GB", u, t) : String(format: "%.0f of %.0f GB", u, t)
        }
    }
}

// Decoding with defaults: a missing key keeps the property's default.
extension Status {
    private enum Keys: String, CodingKey {
        case schema, version, budget, held, free, load, memoryPressure, gate, holders, waiters, leases, outside, outsideTotal, admit, target, activeCores, cpuTicks, bootTime, memory
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        budget = try c.decodeIfPresent(Int.self, forKey: .budget) ?? 0
        held = try c.decodeIfPresent(Int.self, forKey: .held) ?? 0
        free = try c.decodeIfPresent(Int.self, forKey: .free) ?? 0
        load = try c.decodeIfPresent([Double].self, forKey: .load) ?? [0, 0, 0]
        memoryPressure = try c.decodeIfPresent(String.self, forKey: .memoryPressure) ?? ""
        admit = try c.decodeIfPresent(String.self, forKey: .admit) ?? ""
        target = try c.decodeIfPresent(Double.self, forKey: .target)
        activeCores = try c.decodeIfPresent(Int.self, forKey: .activeCores) ?? 0
        cpuTicks = try c.decodeIfPresent([[UInt64]].self, forKey: .cpuTicks)
        bootTime = try c.decodeIfPresent(Double.self, forKey: .bootTime)
        memory = try c.decodeIfPresent(Memory.self, forKey: .memory)
        gate = try c.decodeIfPresent(Gate.self, forKey: .gate) ?? Gate()
        holders = try c.decodeIfPresent([Holder].self, forKey: .holders) ?? []
        waiters = try c.decodeIfPresent([Waiter].self, forKey: .waiters) ?? []
        leases = try c.decodeIfPresent([Lease].self, forKey: .leases) ?? []
        outside = try c.decodeIfPresent([Outside].self, forKey: .outside) ?? []
        outsideTotal = try c.decodeIfPresent(Double.self, forKey: .outsideTotal)
    }
}

extension Status.Gate {
    private enum Keys: String, CodingKey { case state, load, text, trip, reopen, busyTrip }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "open"
        load = try c.decodeIfPresent(Double.self, forKey: .load)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? state
        trip = try c.decodeIfPresent(Double.self, forKey: .trip)
        reopen = try c.decodeIfPresent(Double.self, forKey: .reopen)
        busyTrip = try c.decodeIfPresent(Double.self, forKey: .busyTrip)
    }
}

extension Status.Holder {
    private enum Keys: String, CodingKey { case pid, cores, slots, paused, using, priority, exclusive, opaque, label, note, command, since, progress, left, typical, leftFrom }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        cores = try c.decodeIfPresent(Int.self, forKey: .cores) ?? 0
        slots = try c.decodeIfPresent([Int].self, forKey: .slots) ?? []
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        using = try c.decodeIfPresent(Double.self, forKey: .using)
        priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? ""
        exclusive = try c.decodeIfPresent(Bool.self, forKey: .exclusive) ?? false
        opaque = try c.decodeIfPresent(Bool.self, forKey: .opaque) ?? false
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        since = try c.decodeIfPresent(Int.self, forKey: .since) ?? 0
        progress = try? c.decodeIfPresent(Status.Progress.self, forKey: .progress)
        left = try c.decodeIfPresent(Double.self, forKey: .left)
        leftFrom = try c.decodeIfPresent(String.self, forKey: .leftFrom) ?? ""
        typical = try c.decodeIfPresent(Double.self, forKey: .typical)
    }
}

extension Status.Waiter {
    private enum Keys: String, CodingKey { case order, pid, cores, max, exclusive, label, note, command, since, eta }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        cores = try c.decodeIfPresent(Int.self, forKey: .cores) ?? 0
        max = try c.decodeIfPresent(Int.self, forKey: .max) ?? cores
        exclusive = try c.decodeIfPresent(Bool.self, forKey: .exclusive) ?? false
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        since = try c.decodeIfPresent(Int.self, forKey: .since) ?? 0
        eta = try c.decodeIfPresent(Double.self, forKey: .eta)
    }
}

extension Status.Lease {
    private enum Keys: String, CodingKey { case name, holders, waiters }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        holders = try c.decodeIfPresent([Status.Holder].self, forKey: .holders) ?? []
        waiters = try c.decodeIfPresent([Status.Waiter].self, forKey: .waiters) ?? []
    }
}

extension Status.Outside {
    private enum Keys: String, CodingKey { case pid, name, using, command, cwd }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        using = try c.decodeIfPresent(Double.self, forKey: .using) ?? 0
        command = try c.decodeIfPresent(String.self, forKey: .command)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
    }
}

extension Status {
    /// Its CPU readings as CPUTicks: the machine's in all, and each CPU's; nil when cpuq gave none.
    public var ticks: (all: CPUTicks, each: [CPUTicks])? {
        guard let t = cpuTicks, !t.isEmpty, t.allSatisfy({ $0.count == 2 }) else { return nil }
        let each = t.map { CPUTicks(busy: $0[0], total: $0[1]) }
        return (CPUTicks(busy: each.reduce(0) { $0 + $1.busy }, total: each.reduce(0) { $0 + $1.total }), each)
    }

    /// The cores to count use against: under measured admission the CPUs online,
    /// since `budget` there is only an exclusive run's size and can exceed them
    /// (a Mac with 10 CPUs and `budget = 14`); under `admit = cores`, the budget.
    public var capacity: Int {
        admit == "measured" && activeCores > 0 ? activeCores : budget
    }
}

/// The menu-bar meter: how many of the chip's four cells to fill. None when
/// nothing is held; otherwise the share of the budget held, in quarters,
/// rounded up, so any work at all shows a cell and 4 means the budget is full.
public func meterLevel(held: Int, budget: Int) -> Int {
    guard held > 0, budget > 0 else { return 0 }
    return min(4, (4 * held + budget - 1) / budget)
}

/// Where cpuq is installed: a GUI app does not inherit a shell's PATH, so it
/// looks where install.sh and Homebrew put it.
public func findCpuq(home: String = NSHomeDirectory(), exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
    [home + "/.local/bin/cpuq", "/opt/homebrew/bin/cpuq", "/usr/local/bin/cpuq"].first(where: exists)
}

/// A duration as `cpuq status` writes one: 42s, 3m05s, 2h10m.
public func age(_ seconds: Double) -> String {
    let s = Swift.max(Int(seconds), 0)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return String(format: "%dm%02ds", s / 60, s % 60) }
    return String(format: "%dh%02dm", s / 3600, (s % 3600) / 60)
}

/// One job from `cpuq history --json`.
public struct Job: Decodable, Sendable, Equatable {
    public var state = ""
    public var pool = ""
    public var label = ""
        /// What the job is for (`--note`): shown beside the label, a band of its own in the charts.
        public var note = ""
    /// The job's cpuq pid and the moment it queued, as "PID-TIME".
    public var id = ""
    public var cores: Int?
    public var slots: [Int]?
    public var queued: Double?
    public var started: Double?
    public var ended: Double?
    public var waited: Double?
    public var ran: Double?
    public var used: Double?
    /// It held the machine alone (`--exclusive`).
    public var exclusive = false

    private enum Keys: String, CodingKey { case state, pool, label, note, id, cores, slots, queued, started, ended, waited, ran, used, exclusive }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        pool = try c.decodeIfPresent(String.self, forKey: .pool) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        cores = try c.decodeIfPresent(Int.self, forKey: .cores)
        slots = try c.decodeIfPresent([Int].self, forKey: .slots)
        queued = try c.decodeIfPresent(Double.self, forKey: .queued)
        started = try c.decodeIfPresent(Double.self, forKey: .started)
        ended = try c.decodeIfPresent(Double.self, forKey: .ended)
        waited = try c.decodeIfPresent(Double.self, forKey: .waited)
        ran = try c.decodeIfPresent(Double.self, forKey: .ran)
        used = try c.decodeIfPresent(Double.self, forKey: .used)
        exclusive = try c.decodeIfPresent(Bool.self, forKey: .exclusive) ?? false
    }

    /// The cpuq pid in `id`.
    public var pid: Int? { Int(id.split(separator: "-").first ?? "") }

    public static func decodeList(_ data: Data) throws -> [Job] {
        try JSONDecoder().decode([Job].self, from: data)
    }
}

/// The remotes cpuq's config names (`remotes = HOST, ...`), in order, each with the command that
/// starts it when it is stopped (`remote_start.HOST = COMMAND`), if any: the machines the window
/// shows beside this Mac. A name starting with `-` is no host, and ssh would read it as an option.
public func remoteHosts(config text: String) -> [(host: String, start: String?)] {
    var hosts: [String] = []
    var starts: [String: String] = [:]
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if key == "remotes" {
            hosts = value.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }).map(String.init).filter { !$0.hasPrefix("-") }
        } else if key.hasPrefix("remote_start."), key.count > "remote_start.".count {
            starts[String(key.dropFirst("remote_start.".count))] = value
        }
    }
    return hosts.map { ($0, starts[$0]) }
}

/// How long a machine has run since `since`, from `journalctl --list-boots -o json`: each boot
/// from its first journal entry to its last, the boot still running (index 0) to `now`. Nil when
/// the list cannot be read.
public func runningSeconds(boots data: Data, since: Date, now: Date = Date()) -> Double? {
    struct Boot: Decodable {
        let index: Int
        let first_entry: Double
        let last_entry: Double
    }
    guard let boots = try? JSONDecoder().decode([Boot].self, from: data) else { return nil }
    let from = since.timeIntervalSince1970, to = now.timeIntervalSince1970
    return boots.reduce(0) { sum, b in
        let start = max(b.first_entry / 1e6, from)
        let end = min(b.index == 0 ? to : b.last_entry / 1e6, to)
        return sum + max(end - start, 0)
    }
}

/// One of `cpuq record`'s samples, as `cpuq samples` prints them: when, each
/// CPU's busy share since the sample before (percent), the 1-minute load, cores held, jobs
/// waiting, and the gate.
public struct RecordedSample: Decodable, Sendable, Equatable {
    public let t: Double
    public let cpu: [Double]
    public let load: Double
    public let held: Int
    public let wait: Int
    public let gate: String

    /// `cpuq samples` output, a JSON line each; lines it cannot read are skipped.
    public static func decodeLines(_ data: Data) -> [RecordedSample] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(RecordedSample.self, from: Data($0)) }
    }
}
