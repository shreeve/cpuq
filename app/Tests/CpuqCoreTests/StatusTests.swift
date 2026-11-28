import Foundation
import Testing
@testable import CpuqCore

@Test func meterFillsAQuarterOfTheCapacityBusyPerCellRoundingUp() {
    #expect(meterLevel(busy: 0, capacity: 8) == 0)
    #expect(meterLevel(busy: 0.4, capacity: 8) == 0)
    #expect(meterLevel(busy: 0.5, capacity: 8) == 1)
    #expect(meterLevel(busy: 2, capacity: 8) == 1)
    #expect(meterLevel(busy: 2.1, capacity: 8) == 2)
    #expect(meterLevel(busy: 5.9, capacity: 8) == 3)
    #expect(meterLevel(busy: 6.5, capacity: 8) == 4)
    #expect(meterLevel(busy: 9.1, capacity: 8) == 4)
    #expect(meterLevel(busy: 3, capacity: 0) == 0)
}

@Test func decodesStatus() throws {
    let json = """
    {"schema": 3, "version": "0.40.0", "admit": "contested", "budget": 10, "pool": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
     "capacity": 8, "isolated": [9, 8], "cores": 10, "active_cores": 10, "running": 12, "paused": 0, "waiting": 7,
     "busy": 9.1, "tasks_busy": 7.4, "room": -0.04, "load": [7.5, 6, 5], "memory_pressure": "normal",
     "gate": {"state": "open", "available": null, "disk_free": null, "disk_path": null, "text": "open"},
     "runs": [{"ticket": 2, "pid": 48589, "project": "rig", "weight": 2, "limit": 14, "tasks": 14, "done": 3, "failed": 1,
               "running": 7, "paused": 0, "demoted": 4, "demoted_for": "drain", "io_wait": 2, "tail": false, "oldest": 1795839407,
               "waiting": 3, "running_tasks": [{"task": 5, "attempt": 2, "pid": 9, "since": 1795839410, "paused": false}],
               "stopped": false, "driver": false, "driver_busy": 0, "drain": false, "pin": [], "cpus": [], "noise": 0, "noisy_top": "",
               "urgent": false, "using": 6.5, "flags": ["capped"], "progress": {"done": 4, "total": 14, "failing": 1},
               "left": 540, "left_from": "progress", "label": "rig:matrix", "command": "./test/one", "since": 1795839407},
              {"ticket": 3, "pid": 48593, "project": "cpuq", "limit": 2, "tasks": 1, "running": 1, "drain": true,
               "pin": [9, 8], "cpus": [9, 8], "noise": 0.12, "noisy_top": "mds (88)", "flags": ["noisy"], "using": 1.0,
               "label": "cpuq:bench", "command": "./bench", "since": 1795839407},
              {"ticket": 4, "pid": 48600, "project": "rig", "tasks": 0, "running": 0, "driver": true, "driver_busy": 0.7,
               "flags": ["driver_cpu"], "using": 0, "label": "rig:suite", "command": "./test/run", "since": 1795839400}],
     "waiters": [{"order": 1, "ticket": 2, "pid": 48589, "project": "rig", "waiting": 3, "running": 7, "max": 14, "drain": false,
                  "urgent": false, "why": "1st in line; over its share (8.0 of 8); the machine is busy (7.5 of 8 CPUs)",
                  "label": "rig:matrix", "command": "./test/one", "since": 1795839407}],
     "projects": [{"name": "rig", "weight": 2, "runs": 2, "running": 7, "waiting": 3, "fair": 5.3},
                  {"name": "nexis", "weight": 1, "runs": 1, "running": 4, "waiting": 0, "fair": 2.7}],
     "outside": [{"pid": 77, "name": "Python", "using": 1.2}], "outside_total": 1.2, "outside_work": [], "recorder": true}
    """
    let s = try Status.decode(Data(json.utf8))
    #expect(s.schema == 3 && s.admit == "contested" && s.budget == 10 && s.pool.count == 10)
    #expect(s.capacity == 8 && s.isolated == [9, 8] && s.cores == 10 && s.activeCores == 10)
    #expect(s.running == 12 && s.waiting == 7 && s.busy == 9.1 && s.tasksBusy == 7.4 && s.room == -0.04)
    #expect(s.busyNow == 9.1 && !s.waitsBesideRoom && s.recorder)
    let r = s.runs[0]
    #expect(r.ticket == 2 && r.pid == 48589 && r.project == "rig" && r.weight == 2 && r.limit == 14)
    #expect(r.tasks == 14 && r.done == 3 && r.failed == 1 && r.running == 7 && r.paused == 0 && !r.stopped)
    #expect(r.demoted == 4 && r.demotedFor == "drain" && r.ioWait == 2 && !r.tail && r.oldest == 1795839407 && r.waiting == 3)
    #expect(r.runningTasks == [Status.Task(task: 5, attempt: 2, pid: 9, since: 1795839410, paused: false, demoted: false)])
    #expect(r.using == 6.5 && r.flags == ["capped"] && r.progress == Status.Progress(done: 4, total: 14, failing: 1))
    #expect(r.left == 540 && r.leftFrom == "progress" && r.label == "rig:matrix")
    let d = s.runs[1]
    #expect(d.drain && d.pin == [9, 8] && d.cpus == [9, 8] && d.noise == 0.12 && d.noisyTop == "mds (88)" && d.flags == ["noisy"])
    let v = s.runs[2]
    #expect(v.driver && v.driverBusy == 0.7 && v.flags == ["driver_cpu"] && v.weight == 1)
    let w = try #require(s.waiters.first)
    #expect(w.order == 1 && w.ticket == 2 && w.waiting == 3 && w.running == 7 && w.max == 14 && !w.drain)
    #expect(w.why.hasPrefix("1st in line; over its share"))
    #expect(s.projects.map(\.name) == ["rig", "nexis"] && s.projects[0].fair == 5.3)
    #expect(s.projects[0].runs == 2 && s.projects[0].running == 7 && s.projects[0].waiting == 3)
    #expect(s.outside.first?.name == "Python" && s.outsideTotal == 1.2)
}

