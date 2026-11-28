import Foundation

/// `cpuq status --json`, schema 4: a strict token pool. The pool's CPUs less the reserve are N
/// tokens; a task holds one while it runs (pinned to that token's CPU on Linux), so at most N
/// tasks run at once. Every field has a default, so a cpuq that leaves one out still decodes; a
/// status of any other schema is refused.
public struct Status: Decodable, Sendable, Equatable {
    /// The one schema the app reads.
    public static let readable = 4

    public var schema = 0
    public var version = ""
    /// How cpuq shares CPUs: "tokens", one per CPU of the pool less the reserve.
    public var admit = ""
    /// The pool's CPUs by the machine's numbers, in its order.
    public var pool: [Int] = []
    /// The tokens (N: at most N tasks run at once), their CPUs (the pool's first N), and the
    /// reserve (the pool's last CPUs, never handed out).
    public var tokens = 0
    public var tokenCpus: [Int] = []
    public var reserve = 0
    /// Tokens held (by tasks running and by drains), held back while work outside cpuq keeps
    /// more than the CPUs cpuq leaves it busy, and free.
    public var held = 0
    public var heldBack = 0
    public var free = 0
    /// The CPUs drains isolate, by the machine's numbers.
    public var isolated: [Int] = []
    /// The machine's CPUs, and those online (`active_cores`).
    public var cores = 0
    public var activeCores = 0
    /// cpuq's tasks running (each holding a token), stopped by it (holding none), and waiting to
    /// start.
    public var running = 0
    public var paused = 0
    public var waiting = 0
    /// CPUs the machine kept busy over the sample, all of them, and those of cpuq's tasks.
    public var busy: Double?
    public var tasksBusy: Double?
    public var load: [Double] = [0, 0, 0]
    public var memoryPressure = ""
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
    /// Every run with a task running, a drain isolating its CPUs, or a driver.
    public var runs: [Run] = []
    /// The line: runs with tasks waiting to start, and drains waiting for their turn, in order.
    public var waiters: [Waiter] = []
    /// Each project's tasks against its fair share of the tokens by weight.
    public var projects: [Project] = []
    public var outside: [Outside] = []
    /// CPUs busy outside every cpuq job, in all.
    public var outsideTotal: Double?
    /// The same load by what started it, busiest first.
    public var outsideWork: [Work] = []
    /// `cpuq record` is sampling the machine: `cpuq samples` has its past.
    public var recorder = false

    public struct Gate: Decodable, Sendable, Equatable {
        /// open, pressure, low_memory or low_disk.
        public var state = "open"
        public var text = "open"
    }

    public struct Run: Decodable, Sendable, Equatable {
        /// Its place in the line: what `cpuq kill` and `cpuq limit` name it by.
        public var ticket = 0
        /// Its cpuq: what a pause (SIGTSTP) and a resume (SIGCONT) go to.
        public var pid = 0
        public var project = ""
        /// The project's weight (the config's `weights`).
        public var weight = 1
        /// The most tokens it holds at once (-c); a drain's CPUs.
        public var limit = 1
        /// Its tasks (`-n`): all of them, how many ended well or not, and how many run now, each
        /// holding a token.
        public var tasks = 0
        public var done = 0
        public var failed = 0
        public var running = 0
        /// Its tasks cpuq has stopped, holding no token: after a Ctrl-Z, until each holds one again.
        public var paused = 0
        /// Linux: its tasks waiting on a disk or other device; nil when not measured.
        public var ioWait: Int?
        /// Only its running tasks are left, and when the oldest of them started (Unix seconds).
        public var tail = false
        public var oldest = 0
        /// Tasks it could start now.
        public var waiting = 0
        public var runningTasks: [Task] = []
        /// Its cpuq is stopped (Ctrl-Z, or Pause here): its tasks stopped, and it counts in no share.
        public var stopped = false
        /// `cpuq run --driver`: a test runner with no task of its own, and the CPUs its own
        /// process tree keeps busy.
        public var driver = false
        public var driverBusy = 0.0
        /// `cpuq drain`: the CPUs its command runs on, the CPUs it isolates (holding their
        /// tokens), and the busy CPUs work from outside it keeps on them, with the busiest such
        /// process.
        public var drain = false
        public var pin: [Int] = []
        public var cpus: [Int] = []
        public var noise = 0.0
        public var noisyTop = ""
        public var urgent = false
        /// CPUs its tasks kept busy over the sample; nil with --no-usage.
        public var using: Double?
        /// What deserves a look: over_cpu, capped, stopped, idle_drain, long_drain, noisy,
        /// driver_cpu.
        public var flags: [String] = []
        public var label = ""
        /// What the job is for (`--note`): shown beside the label, a band of its own in the charts.
        public var note = ""
        public var command = ""
        public var since = 0
        /// How far it is: its tasks ended of all, or its own count through `CPUQ_PROGRESS`.
        public var progress: Progress?
        /// Seconds left: from its progress, or else from its label's usual time.
        public var left: Double?
        /// Where `left` comes from: "progress" or "history".
        public var leftFrom = ""
        /// Its label's usual run time, in seconds, from history.
        public var typical: Double?

