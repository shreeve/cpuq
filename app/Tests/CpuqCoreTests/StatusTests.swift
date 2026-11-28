import Foundation
import Testing
@testable import CpuqCore

@Test func meterFillsAQuarterOfTheCPUsBusyPerCellRoundingUp() {
    #expect(meterLevel(busy: 0, cpus: 8) == 0)
    #expect(meterLevel(busy: 0.4, cpus: 8) == 0)
    #expect(meterLevel(busy: 0.5, cpus: 8) == 1)
    #expect(meterLevel(busy: 2, cpus: 8) == 1)
    #expect(meterLevel(busy: 2.1, cpus: 8) == 2)
    #expect(meterLevel(busy: 5.9, cpus: 8) == 3)
    #expect(meterLevel(busy: 6.5, cpus: 8) == 4)
    #expect(meterLevel(busy: 9.1, cpus: 8) == 4)
    #expect(meterLevel(busy: 3, cpus: 0) == 0)
}

/// `cpuq status --json` from cpuq 0.42 on 10 CPUs, reserve 2: a run of 12 tasks with 7 holding
/// tokens on CPUs 0–6 and one paused, and a drain timing on CPU 7 (its outside work cut short).
let schema4 = """
{"schema": 4, "version": "0.42.0", "dir": "/tmp/cq/v4", "admit": "tokens", "pool": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
 "tokens": 8, "token_cpus": [0, 1, 2, 3, 4, 5, 6, 7], "reserve": 2, "held": 8, "held_back": 3, "free": 0,
 "isolated": [7], "cores": 10, "active_cores": 10, "running": 8, "paused": 1, "waiting": 5,
 "busy": 6.686507936507936, "tasks_busy": 0, "load": [9.32470703125, 13.47802734375, 14.15576171875],
 "memory_pressure": "normal",
 "memory": {"total": 34359738368, "used": 22806134784, "swap_total": 7516192768, "swap_used": 6269435904},
 "gate": {"state": "open", "available": null, "disk_free": null, "disk_path": null, "text": "open"},
 "runs": [{"ticket": 1, "pid": 67220, "project": "cpuq", "weight": 1, "limit": 1, "tasks": 1, "done": 0, "failed": 0,
           "running": 1, "paused": 0, "io_wait": null, "tail": false, "oldest": 1795854704, "waiting": 0,
           "running_tasks": [{"task": 1, "attempt": 1, "pid": 67222, "since": 1795854704, "paused": false, "cpu": 7}],
           "stopped": false, "driver": false, "driver_busy": 0, "drain": true, "pin": [7], "cpus": [7], "noise": 0,
           "noisy_top": "", "urgent": false, "using": 0, "flags": [], "progress": null, "left": null, "left_from": "",
           "label": "demo:bench", "command": "sleep 5", "since": 1795854704},
          {"ticket": 2, "pid": 67218, "project": "cpuq", "weight": 1, "limit": 12, "tasks": 12, "done": 0, "failed": 0,
           "running": 7, "paused": 1, "io_wait": null, "tail": false, "oldest": 1795854704, "waiting": 5,
           "running_tasks": [{"task": 1, "attempt": 1, "pid": 67223, "since": 1795854704, "paused": false, "cpu": 0},
                             {"task": 2, "attempt": 1, "pid": 67224, "since": 1795854704, "paused": false, "cpu": 1},
                             {"task": 3, "attempt": 1, "pid": 67225, "since": 1795854704, "paused": false, "cpu": 2},
                             {"task": 4, "attempt": 1, "pid": 67226, "since": 1795854704, "paused": false, "cpu": 3},
                             {"task": 5, "attempt": 1, "pid": 67227, "since": 1795854704, "paused": false, "cpu": 4},
                             {"task": 6, "attempt": 1, "pid": 67228, "since": 1795854704, "paused": false, "cpu": 5},
                             {"task": 7, "attempt": 2, "pid": 67229, "since": 1795854705, "paused": false, "cpu": 6},
                             {"task": 8, "attempt": 1, "pid": 67230, "since": 1795854704, "paused": true, "cpu": 0}],
           "stopped": false, "driver": false, "driver_busy": 0, "drain": false, "pin": [], "cpus": [], "noise": 0,
           "noisy_top": "", "urgent": false, "using": 0, "flags": ["capped"], "progress": null, "left": null,
           "left_from": "", "label": "demo:sleep", "command": "sleep 6", "since": 1795854704}],
 "waiters": [{"order": 1, "ticket": 2, "pid": 67218, "project": "cpuq", "waiting": 5, "running": 7, "max": 12,
              "drain": false, "urgent": false, "why": "1st in line; every token is held (some held back for work outside cpuq)",
              "label": "demo:sleep", "command": "sleep 6", "since": 1795854704}],
 "projects": [{"name": "cpuq", "weight": 1, "runs": 1, "running": 7, "waiting": 5, "fair": 8}],
 "outside": [{"pid": 77, "name": "Python", "using": 1.2}], "outside_total": 3.9, "outside_work": [],
 "cpu_ticks": [[10, 100], [30, 100]], "boot_time": 1795597898, "recorder": false}
"""

