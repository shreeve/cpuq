import Foundation

/// `cpuq status --json`, schema 2: cpuq's pool, one CPU per task. Every field has a default, so a
/// cpuq that leaves one out still decodes.
public struct Status: Decodable, Sendable, Equatable {
    public var version = ""
    public var budget = 0
    public var held = 0
    public var load: [Double] = [0, 0, 0]
    public var memoryPressure = ""
    /// How cpuq shares CPUs: "pool" (one CPU per task).
    public var admit = ""
    /// The pool's CPUs, by the machine's numbers.
    public var pool: [Int] = []
    /// Pool CPUs no one holds or is promised.
    public var free = 0
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
    /// Each project in the line: its weight, the CPUs it holds and wants, and its fair share.
    public var projects: [Project] = []
    public var outside: [Outside] = []
    /// CPUs busy outside every cpuq job, in all.
    public var outsideTotal: Double?
    /// The same load by what started it, busiest first (cpuq 0.31 on).
    public var outsideWork: [Work] = []
    /// `cpuq record` is sampling the machine: `cpuq samples` has its past.
    public var recorder = false

    public struct Gate: Decodable, Sendable, Equatable {
        /// open, pressure, low_memory, low_disk, load or spacing.
        public var state = "open"
        public var load: Double?
        public var text = "open"
    }

    public struct Holder: Decodable, Sendable, Equatable {
        /// Its place in the line: what `cpuq kill` names it by.
        public var ticket = 0
        /// Its cpuq: what a pause (SIGTSTP) and a resume (SIGCONT) go to.
        public var pid = 0
        public var project = ""
        /// The project's weight (the config's `weights`).
        public var weight = 1
        /// The CPUs it holds, one per running task.
        public var cores = 0
        /// Which of the pool's CPUs it holds, by number from 0.
        public var slots: [Int] = []
        /// Its tasks (`-n`): all of them, how many ended well or not, and how many run now.
        public var tasks = 0
        public var done = 0
        public var failed = 0
        public var running = 0
        /// Stopped (Ctrl-Z, or Pause here): its tasks stopped and its CPUs back in the pool.
        public var paused = false
        /// What cpuq sees wrong with it, in words ("its CPU averages 0.05 busy").
        public var flags: [String] = []
        public var urgent = false
        public var using: Double?
        public var exclusive = false
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
        public var ticket = 0
        public var pid = 0
        public var project = ""
        /// The CPUs it holds already, while it waits for more.
        public var holds = 0
        public var urgent = false
        /// Why it waits, in cpuq's words.
        public var why = ""
        public var cores = 0
        public var max = 0
        public var exclusive = false
        public var label = ""
        /// What the job is for (`--note`): shown beside the label, a band of its own in the charts.
        public var note = ""
        public var command = ""
        public var since = 0
    }

    public struct Project: Decodable, Sendable, Equatable {
        public var name = ""
        public var weight = 1
        public var ops = 0
        public var held = 0
        public var want = 0
        /// Its share of the pool by weight, among the projects that want CPUs.
        public var fair = 0.0
    }

    /// Work outside cpuq by what started it: the top of a process tree just below its starter
    /// (an agent's harness, an ssh session, a terminal, a service manager).
    public struct Work: Decodable, Sendable, Equatable {
        public var pid = 0
        /// The command (an agent's own, out of its harness's wrapper) and where it runs.
        public var command = ""
        public var cwd = ""
        /// The starter's program name: `claude`, `sshd-session`, `launchd`, ...
        public var via = ""
        public var procs = 0
        public var using = 0.0

        /// The command for one line: the program's own name, not its path, then its arguments.
        public var shortCommand: String {
            let first = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let head = first.first else { return "pid \(pid)" }
            let prog = head.split(separator: "/").last.map(String.init) ?? String(head)
            return first.count > 1 ? prog + " " + first[1] : prog
        }

        /// Work someone ran: started by an agent, ssh, a terminal or cron, or detached in a folder
        /// of its own (`nohup make &` keeps the folder it was started in). An app or a system
        /// service runs detached in `/`, and isn't work anyone should move under cpuq.
        public var ranBySomeone: Bool {
            starter != "detached" || !(cwd.isEmpty || cwd == "/")
        }

