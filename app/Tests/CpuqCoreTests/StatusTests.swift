import Foundation
import Testing
@testable import CpuqCore

@Test func meterFillsAQuarterPerCellRoundingUp() {
    #expect(meterLevel(held: 0, budget: 8) == 0)
    #expect(meterLevel(held: 1, budget: 8) == 1)
    #expect(meterLevel(held: 2, budget: 8) == 1)
    #expect(meterLevel(held: 3, budget: 8) == 2)
    #expect(meterLevel(held: 6, budget: 8) == 3)
    #expect(meterLevel(held: 7, budget: 8) == 4)
    #expect(meterLevel(held: 8, budget: 8) == 4)
    #expect(meterLevel(held: 9, budget: 8) == 4)
    #expect(meterLevel(held: 3, budget: 0) == 0)
}

@Test func decodesStatus() throws {
    let json = """
    {"schema": 1, "version": "0.4.0", "budget": 8, "held": 5, "free": 3, "load": [7.5, 6, 5],
     "memory_pressure": "normal", "gate": {"state": "spacing", "load": 9.1, "text": "spacing admissions"},
     "holders": [{"pid": 10, "cores": 3, "using": 2.5, "priority": "high", "exclusive": false,
                  "label": "rig:matrix", "command": "./test/run -j 3", "since": 100, "ticket": 4}],
     "waiters": [{"order": 1, "cores": 2, "max": 4, "label": "nexis:build", "command": "zig build", "since": 120, "eta": 30.5}],
     "leases": [{"name": "pup-bench", "holders": [{"label": "gate", "cores": 1}], "waiters": []}],
     "outside": [{"pid": 77, "name": "Python", "using": 1.2}]}
    """
    let s = try Status.decode(Data(json.utf8))
    #expect(s.budget == 8 && s.held == 5)
    #expect(s.memoryPressure == "normal")
    #expect(s.gate.state == "spacing" && s.gate.load == 9.1)
    #expect(s.holders.first?.label == "rig:matrix" && s.holders.first?.using == 2.5)
    #expect(s.waiters.first?.max == 4 && s.waiters.first?.eta == 30.5)
    #expect(s.leases.first?.holders.first?.label == "gate")
    #expect(s.outside.first?.name == "Python")
}

@Test func decodesAnOlderStatusWithFieldsMissing() throws {
    // cpuq 0.1.0's status had no using, max, eta, leases or outside, and its gate was text.
    let json = """
    {"budget": 8, "held": 2, "holders": [{"pid": 1, "cores": 2, "label": "x"}], "waiters": [{"order": 1, "cores": 3}]}
    """
    let s = try Status.decode(Data(json.utf8))
    #expect(s.held == 2)
    #expect(s.holders.first?.using == nil)
    #expect(s.waiters.first?.max == 3)
    #expect(s.leases.isEmpty && s.outside.isEmpty)
    #expect(s.gate.state == "open")
}

@Test func findsCpuqWhereItIsInstalled() {
    #expect(findCpuq(home: "/Users/a", exists: { $0 == "/opt/homebrew/bin/cpuq" }) == "/opt/homebrew/bin/cpuq")
    #expect(findCpuq(home: "/Users/a", exists: { $0 == "/Users/a/.local/bin/cpuq" || $0 == "/usr/local/bin/cpuq" }) == "/Users/a/.local/bin/cpuq")
    #expect(findCpuq(home: "/Users/a", exists: { _ in false }) == nil)
}

@Test func agesReadLikeCpuqStatus() {
    #expect(age(42) == "42s")
    #expect(age(185) == "3m05s")
    #expect(age(7800) == "2h10m")
}

@Test func watchArrivesInCpuq040() {
    #expect(!supportsWatch(version: "0.2.0"))
    #expect(!supportsWatch(version: "0.3.0"))
    #expect(supportsWatch(version: "0.4.0"))
    #expect(supportsWatch(version: "0.10.1"))
    #expect(supportsWatch(version: "1.0.0"))
    #expect(!supportsWatch(version: ""))
}

@Test func decodesEachHoldersCoresAndAHistoryJob() throws {
    // cpuq 0.4.5 names the cores each holder took; an older cpuq leaves them out.
    let s = try Status.decode(Data(#"{"budget": 8, "held": 3, "holders": [{"pid": 7, "cores": 3, "slots": [2, 3, 4]}, {"pid": 8, "cores": 1}]}"#.utf8))
    #expect(s.holders[0].slots == [2, 3, 4])
    #expect(s.holders[1].slots.isEmpty)
    let jobs = try Job.decodeList(Data(#"[{"id": "4321-1700000000.5", "state": "done", "pool": "cores", "cores": 2, "slots": [0, 1], "queued": 1700000000.5, "started": 1700000003}]"#.utf8))
    #expect(jobs[0].pid == 4321)
    #expect(jobs[0].slots == [0, 1])
    #expect(jobs[0].queued == 1700000000.5)
}

@Test func jobActionsNeedCpuq071() {
    #expect(supportsControls(version: "0.7.1"))
    #expect(supportsControls(version: "0.8.0"))
    #expect(!supportsControls(version: "0.7.0"))
    #expect(!supportsControls(version: "0.6.2"))
    #expect(!supportsControls(version: ""))
}
