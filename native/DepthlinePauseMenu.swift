import AppKit

final class DepthlinePauseMenu: NSView {
    private weak var game: Game?
    private let heading = NSTextField(labelWithString: "")
    private let resume = LauncherActionButton()
    private let settings = LauncherActionButton()
    private let launcher = LauncherActionButton()
    private let quit = LauncherActionButton()
    private var panel: NSRect { NSRect(x: bounds.midX-165, y: bounds.midY-160, width: 330, height: 320) }
    override var isFlipped: Bool { true }

    init(game: Game) {
        self.game = game
        super.init(frame: game.view.bounds)
        isHidden = true
        autoresizingMask = [.width, .height]
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityIdentifier("gameplay-pause")
        heading.alignment = .center
        heading.font = .systemFont(ofSize: 26, weight: .bold)
        heading.textColor = .white
        addSubview(heading)
        for (button, id, action) in [
            (resume, "pause-resume", #selector(continuePlay)),
            (settings, "pause-settings", #selector(openSettings)),
            (launcher, "pause-launcher", #selector(returnToLauncher)),
            (quit, "pause-quit", #selector(requestQuit))
        ] {
            button.isBordered = false
            button.setButtonType(.momentaryPushIn)
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(id)
            addSubview(button)
        }
        resume.primary = true
        resume.keyEquivalent = "\r"
        refreshLanguage()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic pause menu") }

    func refreshLanguage() {
        heading.stringValue = DLoc.text("游戏已暂停", "Game Paused")
        for (button, title) in [
            (resume, DLoc.text("继续游戏", "Resume")),
            (settings, DLoc.text("设置", "Settings")),
            (launcher, DLoc.text("返回游戏选择", "Return to Sector Select")),
            (quit, DLoc.text("退出游戏", "Quit the game"))
        ] {
            button.title = title
            button.setAccessibilityLabel(title)
            button.needsDisplay = true
        }
    }

    @objc private func continuePlay() { if game?.paused == true { game?.togglePause() } }
    @objc private func openSettings() { game?.onOpenPauseSettings?() }
    @objc private func returnToLauncher() { game?.onReturnToLauncher?() }
    @objc private func requestQuit() { DepthlineQuit.request(in: window) }
    override func cancelOperation(_ sender: Any?) { continuePlay() }

    override func layout() {
        super.layout()
        let r = panel
        heading.frame = NSRect(x: r.minX+25, y: r.minY+25, width: r.width-50, height: 38)
        for (index, button) in [resume, settings, launcher, quit].enumerated() {
            button.frame = NSRect(x: r.minX+35, y: r.minY+82+CGFloat(index)*53, width: r.width-70, height: 43)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.012, alpha: 0.53).setFill()
        bounds.fill()
        let card = NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12)
        NSColor(srgbRed: 0.055, green: 0.090, blue: 0.095, alpha: 0.98).setFill()
        card.fill()
        NSColor(white: 0.85, alpha: 0.27).setStroke()
        card.stroke()
    }
}