        /// The CPUs whose tokens its tasks hold (a paused task holds none), and a drain's CPUs
        /// its command runs on.
        public var heldCPUs: [Int] {
            Array(Set(runningTasks.filter { !$0.paused }.map(\.cpu) + (drain ? pin : []))).sorted()
        }
    }

    /// One task running: its number, its try, its pid, when it started, whether cpuq has it
    /// stopped, and the CPU whose token it holds.
    public struct Task: Decodable, Sendable, Equatable {
        public var task = 0
        public var attempt = 1
        public var pid = 0
        public var since = 0
        public var paused = false
        public var cpu = 0
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
        /// Tasks it could start now, those it runs, and the most it runs at once (a drain's: the
        /// CPUs it times on).
        public var waiting = 0
        public var running = 0
        public var max = 0
        /// `cpuq drain` waiting for its turn.
        public var drain = false
        public var urgent = false
        /// Why it waits, in cpuq's words: "1st in line; every token is held".
        public var why = ""
        public var label = ""
        /// What the job is for (`--note`): shown beside the label, a band of its own in the charts.
        public var note = ""
        public var command = ""
        public var since = 0
    }

    public struct Project: Decodable, Sendable, Equatable {
        public var name = ""
        public var weight = 1
        /// Its runs, their tasks running and the tasks they could start now.
        public var runs = 0
        public var running = 0
        public var waiting = 0
        /// Its share of the tokens by weight, among the projects running or waiting.
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

    /// A status of a schema other than the one the app reads.
    public struct UnreadableSchema: Error, LocalizedError, Equatable {
        public let schema: Int
        public var errorDescription: String? {
            "its status is schema \(schema); this app reads schema \(Status.readable) (cpuq 0.42.0 or later)"
        }
    }

    public init() {}

    /// Decodes a status, refusing any schema but 4.
    public static func decode(_ data: Data) throws -> Status {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let s = try decoder.decode(Status.self, from: data)
        guard s.schema == readable else { throw UnreadableSchema(schema: s.schema) }
        return s
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
        case schema, version, admit, pool, tokens, tokenCpus, reserve, held, heldBack, free, isolated, cores, activeCores
        case running, paused, waiting, busy, tasksBusy, load, memoryPressure, cpuTicks, bootTime, memory, gate
        case runs, waiters, projects, outside, outsideTotal, outsideWork, recorder
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 0
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        admit = try c.decodeIfPresent(String.self, forKey: .admit) ?? ""
        pool = try c.decodeIfPresent([Int].self, forKey: .pool) ?? []
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        tokenCpus = try c.decodeIfPresent([Int].self, forKey: .tokenCpus) ?? []
        reserve = try c.decodeIfPresent(Int.self, forKey: .reserve) ?? 0
        held = try c.decodeIfPresent(Int.self, forKey: .held) ?? 0
        heldBack = try c.decodeIfPresent(Int.self, forKey: .heldBack) ?? 0
        free = try c.decodeIfPresent(Int.self, forKey: .free) ?? 0
        isolated = try c.decodeIfPresent([Int].self, forKey: .isolated) ?? []
        cores = try c.decodeIfPresent(Int.self, forKey: .cores) ?? 0
        activeCores = try c.decodeIfPresent(Int.self, forKey: .activeCores) ?? 0
        running = try c.decodeIfPresent(Int.self, forKey: .running) ?? 0
        paused = try c.decodeIfPresent(Int.self, forKey: .paused) ?? 0
        waiting = try c.decodeIfPresent(Int.self, forKey: .waiting) ?? 0
        busy = try c.decodeIfPresent(Double.self, forKey: .busy)
        tasksBusy = try c.decodeIfPresent(Double.self, forKey: .tasksBusy)
        load = try c.decodeIfPresent([Double].self, forKey: .load) ?? [0, 0, 0]
        memoryPressure = try c.decodeIfPresent(String.self, forKey: .memoryPressure) ?? ""
        cpuTicks = try c.decodeIfPresent([[UInt64]].self, forKey: .cpuTicks)
        bootTime = try c.decodeIfPresent(Double.self, forKey: .bootTime)
        memory = try c.decodeIfPresent(Memory.self, forKey: .memory)
        gate = try c.decodeIfPresent(Gate.self, forKey: .gate) ?? Gate()
        runs = try c.decodeIfPresent([Run].self, forKey: .runs) ?? []
        waiters = try c.decodeIfPresent([Waiter].self, forKey: .waiters) ?? []
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        outside = try c.decodeIfPresent([Outside].self, forKey: .outside) ?? []
        outsideTotal = try c.decodeIfPresent(Double.self, forKey: .outsideTotal)
        outsideWork = try c.decodeIfPresent([Work].self, forKey: .outsideWork) ?? []
        recorder = try c.decodeIfPresent(Bool.self, forKey: .recorder) ?? false
    }
}

extension Status.Gate {
    private enum Keys: String, CodingKey { case state, text }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "open"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? state
    }
}

