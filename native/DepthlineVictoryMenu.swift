import AppKit

final class DepthlineVictoryMenu: NSView {
    private let sectorLabel = NSTextField(labelWithString: "")
    private let heading = NSTextField(labelWithString: "")
    private let next = LauncherActionButton()
    private let launcher = LauncherActionButton()
    private let onNext: () -> Void
    private let onLauncher: () -> Void

    override var isFlipped: Bool { true }

    init(frame: NSRect, onNext: @escaping () -> Void, onLauncher: @escaping () -> Void) {
        self.onNext = onNext
        self.onLauncher = onLauncher
        super.init(frame: frame)
        isHidden = true
        autoresizingMask = [.width, .height]
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("gameplay-victory")

        for label in [sectorLabel, heading] {
            label.isEditable = false
            label.isSelectable = false
        }
        sectorLabel.alignment = .center
        sectorLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        sectorLabel.textColor = NSColor(srgbRed: 0.92, green: 0.80, blue: 0.54, alpha: 1)
        sectorLabel.setAccessibilityIdentifier("victory-sector")
        addSubview(sectorLabel)

        heading.alignment = .center
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        heading.textColor = .white
        heading.setAccessibilityIdentifier("victory-title")
        addSubview(heading)

        for (button, identifier, action) in [
            (next, "victory-next", #selector(advance)),
            (launcher, "victory-launcher", #selector(leave))
        ] {
            button.isBordered = false
            button.setButtonType(.momentaryPushIn)
            button.focusRingType = .none
            button.cell?.isEditable = false
            button.cell?.isSelectable = false
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(identifier)
            addSubview(button)
        }
        next.primary = true
        next.keyEquivalent = "\r"
        next.nextKeyView = launcher
        launcher.nextKeyView = next
    }

    required init?(coder: NSCoder) { fatalError("Programmatic victory menu") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Keep the AppKit field editor out of the result card. Only the two
        // buttons handle mouse input; labels remain readable to VoiceOver.
        return hit === sectorLabel || hit === heading ? self : hit
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    func show(sector: String, completedLevel: Int) {
        present(sector: sector, title: DLoc.text("第 \(completedLevel) 关完成", "Mission \(completedLevel) Complete"),
                action: DLoc.text("继续下一关", "Continue to Next Mission"))
    }

    func showTrainingCompletion() {
        present(sector: DepthlineIdentity.sector(DepthlineIdentity.trainingID),
                title: DLoc.text("训练完成", "Training Complete"),
                action: DLoc.text("进入海岸战区", "Enter Coastal Sector"))
    }

    func showSectorCompletion(sector: String) {
        present(sector: sector, title: DLoc.text("战区通关", "Sector Complete"), action: nil)
    }

    private func present(sector: String, title: String, action: String?) {
        if heading.stringValue != title || sectorLabel.stringValue != sector {
            sectorLabel.stringValue = sector
            heading.stringValue = title
            next.isHidden = action == nil
            next.title = action ?? ""
            next.setAccessibilityLabel(next.title)
            next.keyEquivalent = action == nil ? "" : "\r"
            launcher.keyEquivalent = action == nil ? "\r" : ""
            launcher.primary = action == nil
            needsLayout = true
            launcher.title = DLoc.text("返回游戏选择", "Return to Sector Select")
            launcher.setAccessibilityLabel(launcher.title)
            setAccessibilityLabel(DLoc.text("\(sector)，\(title)", "\(sector), \(title)"))
        }
        if isHidden {
            isHidden = false
            window?.makeFirstResponder(action == nil ? launcher : next)
        }
    }

    func hide() {
        if !isHidden { isHidden = true }
    }

    @objc private func advance() { if !isHidden { onNext() } }
    @objc private func leave() { if !isHidden { onLauncher() } }

    private var card: NSRect {
        let width = min(350, bounds.width - 32)
        return NSRect(x: floor(bounds.midX - width / 2), y: floor(bounds.midY - 118),
                      width: width, height: 236)
    }

    override func layout() {
        super.layout()
        let r = card
        let labelX = r.minX + 15, labelWidth = r.width - 30
        sectorLabel.frame = NSRect(x: labelX, y: r.minY + 24, width: labelWidth, height: 23)
        heading.frame = NSRect(x: labelX, y: r.minY + 50, width: labelWidth, height: 40)
        for (index, button) in [next, launcher].filter({ !$0.isHidden }).enumerated() {
            button.frame = NSRect(x: r.minX + 35, y: r.minY + 108 + CGFloat(index) * 52,
                                  width: r.width - 70, height: 43)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.012, alpha: 0.53).setFill()
        bounds.fill()
        let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        NSColor(srgbRed: 0.055, green: 0.090, blue: 0.095, alpha: 0.98).setFill()
        path.fill()
        NSColor(white: 0.85, alpha: 0.27).setStroke()
        path.stroke()
    }
}
