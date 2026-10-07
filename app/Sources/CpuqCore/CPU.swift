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

extension CPUTicks {
    /// Each CPU's time so far, in the kernel's order (on Apple silicon, efficiency cores first,
    /// then performance cores).
    public static func perCPU() -> [CPUTicks]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var n: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &n) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(n) * MemoryLayout<integer_t>.stride)) }
        return (0..<Int(count)).map { i in
            let at = i * Int(CPU_STATE_MAX)
            let tick = { (state: Int32) in UInt64(UInt32(bitPattern: info[at + Int(state)])) }
            let busy = tick(CPU_STATE_USER) + tick(CPU_STATE_SYSTEM) + tick(CPU_STATE_NICE)
            return CPUTicks(busy: busy, total: busy + tick(CPU_STATE_IDLE))
        }
    }

    /// How many of the CPUs are performance cores, and what the system calls them ("Super",
    /// "Performance"); nil on a Mac with one kind of core. They are the last CPUs in the kernel's
    /// order.
    public static func performanceCores() -> (count: Int, name: String)? {
        var levels: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.nperflevels", &levels, &size, nil, 0) == 0, levels >= 2 else { return nil }
        var count: Int32 = 0
        size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0, count > 0 else { return nil }
        var name = [CChar](repeating: 0, count: 64)
        size = name.count
        let label = sysctlbyname("hw.perflevel0.name", &name, &size, nil, 0) == 0
            ? String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "Performance"
        return (Int(count), label)
    }
}
