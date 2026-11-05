import AppKit
import CoreGraphics

// Opt-in diagnostics for real WindowServer/input checks. Never enabled in normal play.
enum InteractiveInputTrace {
    static let enabled = CommandLine.arguments.contains("--interactive-test") && CommandLine.arguments.contains("--input-trace")
    static func record(_ kind: String, _ fields: [String: Any] = [:]) {
        guard enabled else { return }
        var event = fields
        event["event"] = kind
        event["uptime"] = ProcessInfo.processInfo.systemUptime
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print("INPUT \(text)")
        fflush(stdout)
    }
}

// Capture is opt-in and belongs to this window only. SystemCursorBackend is
// never used by the state tests, so a failed test cannot trap the real pointer.
protocol CursorCaptureBackend: AnyObject {
    func capture(at point: CGPoint) -> Bool
    func release()
    func captureContext(in view: NSView) -> (inside: Bool, active: Bool)
}

extension CursorCaptureBackend {
    func captureContext(in view: NSView) -> (inside: Bool, active: Bool) {
        guard let window = view.window else { return (false, false) }
        let pointer = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return (view.visibleRect.contains(pointer), window.isKeyWindow && NSApp.isActive)
    }
}

final class SystemCursorBackend: CursorCaptureBackend {
    func capture(at point: CGPoint) -> Bool {
        let warp = CGWarpMouseCursorPosition(point)
        InteractiveInputTrace.record("cursor-warp", ["result": warp.rawValue, "x": point.x, "y": point.y])
        guard warp == .success else { return false }
        let associate = CGAssociateMouseAndMouseCursorPosition(0)
        InteractiveInputTrace.record("cursor-disassociate", ["result": associate.rawValue])
        guard associate == .success else { return false }
        NSCursor.hide()
        return true
    }
    func release() {
        let associate = CGAssociateMouseAndMouseCursorPosition(1)
        InteractiveInputTrace.record("cursor-reassociate", ["result": associate.rawValue])
        NSCursor.unhide()
    }
}

final class MouseCaptureController {
    private let backend: CursorCaptureBackend
    private(set) var isCaptured = false
    var onChange: ((Bool) -> Void)?

    init(backend: CursorCaptureBackend = SystemCursorBackend()) { self.backend = backend }

    @discardableResult
    func toggle(pointerInside: Bool, windowActive: Bool, anchor: CGPoint) -> Bool {
        if isCaptured { release(); return true }
        guard pointerInside, windowActive, backend.capture(at: anchor) else { return false }
        isCaptured = true
        onChange?(true)
        return true
    }

    func release() {
        guard isCaptured else { return }
        isCaptured = false
        backend.release()
        onChange?(false)
    }

    deinit { release() }
}

func isMouseCaptureShortcut(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
    let modifiers = flags.intersection([.control, .option, .command, .shift])
    return (keyCode == 100 && modifiers.isEmpty) ||
        (keyCode == 46 && modifiers == [.control, .option])
}

// AppKit screen points have a bottom-left origin on the primary display;
// Quartz has a top-left origin there. A global flip also handles displays
// above or to the left, unlike flipping against the window's current screen.
func quartzCursorPoint(_ point: NSPoint, primaryTop: CGFloat) -> CGPoint {
    CGPoint(x: point.x, y: primaryTop - point.y)
}

func mouseCaptureSelfTest() throws {
    final class TestBackend: CursorCaptureBackend {
        var captures: [CGPoint] = []
        var releases = 0
        var succeeds = true
        func capture(at point: CGPoint) -> Bool { captures.append(point); return succeeds }
        func release() { releases += 1 }
    }
    func check(_ ok: Bool, _ message: String) throws {
        if !ok { throw NSError(domain: "MouseCaptureTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let backend = TestBackend()
    let controller = MouseCaptureController(backend: backend)
    let anchor = CGPoint(x: 300, y: 250)
    try check(!controller.isCaptured, "Initial pointer must be released")
    try check(!controller.toggle(pointerInside: false, windowActive: true, anchor: anchor), "Outside shortcut must not capture")
    try check(!controller.toggle(pointerInside: true, windowActive: false, anchor: anchor), "Inactive window must not capture")
    try check(backend.captures.isEmpty, "Rejected capture must not touch the system cursor")
    try check(controller.toggle(pointerInside: true, windowActive: true, anchor: anchor) && controller.isCaptured, "Inside explicit shortcut captures")
    try check(backend.captures == [anchor], "Capture uses the converted window center")
    try check(controller.toggle(pointerInside: false, windowActive: false, anchor: anchor) && !controller.isCaptured, "Release must work regardless of pointer location")
    controller.release()
    try check(backend.releases == 1, "Repeated release must not over-unhide the cursor")
    backend.succeeds = false
    try check(!controller.toggle(pointerInside: true, windowActive: true, anchor: anchor) && !controller.isCaptured, "Failed capture remains released")
    controller.release()
    try check(backend.releases == 1, "Failed capture must not unhide an unowned cursor")
    backend.succeeds = true
    _ = controller.toggle(pointerInside: true, windowActive: true, anchor: anchor)
    controller.release() // Same path used for window/application deactivation.
    try check(backend.releases == 2 && !controller.isCaptured, "Focus loss releases owned capture")
    try check(quartzCursorPoint(NSPoint(x: -500, y: 1200), primaryTop: 900) == CGPoint(x: -500, y: -300), "Upper-left secondary display conversion")
    try check(quartzCursorPoint(NSPoint(x: 1700, y: -200), primaryTop: 900) == CGPoint(x: 1700, y: 1100), "Lower-right secondary display conversion")
    try check(isMouseCaptureShortcut(keyCode: 100, flags: [.function]), "F8 shortcut")
    try check(isMouseCaptureShortcut(keyCode: 46, flags: [.control, .option]), "Control-Option-M shortcut")
    try check(!isMouseCaptureShortcut(keyCode: 46, flags: []) && !isMouseCaptureShortcut(keyCode: 46, flags: [.command]), "Ordinary M and Command-M do not capture")
    print("PASS: mouse capture opt-in, inside/active gate, release and failure cleanup, balanced cursor ownership, multi-display coordinates, shortcuts")
}
