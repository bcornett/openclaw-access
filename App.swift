import SwiftUI
import AppKit
import Darwin

struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
struct Configuration: Equatable {
    var executable: String
    var profile: String
    var account: String
    var prefix: [String] { profile.isEmpty ? [] : ["--profile", profile] }
}
struct AccessRequest: Identifiable {
    let id: String
    let sender: String
    let account: String
    let code: String?
    let created: String
    let expires: String
    let metadata: [String: String]
    let gateway: Bool
    var name: String { metadata["name"] ?? metadata["displayName"] ?? metadata["username"] ?? sender }
}
struct Snapshot { let requests: [AccessRequest]; let gateway: Bool }

// Arguments are passed separately, never interpolated into shell source.
struct CLI {
    let config: Configuration
    func run(_ args: [String], timeout: TimeInterval = 35) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let executable = config.executable.isEmpty ? "openclaw" : NSString(string: config.executable).expandingTildeInPath
        process.arguments = ["-lic", "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin\"; exec \"$@\"", "openclaw-access", executable] + config.prefix + args
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        process.environment = env
        try process.run()
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            if output.contains("command not found: openclaw") || output.contains("no such file or directory: openclaw") {
                throw Failure(message: "OpenClaw was not found on this Mac. Install this app on the Mac running OpenClaw, or choose its executable in Connection settings.")
            }
            throw Failure(message: output.isEmpty ? "OpenClaw stopped or timed out. Refresh before retrying an action." : String(output.prefix(5000)))
        }
        return output
    }
    static func object(_ output: String) throws -> [String: Any] {
        // Ignore startup notices, but only accept a complete JSON object with whitespace after it.
        for index in output.indices where output[index] == "{" {
            if let data = output[index...].data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        }
        throw Failure(message: "OpenClaw did not return valid JSON. Check its version and connection settings.")
    }
    func rpc(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        return try Self.object(run(["gateway", "call", method, "--params", String(decoding: data, as: UTF8.self), "--json"]))
    }
    static func parse(_ object: [String: Any], gateway: Bool) throws -> Snapshot {
        guard let rows = object["requests"] as? [[String: Any]] else { throw Failure(message: "Unexpected OpenClaw response: missing requests array.") }
        let requests = try rows.map { row -> AccessRequest in
            let meta = (row[gateway ? "metadata" : "meta"] as? [String: Any] ?? [:]).mapValues { String(describing: $0) }
            guard let id = row[gateway ? "requestId" : "id"] as? String, !id.isEmpty else { throw Failure(message: "OpenClaw returned a request without an ID.") }
            let code = row["code"] as? String
            if !gateway && (code ?? "").isEmpty { throw Failure(message: "OpenClaw returned a request without a pairing code.") }
            return AccessRequest(id: id, sender: row["senderId"] as? String ?? meta["senderId"] ?? id,
                account: row["accountId"] as? String ?? meta["accountId"] ?? "",
                code: code, created: row["createdAt"] as? String ?? "", expires: row["expiresAt"] as? String ?? "",
                metadata: meta, gateway: gateway)
        }
        return Snapshot(requests: requests, gateway: gateway)
    }
    func list() throws -> Snapshot {
        var params: [String: Any] = ["channel": "slack"]
        if !config.account.isEmpty { params["accountId"] = config.account }
        do { return try Self.parse(rpc("channels.pairing.list", params), gateway: true) }
        catch {
            // Only fall back when the method is unsupported. Authentication/network failures stay visible.
            let message = error.localizedDescription.lowercased()
            guard message.contains("unknown method") || message.contains("method not found") || message.contains("unknown command 'call'") else { throw error }
            var args = ["pairing", "list", "slack", "--json"]
            if !config.account.isEmpty { args += ["--account", config.account] }
            return try Self.parse(Self.object(run(args)), gateway: false)
        }
    }
    func act(_ request: AccessRequest, approve: Bool) throws {
        if request.gateway {
            var params: [String: Any] = ["channel": "slack", "accountId": request.account, "requestId": request.id]
            if approve { params["notify"] = false; params["bootstrapCommandOwner"] = false }
            let result = try rpc(approve ? "channels.pairing.approve" : "channels.pairing.dismiss", params)
            guard result["requestId"] as? String == request.id else { throw Failure(message: "The action returned an unexpected response. Refresh to verify the request before retrying.") }
        } else {
            guard approve, let code = request.code else { throw Failure(message: "This OpenClaw version does not support dismissal. Upgrade OpenClaw to use Dismiss.") }
            var args = ["pairing", "approve", "slack", code]
            if !request.account.isEmpty { args += ["--account", request.account] }
            _ = try run(args)
        }
    }
}

