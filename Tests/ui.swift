import SwiftUI
import AppKit

// Clicks through the real views against the test fixture and writes a PNG of each state for review.
// The window is transparent and off every display, and the app is never activated, so nothing shows on screen.
// Click positions are points from the top-left of the content and follow the current layout; update them when it changes.
setvbuf(stdout, nil, _IONBF, 0)
let repo = CommandLine.arguments[1], out = CommandLine.arguments[2], scenario = CommandLine.arguments[3]
let state = "\(repo)/build/tests/fixture-state.json"
UserDefaults.standard.set(scenario == "missing" ? "/nonexistent/openclaw" : "\(repo)/Tests/fixture.py", forKey: "executable")
UserDefaults.standard.set(scenario == "conflict" ? "conflict" : "schedules", forKey: "profile")
UserDefaults.standard.set("", forKey: "account")
try? FileManager.default.removeItem(atPath: state)

// Reports itself as active and key so views treat clicks as real clicks rather than a first click on an inactive window.
final class TestApp: NSApplication { override var isActive: Bool { true } }
final class TestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}
let app = TestApp.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: scenario == "dark" ? .darkAqua : .aqua)
app.finishLaunching()

// Dispatch queued events and main-actor work, as the app's own run loop would.
func pump(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) { app.sendEvent(event) }
    }
}
func open(_ width: CGFloat, _ height: CGFloat) -> NSWindow {
    let window = TestWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: ContentView().background(Color(nsColor: .windowBackgroundColor)))
    window.setContentSize(NSSize(width: width, height: height))
    window.alphaValue = 0
    window.orderFrontRegardless()
    return window
}
func click(_ x: CGFloat, _ y: CGFloat, times: Int = 1, wait: TimeInterval = 0.5) {
    let point = NSPoint(x: x, y: (window.contentView?.bounds.height ?? 0) - y)
    func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    for _ in 0..<times {
        // Controls that track the mouse wait for the release in the queue, so it is queued before the press is delivered.
        app.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        pump(times > 1 ? 0.25 : wait)
    }
}
func save(_ rep: NSBitmapImageRep, _ name: String) {
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(scenario)-\(name).png"))
    print("  \(scenario)-\(name).png")
}
func shoot(_ name: String, crop: NSRect? = nil) {
    guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    if let crop, let cut = rep.cgImage?.cropping(to: CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)) { save(NSBitmapImageRep(cgImage: cut), name) } else { save(rep, name) }
}
// Replaces the text of the field that was just clicked, as typing over a selection would.
func type(_ text: String, commit: Bool = false) {
    guard let editor = window.firstResponder as? NSTextView else { fatalError("No text field has focus for \(text)") }
    editor.selectAll(nil)
    editor.insertText(text, replacementRange: editor.selectedRange())
    if commit { editor.insertNewline(nil) }
    pump(0.5)
}
// Confirmation alerts are sheets on the window: record the text, save a picture, and press a button by its title.
func confirm(_ name: String, expect: String, press title: String) {
    var texts: [String] = [], buttons: [NSButton] = []
    func visit(_ view: NSView) {
        if let button = view as? NSButton { buttons.append(button) } else if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
        view.subviews.forEach(visit)
    }
    guard let content = window.attachedSheet?.contentView else { fatalError("\(name): no confirmation appeared") }
    visit(content)
    print("  confirmation: \(texts.joined(separator: " / ").replacingOccurrences(of: "\n", with: " / "))")
    guard texts.contains(where: { $0.contains(expect) }) else { fatalError("\(name): expected \(expect)") }
    if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) { content.cacheDisplay(in: content.bounds, to: rep); save(rep, name) }
    guard let button = buttons.first(where: { $0.title == title }) else { fatalError("\(name): no \(title) button") }
    button.performClick(nil)
    pump(4)
}
// What the fixture holds after a change, read back from its state file.
func stored(_ id: String) -> [String: Any] {
    let rows = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: state)))) as? [[String: Any]] ?? []
    return rows.first { $0["id"] as? String == id } ?? [:]
}

let small = scenario == "min"
let window = open(small ? 780 : 940, small ? 700 : scenario == "type" ? 1180 : 780)
let right = window.contentView!.bounds.width
pump(4)
if scenario == "edit" { shoot("01-access") }
click(right - 244, 45, wait: 4)                       // Schedules
shoot("02-schedules")
if scenario == "missing" { exit(0) }

if scenario == "conflict" {
    click(150, 354)                                   // First job
    click(455, 587); click(513, 592, times: 5)        // Hour, then step down from 8 to 3
    click(843, 709)                                   // Save schedule
    confirm("03-confirm", expect: "New: Mondays at 3:00 AM", press: "Save")
    shoot("04-rejected")
    exit(0)
}

if scenario == "type" {
    let pane = NSRect(x: 341, y: 302, width: 599, height: 420)
    click(150, 354 + 72 * 7)                          // Quarterly job, which opens in Advanced
    click(676, 529); type("0 6 * * 1-5")
    shoot("03-expression", crop: pane)
    click(676, 529); type("0 8 L * *")
    shoot("04-unreadable", crop: pane)
    click(561, 563); type("Mars/Phobos")
    shoot("05-bad-zone", crop: pane)
    click(150, 354 + 72 * 6)                          // Interval job
    click(441, 522); type("45", commit: true)
    shoot("06-interval", crop: pane)
    exit(0)
}

click(small ? 309 : 362, 152)                         // Monday 8 AM in the busy-hours map
shoot("03-busy-hour")
click(150, 350)                                       // First job in that hour
shoot("04-job")
if scenario != "edit" { exit(0) }

click(455, 587); click(513, 592, times: 5)            // Hour, then step down from 8 to 3
shoot("05-edit")
click(843, 709)                                       // Save schedule
confirm("06-confirm", expect: "New: Mondays at 3:00 AM", press: "Save")
shoot("07-saved")
guard (stored("fx-1")["schedule"] as? [String: Any])?["expr"] as? String == "0 3 * * 1" else { fatalError("The saved schedule did not reach the fixture") }

// The saved notice adds a line above the map, so everything below sits 28 points lower from here on.
click(right - 45, 142)                                // Clear the focused hour
window.setContentSize(NSSize(width: 940, height: 1180))
pump(0.5)
shoot("08-all-jobs")
let pane = NSRect(x: 341, y: 330, width: 599, height: 470)
func row(_ index: Int) { click(150, CGFloat(382 + 72 * index)) }
for (index, name) in [(5, "09-failed-job"), (6, "10-interval"), (7, "11-custom"), (9, "12-managed")] { row(index); shoot(name, crop: pane) }
row(4)                                                // Nightly job at 2:30 AM
click(457, 590); click(513, 586, times: 6)            // Hour, then step up from 2 to 8
shoot("13-busy-warning", crop: pane)
row(5)                                                // Friday job
click(671, 557)                                       // Turn Friday off, leaving no days
shoot("14-no-days", crop: pane)
row(8)                                                // Paused job
shoot("15-paused", crop: pane)
click(406, 663)                                       // Resume job
confirm("16-confirm-resume", expect: "will run on its schedule again", press: "Resume")
shoot("17-resumed")
guard stored("fx-9")["enabled"] as? Bool == true else { fatalError("The resume did not reach the fixture") }
guard (stored("fx-5")["schedule"] as? [String: Any])?["expr"] as? String == "30 2 * * *" else { fatalError("An unsaved edit changed the fixture") }
try? FileManager.default.removeItem(atPath: state)
print("PASS: schedule edit and resume clicked through the UI and confirmed in the fixture")
