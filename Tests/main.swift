import Foundation

let fixture = CommandLine.arguments[1]
func client(_ profile: String = "") -> CLI { CLI(config: Configuration(executable: fixture, profile: profile, account: "")) }
func expectFailure(_ action: () throws -> Void) {
    do { try action(); fatalError("Expected failure") } catch { }
}
let normal = client()
let snapshot = try normal.list()
assert(snapshot.gateway && snapshot.requests.count == 1)
assert(snapshot.requests[0].sender == "U_TEST_ONLY")
try normal.act(snapshot.requests[0], approve: true)
try normal.act(snapshot.requests[0], approve: false)
let legacy = try client("legacy").list()
assert(!legacy.gateway && legacy.requests[0].code == "TESTCODE")
try client("legacy").act(legacy.requests[0], approve: true)
expectFailure { try client("legacy").act(legacy.requests[0], approve: false) }
expectFailure { _ = try client("auth-failure").list() }
expectFailure { _ = try CLI.parse(["wrong": []], gateway: true) }
expectFailure { _ = try CLI.parse(["requests": [["id":"x"]]], gateway: false) }
let literals = ["spaces in argument", "$(touch /tmp/openclaw-access-should-not-exist)", "'quoted'", "; exit 1", "line\nbreak"]
let returned = try CLI.object(client("arguments").run(literals))
assert(returned["args"] as? [String] == literals)
let start = Date()
expectFailure { _ = try client("timeout").run([], timeout: 0.3) }
assert(Date().timeIntervalSince(start) < 5)

// Scheduled jobs
func plan(_ expr: String) -> CronPlan { guard let plan = Cron.plan(expr) else { fatalError("Expected a plan for \(expr)") }; return plan }
func cron(_ expr: String, tz: String = "") -> Schedule { Schedule(["kind": "cron", "expr": expr, "tz": tz]) }
assert(plan("0 8 * * 1").simple && plan("0 8 * * 1").days == [1] && plan("0 8 * * 1").hours == [8])
assert(plan("00 08 * * MON") == plan("0 8 * * 1") && plan("0 8 * * 7").days == [0])
assert(plan("*/15 9-17 * * mon-fri").minutes == [0, 15, 30, 45] && plan("*/15 9-17 * * mon-fri").hours.count == 9)
assert(!plan("0 8,14 * * *").simple && !plan("0 9 1 * *").simple && !plan("0 0 8 * * 1").simple)
assert(plan("30 0 8 * * 1") != plan("0 0 8 * * 1"))
for bad in ["", "0 8 * *", "0 8 L * *", "0 8 * * 1#2", "0 24 * * *", "0 8-3 * * *", "0 8 * * 1 2 3", "x 8 * * *", "0 8 * * 5-1"] { assert(Cron.plan(bad) == nil, bad) }
assert(Cron.describe(cron("0 8 * * 1")) == "Mondays at 8:00 AM")
assert(Cron.describe(cron("0 3 * * 1")) == "Mondays at 3:00 AM")
assert(Cron.describe(cron("30 14 * * 1-5")) == "Weekdays at 2:30 PM")
assert(Cron.describe(cron("0 0 * * *")) == "Every day at 12:00 AM")
assert(Cron.describe(cron("0 12 * * 0,6")) == "Weekends at 12:00 PM")
assert(Cron.describe(cron("0 8,14 * * 1,3,5")) == "Mon, Wed, Fri at 8:00 AM, 2:00 PM")
assert(Cron.describe(cron("5 * * * *")) == "Every hour at :05")
assert(Cron.describe(cron("*/15 * * * *")) == "Every 15 minutes")
assert(Cron.describe(cron("0 9 1 * *")) == "Day 1 of each month at 9:00 AM")
assert(Cron.describe(cron("0 9 1 */3 *")) == "Custom schedule" && Cron.describe(cron("0 8 L * *")) == "Custom schedule")
assert(Cron.describe(Schedule(["kind": "every", "everyMs": 1_800_000])) == "Every 30 minutes")
assert(Cron.describe(Schedule(["kind": "every", "everyMs": 3_600_000])) == "Every hour")
assert(Cron.describe(Schedule(["kind": "every", "everyMs": 172_800_000])) == "Every 2 days")
assert(Cron.expression(hour: 3, minute: 0, days: [1]) == "0 3 * * 1")
assert(Cron.expression(hour: 15, minute: 45, days: [1, 2, 3, 4, 5]) == "45 15 * * 1-5")
assert(Cron.expression(hour: 6, minute: 5, days: Set(0...6)) == "5 6 * * *")
assert(Cron.dayField([0, 1, 3, 4, 5, 6]) == "0,1,3-6" && Cron.dayField([0, 6]) == "0,6")
for days: Set<Int> in [[1], [0, 6], [1, 2, 3, 4, 5], [0, 2, 4], Set(0...6)] { assert(plan(Cron.expression(hour: 3, minute: 0, days: days)).days == days) }
// A time in another zone lands on this Mac's clock; crossing midnight moves the day too.
assert(Cron.slots(cron("0 8 * * 1"), shift: 0) == [Slot(day: 1, hour: 8)])
assert(Cron.slots(cron("30 8 * * 1"), shift: 60) == [Slot(day: 1, hour: 9)])
assert(Cron.slots(cron("0 1 * * 1"), shift: -120) == [Slot(day: 0, hour: 23)])
assert(Cron.slots(cron("0 23 * * 6"), shift: 90) == [Slot(day: 0, hour: 0)])
assert(Cron.slots(cron("0 9 1 * *"), shift: 0).isEmpty && Cron.slots(cron("0 9 * 1 1"), shift: 0).isEmpty && Cron.slots(cron("0 * * * *"), shift: 0).isEmpty)
assert(Cron.slots(Schedule(["kind": "every", "everyMs": 60_000]), shift: 0).isEmpty)