// Scheduled jobs use OpenClaw's cron.list and cron.update gateway methods. Only the fields below are read or written.
struct Schedule: Equatable {
    var kind = ""
    var expr = ""
    var tz = ""            // Empty means the gateway host's time zone.
    var staggerMs: Int?
    var everyMs = 0
    var anchorMs: Int?
    var at = ""
    init(_ row: [String: Any]) {
        kind = row["kind"] as? String ?? ""
        expr = (row["expr"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        tz = (row["tz"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        staggerMs = row["staggerMs"] as? Int
        everyMs = row["everyMs"] as? Int ?? 0
        anchorMs = row["anchorMs"] as? Int
        at = row["at"] as? String ?? ""
    }
    // Clock and interval schedules can be saved. Stagger and anchor go back unchanged.
    var wire: [String: Any]? {
        switch kind {
        case "cron":
            var row: [String: Any] = ["kind": "cron", "expr": expr]
            if !tz.isEmpty { row["tz"] = tz }
            if let staggerMs { row["staggerMs"] = staggerMs }
            return row
        case "every":
            var row: [String: Any] = ["kind": "every", "everyMs": everyMs]
            if let anchorMs { row["anchorMs"] = anchorMs }
            return row
        default: return nil
        }
    }
}
struct Job: Identifiable, Equatable {
    let id: String
    let name: String
    let about: String
    let enabled: Bool
    let schedule: Schedule
    let next: Date?
    let last: Date?
    let status: String
    let problem: String
    let revision: String?
    let payload: String
    let task: String
    // The gateway owns its heartbeat monitor; it is shown but never changed here.
    var managed: Bool { payload == "heartbeat" }
    init(_ row: [String: Any]) throws {
        guard let id = row["id"] as? String, !id.isEmpty else { throw Failure(message: "OpenClaw returned a scheduled job without an ID.") }
        guard let schedule = row["schedule"] as? [String: Any], let enabled = row["enabled"] as? Bool else { throw Failure(message: "OpenClaw returned an incomplete scheduled job (\(id)).") }
        let state = row["state"] as? [String: Any] ?? [:]
        let payload = row["payload"] as? [String: Any] ?? [:]
        func date(_ key: String) -> Date? { ((row[key] as? Double) ?? (state[key] as? Double)).map { Date(timeIntervalSince1970: $0 / 1000) } }
        self.id = id
        name = row["displayName"] as? String ?? row["name"] as? String ?? id
        about = row["description"] as? String ?? ""
        self.enabled = enabled
        self.schedule = Schedule(schedule)
        next = date("nextRunAtMs")
        last = date("lastRunAtMs")
        status = row["lastRunStatus"] as? String ?? state["lastRunStatus"] as? String ?? state["lastStatus"] as? String ?? ""
        problem = row["lastRunError"] as? String ?? state["lastError"] as? String ?? ""
        revision = row["configRevision"] as? String
        self.payload = payload["kind"] as? String ?? ""
        task = payload["message"] as? String ?? payload["text"] as? String ?? (payload["argv"] as? [String])?.joined(separator: " ") ?? payload["script"] as? String ?? ""
    }
}
enum JobChange { case schedule(Schedule), enabled(Bool) }

struct CronPlan: Equatable {
    var minutes: Set<Int>
    var hours: Set<Int>
    var days: Set<Int>      // 0 is Sunday.
    var dates: Set<Int>
    var months: Set<Int>
    var seconds: Set<Int>?  // Present for six-field expressions.
    var anyDate: Bool { dates.count == 31 && months.count == 12 }
    // One clock time on chosen weekdays: the shape the day and time editor can write back.
    var simple: Bool { seconds == nil && anyDate && minutes.count == 1 && hours.count == 1 }
}
struct Slot: Hashable { let day: Int; let hour: Int }

enum Cron {
    static let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let longDays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    static let busy = 3     // Jobs starting in the same hour before that hour is flagged.
    static let kinds = ["cron": "Clock time", "every": "Interval", "at": "One time", "on-exit": "After a command finishes", "stream": "On command output"]
    static let results = ["ok": "OK", "error": "Failed", "skipped": "Skipped"]

    // Plain lists, ranges, and steps only. Anything else (L, #, ?, +) is left to OpenClaw and shown as custom.
    static func field(_ text: String, _ range: ClosedRange<Int>, names: [String] = []) -> Set<Int>? {
        var values = Set<Int>()
        func number(_ token: Substring) -> Int? {
            if let index = names.firstIndex(of: String(token)) { return range.lowerBound + index }
            guard let value = Int(token), range.contains(value) else { return nil }
            return value
        }
        for part in text.uppercased().split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2, let head = pieces.first, !head.isEmpty else { return nil }
            var step = 1
            if pieces.count == 2 { guard let parsed = Int(pieces[1]), parsed > 0 else { return nil }; step = parsed }
            var low = range.lowerBound, high = range.upperBound
            if head != "*" {
                let ends = head.split(separator: "-", omittingEmptySubsequences: false)
                guard ends.count <= 2, let first = number(ends[0]) else { return nil }
                low = first
                if ends.count == 2 { guard let last = number(ends[1]), last >= first else { return nil }; high = last }
                else if pieces.count == 1 { high = first }
            }
            values.formUnion(stride(from: low, through: high, by: step))
        }
        return values.isEmpty ? nil : values
    }
    static func plan(_ expr: String) -> CronPlan? {
        var fields = expr.split(whereSeparator: \.isWhitespace).map(String.init)
        var seconds: Set<Int>?
        if fields.count == 6 { seconds = field(fields.removeFirst(), 0...59); guard seconds != nil else { return nil } }
        guard fields.count == 5, let minutes = field(fields[0], 0...59), let hours = field(fields[1], 0...23),
              let dates = field(fields[2], 1...31), let months = field(fields[3], 1...12, names: Cron.months),
              let days = field(fields[4], 0...7, names: Cron.days.map { $0.uppercased() }) else { return nil }
        return CronPlan(minutes: minutes, hours: hours, days: Set(days.map { $0 % 7 }), dates: dates, months: months, seconds: seconds)
    }
    static func clock(_ hour: Int, _ minute: Int) -> String {
        String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, minute, hour < 12 ? "AM" : "PM")
    }
    static func hourLabel(_ hour: Int) -> String { "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")" }
    static func slotLabel(_ slot: Slot) -> String { "\(days[slot.day]) \(hourLabel(slot.hour))" }
    static func dayPhrase(_ days: Set<Int>) -> String {
        let sorted = days.sorted()
        switch sorted {
        case [0, 1, 2, 3, 4, 5, 6]: return "Every day"
        case [1, 2, 3, 4, 5]: return "Weekdays"
        case [0, 6]: return "Weekends"
        default: return sorted.count == 1 ? "\(longDays[sorted[0]])s" : sorted.map { self.days[$0] }.joined(separator: ", ")
        }
    }
    static func dayField(_ days: Set<Int>) -> String {
        if days.count == 7 { return "*" }
        var runs: [[Int]] = []
        for day in days.sorted() {
            if let last = runs.last?.last, day == last + 1 { runs[runs.count - 1].append(day) } else { runs.append([day]) }
        }
        return runs.map { $0.count > 2 ? "\($0[0])-\($0[$0.count - 1])" : $0.map(String.init).joined(separator: ",") }.joined(separator: ",")
    }
    static func expression(hour: Int, minute: Int, days: Set<Int>) -> String { "\(minute) \(hour) * * \(dayField(days))" }
    static func duration(_ ms: Int) -> String {
        for (size, unit) in [(86_400_000, "day"), (3_600_000, "hour"), (60_000, "minute"), (1000, "second")] where ms >= size && ms % size == 0 {
            return ms == size ? "Every \(unit)" : "Every \(ms / size) \(unit)s"
        }
        return "Every \(ms) ms"
    }
    static func describe(_ schedule: Schedule) -> String {
        switch schedule.kind {
        case "every": return duration(schedule.everyMs)
        case "at":
            let parsed = ISO8601DateFormatter().date(from: schedule.at)
            return "Once, \(parsed?.formatted(date: .abbreviated, time: .shortened) ?? schedule.at)"
        case "on-exit": return "When a watched command finishes"
        case "stream": return "When a watched command prints output"
        case "cron":
            guard let plan = plan(schedule.expr), let minute = plan.minutes.min() else { return "Custom schedule" }
            let single = plan.minutes.count == 1
            if plan.anyDate && single && plan.hours.count <= 4 {
                return "\(dayPhrase(plan.days)) at \(plan.hours.sorted().map { clock($0, minute) }.joined(separator: ", "))"
            }
            if plan.anyDate && plan.hours.count == 24 {
                let every = plan.days.count == 7 ? "Every" : "\(dayPhrase(plan.days)), every"
                if single { return "\(every) hour at :\(String(format: "%02d", minute))" }
                let sorted = plan.minutes.sorted(), step = sorted[1] - sorted[0]
                if minute == 0, 60 % step == 0, sorted == Array(stride(from: 0, to: 60, by: step)) { return step == 1 ? "\(every) minute" : "\(every) \(step) minutes" }
            }
            if single, plan.hours.count == 1, plan.dates.count == 1, plan.months.count == 12, plan.days.count == 7, let date = plan.dates.first, let hour = plan.hours.first {
                return "Day \(date) of each month at \(clock(hour, minute))"
            }
            return "Custom schedule"
        default: return "Unknown schedule"
        }
    }
    // Minutes to add to a job's wall clock to get this Mac's wall clock.
    static func shift(_ tz: String) -> Int {
        guard !tz.isEmpty, let zone = TimeZone(identifier: tz) else { return 0 }
        return (TimeZone.current.secondsFromGMT() - zone.secondsFromGMT()) / 60
    }
    // Weekday and hour of each weekly start. Left out: day-of-month and month rules, which do not fall on a fixed weekday,
    // and jobs that run in more than half the hours of a day, which would mark every hour.
    static func slots(_ schedule: Schedule, shift: Int) -> Set<Slot> {
        guard schedule.kind == "cron", let plan = plan(schedule.expr), plan.anyDate, plan.hours.count <= 12 else { return [] }
        var result = Set<Slot>()
        for day in plan.days { for hour in plan.hours { for minute in plan.minutes {
            let total = ((day * 1440 + hour * 60 + minute + shift) % 10080 + 10080) % 10080
            result.insert(Slot(day: total / 1440, hour: total % 1440 / 60))
        } } }
        return result
    }
    static func load(_ jobs: [Job], shift: (String) -> Int = Cron.shift) -> [Slot: [Job]] {
        var map: [Slot: [Job]] = [:]
        for job in jobs where job.enabled { for slot in slots(job.schedule, shift: shift(job.schedule.tz)) { map[slot, default: []].append(job) } }
        return map
    }
}

extension CLI {
    func jobs() throws -> [Job] {
        var all: [Job] = [], offset = 0
        // Older gateways return every job at once. Newer ones page and say so with hasMore.
        for _ in 0..<100 {
            var params: [String: Any] = ["includeDisabled": true]
            if offset > 0 { params["offset"] = offset }
            let page = try rpc("cron.list", params)
            guard let rows = page["jobs"] as? [[String: Any]] else { throw Failure(message: "Unexpected OpenClaw response: missing jobs array.") }
            for job in try rows.map(Job.init) where !all.contains(where: { $0.id == job.id }) { all.append(job) }
            guard page["hasMore"] as? Bool == true else { return all }
            guard let next = page["nextOffset"] as? Int, next > offset else { throw Failure(message: "OpenClaw returned an incomplete list of scheduled jobs. Refresh to try again.") }
            offset = next
        }
        throw Failure(message: "OpenClaw returned too many pages of scheduled jobs.")
    }
    func apply(_ change: JobChange, to job: Job) throws -> Job {
        var patch: [String: Any] = [:]
        switch change {
        case .enabled(let enabled): patch["enabled"] = enabled
        case .schedule(let schedule):
            guard let wire = schedule.wire else { throw Failure(message: "This kind of schedule cannot be changed here.") }
            patch["schedule"] = wire
        }
        var params: [String: Any] = ["id": job.id, "patch": patch]
        // The gateway rejects the change if the job was edited elsewhere after it was loaded here.
        if let revision = job.revision { params["expectedConfigRevision"] = revision }
        let updated = try Job(rpc("cron.update", params))
        guard updated.id == job.id else { throw Failure(message: "The change returned an unexpected response. Refresh to verify the job before retrying.") }
        return updated
    }
}

@MainActor final class Model: ObservableObject {
    @Published var requests: [AccessRequest] = []
    @Published var busy = false
    @Published var error: String?
    @Published var notice = ""
    @Published var loaded = false
    @Published var gateway = true
    @Published var lastRefresh: Date?
    func refresh(_ config: Configuration, clearNotice: Bool = true) {
        guard !busy else { return }
        busy = true; error = nil
        if clearNotice { notice = "" }
        Task {
            do {
                let snapshot = try await Task.detached { try CLI(config: config).list() }.value
                requests = snapshot.requests; gateway = snapshot.gateway; loaded = true; lastRefresh = Date()
            } catch { self.error = error.localizedDescription; requests = []; loaded = false }
            busy = false
        }
    }
    func act(_ request: AccessRequest, approve: Bool, config: Configuration) {
        guard !busy else { return }
        busy = true; error = nil; notice = ""
        Task {
            do {
                try await Task.detached { try CLI(config: config).act(request, approve: approve) }.value
                notice = "\(approve ? "Approved" : "Dismissed") \(request.sender)."
                busy = false; refresh(config, clearNotice: false)
            } catch {
                self.error = error.localizedDescription
                requests = []; loaded = false; busy = false
            }
        }
    }
}

@MainActor final class ScheduleModel: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var busy = false
    @Published var error: String?
    @Published var notice = ""
    @Published var loaded = false
    @Published var lastRefresh: Date?
    func refresh(_ config: Configuration, clearNotice: Bool = true, keepError: Bool = false) {
        guard !busy else { return }
        busy = true
        if !keepError { error = nil }
        if clearNotice { notice = "" }
        Task {
            do {
                jobs = try await Task.detached { try CLI(config: config).jobs() }.value
                loaded = true; lastRefresh = Date()
            } catch { self.error = error.localizedDescription; jobs = []; loaded = false }
            busy = false
        }
    }
    func apply(_ change: JobChange, to job: Job, notice text: String, config: Configuration) {
        guard !busy else { return }
        busy = true; error = nil; notice = ""
        Task {
            do {
                _ = try await Task.detached { try CLI(config: config).apply(change, to: job) }.value
                notice = text
                busy = false; refresh(config, clearNotice: false)
            } catch {
                // A rejected change (a mistyped expression, or a job edited elsewhere) keeps its message and reloads what OpenClaw has now.
                self.error = error.localizedDescription
                busy = false; refresh(config, keepError: true)
            }
        }
    }
}

enum Pane { case access, schedules }

func detail(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value.isEmpty ? "Not provided" : value).textSelection(.enabled) }
}