@Test func waitsBesideRoomOnlyWithTheGateOpenAndNoDrainWaiting() throws {
    let base = #"{"schema": 3, "capacity": 8, "room": 1.5, "waiters": [{"order": 1, "waiting": 3}]}"#
    #expect(try Status.decode(Data(base.utf8)).waitsBesideRoom)
    #expect(try !Status.decode(Data(#"{"schema": 3, "room": 1.5, "waiters": []}"#.utf8)).waitsBesideRoom)
    #expect(try !Status.decode(Data(#"{"schema": 3, "room": 0, "waiters": [{"order": 1, "waiting": 3}]}"#.utf8)).waitsBesideRoom)
    #expect(try !Status.decode(Data(#"{"schema": 3, "room": 1.5, "gate": {"state": "pressure"}, "waiters": [{"order": 1, "waiting": 3}]}"#.utf8)).waitsBesideRoom)
    #expect(try !Status.decode(Data(#"{"schema": 3, "room": 1.5, "waiters": [{"order": 1, "waiting": 3}, {"order": 2, "drain": true, "max": 2}]}"#.utf8)).waitsBesideRoom)
}

@Test func readsASchema2StatusAsRuns() throws {
    // cpuq before 0.40 (other machines during the cut-over): its holders are runs, the CPUs each
    // held its tasks running, its free CPUs the room.
    let json = """
    {"schema": 2, "version": "0.35.0", "admit": "pool", "budget": 8, "pool": [10, 11, 12, 13, 14, 15, 16, 17],
     "held": 5, "free": 3, "load": [7.5, 6, 5],
     "memory_pressure": "normal", "gate": {"state": "outside_load", "load": 9.1, "text": "outside load leaves 1 of 3 free CPUs idle"},
     "holders": [{"ticket": 4, "pid": 10, "project": "rig", "weight": 2, "cores": 3, "slots": [0, 1, 2], "cpus": [10, 11, 12], "using": 2.5,
                  "tasks": 40, "done": 12, "failed": 2, "running": 3, "urgent": false, "flags": [], "note": "#88",
                  "label": "rig:matrix", "command": "./test/one", "since": 100},
                 {"ticket": 5, "pid": 12, "cores": 2, "slots": [6, 7], "exclusive": true, "paused": true, "label": "rig:bench"}],
     "waiters": [{"order": 1, "ticket": 6, "pid": 11, "project": "nexis", "cores": 2, "max": 4, "holds": 1,
                  "why": "behind rig: 3 of its fair 5.3", "label": "nexis:build", "command": "zig build -j1", "since": 120},
                 {"order": 2, "ticket": 7, "pid": 13, "cores": 8, "exclusive": true, "label": "x:bench"}],
     "projects": [{"name": "rig", "weight": 2, "ops": 1, "held": 3, "want": 3, "fair": 5.3},
                  {"name": "nexis", "weight": 1, "ops": 1, "held": 0, "want": 2, "fair": 2.7}]}
    """
    let s = try Status.decode(Data(json.utf8))
    #expect(s.schema == 2 && s.running == 5 && s.room == 3 && s.capacity == 8 && s.waiting == 2)
    #expect(s.gate.state == "outside_load" && s.gate.load == 9.1)
    let h = try #require(s.runs.first)
    #expect(h.label == "rig:matrix" && h.note == "#88" && h.using == 2.5 && h.ticket == 4 && h.project == "rig" && h.weight == 2)
    #expect(h.tasks == 40 && h.done == 12 && h.failed == 2 && h.running == 3 && h.limit == 3 && !h.drain && h.cpus.isEmpty && !h.stopped)
    // An exclusive holder is a drain on the pool's CPUs it held; its `paused` is its cpuq stopped.
    let d = s.runs[1]
    #expect(d.drain && d.cpus == [16, 17] && d.pin == [16, 17] && d.stopped && d.paused == 0 && d.running == 2)
    // One naming its CPUs by the machine's numbers.
    let named = try Status.decode(Data(#"{"schema": 2, "pool": [10, 11], "holders": [{"cores": 2, "slots": [0, 1], "cpus": [10, 11], "exclusive": true}]}"#.utf8))
    #expect(named.runs[0].cpus == [10, 11])
    let w = s.waiters[0]
    #expect(w.waiting == 2 && w.running == 1 && w.max == 4 && w.ticket == 6 && w.project == "nexis" && !w.drain)
    #expect(s.waiters[1].drain && s.waiters[1].max == 8)
    #expect(s.projects[0].runs == 1 && s.projects[0].running == 3 && s.projects[0].waiting == 3 && s.projects[0].fair == 5.3)
    #expect(s.busyNow == 5)
}

@Test func keepsARunsFlagsAndStop() throws {
    let json = """
    {"runs": [{"ticket": 80, "pid": 3675197, "project": "trig", "running": 22, "paused": 3, "stopped": true,
               "flags": ["stopped", "over_cpu"], "label": "trig:slot766"}]}
    """
    let r = try #require(try Status.decode(Data(json.utf8)).runs.first)
    #expect(r.stopped && r.paused == 3 && r.running == 22 && r.weight == 1)
    #expect(r.flags == ["stopped", "over_cpu"])
}

@Test func decodesAStatusWithFieldsMissing() throws {
    // Each field left out keeps its default.
    let json = """
    {"capacity": 8, "runs": [{"pid": 1, "running": 2, "label": "x"}], "waiters": [{"order": 1, "waiting": 3}]}
    """
    let s = try Status.decode(Data(json.utf8))
    #expect(s.running == 2 && s.waiting == 3 && s.room == 0 && s.busy == nil)
    #expect(s.runs.first?.using == nil && s.runs.first?.ioWait == nil && s.runs.first?.limit == 2)
    #expect(s.waiters.first?.max == 3)
    #expect(s.outside.isEmpty && !s.recorder && s.isolated.isEmpty)
    #expect(s.gate.state == "open")
    #expect(try Status.decode(Data("{}".utf8)) == Status())
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
    #expect(try Status.decode(Data(#"{"recorder": true}"#.utf8)).recorder)
    #expect(try !Status.decode(Data(#"{"recorder": false}"#.utf8)).recorder)
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

@Test func capacityIsCpuqsOrASchema2PoolsSize() throws {
    // Schema 3 says it: the pool less the CPUs drains isolate.
    #expect(try Status.decode(Data(#"{"schema": 3, "budget": 10, "capacity": 8, "active_cores": 10}"#.utf8)).capacity == 8)
    // Schema 2 under measured admission: the CPUs online (`budget = 14` kept for drains).
    let measured = try Status.decode(Data(#"{"budget": 14, "held": 8, "admit": "measured", "target": 11, "active_cores": 10}"#.utf8))
    #expect(measured.capacity == 10)
    let cores = try Status.decode(Data(#"{"budget": 8, "held": 8, "admit": "cores", "active_cores": 10}"#.utf8))
    #expect(cores.capacity == 8)
    let older = try Status.decode(Data(#"{"budget": 8, "held": 2}"#.utf8))
    #expect(older.capacity == 8)
}

@Test func readsRemotesFromTheConfig() {
    let hosts = remoteHosts(config: """
    admit = measured
    remotes = pup, burst   # in order
    remote_start.burst = ~/runbooks/host-gcp-burst/start
    """)
    #expect(hosts.map(\.host) == ["pup", "burst"])
    #expect(hosts[0].start == nil && hosts[1].start == "~/runbooks/host-gcp-burst/start")
    #expect(remoteHosts(config: "budget = 8\nload_check = on\n").isEmpty)
    #expect(remoteHosts(config: "remotes = -oProxyCommand=touch, pup").map(\.host) == ["pup"])
}

@Test func decodesAnotherMachinesCPUTicks() throws {
    let s = try Status.decode(Data(#"{"schema": 3, "capacity": 20, "running": 4, "active_cores": 2, "cpu_ticks": [[10, 100], [30, 100]]}"#.utf8))
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
    // cpuq 0.40's recorder writes `running` (tasks); one before it, `held` (a CPU per task).
    let text = """
    {"t":1792038868,"cpu":[46,35],"load":2.24,"running":7,"wait":1,"gate":"open"}
    not a sample
    {"t":1792038871,"cpu":[0,100],"load":2.5,"held":2,"wait":0,"gate":"low_disk"}
    {"t":1792038874,"cpu":[0,100],"load":2.5,"gate":"open"}
    """
    let s = RecordedSample.decodeLines(Data(text.utf8))
    #expect(s.count == 3)
    #expect(s[0].cpu == [46, 35] && s[0].load == 2.24 && s[0].running == 7)
    #expect(s[1].gate == "low_disk" && s[1].running == 2)
    #expect(s[2].running == nil)
}

@Test func decodesMemory() throws {
    let json = #"{"schema":1,"memory":{"total":137438953472,"used":104152956928,"swap_total":34359738368,"swap_used":25769803776}}"#
    let s = try Status.decode(Data(json.utf8))
    let m = try #require(s.memory)
    #expect(Status.Memory.ofGB(m.used, m.total) == "97 of 128 GB")
    #expect(Status.Memory.ofGB(m.swapUsed, m.swapTotal) == "24 of 32 GB")
    #expect(Status.Memory.ofGB(1_395_864_371, 2_147_483_648) == "1.3 of 2.0 GB")
    #expect(try Status.decode(Data(#"{"schema":1}"#.utf8)).memory == nil)
}

@Test func decodesProgress() throws {
    let json = #"{"schema":3,"runs":[{"pid":7,"label":"rig:matrix","progress":{"done":4210,"total":12629,"failing":3},"left":540,"left_from":"progress","typical":2760},{"pid":8,"label":"rig:probe","progress":null,"left":null}]}"#
    let s = try Status.decode(Data(json.utf8))
    #expect(s.runs[0].progress == Status.Progress(done: 4210, total: 12629, failing: 3))
    #expect(s.runs[0].left == 540 && s.runs[0].leftFrom == "progress" && s.runs[0].typical == 2760)
    #expect(s.runs[1].progress == nil && s.runs[1].left == nil && s.runs[1].leftFrom == "")
}

@Test func decodesOutsideWork() throws {
    let json = #"{"schema":1,"outside_total":9.8,"outside":[{"pid":7,"name":"Python","using":0.69,"command":"/opt/homebrew/bin/python3 -I model.py 4 p2on","cwd":"/tmp/x"},{"pid":8,"name":"zig","using":0.5}]}"#
    let s = try Status.decode(Data(json.utf8))
    #expect(s.outsideTotal == 9.8)
    #expect(s.outside[0].shortCommand == "python3 -I model.py 4 p2on", "got \(s.outside[0].shortCommand) from \(String(describing: s.outside[0].command))")
    #expect(s.outside[0].cwd == "/tmp/x")
    #expect(s.outside[1].shortCommand == "zig" && s.outside[1].command == nil)
    #expect(try Status.decode(Data(#"{"schema":1}"#.utf8)).outsideTotal == nil)
}

@Test func decodesOutsideWorkByStarter() throws {
    let json = """
    {"schema": 2, "budget": 4, "outside_total": 3.1,
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
    // Older cpuq: no outside_work.
    #expect(try Status.decode(Data(#"{"schema": 2}"#.utf8)).outsideWork.isEmpty)
}