        /// Who started it, in words: "an agent", "ssh", "a terminal", or the starter's name.
        public var starter: String {
            switch via {
            case "claude": "an agent"
            case "sshd", "sshd-session": "ssh"
            case "Terminal", "iTerm2", "login", "tmux", "tmux: server", "screen": "a terminal"
            case "launchd", "systemd", "init": "detached"
            case "": "?"
            default: via
            }
        }
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
        case version, budget, held, load, memoryPressure, gate, holders, waiters, projects, outside, outsideTotal, outsideWork, recorder, admit, pool, free, activeCores, cpuTicks, bootTime, memory
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        budget = try c.decodeIfPresent(Int.self, forKey: .budget) ?? 0
        held = try c.decodeIfPresent(Int.self, forKey: .held) ?? 0
        load = try c.decodeIfPresent([Double].self, forKey: .load) ?? [0, 0, 0]
        memoryPressure = try c.decodeIfPresent(String.self, forKey: .memoryPressure) ?? ""
        admit = try c.decodeIfPresent(String.self, forKey: .admit) ?? ""
        pool = try c.decodeIfPresent([Int].self, forKey: .pool) ?? []
        free = try c.decodeIfPresent(Int.self, forKey: .free) ?? 0
        activeCores = try c.decodeIfPresent(Int.self, forKey: .activeCores) ?? 0
        cpuTicks = try c.decodeIfPresent([[UInt64]].self, forKey: .cpuTicks)
        bootTime = try c.decodeIfPresent(Double.self, forKey: .bootTime)
        memory = try c.decodeIfPresent(Memory.self, forKey: .memory)
        gate = try c.decodeIfPresent(Gate.self, forKey: .gate) ?? Gate()
        holders = try c.decodeIfPresent([Holder].self, forKey: .holders) ?? []
        waiters = try c.decodeIfPresent([Waiter].self, forKey: .waiters) ?? []
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        outside = try c.decodeIfPresent([Outside].self, forKey: .outside) ?? []
        outsideTotal = try c.decodeIfPresent(Double.self, forKey: .outsideTotal)
        outsideWork = try c.decodeIfPresent([Work].self, forKey: .outsideWork) ?? []
        recorder = try c.decodeIfPresent(Bool.self, forKey: .recorder) ?? false
    }
}

extension Status.Gate {
    private enum Keys: String, CodingKey { case state, load, text }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "open"
        load = try c.decodeIfPresent(Double.self, forKey: .load)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? state
    }
}

extension Status.Holder {
    private enum Keys: String, CodingKey {
        case ticket, pid, project, weight, cores, slots, tasks, done, failed, running, paused, flags, urgent
        case using, exclusive, label, note, command, since, progress, left, typical, leftFrom
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        ticket = try c.decodeIfPresent(Int.self, forKey: .ticket) ?? 0
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        weight = try c.decodeIfPresent(Int.self, forKey: .weight) ?? 1
        cores = try c.decodeIfPresent(Int.self, forKey: .cores) ?? 0
        slots = try c.decodeIfPresent([Int].self, forKey: .slots) ?? []
        tasks = try c.decodeIfPresent(Int.self, forKey: .tasks) ?? 0
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        running = try c.decodeIfPresent(Int.self, forKey: .running) ?? 0
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        flags = try c.decodeIfPresent([String].self, forKey: .flags) ?? []
        urgent = try c.decodeIfPresent(Bool.self, forKey: .urgent) ?? false
        using = try c.decodeIfPresent(Double.self, forKey: .using)
        exclusive = try c.decodeIfPresent(Bool.self, forKey: .exclusive) ?? false
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
    private enum Keys: String, CodingKey { case order, ticket, pid, project, holds, urgent, why, cores, max, exclusive, label, note, command, since }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        ticket = try c.decodeIfPresent(Int.self, forKey: .ticket) ?? 0
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        holds = try c.decodeIfPresent(Int.self, forKey: .holds) ?? 0
        urgent = try c.decodeIfPresent(Bool.self, forKey: .urgent) ?? false
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        cores = try c.decodeIfPresent(Int.self, forKey: .cores) ?? 0
        max = try c.decodeIfPresent(Int.self, forKey: .max) ?? cores
        exclusive = try c.decodeIfPresent(Bool.self, forKey: .exclusive) ?? false
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        since = try c.decodeIfPresent(Int.self, forKey: .since) ?? 0
    }
}


extension Status.Project {
    private enum Keys: String, CodingKey { case name, weight, ops, held, want, fair }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        weight = try c.decodeIfPresent(Int.self, forKey: .weight) ?? 1
        ops = try c.decodeIfPresent(Int.self, forKey: .ops) ?? 0
        held = try c.decodeIfPresent(Int.self, forKey: .held) ?? 0
        want = try c.decodeIfPresent(Int.self, forKey: .want) ?? 0
        fair = try c.decodeIfPresent(Double.self, forKey: .fair) ?? 0
    }
}

extension Status.Work {
    private enum Keys: String, CodingKey { case pid, command, cwd, via, procs, using }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        via = try c.decodeIfPresent(String.self, forKey: .via) ?? ""
        procs = try c.decodeIfPresent(Int.self, forKey: .procs) ?? 0
        using = try c.decodeIfPresent(Double.self, forKey: .using) ?? 0
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
    public var started: Double?
    public var ended: Double?
    public var waited: Double?
    public var ran: Double?
    public var used: Double?
    /// It held the machine alone (`--exclusive`).
    public var exclusive = false

    private enum Keys: String, CodingKey { case state, pool, label, note, id, cores, slots, started, ended, waited, ran, used, exclusive }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        pool = try c.decodeIfPresent(String.self, forKey: .pool) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        cores = try c.decodeIfPresent(Int.self, forKey: .cores)
        slots = try c.decodeIfPresent([Int].self, forKey: .slots)
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
/// CPU's busy share since the sample before (percent), the 1-minute load, and the gate.
public struct RecordedSample: Decodable, Sendable, Equatable {
    public let t: Double
    public let cpu: [Double]
    public let load: Double
    public let gate: String

    /// `cpuq samples` output, a JSON line each; lines it cannot read are skipped.
    public static func decodeLines(_ data: Data) -> [RecordedSample] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(RecordedSample.self, from: Data($0)) }
    }
}