struct ContentView: View {
    @StateObject private var model = Model()
    @StateObject private var schedules = ScheduleModel()
    @AppStorage("executable") private var executable = ""
    @AppStorage("profile") private var profile = ""
    @AppStorage("account") private var account = ""
    @State private var pane = Pane.access
    @State private var settings = false
    @State private var selected: String?
    @State private var pending: AccessRequest?
    @State private var approving = true
    private var config: Configuration { Configuration(executable: executable.trimmingCharacters(in: .whitespacesAndNewlines), profile: profile.trimmingCharacters(in: .whitespacesAndNewlines), account: account.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var busy: Bool { model.busy || schedules.busy }
    private func refresh() { if pane == .access { model.refresh(config) } else { schedules.refresh(config) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: pane == .access ? "person.badge.key.fill" : "calendar.badge.clock").font(.system(size: 34)).foregroundStyle(.blue).frame(width: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pane == .access ? "Slack access requests" : "Scheduled jobs").font(.title2.bold())
                    Text("OpenClaw · \(profile.isEmpty ? "Default profile" : profile)").foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Picker("View", selection: $pane) { Text("Access requests").tag(Pane.access); Text("Schedules").tag(Pane.schedules) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().disabled(busy || settings)
                Button { refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.keyboardShortcut("r").disabled(busy || settings)
                Button { settings.toggle() } label: { Image(systemName: "gearshape") }.help("Connection settings").disabled(busy)
            }.padding(24)
            Divider()
            if let error = pane == .access ? model.error : schedules.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Couldn’t complete the request", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                    ScrollView { Text(error).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 115)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08))
            }
            if !(pane == .access ? model.notice : schedules.notice).isEmpty {
                Label(pane == .access ? model.notice : schedules.notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green).padding(.horizontal, 24).padding(.top, 12)
            }
            if pane == .access { requests } else { SchedulesView(model: schedules, config: config, locked: settings) { settings = true } }
            Divider()
            HStack {
                if pane == .access {
                    Text(model.loaded ? "\(model.requests.count) pending" : "Not connected")
                    if !model.gateway && model.loaded { Text("· Older OpenClaw: approval only") }
                } else {
                    Text(schedules.loaded ? "\(schedules.jobs.count) scheduled \(schedules.jobs.count == 1 ? "job" : "jobs")" : "Not connected")
                    if schedules.jobs.contains(where: { !$0.enabled }) { Text("· \(schedules.jobs.filter { !$0.enabled }.count) paused") }
                }
                Spacer()
                if let last = pane == .access ? model.lastRefresh : schedules.lastRefresh { Text("Updated \(last.formatted(date: .omitted, time: .shortened))") }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
        }.frame(minWidth: 780, minHeight: 700)
        .sheet(isPresented: $settings) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connection settings").font(.headline)
                    Text("Uses the current Mac user’s OpenClaw configuration and credentials. Run this app on the client Mac that has OpenClaw configured.").foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow { Text("Executable"); TextField("Automatic (openclaw)", text: $executable); Button("Browse…", action: browse) }
                        GridRow { Text("Profile"); TextField("Default", text: $profile) }
                        GridRow { Text("Account"); TextField("All Slack accounts", text: $account) }
                    }.textFieldStyle(.roundedBorder)
                    Button("Save and connect") { settings = false; selected = nil; refresh() }.buttonStyle(.borderedProminent)
                }.padding(24)
                .frame(width: 660)
        }
        .onChange(of: config) { _ in model.requests = []; model.loaded = false; selected = nil; schedules.jobs = []; schedules.loaded = false }
        .onChange(of: pane) { _ in if pane == .access ? !model.loaded : !schedules.loaded { refresh() } }
        .task { model.refresh(config) }
        .alert(approving ? "Approve Slack access?" : "Dismiss this request?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { request in
            Button("Cancel", role: .cancel) { pending = nil }
            Button(approving ? "Approve" : "Dismiss", role: approving ? nil : .destructive) { model.act(request, approve: approving, config: config); pending = nil }
        } message: { request in
            Text(approving ? "Grant \(request.sender) access to direct-message this bot?" + (request.gateway ? "" : " Older OpenClaw may also make this user the command owner if none exists.") : "Remove the pending request from \(request.sender)? They can request access again later.")
        }
    }
    @ViewBuilder private var requests: some View {
        if model.requests.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: model.loaded ? "checkmark.shield" : "network").font(.system(size: 44)).foregroundStyle(.secondary)
                Text(model.loaded ? "No pending requests" : model.busy ? "Connecting to OpenClaw…" : "Connect to OpenClaw").font(.title3.bold())
                Text(model.loaded ? "New Slack DM access requests will appear here when you refresh." : "Your OpenClaw installation supplies the requests and handles access.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !model.loaded && !model.busy { Button("Connection settings") { settings = true } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        } else {
            HSplitView {
                List(model.requests, selection: $selected) { request in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(request.name).font(.headline)
                        Text(request.sender).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        if !request.account.isEmpty { Text(request.account).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 8).tag(request.id)
                }.frame(minWidth: 240, idealWidth: 270, maxWidth: 310)
                if let request = model.requests.first(where: { $0.id == selected }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(request.name).font(.title2.bold())
                            detail("Slack user", request.sender)
                            if !request.account.isEmpty { detail("Account", request.account) }
                            detail("Requested", date(request.created))
                            if !request.expires.isEmpty { detail("Expires", date(request.expires)) }
                            if let code = request.code { detail("Pairing code", code) }
                            ForEach(request.metadata.keys.sorted().filter { $0 != "senderId" && $0 != "accountId" }, id: \.self) { key in detail(key, request.metadata[key] ?? "") }
                            Divider()
                            Text("Approve grants access to direct-message this OpenClaw bot. Dismiss removes this request; it does not permanently block the user.").font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button("Dismiss") { pending = request; approving = false }.disabled(!request.gateway)
                                Spacer()
                                Button("Approve access") { pending = request; approving = true }.buttonStyle(.borderedProminent)
                            }.disabled(model.busy || settings)
                        }.padding(24)
                    }.frame(minWidth: 360)
                } else {
                    Text("Select a request to review").foregroundStyle(.secondary).frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
    func date(_ value: String) -> String {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return parsed?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
    func browse() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { executable = url.path }
    }
}