@Test func decodesASchema4Status() throws {
    let s = try Status.decode(Data(schema4.utf8))
    #expect(s.schema == 4 && s.admit == "tokens" && s.pool == Array(0...9))
    #expect(s.tokens == 8 && s.tokenCpus == Array(0...7) && s.reserve == 2)
    #expect(s.held == 8 && s.heldBack == 3 && s.free == 0 && s.isolated == [7])
    #expect(s.cores == 10 && s.activeCores == 10 && s.running == 8 && s.paused == 1 && s.waiting == 5)
    #expect(s.busy == 6.686507936507936 && s.tasksBusy == 0 && s.busyNow == 6.686507936507936)
    #expect(s.memory?.total == 34359738368 && s.gate.state == "open" && s.bootTime == 1795597898 && !s.recorder)
    #expect(s.tokensText == "8 tokens, 2 reserved" && s.reserveCPUs == [8, 9])
    let d = s.runs[0]
    #expect(d.drain && d.pin == [7] && d.cpus == [7] && d.running == 1 && d.heldCPUs == [7])
    let r = s.runs[1]
    #expect(r.ticket == 2 && r.pid == 67218 && r.limit == 12 && r.tasks == 12 && r.running == 7 && r.paused == 1)
    #expect(r.ioWait == nil && !r.tail && r.oldest == 1795854704 && r.waiting == 5 && r.flags == ["capped"])
    #expect(r.runningTasks[6] == Status.Task(task: 7, attempt: 2, pid: 67229, since: 1795854705, paused: false, cpu: 6))
    // A paused task holds no token: its CPU is the token of another task's.
    #expect(r.heldCPUs == Array(0...6))
    #expect(s.holders == [0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1, 7: 0])
    let w = try #require(s.waiters.first)
    #expect(w.order == 1 && w.ticket == 2 && w.waiting == 5 && w.running == 7 && w.max == 12 && !w.drain)
    #expect(w.why == "1st in line; every token is held (some held back for work outside cpuq)")
    #expect(s.projects.first == Status.Project(name: "cpuq", weight: 1, runs: 1, running: 7, waiting: 5, fair: 8))
    #expect(s.outside.first?.name == "Python" && s.outsideTotal == 3.9)
    #expect(s.ticks?.all == CPUTicks(busy: 40, total: 200))
    #expect(!s.waitsBesideFree)
}

