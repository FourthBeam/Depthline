import AppKit

/// Windowed-play reminder, dismissed for this entry after the first successful capture.
final class DepthlineEntryPrompt: NSView {
    private var hasCaptured = false
    private var widthConstraint: NSLayoutConstraint?
    private let headingFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
    private let shortcutFont = NSFont.systemFont(ofSize: 12.5)
    private var heading: String { DLoc.text("移入画面，按 F8 锁定鼠标", "Point inside and press F8") }
    private var shortcut: String { DLoc.text("媒体键模式可按 Fn + F8，也可按 ⌃⌥M", "Also locks with Fn + F8 or ⌃⌥M.") }
    private var panelWidth: CGFloat {
        let headingWidth = (heading as NSString).size(withAttributes: [.font: headingFont]).width
        let shortcutWidth = (shortcut as NSString).size(withAttributes: [.font: shortcutFont]).width
        return max(332, 102 + ceil(max(headingWidth, shortcutWidth)))
    }

    init() {
        super.init(frame: .zero)
        identifier = .init("gameplay-capture-prompt")
        setAccessibilityElement(true)
        setAccessibilityIdentifier("gameplay-capture-prompt")
        setAccessibilityRole(.staticText)
        refreshLanguage()
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("Programmatic overlay") }

    func refreshLanguage() {
        widthConstraint?.constant = panelWidth
        setAccessibilityLabel(DLoc.text("将指针移入游戏画面，按 F8 锁定鼠标。也可按 Control Option M。",
                                        "Move the pointer into the game, then press F8 or Control Option M to lock it."))
        needsDisplay = true
    }

    func attach(to host: NSView) {
        guard superview !== host else { return }
        host.addSubview(self)
        translatesAutoresizingMaskIntoConstraints = false
        let width = widthAnchor.constraint(equalToConstant: panelWidth)
        widthConstraint = width
        NSLayoutConstraint.activate([
            width,
            heightAnchor.constraint(equalToConstant: 76),
            centerXAnchor.constraint(equalTo: host.centerXAnchor),
            topAnchor.constraint(equalTo: host.centerYAnchor, constant: 55)
        ])
    }

    func reset() {
        hasCaptured = false
        isHidden = true
    }

    func update(windowed: Bool, active: Bool, captured: Bool) {
        if captured { hasCaptured = true }
        let hidden = !windowed || !active || hasCaptured
        if isHidden != hidden { isHidden = hidden }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        NSColor(srgbRed: 0.035, green: 0.07, blue: 0.079, alpha: 0.94).setFill()
        panel.fill()
        let gold = NSColor(srgbRed: 0.94, green: 0.81, blue: 0.51, alpha: 1)
        gold.withAlphaComponent(0.55).setStroke()
        panel.stroke()
        let key = NSBezierPath(roundedRect: NSRect(x: 15, y: 16, width: 55, height: 44), xRadius: 5, yRadius: 5)
        gold.setFill()
        key.fill()
        ("F8" as NSString).draw(at: .init(x: 27, y: 24), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 23, weight: .bold), .foregroundColor: NSColor.black
        ])
        (heading as NSString).draw(at: .init(x: 84, y: 14), withAttributes: [
            .font: headingFont, .foregroundColor: NSColor.white
        ])
        (shortcut as NSString).draw(at: .init(x: 84, y: 42), withAttributes: [
            .font: shortcutFont, .foregroundColor: NSColor(white: 0.83, alpha: 1)
        ])
    }
}