struct SchedulesView: View {
    @ObservedObject var model: ScheduleModel
    let config: Configuration
    let locked: Bool
    let openSettings: () -> Void
    @State private var selected: String?
    @State private var focus: Slot?
    var body: some View {
        if model.jobs.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: model.loaded ? "calendar" : "network").font(.system(size: 44)).foregroundStyle(.secondary)
                Text(model.loaded ? "No scheduled jobs" : model.busy ? "Connecting to OpenClaw…" : "Connect to OpenClaw").font(.title3.bold())
                Text(model.loaded ? "Jobs scheduled in OpenClaw will appear here when you refresh." : "Your OpenClaw installation supplies the scheduled jobs and runs them.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !model.loaded && !model.busy { Button("Connection settings", action: openSettings) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        } else {
            let load = Cron.load(model.jobs)
            // A focused hour that no longer has jobs (they were moved) falls back to the plain list.
            let slot = focus.flatMap { load[$0] == nil ? nil : $0 }
            let hot = slot.flatMap { load[$0] } ?? []
            // Jobs in the focused hour move to the top and the rest dim. Every job stays in the list, so the selection is never dropped.
            let shown = hot + model.jobs.filter { !hot.contains($0) }
            VStack(spacing: 0) {
                BusyHours(load: load, unmapped: model.jobs.filter { job in job.enabled && !load.values.contains { $0.contains(job) } }.count, focus: Binding(get: { slot }, set: { focus = $0 }))
                Divider()
                HSplitView {
                    List(shown, selection: $selected) { job in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(job.name).font(.headline).lineLimit(1)
                                Text(Cron.describe(job.schedule)).font(.callout).lineLimit(1)
                                Text(job.enabled ? "Next: \(job.next?.formatted(date: .abbreviated, time: .shortened) ?? "not scheduled")" : "Paused").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if job.enabled && load.contains(where: { $0.value.count >= Cron.busy && $0.value.contains(job) }) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Starts in a busy hour")
                            }
                            if job.status == "error" { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help("Last run failed") }
                            if !job.enabled { Image(systemName: "pause.circle").foregroundStyle(.secondary).help("Paused") }
                        }.padding(.vertical, 6).opacity(slot == nil || hot.contains(job) ? 1 : 0.4).tag(job.id)
                    }.frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
                    if let job = model.jobs.first(where: { $0.id == selected }) {
                        JobDetail(job: job, load: load, locked: model.busy || locked) { change, notice in model.apply(change, to: job, notice: notice, config: config) }
                            .id("\(job.id) \(job.schedule.expr) \(job.schedule.tz) \(job.schedule.everyMs)").frame(minWidth: 380)
                    } else {
                        Text("Select a job to see or change when it runs").foregroundStyle(.secondary).frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

// Starts per weekday and hour, so a pile such as Monday at 8 AM is visible before and after a change.
struct BusyHours: View {
    let load: [Slot: [Job]]
    let unmapped: Int
    @Binding var focus: Slot?
    private var summary: String {
        // Ties go to the earliest hour of the week, Monday first, so the text does not jump between refreshes.
        func order(_ slot: Slot) -> Int { (slot.day + 6) % 7 * 24 + slot.hour }
        guard let worst = load.max(by: { ($0.value.count, order($1.key)) < ($1.value.count, order($0.key)) }), worst.value.count >= Cron.busy else { return "No hour has \(Cron.busy) or more jobs starting." }
        return "Busiest: \(Cron.slotLabel(worst.key)), \(worst.value.count) jobs start."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Busy hours").font(.headline)
                Text(focus.map { "\(Cron.slotLabel($0)): \(load[$0]?.count ?? 0) \(load[$0]?.count == 1 ? "job starts" : "jobs start"), listed first." } ?? summary).foregroundStyle(.secondary)
                Spacer()
                if focus != nil { Button("Clear") { focus = nil }.controlSize(.small) }
            }
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    Text("")
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hour % 3 == 0 ? "\(hour % 12 == 0 ? 12 : hour % 12)\(hour < 12 ? "a" : "p")" : "")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize().frame(maxWidth: .infinity, maxHeight: 12, alignment: .leading)
                    }
                }
                ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                    GridRow {
                        Text(Cron.days[day]).font(.caption).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in cell(Slot(day: day, hour: hour)) }
                    }
                }
            }
            Text("Job starts per hour, in this Mac’s time zone. Click an hour to bring its jobs to the top." + (unmapped == 0 ? "" : " \(unmapped) \(unmapped == 1 ? "job runs" : "jobs run") on an interval, monthly, or custom schedule and \(unmapped == 1 ? "is" : "are") not counted."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }
    private func cell(_ slot: Slot) -> some View {
        let jobs = load[slot] ?? []
        let color = jobs.isEmpty ? Color.secondary.opacity(0.1) : jobs.count >= Cron.busy ? Color.orange : Color.blue.opacity(jobs.count == 1 ? 0.3 : 0.55)
        return RoundedRectangle(cornerRadius: 3).fill(color).frame(maxWidth: .infinity).frame(height: 16)
            .overlay { if !jobs.isEmpty { Text("\(jobs.count)").font(.caption2.weight(.semibold)).foregroundStyle(jobs.count >= Cron.busy ? Color.white : Color.primary) } }
            .overlay { if focus == slot { RoundedRectangle(cornerRadius: 3).stroke(Color.primary, lineWidth: 1.5) } }
            .contentShape(Rectangle())
            .onTapGesture { if !jobs.isEmpty { focus = focus == slot ? nil : slot } }
            .help(jobs.isEmpty ? "\(Cron.slotLabel(slot)): no jobs start" : "\(Cron.slotLabel(slot)): \(jobs.map(\.name).joined(separator: ", "))")
    }
}

