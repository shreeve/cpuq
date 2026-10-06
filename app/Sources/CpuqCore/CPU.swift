import Darwin

/// The Mac's CPU time so far, from the kernel: busy (user, system and nice) and all of it, in
/// ticks summed over every CPU. Two readings give how busy the CPUs were between them, the
/// figure cpuq's load valve checks (it trips only while they are at least 90% busy).
public struct CPUTicks: Sendable, Equatable {
    public var busy: UInt64
    public var total: UInt64

    public init(busy: UInt64, total: UInt64) {
        self.busy = busy
        self.total = total
    }

    public static func now() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        return CPUTicks(busy: user + system + nice, total: user + system + idle + nice)
    }

    /// The share of CPU time that was busy from `a` to `b`, 0 to 1; nil when no time passed.
    public static func busy(from a: CPUTicks, to b: CPUTicks) -> Double? {
        guard b.total > a.total, b.busy >= a.busy else { return nil }
        return min(Double(b.busy - a.busy) / Double(b.total - a.total), 1)
    }
}