let jobs = try normal.jobs()
assert(jobs.map(\.id) == ["test-monday-report", "test-interval", "test-paused"])
let report = jobs[0]
assert(report.name == "Test fixture: Monday report" && report.enabled && report.revision == "rev-1" && report.status == "ok")
assert(report.schedule.tz == "America/Chicago" && report.schedule.staggerMs == 0 && report.next == Date(timeIntervalSince1970: 1_759_150_800))
assert(jobs[1].revision == nil && jobs[1].schedule.everyMs == 1_800_000 && jobs[1].task == "Test fixture event" && !jobs[2].enabled)
let paged = try client("paged").jobs()
assert(paged.map(\.id) == jobs.map(\.id))
// The fixture checks the exact request: only the schedule changes, with its time zone, stagger, and revision passed through.
var moved = report.schedule
moved.expr = "0 3 * * 1"
let saved = try normal.apply(.schedule(moved), to: report)
assert(saved.schedule.expr == "0 3 * * 1" && saved.schedule.tz == "America/Chicago" && saved.revision == "rev-1+")
var slower = jobs[1].schedule
slower.everyMs = 3_600_000
let slowed = try normal.apply(.schedule(slower), to: jobs[1])
assert(slowed.schedule == slower && slowed.revision == nil)
let paused = try normal.apply(.enabled(false), to: report), resumed = try normal.apply(.enabled(true), to: jobs[2])
assert(!paused.enabled && resumed.enabled)
expectFailure { _ = try client("conflict").apply(.schedule(moved), to: report) }
expectFailure { _ = try client("auth-failure").jobs() }
expectFailure { _ = try client("no-jobs").jobs() }
expectFailure { _ = try normal.apply(.schedule(Schedule(["kind": "at", "at": "2026-10-05T08:00:00Z"])), to: report) }
expectFailure { _ = try Job(["id": "x", "schedule": ["kind": "cron", "expr": "0 8 * * 1"]]) }
expectFailure { _ = try Job(["name": "No id", "enabled": true, "schedule": ["kind": "cron"]]) }

// Stateful round trip: three jobs pile up Monday at 8 AM; moving one to 3 AM is what OpenClaw reports back afterward.
let state = URL(fileURLWithPath: fixture).deletingLastPathComponent().appendingPathComponent("../build/tests/fixture-state.json").standardizedFileURL
try? FileManager.default.removeItem(at: state)
let demo = try client("schedules").jobs()
let before = Cron.load(demo, shift: { _ in 0 })
assert(before[Slot(day: 1, hour: 8)]?.map(\.id) == ["fx-1", "fx-2", "fx-3", "fx-4"] && before[Slot(day: 2, hour: 8)]?.count == 1)
assert(before[Slot(day: 1, hour: 3)] == nil && before[Slot(day: 1, hour: 17)] == nil)   // Paused jobs are not counted.
assert(before.values.filter { $0.count >= Cron.busy }.count == 1)
assert(!before.values.contains { $0.contains { ["fx-7", "fx-8", "fx-10"].contains($0.id) } })
assert(demo.first { $0.id == "fx-10" }?.managed == true && demo.first { $0.id == "fx-6" }?.problem.isEmpty == false)
for id in ["fx-1", "fx-2"] {
    guard let job = try client("schedules").jobs().first(where: { $0.id == id }) else { fatalError("Missing \(id)") }
    var next = job.schedule
    next.expr = Cron.expression(hour: id == "fx-1" ? 3 : 4, minute: 0, days: [1])
    _ = try client("schedules").apply(.schedule(next), to: job)
}
let after = Cron.load(try client("schedules").jobs(), shift: { _ in 0 })
assert(after[Slot(day: 1, hour: 8)]?.map(\.id) == ["fx-3", "fx-4"] && after[Slot(day: 1, hour: 3)]?.map(\.id) == ["fx-1"] && after[Slot(day: 1, hour: 4)]?.map(\.id) == ["fx-2"])
assert(!after.values.contains { $0.count >= Cron.busy })
try? FileManager.default.removeItem(at: state)
print("PASS: gateway list/approve/dismiss, legacy fallback and approval, authentication failure, schema validation, literal arguments, process timeout, schedule parsing and wording, busy-hour counts, job list paging, schedule and pause changes, change conflict")