extension Status.Run {
    private enum Keys: String, CodingKey {
        case ticket, pid, project, weight, limit, tasks, done, failed, running, paused, ioWait, tail, oldest, waiting
        case runningTasks, stopped, driver, driverBusy, drain, pin, cpus, noise, noisyTop, urgent, using, flags
        case label, note, command, since, progress, left, leftFrom, typical
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        ticket = try c.decodeIfPresent(Int.self, forKey: .ticket) ?? 0
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        weight = try c.decodeIfPresent(Int.self, forKey: .weight) ?? 1
        tasks = try c.decodeIfPresent(Int.self, forKey: .tasks) ?? 0
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        running = try c.decodeIfPresent(Int.self, forKey: .running) ?? 0
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? Swift.max(running, 1)
        paused = try c.decodeIfPresent(Int.self, forKey: .paused) ?? 0
        stopped = try c.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
        ioWait = try c.decodeIfPresent(Int.self, forKey: .ioWait)
        tail = try c.decodeIfPresent(Bool.self, forKey: .tail) ?? false
        oldest = try c.decodeIfPresent(Int.self, forKey: .oldest) ?? 0
        waiting = try c.decodeIfPresent(Int.self, forKey: .waiting) ?? 0
        runningTasks = try c.decodeIfPresent([Status.Task].self, forKey: .runningTasks) ?? []
        driver = try c.decodeIfPresent(Bool.self, forKey: .driver) ?? false
        driverBusy = try c.decodeIfPresent(Double.self, forKey: .driverBusy) ?? 0
        drain = try c.decodeIfPresent(Bool.self, forKey: .drain) ?? false
        pin = try c.decodeIfPresent([Int].self, forKey: .pin) ?? []
        cpus = try c.decodeIfPresent([Int].self, forKey: .cpus) ?? []
        noise = try c.decodeIfPresent(Double.self, forKey: .noise) ?? 0
        noisyTop = try c.decodeIfPresent(String.self, forKey: .noisyTop) ?? ""
        urgent = try c.decodeIfPresent(Bool.self, forKey: .urgent) ?? false
        using = try c.decodeIfPresent(Double.self, forKey: .using)
        flags = try c.decodeIfPresent([String].self, forKey: .flags) ?? []
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

extension Status.Task {
    private enum Keys: String, CodingKey { case task, attempt, pid, since, paused, cpu }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        task = try c.decodeIfPresent(Int.self, forKey: .task) ?? 0
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt) ?? 1
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        since = try c.decodeIfPresent(Int.self, forKey: .since) ?? 0
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        cpu = try c.decodeIfPresent(Int.self, forKey: .cpu) ?? 0
    }
}

