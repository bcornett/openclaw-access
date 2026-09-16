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
print("PASS: gateway list/approve/dismiss, legacy fallback and approval, authentication failure, schema validation, literal arguments, process timeout")