struct JobDetail: View {
    let job: Job
    let load: [Slot: [Job]]
    let locked: Bool
    let apply: (JobChange, String) -> Void
    @State private var custom: Bool
    @State private var time: Date
    @State private var days: Set<Int>
    @State private var expr: String
    @State private var tz: String
    @State private var every: Int
    @State private var unit: Int
    @State private var confirmSave = false
    @State private var confirmToggle = false
    static let units = [(1000, "seconds"), (60_000, "minutes"), (3_600_000, "hours"), (86_400_000, "days")]
    static let limit = 10_000
    // The picker only carries an hour and minute; a fixed winter date keeps daylight-saving gaps out of it.
    static func clock(_ hour: Int, _ minute: Int) -> Date { Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: hour, minute: minute)) ?? Date() }
    init(job: Job, load: [Slot: [Job]], locked: Bool, apply: @escaping (JobChange, String) -> Void) {
        self.job = job; self.load = load; self.locked = locked; self.apply = apply
        let plan = Cron.plan(job.schedule.expr)
        _custom = State(initialValue: !(plan?.simple ?? false))
        _time = State(initialValue: Self.clock(plan?.hours.min() ?? 3, plan?.minutes.min() ?? 0))
        _days = State(initialValue: plan?.days ?? Set(0...6))
        _expr = State(initialValue: job.schedule.expr)
        _tz = State(initialValue: job.schedule.tz)
        let size = Self.units.last { job.schedule.everyMs >= $0.0 && job.schedule.everyMs % $0.0 == 0 }?.0 ?? 60_000
        _every = State(initialValue: max(1, job.schedule.everyMs / size))
        _unit = State(initialValue: size)
    }
    private var kind: String { job.schedule.kind }
    private var proposed: Schedule {
        var next = job.schedule
        if kind == "cron" {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            next.expr = custom ? expr.split(whereSeparator: \.isWhitespace).joined(separator: " ") : Cron.expression(hour: parts.hour ?? 0, minute: parts.minute ?? 0, days: days)
            next.tz = tz.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if kind == "every" { next.everyMs = min(max(every, 0), Self.limit) * unit }
        return next
    }
    // Expressions that mean the same thing (0 8 * * MON and 0 8 * * 1) do not count as a change.
    private var changed: Bool {
        let next = proposed
        if next.tz != job.schedule.tz || next.everyMs != job.schedule.everyMs { return true }
        guard kind == "cron" else { return false }
        guard let old = Cron.plan(job.schedule.expr), let new = Cron.plan(next.expr) else { return next.expr != job.schedule.expr }
        return old != new
    }
    private var problem: String? {
        if kind == "every" {
            if job.schedule.everyMs % 1000 != 0 { return "This interval is not a whole number of seconds and can’t be changed here." }
            return (1...Self.limit).contains(every) ? nil : "Enter a whole number from 1 to \(Self.limit)."
        }
        if !proposed.tz.isEmpty && TimeZone(identifier: proposed.tz) == nil { return "Use a time zone name such as America/Chicago, or leave it empty." }
        if custom { return proposed.expr.isEmpty ? "Enter a cron expression." : nil }
        return days.isEmpty ? "Choose at least one day." : nil
    }
    private func label(_ schedule: Schedule) -> String {
        guard schedule.kind == "cron" else { return Cron.describe(schedule) }
        return "\(Cron.describe(schedule)) (\(schedule.expr)\(schedule.tz.isEmpty ? "" : ", \(schedule.tz)"))"
    }
    // Short enough for one line of a confirmation alert. The expression stands in when there is no plain wording for it.
    private func brief(_ schedule: Schedule) -> String {
        let text = Cron.describe(schedule), zone = proposed.tz == job.schedule.tz ? "" : ", \(schedule.tz.isEmpty ? "gateway time zone" : schedule.tz)"
        return (text == "Custom schedule" ? schedule.expr : text) + zone
    }
    // The most crowded hour the proposed timing would start in, counting other jobs only.
    private var overlap: (text: String, crowded: Bool)? {
        let slots = Cron.slots(proposed, shift: Cron.shift(proposed.tz))
        guard let worst = slots.map({ slot in (slot, (load[slot] ?? []).filter { $0.id != job.id }.count) }).max(by: { $0.1 < $1.1 }) else { return nil }
        if worst.1 == 0 { return ("No other jobs start in that hour.", false) }
        return ("\(worst.1) other \(worst.1 == 1 ? "job starts" : "jobs start") \(Cron.slotLabel(worst.0)).", worst.1 + 1 >= Cron.busy)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name).font(.title2.bold())
                    if !job.about.isEmpty { Text(job.about).foregroundStyle(.secondary) }
                }
                Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 14) {
                    GridRow {
                        detail("Runs", job.enabled ? Cron.describe(job.schedule) : "Paused · \(Cron.describe(job.schedule))")
                        detail(kind == "cron" ? "Cron expression" : "Kind", kind == "cron" ? "\(job.schedule.expr)\(job.schedule.tz.isEmpty ? "" : " (\(job.schedule.tz))")" : Cron.kinds[kind] ?? kind)
                    }
                    GridRow {
                        detail("Next run", job.next?.formatted(date: .abbreviated, time: .shortened) ?? "Not scheduled")
                        detail("Last run", job.last == nil && job.status.isEmpty ? "No run recorded" : [job.last?.formatted(date: .abbreviated, time: .shortened), Cron.results[job.status] ?? job.status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                }
                Divider()
                if job.managed {
                    Text("OpenClaw manages this job. It cannot be changed here.").font(.callout).foregroundStyle(.secondary)
                } else {
                    editor
                    HStack {
                        Button(job.enabled ? "Pause job" : "Resume job") { confirmToggle = true }
                        Spacer()
                        if kind == "cron" || kind == "every" { Button("Save schedule") { confirmSave = true }.buttonStyle(.borderedProminent).disabled(!changed || problem != nil) }
                    }.disabled(locked)
                }
                if job.status == "error" && !job.problem.isEmpty || !job.task.isEmpty { Divider() }
                if job.status == "error" && !job.problem.isEmpty { detail("Last error", String(job.problem.prefix(400))) }
                if !job.task.isEmpty { VStack(alignment: .leading, spacing: 4) { Text("What it runs").font(.caption).foregroundStyle(.secondary); Text(job.task).lineLimit(3).textSelection(.enabled) } }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        // The two editors stay in step while the expression is one the day and time editor can write. A custom expression is left as typed.
        .onChange(of: custom) { now in
            guard let plan = Cron.plan(expr), plan.simple else { return }
            if now { expr = proposedSimple } else { time = Self.clock(plan.hours.min() ?? 0, plan.minutes.min() ?? 0); days = plan.days }
        }
        .alert("Change this schedule?", isPresented: $confirmSave) {
            Button("Cancel", role: .cancel) {}
            Button("Save") { apply(.schedule(proposed), "Updated \(job.name). New timing: \(brief(proposed)).") }
        } message: { Text("\(job.name)\nNow: \(brief(job.schedule))\nNew: \(brief(proposed))") }
        .alert(job.enabled ? "Pause this job?" : "Resume this job?", isPresented: $confirmToggle) {
            Button("Cancel", role: .cancel) {}
            Button(job.enabled ? "Pause" : "Resume") { apply(.enabled(!job.enabled), "\(job.enabled ? "Paused" : "Resumed") \(job.name).") }
        } message: { Text(job.enabled ? "\(job.name) will not run again until it is resumed." : "\(job.name) will run on its schedule again.") }
    }
    private var proposedSimple: String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return days.isEmpty ? expr : Cron.expression(hour: parts.hour ?? 0, minute: parts.minute ?? 0, days: days)
    }
    @ViewBuilder private var editor: some View {
        if kind == "cron" {
            HStack {
                Text("Change when it runs").font(.headline)
                Spacer()
                Picker("Editor", selection: $custom) { Text("Days and time").tag(false); Text("Advanced").tag(true) }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if custom {
                    GridRow { Text("Cron expression"); TextField("minute hour day month weekday", text: $expr).font(.system(.body, design: .monospaced)) }
                } else {
                    GridRow {
                        Text("Days")
                        HStack(spacing: 4) {
                            ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                                Toggle(Cron.days[day], isOn: Binding(get: { days.contains(day) }, set: { on in if on { days.insert(day) } else { days.remove(day) } })).toggleStyle(.button)
                            }
                        }
                    }
                    GridRow { Text("Time"); DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).labelsHidden().fixedSize() }
                }
                GridRow { Text("Time zone"); TextField("Gateway time zone", text: $tz).frame(maxWidth: 240) }
            }.textFieldStyle(.roundedBorder).disabled(locked)
            if let problem { Text(problem).font(.callout).foregroundStyle(.orange) }
            else if changed {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New: \(label(proposed))").font(.callout)
                    if let overlap { Label(overlap.text, systemImage: overlap.crowded ? "exclamationmark.triangle.fill" : "checkmark.circle").font(.callout).foregroundStyle(overlap.crowded ? .orange : .secondary) }
                    else { Text(Cron.plan(proposed.expr) == nil ? "This app can’t read this expression. OpenClaw checks it when you save." : "This timing is not counted in busy hours.").font(.callout).foregroundStyle(.secondary) }
                }
            }
        } else if kind == "every" {
            Text("Change how often it runs").font(.headline)
            HStack {
                Text("Every")
                TextField("Count", value: $every, format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                Picker("Unit", selection: $unit) { ForEach(Self.units, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().fixedSize()
            }.disabled(locked || job.schedule.everyMs % 1000 != 0)
            if let problem { Text(problem).font(.callout).foregroundStyle(.orange) }
            else if changed { Text("New: \(Cron.describe(proposed))").font(.callout) }
        } else {
            Text("Timing for this kind of job is changed in OpenClaw. It can be paused or resumed here.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

@main struct AccessApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    var body: some Scene {
        WindowGroup("OpenClaw Access") { ContentView() }.defaultSize(width: 940, height: 780)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