extension Status.Waiter {
    private enum Keys: String, CodingKey { case order, ticket, pid, project, waiting, running, max, drain, urgent, why, label, note, command, since }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        ticket = try c.decodeIfPresent(Int.self, forKey: .ticket) ?? 0
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        waiting = try c.decodeIfPresent(Int.self, forKey: .waiting) ?? 0
        running = try c.decodeIfPresent(Int.self, forKey: .running) ?? 0
        max = try c.decodeIfPresent(Int.self, forKey: .max) ?? waiting
        drain = try c.decodeIfPresent(Bool.self, forKey: .drain) ?? false
        urgent = try c.decodeIfPresent(Bool.self, forKey: .urgent) ?? false
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        since = try c.decodeIfPresent(Int.self, forKey: .since) ?? 0
    }
}

extension Status.Project {
    private enum Keys: String, CodingKey { case name, weight, runs, running, waiting, fair }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        weight = try c.decodeIfPresent(Int.self, forKey: .weight) ?? 1
        runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
        running = try c.decodeIfPresent(Int.self, forKey: .running) ?? 0
        waiting = try c.decodeIfPresent(Int.self, forKey: .waiting) ?? 0
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

    /// CPUs busy: the machine's, else its tasks', else (a cpuq with no reading) its tasks running.
    public var busyNow: Double { busy ?? tasksBusy ?? Double(running) }

    /// "8 tokens, 2 reserved": the pool as cpuq shares it.
    public var tokensText: String {
        (tokens == 1 ? "1 token" : "\(tokens) tokens") + ", \(reserve) reserved"
    }

    /// The reserve's CPUs: the pool's past its tokens, never handed out.
    public var reserveCPUs: [Int] { Array(pool.dropFirst(tokenCpus.count)) }

    /// Each CPU whose token a run's task holds (or a drain's command runs on), with that run's
    /// index in `runs`.
    public var holders: [Int: Int] {
        var out: [Int: Int] = [:]
        for (i, r) in runs.enumerated() { for c in r.heldCPUs { out[c] = i } }
        return out
    }

    /// Runs wait beside free tokens: tasks waiting, a token free, and the gate open. cpuq hands
    /// a free token to the line at once, so this lasting is the case to fix. A drain waiting for
    /// its turn holds the line on purpose.
    public var waitsBesideFree: Bool { !waiters.isEmpty && free > 0 && gate.state == "open" && !waiters.contains(where: \.drain) }
}

/// The menu-bar meter: how many of the chip's four cells to fill. None while under half a CPU is
/// busy; otherwise the share of the machine's CPUs busy, in quarters, rounded up, so any work at
/// all shows a cell and 4 means every CPU is busy.
public func meterLevel(busy: Double, cpus: Int) -> Int {
    guard busy >= 0.5, cpus > 0 else { return 0 }
    return min(4, Int((4 * busy / Double(cpus)).rounded(.up)))
}

/// CPUs by number, in runs: "8, 9", "0, 2, 4–7".
public func cpuRanges(_ cpus: [Int]) -> String {
    var out: [String] = []
    var run: (Int, Int)?
    func close() { if let (a, b) = run { out.append(a == b ? "\(a)" : b == a + 1 ? "\(a), \(b)" : "\(a)–\(b)") } }
    for c in Set(cpus).sorted() {
        if let (a, b) = run, c == b + 1 { run = (a, c) } else { close(); run = (c, c) }
    }
    close()
    return out.joined(separator: ", ")
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
/// CPU's busy share since the sample before (percent), the 1-minute load, cpuq's tasks running,
/// and the gate.
public struct RecordedSample: Decodable, Sendable, Equatable {
    public let t: Double
    public let cpu: [Double]
    public let load: Double
    public let running: Int?
    public let gate: String

    private enum Keys: String, CodingKey { case t, cpu, load, running, gate }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        t = try c.decode(Double.self, forKey: .t)
        cpu = try c.decode([Double].self, forKey: .cpu)
        load = try c.decode(Double.self, forKey: .load)
        running = try c.decodeIfPresent(Int.self, forKey: .running)
        gate = try c.decode(String.self, forKey: .gate)
    }

    /// `cpuq samples` output, a JSON line each; lines it cannot read are skipped.
    public static func decodeLines(_ data: Data) -> [RecordedSample] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(RecordedSample.self, from: Data($0)) }
    }
}
