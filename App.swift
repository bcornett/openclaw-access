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

struct ContentView: View {
    @StateObject private var model = Model()
    @AppStorage("executable") private var executable = ""
    @AppStorage("profile") private var profile = ""
    @AppStorage("account") private var account = ""
    @State private var settings = false
    @State private var selected: String?
    @State private var pending: AccessRequest?
    @State private var approving = true
    private var config: Configuration { Configuration(executable: executable.trimmingCharacters(in: .whitespacesAndNewlines), profile: profile.trimmingCharacters(in: .whitespacesAndNewlines), account: account.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "person.badge.key.fill").font(.system(size: 34)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Slack access requests").font(.title2.bold())
                    Text("OpenClaw · \(profile.isEmpty ? "Default profile" : profile)").foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { model.refresh(config) } label: { Label("Refresh", systemImage: "arrow.clockwise") }.keyboardShortcut("r").disabled(model.busy || settings)
                Button { settings.toggle() } label: { Image(systemName: "gearshape") }.help("Connection settings").disabled(model.busy)
            }.padding(24)
            Divider()
            if let error = model.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Couldn’t complete the request", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                    ScrollView { Text(error).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 115)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08))
            }
            if !model.notice.isEmpty { Label(model.notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green).padding(.horizontal, 24).padding(.top, 12) }
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
            Divider()
            HStack {
                Text(model.loaded ? "\(model.requests.count) pending" : "Not connected")
                if !model.gateway && model.loaded { Text("· Older OpenClaw: approval only") }
                Spacer()
                if let last = model.lastRefresh { Text("Updated \(last.formatted(date: .omitted, time: .shortened))") }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
        }.frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: $settings) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connection settings").font(.headline)
                    Text("Uses the current Mac user’s OpenClaw configuration and credentials. Run this app on the client Mac that has OpenClaw configured.").foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow { Text("Executable"); TextField("Automatic (openclaw)", text: $executable); Button("Browse…", action: browse) }
                        GridRow { Text("Profile"); TextField("Default", text: $profile) }
                        GridRow { Text("Account"); TextField("All Slack accounts", text: $account) }
                    }.textFieldStyle(.roundedBorder)
                    Button("Save and connect") { settings = false; selected = nil; model.refresh(config) }.buttonStyle(.borderedProminent)
                }.padding(24)
                .frame(width: 660)
        }
        .onChange(of: config) { _ in model.requests = []; model.loaded = false; selected = nil }
        .task { model.refresh(config) }
        .alert(approving ? "Approve Slack access?" : "Dismiss this request?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { request in
            Button("Cancel", role: .cancel) { pending = nil }
            Button(approving ? "Approve" : "Dismiss", role: approving ? nil : .destructive) { model.act(request, approve: approving, config: config); pending = nil }
        } message: { request in
            Text(approving ? "Grant \(request.sender) access to direct-message this bot?" + (request.gateway ? "" : " Older OpenClaw may also make this user the command owner if none exists.") : "Remove the pending request from \(request.sender)? They can request access again later.")
        }
    }
    func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value.isEmpty ? "Not provided" : value).textSelection(.enabled) }
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

@main struct AccessApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    var body: some Scene {
        WindowGroup("OpenClaw Access") { ContentView() }.defaultSize(width: 880, height: 640)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
