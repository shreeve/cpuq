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
    public var gate = Gate()
    public var holders: [Holder] = []
    public var waiters: [Waiter] = []
    public var leases: [Lease] = []
    public var outside: [Outside] = []

    public struct Gate: Decodable, Sendable, Equatable {
        /// open, pressure, load or spacing.
        public var state = "open"
        public var load: Double?
        public var text = "open"
    }

    public struct Holder: Decodable, Sendable, Equatable {
        public var pid = 0
        public var cores = 0
        public var using: Double?
        public var priority = ""
        public var exclusive = false
        public var label = ""
        public var command = ""
        public var since = 0
    }

    public struct Waiter: Decodable, Sendable, Equatable {
        public var order = 0
        public var cores = 0
        public var max = 0
        public var exclusive = false
        public var label = ""
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
    }

    public init() {}

    public static func decode(_ data: Data) throws -> Status {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Status.self, from: data)
    }
}

// Decoding with defaults: a missing key keeps the property's default.
extension Status {
    private enum Keys: String, CodingKey {
        case schema, version, budget, held, free, load, memoryPressure, gate, holders, waiters, leases, outside
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
        gate = try c.decodeIfPresent(Gate.self, forKey: .gate) ?? Gate()
        holders = try c.decodeIfPresent([Holder].self, forKey: .holders) ?? []
        waiters = try c.decodeIfPresent([Waiter].self, forKey: .waiters) ?? []
        leases = try c.decodeIfPresent([Lease].self, forKey: .leases) ?? []
        outside = try c.decodeIfPresent([Outside].self, forKey: .outside) ?? []
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
    private enum Keys: String, CodingKey { case pid, cores, using, priority, exclusive, label, command, since }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        cores = try c.decodeIfPresent(Int.self, forKey: .cores) ?? 0
        using = try c.decodeIfPresent(Double.self, forKey: .using)
        priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? ""
        exclusive = try c.decodeIfPresent(Bool.self, forKey: .exclusive) ?? false
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        since = try c.decodeIfPresent(Int.self, forKey: .since) ?? 0
    }
}

extension Status.Waiter {
    private enum Keys: String, CodingKey { case order, cores, max, exclusive, label, command, since, eta }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        cores = try c.decodeIfPresent(Int.self, forKey: .cores) ?? 0
        max = try c.decodeIfPresent(Int.self, forKey: .max) ?? cores
        exclusive = try c.decodeIfPresent(Bool.self, forKey: .exclusive) ?? false
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
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
    private enum Keys: String, CodingKey { case pid, name, using }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        using = try c.decodeIfPresent(Double.self, forKey: .using) ?? 0
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

/// Whether a cpuq of this version has `status --watch` (0.4.0 and later).
public func supportsWatch(version: String) -> Bool {
    let parts = version.split(separator: ".").compactMap { Int($0) }
    guard parts.count >= 2 else { return false }
    return parts[0] > 0 || parts[1] >= 4
}