@Test func refusesEveryOtherSchema() throws {
    for json in [#"{}"#, #"{"schema": 3, "capacity": 8, "room": 1.5}"#, #"{"schema": 2, "holders": []}"#, #"{"schema": 5}"#] {
        #expect(throws: Status.UnreadableSchema.self) { try Status.decode(Data(json.utf8)) }
    }
    do {
        _ = try Status.decode(Data(#"{"schema": 3}"#.utf8))
    } catch let e as Status.UnreadableSchema {
        #expect(e.schema == 3 && e.localizedDescription.contains("reads schema 4"))
    }
}

@Test func waitsBesideFreeTokensOnlyWithTheGateOpenAndNoDrainWaiting() throws {
    let base = #"{"schema": 4, "tokens": 8, "free": 2, "waiters": [{"order": 1, "waiting": 3}]}"#
    #expect(try Status.decode(Data(base.utf8)).waitsBesideFree)
    #expect(try !Status.decode(Data(#"{"schema": 4, "free": 2, "waiters": []}"#.utf8)).waitsBesideFree)
    #expect(try !Status.decode(Data(#"{"schema": 4, "free": 0, "held_back": 2, "waiters": [{"order": 1, "waiting": 3}]}"#.utf8)).waitsBesideFree)
    #expect(try !Status.decode(Data(#"{"schema": 4, "free": 2, "gate": {"state": "pressure"}, "waiters": [{"order": 1, "waiting": 3}]}"#.utf8)).waitsBesideFree)
    #expect(try !Status.decode(Data(#"{"schema": 4, "free": 2, "waiters": [{"order": 1, "waiting": 3}, {"order": 2, "drain": true, "max": 2}]}"#.utf8)).waitsBesideFree)
}

@Test func saysTheTokensAndTheReserve() throws {
    let one = try Status.decode(Data(#"{"schema": 4, "pool": [4, 5, 6], "tokens": 1, "token_cpus": [4], "reserve": 2}"#.utf8))
    #expect(one.tokensText == "1 token, 2 reserved" && one.reserveCPUs == [5, 6])
    let none = try Status.decode(Data(#"{"schema": 4, "pool": [0, 1], "tokens": 2, "token_cpus": [0, 1], "reserve": 0}"#.utf8))
    #expect(none.tokensText == "2 tokens, 0 reserved" && none.reserveCPUs.isEmpty && none.holders.isEmpty)
}

@Test func keepsARunsFlagsAndStop() throws {
    let json = """
    {"schema": 4, "runs": [{"ticket": 80, "pid": 3675197, "project": "trig", "running": 22, "paused": 3, "stopped": true,
               "flags": ["stopped", "over_cpu"], "label": "trig:slot766"}]}
    """
    let r = try #require(try Status.decode(Data(json.utf8)).runs.first)
    #expect(r.stopped && r.paused == 3 && r.running == 22 && r.weight == 1)
    #expect(r.flags == ["stopped", "over_cpu"])
}

@Test func decodesAStatusWithFieldsMissing() throws {
    // Each field left out keeps its default.
    let json = """
    {"schema": 4, "runs": [{"pid": 1, "running": 2, "label": "x", "running_tasks": [{"task": 1}]}], "waiters": [{"order": 1, "waiting": 3}]}
    """
    let s = try Status.decode(Data(json.utf8))
    #expect(s.running == 0 && s.waiting == 0 && s.free == 0 && s.tokens == 0 && s.busy == nil)
    #expect(s.runs.first?.using == nil && s.runs.first?.ioWait == nil && s.runs.first?.limit == 2)
    #expect(s.runs.first?.runningTasks == [Status.Task(task: 1, attempt: 1, pid: 0, since: 0, paused: false, cpu: 0)])
    #expect(s.waiters.first?.max == 3)
    #expect(s.outside.isEmpty && !s.recorder && s.isolated.isEmpty)
    #expect(s.gate.state == "open")
    var empty = Status()
    empty.schema = 4
    #expect(try Status.decode(Data(#"{"schema": 4}"#.utf8)) == empty)
}

@Test func writesCPUsInRuns() {
    #expect(cpuRanges([9, 8]) == "8, 9")
    #expect(cpuRanges([0, 2, 4, 5, 6, 7]) == "0, 2, 4–7")
    #expect(cpuRanges([3]) == "3")
    #expect(cpuRanges([]) == "")
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

@Test func decodesAHistoryJob() throws {
    let jobs = try Job.decodeList(Data(#"[{"id": "4321-1700000000.5", "state": "done", "pool": "cpus", "cores": 2, "queued": 1700000000.5, "started": 1700000003, "noisy": {"cpus": 0.2, "max": 0.5, "top": "mds (88)"}}]"#.utf8))
    #expect(jobs[0].pid == 4321)
    #expect(jobs[0].cores == 2)
    #expect(jobs[0].started == 1700000003)
}

@Test func saysWhetherTheRecorderRuns() throws {
    #expect(try Status.decode(Data(#"{"schema": 4, "recorder": true}"#.utf8)).recorder)
    #expect(try !Status.decode(Data(#"{"schema": 4, "recorder": false}"#.utf8)).recorder)
}

@Test func busyShareBetweenTwoReadings() {
    let a = CPUTicks(busy: 1000, total: 4000)
    #expect(CPUTicks.busy(from: a, to: CPUTicks(busy: 1750, total: 5000)) == 0.75)
    #expect(CPUTicks.busy(from: a, to: a) == nil)
    #expect(CPUTicks.now() != nil)
}

@Test func everyCPUHasTicks() {
    let all = CPUTicks.perCPU()
    #expect(all?.count == ProcessInfo.processInfo.processorCount)
    #expect(all?.allSatisfy { $0.total >= $0.busy } == true)
}

@Test func readsRemotesFromTheConfig() {
    let hosts = remoteHosts(config: """
    reserve = 2
    remotes = pup, burst   # in order
    remote_start.burst = ~/runbooks/host-gcp-burst/start
    """)
    #expect(hosts.map(\.host) == ["pup", "burst"])
    #expect(hosts[0].start == nil && hosts[1].start == "~/runbooks/host-gcp-burst/start")
    #expect(remoteHosts(config: "reserve = 2\nload_check = on\n").isEmpty)
    #expect(remoteHosts(config: "remotes = -oProxyCommand=touch, pup").map(\.host) == ["pup"])
}

@Test func decodesAnotherMachinesCPUTicks() throws {
    let s = try Status.decode(Data(#"{"schema": 4, "tokens": 20, "running": 4, "active_cores": 2, "cpu_ticks": [[10, 100], [30, 100]]}"#.utf8))
    #expect(s.ticks?.each.count == 2)
    #expect(s.ticks?.all == CPUTicks(busy: 40, total: 200))
}

@Test func addsUpAMonthsBoots() throws {
    // Three boots: one before the month began (half inside it), one inside, one still running.
    let since = Date(timeIntervalSince1970: 1_000_000)
    let now = Date(timeIntervalSince1970: 1_010_000)
    let boots = """
    [{"index": -2, "first_entry": \(999_000.0 * 1e6), "last_entry": \(1_002_000.0 * 1e6)},
     {"index": -1, "first_entry": \(1_003_000.0 * 1e6), "last_entry": \(1_004_000.0 * 1e6)},
     {"index": 0, "first_entry": \(1_009_000.0 * 1e6), "last_entry": \(1_009_500.0 * 1e6)}]
    """
    let seconds = runningSeconds(boots: Data(boots.utf8), since: since, now: now)
    #expect(seconds == 4000.0, "got \(String(describing: seconds))")
    #expect(runningSeconds(boots: Data("not json".utf8), since: since) == nil)
}

@Test func decodesRecordedSamples() {
    let text = """
    {"t":1792038868,"cpu":[46,35],"load":2.24,"running":7,"wait":1,"gate":"open"}
    not a sample
    {"t":1792038871,"cpu":[0,100],"load":2.5,"running":2,"wait":0,"gate":"low_disk"}
    {"t":1792038874,"cpu":[0,100],"load":2.5,"gate":"open"}
    """
    let s = RecordedSample.decodeLines(Data(text.utf8))
    #expect(s.count == 3)
    #expect(s[0].cpu == [46, 35] && s[0].load == 2.24 && s[0].running == 7)
    #expect(s[1].gate == "low_disk" && s[1].running == 2)
    #expect(s[2].running == nil)
}

@Test func decodesMemory() throws {
    let json = #"{"schema":4,"memory":{"total":137438953472,"used":104152956928,"swap_total":34359738368,"swap_used":25769803776}}"#
    let s = try Status.decode(Data(json.utf8))
    let m = try #require(s.memory)
    #expect(Status.Memory.ofGB(m.used, m.total) == "97 of 128 GB")
    #expect(Status.Memory.ofGB(m.swapUsed, m.swapTotal) == "24 of 32 GB")
    #expect(Status.Memory.ofGB(1_395_864_371, 2_147_483_648) == "1.3 of 2.0 GB")
    #expect(try Status.decode(Data(#"{"schema":4}"#.utf8)).memory == nil)
}

@Test func decodesProgress() throws {
    let json = #"{"schema":4,"runs":[{"pid":7,"label":"rig:matrix","progress":{"done":4210,"total":12629,"failing":3},"left":540,"left_from":"progress","typical":2760},{"pid":8,"label":"rig:probe","progress":null,"left":null}]}"#
    let s = try Status.decode(Data(json.utf8))
    #expect(s.runs[0].progress == Status.Progress(done: 4210, total: 12629, failing: 3))
    #expect(s.runs[0].left == 540 && s.runs[0].leftFrom == "progress" && s.runs[0].typical == 2760)
    #expect(s.runs[1].progress == nil && s.runs[1].left == nil && s.runs[1].leftFrom == "")
}

@Test func decodesOutsideWork() throws {
    let json = #"{"schema":4,"outside_total":9.8,"outside":[{"pid":7,"name":"Python","using":0.69,"command":"/opt/homebrew/bin/python3 -I model.py 4 p2on","cwd":"/tmp/x"},{"pid":8,"name":"zig","using":0.5}]}"#
    let s = try Status.decode(Data(json.utf8))
    #expect(s.outsideTotal == 9.8)
    #expect(s.outside[0].shortCommand == "python3 -I model.py 4 p2on", "got \(s.outside[0].shortCommand) from \(String(describing: s.outside[0].command))")
    #expect(s.outside[0].cwd == "/tmp/x")
    #expect(s.outside[1].shortCommand == "zig" && s.outside[1].command == nil)
    #expect(try Status.decode(Data(#"{"schema":4}"#.utf8)).outsideTotal == nil)
}

@Test func decodesOutsideWorkByStarter() throws {
    let json = """
    {"schema": 4, "tokens": 4, "outside_total": 3.1,
     "outside_work": [{"pid": 77, "command": "/bin/bash -c for n in 4 9; do python3 r5mut.py $n & done", "cwd": "/home/s/emdb",
                       "via": "sshd-session", "procs": 9, "using": 3.0}]}
    """
    let s = try Status.decode(Data(json.utf8))
    #expect(s.outsideWork.count == 1)
    let w = s.outsideWork[0]
    #expect(w.pid == 77 && w.procs == 9 && w.using == 3.0 && w.cwd == "/home/s/emdb")
    #expect(w.shortCommand == "bash -c for n in 4 9; do python3 r5mut.py $n & done")
    #expect(w.starter == "ssh" && w.ranBySomeone)
    // A service or an app runs detached in /: not work someone ran. A detached job in its own
    // folder is.
    var svc = w; svc.via = "launchd"; svc.cwd = "/"
    #expect(!svc.ranBySomeone)
    svc.cwd = "/home/s/emdb"
    #expect(svc.ranBySomeone)
    // None outside: an empty list.
    #expect(try Status.decode(Data(#"{"schema": 4}"#.utf8)).outsideWork.isEmpty)
}
