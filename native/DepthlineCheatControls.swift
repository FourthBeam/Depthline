import AppKit

private extension DepthlineCheat {
    var help: String {
        switch self {
        case .fullAmmo: return DLoc.text("补满本关可用的各类弹药。", "Refill every available ammo type for this mission.")
        case .fullHealth: return DLoc.text("把阵地防御恢复至 100%。", "Restore the position to 100% health.")
        case .invulnerability: return DLoc.text("本关免受伤害。再次输入可关闭。", "Take no damage this mission. Enter again to turn it off.")
        }
    }
}

final class DepthlineCheatControls: NSView {
    private let label = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let help = NSButton()
    private let submit = LauncherActionButton()
    private let feedback = NSTextField(labelWithString: "")
    let helpPopover = NSPopover()
    private let onSubmit: (DepthlineCheat) -> String

    override var isFlipped: Bool { true }

    init(onSubmit: @escaping (DepthlineCheat) -> String) {
        self.onSubmit = onSubmit
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        field.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        field.textColor = LauncherPalette.accent
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(submitCode)
        (field.cell as? NSActionCell)?.sendsActionOnEndEditing = false
        field.setAccessibilityIdentifier("cheat-input")
        help.bezelStyle = .helpButton
        help.title = ""
        help.target = self
        help.action = #selector(toggleHelp)
        help.setAccessibilityIdentifier("cheat-help")
        submit.isBordered = false
        submit.setButtonType(.momentaryPushIn)
        submit.target = self
        submit.action = #selector(submitCode)
        submit.setAccessibilityIdentifier("cheat-submit")
        feedback.font = .systemFont(ofSize: 12)
        feedback.textColor = .secondaryLabelColor
        feedback.setAccessibilityIdentifier("cheat-feedback")
        helpPopover.behavior = .transient
        for control in [label, field, help, submit, feedback] { addSubview(control) }
        refreshLanguage()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic cheat controls") }

    func refreshLanguage() {
        label.stringValue = DLoc.text("本关秘籍", "Mission cheats")
        field.placeholderString = DLoc.text("输入秘籍", "Enter a cheat code")
        field.setAccessibilityLabel(label.stringValue)
        submit.title = DLoc.text("提交", "Submit")
        submit.setAccessibilityLabel(submit.title)
        help.toolTip = DLoc.text("查看可用秘籍与效果", "Show available cheats and effects")
        help.setAccessibilityLabel(help.toolTip)
        feedback.stringValue = ""
        if helpPopover.isShown { helpPopover.performClose(nil) }
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
        let fieldWidth = bounds.width - 112
        field.frame = NSRect(x: 0, y: 25, width: fieldWidth, height: 26)
        help.frame = NSRect(x: fieldWidth + 4, y: 24, width: 29, height: 29)
        submit.frame = NSRect(x: fieldWidth + 40, y: 22, width: 72, height: 32)
        feedback.frame = NSRect(x: 0, y: 56, width: bounds.width, height: 25)
    }

    @objc private func submitCode() {
        let code = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let cheat = DepthlineCheat(rawValue: code) else {
            feedback.stringValue = code.isEmpty ? DLoc.text("请先输入秘籍。", "Enter a code first.")
                : DLoc.text("未识别的秘籍，点问号查看。", "Unknown code. See ? for available cheats.")
            field.selectText(nil)
            return
        }
        feedback.stringValue = onSubmit(cheat)
        field.stringValue = ""
    }

    @objc private func toggleHelp() {
        if helpPopover.isShown { helpPopover.performClose(nil); return }
        let content = NSView()
        let textWidth: CGFloat = 266
        let inset: CGFloat = 18
        var previousEffect: NSTextField?
        for code in DepthlineCheat.allCases {
            let name = NSTextField(labelWithString: code.rawValue)
            name.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)
            name.textColor = LauncherPalette.accent
            let effect = NSTextField(wrappingLabelWithString: code.help)
            effect.font = .systemFont(ofSize: 13)
            effect.textColor = .secondaryLabelColor
            effect.preferredMaxLayoutWidth = textWidth
            for line in [name, effect] {
                line.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(line)
                line.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset).isActive = true
            }
            NSLayoutConstraint.activate([
                name.topAnchor.constraint(equalTo: previousEffect?.bottomAnchor ?? content.topAnchor,
                                          constant: previousEffect == nil ? 16 : 14),
                effect.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
                effect.widthAnchor.constraint(equalToConstant: textWidth),
                effect.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset)
            ])
            previousEffect = effect
        }
        previousEffect?.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16).isActive = true
        let controller = NSViewController()
        controller.view = content
        helpPopover.appearance = effectiveAppearance
        helpPopover.contentViewController = controller
        helpPopover.contentSize = content.fittingSize
        helpPopover.show(relativeTo: help.bounds, of: help, preferredEdge: .minY)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil && helpPopover.isShown { helpPopover.performClose(nil) }
        super.viewWillMove(toWindow: newWindow)
    }
}
