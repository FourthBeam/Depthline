import AppKit

enum LauncherPalette {
    static let background = NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.063, alpha: 1)
    static let panel = NSColor(calibratedRed: 0.045, green: 0.072, blue: 0.078, alpha: 0.96)
    static let muted = NSColor(calibratedRed: 0.61, green: 0.68, blue: 0.67, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.85, green: 0.74, blue: 0.46, alpha: 1)
}

private func launcherText(_ value: String, in rect: NSRect, size: CGFloat,
                          color: NSColor = .white, weight: NSFont.Weight = .regular,
                          alignment: NSTextAlignment = .left, singleLine: Bool = false) {
    let baseFont = NSFont.systemFont(ofSize: size, weight: weight)
    let font = singleLine ? baseFont.fitting(value, in: rect.width) : baseFont
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
    paragraph.lineSpacing = 5
    (value as NSString).draw(in: rect, withAttributes: [
        .font: font,
        .foregroundColor: color, .paragraphStyle: paragraph
    ])
}

private func drawSectorPoster(_ image: NSImage?, in rect: NSRect) {
    guard let image, image.isValid, image.size.width > 0, image.size.height > 0 else {
        NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.25, blue: 0.25, alpha: 1),
                   ending: LauncherPalette.background)?.draw(in: rect, angle: 75)
        return
    }
    let ratio = max(rect.width / image.size.width, rect.height / image.size.height)
    let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
    let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                        width: size.width, height: size.height)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: rect).addClip()
    image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1,
               respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
}

private func missionName(_ id: String) -> String {
    switch id {
    case "2000": return DLoc.text("潮口守备", "Tidewatch")
    case "2002": return DLoc.text("丘陵屏障", "Ridgeline")
    default: return DLoc.text("靶场训练", "Firing Range")
    }
}

class LauncherButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private(set) var hovered = false
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    func drawFocus() {
        guard focusRingType != .none, window?.firstResponder === self else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.7, dy: 0.7), xRadius: 9, yRadius: 9)
        outline.lineWidth = 2; outline.stroke()
    }
}

private final class LauncherChoiceButton: LauncherButton {
    private static let flag = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [NSColor(srgbRed: 1, green: 0.32, blue: 0.29, alpha: 1)]))
    let gameID: String
    let picture: NSImage?
    let completed: Bool
    var selected = false {
        didSet {
            needsDisplay = true
            updateSelectionDescription()
        }
    }

    private func updateSelectionDescription() {
        setAccessibilityValue((selected ? DLoc.text("已选择", "Selected") : DLoc.text("未选择", "Unselected")) + (completed ? DLoc.text("，已完成", ", completed") : DLoc.text("，未完成", ", incomplete")))
    }

    init(gameID: String, picture: NSImage?, completed: Bool, target: AnyObject, action: Selector) {
        self.gameID = gameID
        self.picture = picture
        self.completed = completed
        super.init(frame: .zero)
        title = DepthlineIdentity.sector(gameID)
        self.target = target; self.action = action
        isBordered = false; setButtonType(.momentaryPushIn)
        refreshLanguage()
        setAccessibilityIdentifier("select-game-" + gameID)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshLanguage() {
        title = DepthlineIdentity.sector(gameID)
        setAccessibilityLabel(DLoc.text("选择\(title)", "Select \(title)"))
        updateSelectionDescription()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        drawSectorPoster(picture, in: r)
        NSGradient(starting: NSColor(calibratedWhite: 0.02, alpha: selected || hovered ? 0.14 : 0.28),
                   ending: NSColor(calibratedWhite: 0.015, alpha: 0.89))?.draw(in: r, angle: 90)
        let inset: CGFloat = 16
        launcherText(DepthlineIdentity.sector(gameID), in: NSRect(x: inset, y: r.maxY - 60, width: r.width - 35, height: 29),
                     size: bounds.width < 205 ? 17 : 21, weight: .bold, singleLine: true)
        launcherText(missionName(gameID), in: NSRect(x: inset + 1, y: r.maxY - 28, width: r.width - 43, height: 18),
                     size: 12, color: NSColor(calibratedWhite: 0.86, alpha: 1), singleLine: true)
        if completed {
            let badge = NSRect(x: r.maxX - 90, y: r.minY + 8, width: 82, height: 24)
            LauncherPalette.background.withAlphaComponent(0.88).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
            Self.flag?.draw(in: NSRect(x: badge.minX + 7, y: badge.minY + 5, width: 15, height: 14),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            launcherText(DLoc.text("已完成", "Cleared"), in: NSRect(x: badge.minX + 27, y: badge.minY + 4, width: 51, height: 17),
                         size: 12, weight: .semibold, singleLine: true)
        }
        if selected {
            LauncherPalette.accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.maxX - 22, y: r.maxY - 21, width: 6, height: 6)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        (selected ? LauncherPalette.accent : NSColor(calibratedWhite: 0.7, alpha: hovered ? 0.65 : 0.25)).setStroke()
        path.lineWidth = selected ? 2 : 1; path.stroke()
        drawFocus()
    }
}

final class LauncherActionButton: LauncherButton {
    var primary = false
    var showsSelection = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let fill = primary ? LauncherPalette.accent : NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.12, alpha: 0.95)
        let focusedWithoutRing = focusRingType == .none && window?.firstResponder === self
        let highlight = isHighlighted ? 0.21 : (hovered || showsSelection || focusedWithoutRing ? 0.10 : 0)
        let background = fill.blended(withFraction: highlight, of: .white) ?? fill
        (isEnabled ? background : LauncherPalette.panel).setFill()
        let radius: CGFloat = image == nil ? 7 : 11
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        path.fill()
        (primary || showsSelection ? LauncherPalette.accent : NSColor(calibratedWhite: 0.65, alpha: hovered ? 0.60 : 0.27)).setStroke()
        path.lineWidth = 1; path.stroke()
        if let icon = image {
            let side: CGFloat = 22
            icon.draw(in: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            launcherText(title, in: NSRect(x: 8, y: bounds.midY - 10, width: r.width - 13, height: 24),
                         size: 14, color: isEnabled ? (primary ? LauncherPalette.background : .white) : LauncherPalette.muted.withAlphaComponent(0.48),
                         weight: primary ? .semibold : .medium, alignment: .center, singleLine: true)
        }
        drawFocus()
    }
}

/// A shared native entry point. resourceRoot is the packaged launcher-assets directory.
/// The selected game's original images are presentation assets; onStart selects its own game data.
final class LauncherView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Page { case home, settings, scores, savedGames }
    private var settingsReturnPage = Page.home
    private let store: CampaignStore
    private let music: OriginalMenuMusic
    private let onStart: (String) -> Void
    private let onContinue: ((String, CampaignStore.Checkpoint) -> Void)?
    private let onSettingsChanged: ((CampaignStore.Settings) -> Void)?
    private let onReturnToPause: (() -> Void)?
    private let cheatControls: DepthlineCheatControls?
    private let languageControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scoreDate = DateFormatter()
    private let saveDate = DateFormatter()
    private var page = Page.home
    private var pictures: [String: NSImage] = [:]
    private var choiceButtons: [LauncherChoiceButton] = []
    private var startButton: LauncherActionButton!
    private var continueButton: LauncherActionButton!
    private var scoresButton: LauncherActionButton!
    private var settingsButton: LauncherActionButton!
    private var savedGamesButton: LauncherActionButton!
    private var quitButton: LauncherActionButton!
    private var backButton: LauncherActionButton!
    private let playerField = NSTextField()
    private let creditsRow = NSStackView()
    private let producersLabel = NSTextField(labelWithString: "")
    private let soundCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let musicCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let invertCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let antialiasingControl = NSSegmentedControl(labels: ["", "2×", "4×"], trackingMode: .selectOne, target: nil, action: nil)
    private let sensitivityControl = NSSegmentedControl(labels: ["", "2", "3", "", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let scoreScroll = NSScrollView()
    private let scoreTable = NSTableView()
    private var scoreEntries: [CampaignStore.ScoreEntry] = []
    private let savedGamesScroll = NSScrollView()
    private let savedGamesTable = NSTableView()
    private let savedGameNameField = NSTextField()
    private var saveNewButton: LauncherActionButton!
    private var overwriteSaveButton: LauncherActionButton!
    private var loadSaveButton: LauncherActionButton!
    private var savedGames: [CampaignStore.SavedGame] = []
    private var lastSave: CampaignStore.SavedGame?
    private enum SettingsStatus {
        case automatic, saved, failed
        var message: String {
            switch self {
            case .automatic: return DLoc.text("更改将自动保存到本机。", "Changes are saved automatically.")
            case .saved: return DLoc.text("已保存。", "Settings saved.")
            case .failed: return DLoc.text("保存失败，设置已恢复。", "Could not save settings. Previous values restored.")
            }
        }
    }
    private var settingsStatus = SettingsStatus.automatic
    private(set) var selectedGameID = "2000"
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    static func orderedSectorIDs(in store: CampaignStore) -> [String] {
        let training = DepthlineIdentity.trainingID
        let campaigns = CampaignStore.supportedGames
        let unfinished = ([training] + campaigns).filter { !store.isSectorCompleted($0) }
        let completed = (campaigns + [training]).filter { store.isSectorCompleted($0) }
        return unfinished + completed
    }

    init(frame: NSRect, resourceRoot: URL, store: CampaignStore = CampaignStore(),
         onContinue: ((String, CampaignStore.Checkpoint) -> Void)? = nil,
         onSettingsChanged: ((CampaignStore.Settings) -> Void)? = nil,
         onReturnToPause: (() -> Void)? = nil,
         onSubmitCheat: ((DepthlineCheat) -> String)? = nil,
         onStart: @escaping (String) -> Void) {
        self.store = store
        self.music = OriginalMenuMusic(resourceRoot: resourceRoot)
        self.onStart = onStart
        self.onContinue = onContinue
        self.onSettingsChanged = onSettingsChanged
        self.onReturnToPause = onReturnToPause
        self.cheatControls = onSubmitCheat.map { DepthlineCheatControls(onSubmit: $0) }
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityIdentifier("game-library")
        let sectorIDs = Self.orderedSectorIDs(in: store)
        let posterDirectory = resourceRoot.deletingLastPathComponent().appendingPathComponent("remastered-assets")
        for id in sectorIDs {
            pictures[id] = NSImage(contentsOf: posterDirectory.appendingPathComponent("menu-\(id).png"))
            let button = LauncherChoiceButton(gameID: id, picture: pictures[id], completed: store.isSectorCompleted(id),
                                              target: self, action: #selector(chooseGame(_:)))
            choiceButtons.append(button); addSubview(button)
        }
        startButton = action(id: "start-game", selector: #selector(startGame), primary: true)
        continueButton = action(id: "continue-game", selector: #selector(continueGame))
        scoresButton = action(id: "game-scores", selector: #selector(showScores))
        settingsButton = action(id: "global-settings", selector: #selector(showSettings))
        let iconStyle = NSImage.SymbolConfiguration(paletteColors: [LauncherPalette.accent])
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?.withSymbolConfiguration(iconStyle)
        settingsButton.keyEquivalent = ","
        settingsButton.keyEquivalentModifierMask = .command
        savedGamesButton = action(id: "game-saved-games", selector: #selector(showSavedGames))
        quitButton = action(id: "global-quit", selector: #selector(quit))
        quitButton.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)?.withSymbolConfiguration(iconStyle)
        backButton = action(id: "back-to-launcher", selector: #selector(back))
        playerField.font = .systemFont(ofSize: 15)
        playerField.textColor = .white
        playerField.bezelStyle = .roundedBezel
        playerField.delegate = self
        playerField.setAccessibilityIdentifier("player-name")
        addSubview(playerField)
        producersLabel.font = .systemFont(ofSize: 14, weight: .medium)
        producersLabel.textColor = .secondaryLabelColor
        creditsRow.orientation = .horizontal
        creditsRow.alignment = .centerY
        creditsRow.spacing = 7
        creditsRow.setAccessibilityIdentifier("game-producers")
        creditsRow.addArrangedSubview(producersLabel)
        creditsRow.setCustomSpacing(14, after: producersLabel)
        let creditsDirectory = resourceRoot.deletingLastPathComponent().appendingPathComponent("credits")
        for (name, file) in [("FourthBeam", "fourthbeam"), ("codex", "codex")] {
            let icon = NSImageView()
            icon.image = NSImage(contentsOf: creditsDirectory.appendingPathComponent(file + ".png"))
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.setAccessibilityIdentifier("producer-" + file + "-icon")
            icon.setAccessibilityLabel(name)
            icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 26).isActive = true
            let credit = NSTextField(labelWithString: name)
            credit.font = .systemFont(ofSize: 15, weight: .semibold)
            creditsRow.addArrangedSubview(icon)
            creditsRow.addArrangedSubview(credit)
            creditsRow.setCustomSpacing(18, after: credit)
        }
        addSubview(creditsRow)
        for (control, identifier) in [(soundCheckbox, "sound-enabled"), (musicCheckbox, "music-enabled"), (invertCheckbox, "invert-y")] {
            control.target = self; control.action = #selector(changeSettings)
            control.font = .systemFont(ofSize: 15)
            control.setAccessibilityIdentifier(identifier)
            addSubview(control)
        }
        antialiasingControl.target = self; antialiasingControl.action = #selector(changeSettings)
        antialiasingControl.setAccessibilityIdentifier("antialiasing-samples")
        addSubview(antialiasingControl)
        sensitivityControl.target = self; sensitivityControl.action = #selector(changeSettings)
        sensitivityControl.setAccessibilityIdentifier("mouse-sensitivity")
        addSubview(sensitivityControl)
        languageControl.target = self
        languageControl.action = #selector(changeSettings)
        languageControl.setAccessibilityIdentifier("language-picker")
        addSubview(languageControl)
        if let cheatControls { addSubview(cheatControls) }
        scoreTable.headerView = NSTableHeaderView()
        scoreTable.rowHeight = 36; scoreTable.intercellSpacing = NSSize(width: 8, height: 3)
        scoreTable.backgroundColor = .clear
        scoreTable.selectionHighlightStyle = .none
        scoreTable.usesAlternatingRowBackgroundColors = false
        scoreTable.dataSource = self; scoreTable.delegate = self
        scoreTable.setAccessibilityIdentifier("score-table")
        for (id, width) in [("rank", 52.0), ("name", 160.0), ("score", 80.0), ("level", 65.0), ("mode", 80.0), ("date", 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width; column.minWidth = id == "name" ? 100 : 50
            scoreTable.addTableColumn(column)
        }
        scoreScroll.documentView = scoreTable; scoreScroll.hasVerticalScroller = true
        scoreScroll.drawsBackground = false; scoreScroll.borderType = .noBorder
        addSubview(scoreScroll)
        savedGamesTable.headerView = NSTableHeaderView()
        savedGamesTable.rowHeight = 30; savedGamesTable.intercellSpacing = NSSize(width: 6, height: 2)
        savedGamesTable.backgroundColor = .clear
        savedGamesTable.allowsMultipleSelection = false
        savedGamesTable.usesAlternatingRowBackgroundColors = false
        savedGamesTable.dataSource = self; savedGamesTable.delegate = self
        savedGamesTable.setAccessibilityIdentifier("saved-games-table")
        for (id, width) in [("slot", 46.0), ("name", 180.0), ("level", 52.0), ("score", 80.0), ("date", 160.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width; column.minWidth = id == "name" ? 110 : 40
            savedGamesTable.addTableColumn(column)
        }
        savedGamesScroll.documentView = savedGamesTable; savedGamesScroll.hasVerticalScroller = true
        savedGamesScroll.drawsBackground = false; savedGamesScroll.borderType = .noBorder
        addSubview(savedGamesScroll)
        savedGameNameField.font = .systemFont(ofSize: 14)
        savedGameNameField.setAccessibilityIdentifier("saved-game-name")
        addSubview(savedGameNameField)
        saveNewButton = action(id: "save-new-game", selector: #selector(saveNewGame))
        overwriteSaveButton = action(id: "save-overwrite", selector: #selector(overwriteSavedGame))
        loadSaveButton = action(id: "load-saved-game", selector: #selector(loadSavedGame), primary: true)
        refreshLanguage()
        startButton.keyEquivalent = "\r"
        if onReturnToPause != nil {
            page = .settings
            syncSettings()
            refreshPage()
        } else {
            selectGame(sectorIDs[0])
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMenuMusic()
    }

    private func updateMenuMusic() {
        music.update(gameID: selectedGameID == DepthlineIdentity.trainingID ? "2000" : selectedGameID, enabled: store.settings.musicEnabled,
                     visible: window != nil && onReturnToPause == nil)
    }

    private func action(id: String, selector: Selector, primary: Bool = false) -> LauncherActionButton {
        let button = LauncherActionButton(title: "", target: self, action: selector)
        button.primary = primary; button.isBordered = false; button.setButtonType(.momentaryPushIn)
        button.setAccessibilityIdentifier(id)
        addSubview(button)
        return button
    }

    func refreshLanguage() {
        choiceButtons.forEach { $0.refreshLanguage() }
        for (button, title) in [
            (scoresButton!, DLoc.text("高分榜", "High scores")),
            (savedGamesButton!, DLoc.text("存档与载入", "Saved games")),
            (settingsButton!, DLoc.text("全局设置", "Settings")),
            (quitButton!, DLoc.text("退出游戏", "Quit the game")),
            (backButton!, onReturnToPause == nil ? DLoc.text("返回", "Back") : DLoc.text("返回暂停菜单", "Back to pause menu")),
            (saveNewButton!, DLoc.text("保存为新档", "New save")),
            (overwriteSaveButton!, DLoc.text("覆盖所选", "Overwrite")),
            (loadSaveButton!, DLoc.text("载入所选", "Load selected"))
        ] {
            button.title = title
            button.setAccessibilityLabel(title)
            button.needsDisplay = true
        }
        settingsButton.toolTip = DLoc.text("全局设置（⌘,）", "Settings (⌘,)")
        quitButton.toolTip = quitButton.title
        playerField.placeholderString = DLoc.text("玩家名（最多 24 字）", "Player name (up to 24 characters)")
        playerField.setAccessibilityLabel(DLoc.text("当前战区的新游戏玩家名", "Player name for this sector"))
        savedGameNameField.placeholderString = DLoc.text("为关卡开始进度命名", "Name this mission checkpoint")
        savedGameNameField.setAccessibilityLabel(DLoc.text("存档名称", "Save name"))
        producersLabel.stringValue = DLoc.text("游戏制作人", "Game producers")
        soundCheckbox.title = DLoc.text("播放游戏音效", "Game sound effects")
        musicCheckbox.title = DLoc.text("播放战区氛围音乐", "Sector menu music")
        invertCheckbox.title = DLoc.text("反转鼠标纵向瞄准（Y 轴）", "Invert mouse Y axis")
        antialiasingControl.setLabel(DLoc.text("关闭", "Off"), forSegment: 0)
        antialiasingControl.setAccessibilityLabel(DLoc.text("抗锯齿", "Antialiasing"))
        for (index, label) in [DLoc.text("1 · 低", "1 · Low"), "2", "3", DLoc.text("4 · 标准", "4 · Normal"), DLoc.text("5 · 高", "5 · High")].enumerated() {
            sensitivityControl.setLabel(label, forSegment: index)
        }
        sensitivityControl.setAccessibilityLabel(DLoc.text("鼠标灵敏度，共五档", "Mouse sensitivity, five levels"))
        languageControl.removeAllItems()
        languageControl.addItems(withTitles: DepthlineLanguage.menuOrder.map(\.menuTitle))
        selectStoredLanguage()
        languageControl.setAccessibilityLabel(DLoc.text("界面语言", "Interface language"))
        for (id, title) in [("rank", DLoc.text("排名", "Rank")), ("name", DLoc.text("玩家", "Player")),
                            ("level", DLoc.text("关卡", "Mission")), ("mode", DLoc.text("辅助", "Assists")),
                            ("date", DLoc.text("记录日期", "Date"))] {
            scoreTable.tableColumn(withIdentifier: .init(id))?.title = title
        }
        for (id, title) in [("slot", DLoc.text("槽位", "Slot")), ("name", DLoc.text("存档名", "Name")),
                            ("level", DLoc.text("关卡", "Mission")), ("score", DLoc.text("分数", "Score")),
                            ("date", DLoc.text("保存时间", "Saved"))] {
            savedGamesTable.tableColumn(withIdentifier: .init(id))?.title = title
        }
        for date in [scoreDate, saveDate] {
            date.locale = DLoc.locale
            date.dateStyle = .short
        }
        saveDate.timeStyle = .short
        scoreTable.reloadData()
        savedGamesTable.reloadData()
        cheatControls?.refreshLanguage()
        if onReturnToPause == nil && selectedGameID != DepthlineIdentity.trainingID && playerField.currentEditor() == nil {
            playerField.stringValue = store.playerName(for: selectedGameID)
        }
        refreshPage()
    }

    func selectGame(_ id: String) {
        guard choiceButtons.contains(where: { $0.gameID == id }) else { return }
        selectedGameID = id
        playerField.stringValue = id == DepthlineIdentity.trainingID ? "" : store.playerName(for: id)
        choiceButtons.forEach { $0.selected = $0.gameID == id }
        page = .home
        refreshPage()
    }
    @objc private func chooseGame(_ sender: LauncherChoiceButton) {
        guard savePlayerName() else { return }
        selectGame(sender.gameID)
    }
    @objc private func startGame() {
        if selectedGameID == DepthlineIdentity.trainingID { onStart(DepthlineIdentity.trainingID); return }
        guard savePlayerName() else { return }
        guard let checkpoint = store.checkpoint(for: selectedGameID), let window else { onStart(selectedGameID); return }
        let id = selectedGameID
        let alert = NSAlert()
        alert.messageText = DLoc.text("开始新的\(DepthlineIdentity.sector(id))战役？", "Start a new campaign in \(DepthlineIdentity.sector(id))?")
        alert.informativeText = DLoc.text("当前第 \(checkpoint.level) 关的自动进度会被新游戏更新；命名存档与已记录的成绩会保留。", "Starting a new campaign replaces the automatic checkpoint for mission \(checkpoint.level). Your named saves and scores are kept.")
        alert.addButton(withTitle: DLoc.text("开始新游戏", "New game")); alert.addButton(withTitle: DLoc.text("取消", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.onStart(id) }
        }
    }
    @objc private func continueGame() {
        guard let checkpoint = store.checkpoint(for: selectedGameID), let onContinue else { return }
        onContinue(selectedGameID, checkpoint)
    }
    @objc private func showScores() {
        guard savePlayerName() else { return }
        page = .scores; scoreEntries = store.highScores(for: selectedGameID); scoreTable.reloadData(); refreshPage()
    }
    @objc private func showSettings() {
        if page == .settings { back(); return }
        guard savePlayerName() else { return }
        settingsReturnPage = page
        page = .settings; syncSettings(); refreshPage()
        window?.makeFirstResponder(soundCheckbox)
    }
    @objc private func showSavedGames() {
        guard savePlayerName() else { return }
        page = .savedGames; lastSave = nil
        savedGameNameField.stringValue = store.checkpoint(for: selectedGameID).map { $0.playerName + DLoc.text(" · 第 \($0.level) 关", " · Mission \($0.level)") } ?? ""
        reloadSavedGames(); refreshPage()
    }
    private var selectedSavedGame: CampaignStore.SavedGame? {
        savedGames.first { $0.slot == savedGamesTable.selectedRow + 1 }
    }
    private func reloadSavedGames(selecting id: UUID? = nil) {
        savedGames = store.savedGames(for: selectedGameID)
        savedGamesTable.reloadData()
        if let id, let entry = savedGames.first(where: { $0.id == id }) {
            savedGamesTable.selectRowIndexes(IndexSet(integer: entry.slot - 1), byExtendingSelection: false)
            savedGamesTable.scrollRowToVisible(entry.slot - 1)
        } else { savedGamesTable.deselectAll(nil) }
        updateSaveButtons()
    }
    private func updateSaveButtons() {
        let canSave = store.checkpoint(for: selectedGameID) != nil
        saveNewButton.isEnabled = canSave && savedGames.count < CampaignStore.saveSlotCount(gameID: selectedGameID)
        overwriteSaveButton.isEnabled = canSave && selectedSavedGame != nil
        loadSaveButton.isEnabled = selectedSavedGame != nil && onContinue != nil
        savedGameNameField.isEnabled = canSave
    }
    @objc private func saveNewGame() { saveCurrentCheckpoint(replacingID: nil) }
    private func saveCurrentCheckpoint(replacingID: UUID?) {
        do {
            let saved = try store.saveCurrentCheckpoint(gameID: selectedGameID, name: savedGameNameField.stringValue, replacingID: replacingID)
            lastSave = saved
            reloadSavedGames(selecting: saved.id); needsDisplay = true
        } catch { reportStorageError(error) }
    }
    @objc private func overwriteSavedGame() {
        guard let selected = selectedSavedGame, let window else { return }
        let alert = NSAlert(); alert.messageText = DLoc.text("覆盖“", "Overwrite “") + selected.name + DLoc.text("”？", "”?")
        alert.informativeText = DLoc.text("将用当前关卡开始进度替换槽位 \(selected.slot) 的记录。其他存档会保留。", "Replace the save in slot \(selected.slot) with your current mission checkpoint?")
        alert.addButton(withTitle: DLoc.text("覆盖存档", "Overwrite")); alert.addButton(withTitle: DLoc.text("取消", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.saveCurrentCheckpoint(replacingID: selected.id) }
        }
    }
    @objc private func loadSavedGame() {
        guard let selected = selectedSavedGame, let onContinue else { return }
        do {
            let checkpoint = try store.loadSavedGame(gameID: selectedGameID, id: selected.id)
            playerField.stringValue = checkpoint.playerName
            onContinue(selectedGameID, checkpoint)
        } catch { reportStorageError(error, title: DLoc.text("无法载入本机存档", "Unable to load save")) }
    }
    @objc private func back() {
        if let onReturnToPause { onReturnToPause(); return }
        let wasSettings = page == .settings
        page = wasSettings ? settingsReturnPage : .home
        refreshPage()
        window?.makeFirstResponder(wasSettings ? settingsButton : self)
    }
    @objc private func quit() { DepthlineQuit.request(in: window) }
    private func refreshPage() {
        updateMenuMusic()
        scoreTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("score"))?.title = selectedGameID == "2000" ? DLoc.text("分数", "Score") : DLoc.text("关卡成绩", "Mission reached")
        scoreTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("level"))?.isHidden = selectedGameID == "2002"
        savedGamesTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("score"))?.isHidden = selectedGameID == "2002"
        startButton.keyEquivalent = page == .home ? "\r" : ""
        let training = selectedGameID == DepthlineIdentity.trainingID
        startButton.title = training ? DLoc.text("开始训练", "Start training") : DLoc.text("开始新游戏", "New game")
        startButton.setAccessibilityLabel(startButton.title)
        settingsButton.showsSelection = page == .settings
        let checkpoint = training ? nil : store.checkpoint(for: selectedGameID)
        continueButton.isEnabled = checkpoint != nil && onContinue != nil
        continueButton.title = checkpoint.map { DLoc.text("继续游戏 · 第 \($0.level) 关", "Continue · Mission \($0.level)") } ?? DLoc.text("继续游戏 · 暂无进度", "Continue (no save)")
        continueButton.setAccessibilityLabel(continueButton.title)
        continueButton.toolTip = DLoc.text("读取所选版本的关卡开始检查点；本功能不保存战场中途状态。", "Resume at the start of the saved mission.")
        if !training { updateSaveButtons() }
        needsLayout = true; needsDisplay = true
    }
    private func syncSettings() {
        soundCheckbox.state = store.settings.soundEnabled ? .on : .off
        musicCheckbox.state = store.settings.musicEnabled ? .on : .off
        invertCheckbox.state = store.settings.invertY ? .on : .off
        sensitivityControl.selectedSegment = store.settings.sensitivityLevel - 1
        selectStoredLanguage()
        antialiasingControl.selectedSegment = [0,2,4].firstIndex(of: store.settings.antialiasingSamples) ?? 2
    }
    private func selectStoredLanguage() {
        if let index = DepthlineLanguage.menuOrder.firstIndex(of: store.settings.language) {
            languageControl.selectItem(at: index)
        }
    }
    @objc private func changeSettings() {
        var settings = store.settings
        settings.soundEnabled = soundCheckbox.state == .on
        settings.musicEnabled = musicCheckbox.state == .on
        settings.invertY = invertCheckbox.state == .on
        settings.sensitivityLevel = sensitivityControl.selectedSegment + 1
        let samples = [0, 2, 4]
        if samples.indices.contains(antialiasingControl.selectedSegment) {
            settings.antialiasingSamples = samples[antialiasingControl.selectedSegment]
        }
        let oldLanguage = settings.language
        let languageIndex = languageControl.indexOfSelectedItem
        if DepthlineLanguage.menuOrder.indices.contains(languageIndex) {
            settings.language = DepthlineLanguage.menuOrder[languageIndex]
        }
        do {
            try store.updateSettings(settings)
            if settings.language != oldLanguage {
                DLoc.language = settings.language
                refreshLanguage()
            }
            settingsStatus = .saved
            onSettingsChanged?(settings)
            updateMenuMusic()
        } catch {
            syncSettings(); settingsStatus = .failed
            reportStorageError(error)
        }
        needsDisplay = true
    }
    private func savePlayerName() -> Bool {
        guard onReturnToPause == nil, selectedGameID != DepthlineIdentity.trainingID else { return true }
        guard playerField.stringValue != store.playerName(for: selectedGameID) else { return true }
        do {
            try store.savePlayerName(playerField.stringValue, for: selectedGameID)
            playerField.stringValue = store.playerName(for: selectedGameID)
            return true
        } catch { reportStorageError(error); return false }
    }
    func controlTextDidEndEditing(_ obj: Notification) { _ = savePlayerName() }
    private func reportStorageError(_ error: Error, title: String = DLoc.text("无法保存本机数据", "Unable to save data")) {
        let alert = NSAlert(); alert.messageText = title
        alert.informativeText = error.localizedDescription; alert.addButton(withTitle: DLoc.text("知道了", "OK"))
        if let window { alert.beginSheetModal(for: window) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === savedGamesTable ? (selectedGameID == DepthlineIdentity.trainingID ? 0 : CampaignStore.saveSlotCount(gameID: selectedGameID)) : scoreEntries.count
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard selectedGameID != DepthlineIdentity.trainingID, notification.object as? NSTableView === savedGamesTable else { return }
        if let selected = selectedSavedGame { savedGameNameField.stringValue = selected.name }
        updateSaveButtons()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === savedGamesTable {
            guard let column = tableColumn else { return nil }
            let entry = savedGames.first { $0.slot == row + 1 }
            let value: String
            switch column.identifier.rawValue {
            case "slot": value = String(row + 1)
            case "name": value = entry?.name ?? DLoc.text("空槽", "Empty")
            case "level": value = entry.map { String($0.checkpoint.level) } ?? "—"
            case "score": value = entry.map { CampaignStore.displayScore(gameID: selectedGameID, score: $0.checkpoint.score) } ?? "—"
            default: value = entry.map { saveDate.string(from: $0.savedAt) } ?? "—"
            }
            let label = NSTextField(labelWithString: value)
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = entry == nil ? LauncherPalette.muted : .white
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityLabel(column.title + DLoc.text("：", ": ") + value)
            return label
        }
        guard row < scoreEntries.count, let column = tableColumn else { return nil }
        let entry = scoreEntries[row]
        let value: String
        switch column.identifier.rawValue {
        case "rank": value = String(row + 1)
        case "name": value = entry.playerName
        case "score": value = selectedGameID == "2002" ? String(entry.level) : CampaignStore.displayScore(gameID: selectedGameID, score: entry.score)
        case "level": value = String(entry.level)
        case "mode": value = entry.usedCheats == true ? DLoc.text("已使用", "Used") : DLoc.text("未标记", "—")
        default: value = scoreDate.string(from: entry.recordedAt)
        }
        let label = NSTextField(labelWithString: value)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = column.identifier.rawValue == "score" ? LauncherPalette.accent : .white
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityLabel(column.title + DLoc.text("：", ": ") + value)
        return label
    }
    override func cancelOperation(_ sender: Any?) {
        if page != .home { back() }
        else { super.cancelOperation(sender) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && page != .home { back(); return }
        super.keyDown(with: event)
    }

    private var margin: CGFloat { bounds.width < 1100 ? 24 : 32 }
    private var rail: CGFloat { min(236,max(186,bounds.width * 0.185)) }
    private var heroRect: NSRect {
        let x = page == .settings ? margin : margin + rail + 20
        let top: CGFloat = 102
        let foot: CGFloat = store.storageNotice == nil ? 24 : 46
        return NSRect(x:x,y:top,width:bounds.width-x-margin,height:bounds.height-top-foot)
    }
    private var menuButtons: [LauncherActionButton] {
        selectedGameID == DepthlineIdentity.trainingID ? [startButton] : [startButton,continueButton,savedGamesButton,scoresButton]
    }
    override func layout() {
        super.layout()
        let hero = heroRect
        quitButton.frame = NSRect(x:bounds.maxX-margin-44,y:22,width:44,height:44)
        settingsButton.frame = quitButton.frame.offsetBy(dx: -54, dy: 0)
        let cardHeight = min(166,(hero.height - 56) / 3)
        for (i, button) in choiceButtons.enumerated() {
            button.frame = NSRect(x:margin,y:hero.minY + 32 + CGFloat(i)*(cardHeight+12),width:rail,height:cardHeight)
            button.isHidden = page == .settings
        }
        let menuWidth: CGFloat = bounds.width < 1100 ? 178 : 208
        let x = hero.maxX-menuWidth-30
        let shown = menuButtons
        let menuHeight = CGFloat(shown.count)*44 - 6
        let y = hero.maxY - 29 - menuHeight
        for button in [startButton!,continueButton!,savedGamesButton!,scoresButton!] {
            if page == .home, let i = shown.firstIndex(of:button) {
                button.frame = NSRect(x:x,y:y+CGFloat(i)*44,width:menuWidth,height:38)
                button.isHidden = false
            } else {
                button.isHidden = true
            }
        }
        playerField.frame = NSRect(x:hero.minX+30,y:hero.maxY-85,
                                   width:min(250,max(145,x-hero.minX-90)),height:29)
        playerField.isHidden = page != .home || selectedGameID == DepthlineIdentity.trainingID
        backButton.frame = NSRect(x:hero.maxX-182,y:hero.maxY-64,width:152,height:38)
        backButton.isHidden = page == .home
        creditsRow.frame = NSRect(x: hero.minX + 31, y: backButton.frame.midY - 15,
                                  width: creditsRow.fittingSize.width.rounded(.up), height: 30)
        creditsRow.isHidden = page != .settings
        let settings = settingsColumns(hero)
        antialiasingControl.frame = NSRect(x:settings.left.minX+21,y:settings.left.minY+75,
                                           width:min(224,settings.left.width-42),height:29)
        sensitivityControl.frame = NSRect(x:settings.right.minX+21,y:settings.right.minY+75,
                                           width:min(340,settings.right.width-42),height:29)
        invertCheckbox.frame = NSRect(x:settings.right.minX+21,y:settings.right.minY+117,width:settings.right.width-38,height:28)
        soundCheckbox.frame = NSRect(x:settings.left.minX+21,y:settings.left.minY+143,width:settings.left.width-38,height:28)
        musicCheckbox.frame = NSRect(x:settings.left.minX+21,y:settings.left.minY+169,width:settings.left.width-38,height:28)
        languageControl.frame = NSRect(x: settings.left.minX+21, y: settings.left.minY+236,
                                       width: settings.left.width-42, height: 30)
        cheatControls?.frame = NSRect(x: settings.right.minX+21, y: settings.right.minY+174, width: settings.right.width-42, height: 88)
        cheatControls?.isHidden = page != .settings
        for control in [soundCheckbox, musicCheckbox, invertCheckbox, sensitivityControl, antialiasingControl, languageControl] {
            control.isHidden = page != .settings
        }
        scoreScroll.frame = NSRect(x: hero.minX + 30, y: hero.minY + 100, width: hero.width - 60, height: max(80, hero.height - 215))
        scoreScroll.isHidden = page != .scores || scoreEntries.isEmpty
        let width = scoreScroll.contentSize.width
        let fractions = selectedGameID == "2002" ? [0.10, 0.28, 0.17, 0, 0.15, 0.30] : [0.08, 0.24, 0.15, 0.11, 0.15, 0.27]
        for (column, fraction) in zip(scoreTable.tableColumns, fractions) where !column.isHidden {
            column.width = max(column.minWidth, width * fraction - 8)
        }
        savedGamesScroll.frame = NSRect(x: hero.minX + 30, y: hero.minY + 106, width: hero.width - 60, height: max(96, hero.height - 283))
        savedGamesScroll.isHidden = page != .savedGames
        let savedWidth = savedGamesScroll.contentSize.width
        let savedFractions = selectedGameID == "2002" ? [0.09, 0.40, 0.12, 0, 0.39] : [0.08, 0.33, 0.10, 0.15, 0.34]
        for (column, fraction) in zip(savedGamesTable.tableColumns, savedFractions) where !column.isHidden {
            column.width = max(column.minWidth, savedWidth * fraction - 6)
        }
        savedGameNameField.frame = NSRect(x: hero.minX + 34, y: hero.maxY - 138, width: hero.width - 68, height: 29)
        savedGameNameField.isHidden = page != .savedGames
        let actionWidth = min(148, (hero.width - 96) / 4)
        for (index, button) in [saveNewButton!, overwriteSaveButton!, loadSaveButton!].enumerated() {
            button.frame = NSRect(x: hero.minX + 30 + CGFloat(index) * (actionWidth + 10), y: hero.maxY - 68, width: actionWidth, height: 42)
            button.isHidden = page != .savedGames
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        LauncherPalette.background.setFill(); bounds.fill()
        let halo = NSGradient(starting: NSColor(calibratedRed:0.107,green:0.158,blue:0.16,alpha:1),
                              ending: LauncherPalette.background)
        halo?.draw(in: bounds, angle: 90)
        drawHeader()
        let hero = heroRect
        if page != .settings {
            launcherText(DLoc.text("战区选择", "Select a sector"), in: NSRect(x:margin+2,y:hero.minY,width:rail,height:23),
                         size:14,color:LauncherPalette.muted,weight:.semibold)
        }
        NSGraphicsContext.saveGraphicsState()
        let outline = NSBezierPath(roundedRect: hero, xRadius: 12, yRadius: 12)
        outline.addClip()
        LauncherPalette.panel.setFill(); hero.fill()
        if page == .settings {
            drawSettings(hero)
        } else if page == .home {
            drawSectorPoster(pictures[selectedGameID], in: hero)
            drawHome(hero)
        } else if page == .savedGames {
            drawSavedGames(hero)
        } else {
            drawScores(hero)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite:0.66,alpha:0.19).setStroke(); outline.lineWidth=1; outline.stroke()
        if let notice = store.storageNotice {
            launcherText(notice,in:NSRect(x:margin,y:hero.maxY+10,width:bounds.width-margin*2,height:25),size:12,color:LauncherPalette.accent)
        }
    }

    private func drawHeader() {
        let x = margin+2
        let mark = NSBezierPath()
        // Three staggered bars on a common diagonal, echoing the depth of a defensive line.
        for i in 0..<3 {
            let sx = x + CGFloat(i)*10, sy = 31-CGFloat(i)*3
            mark.move(to:NSPoint(x:sx,y:sy+22))
            mark.line(to:NSPoint(x:sx,y:sy+8))
            mark.line(to:NSPoint(x:sx+7,y:sy+2))
            mark.line(to:NSPoint(x:sx+7,y:sy+16)); mark.close()
        }
        LauncherPalette.accent.setFill(); mark.fill()
        launcherText(DepthlineIdentity.title,in:NSRect(x:x+41,y:21,width:180,height:39),size:29,weight:.bold)
        if DepthlineIdentity.title.caseInsensitiveCompare(DepthlineIdentity.subtitle) != .orderedSame {
            launcherText(DepthlineIdentity.subtitle,in:NSRect(x:x+43,y:57,width:140,height:16),size:10,color:LauncherPalette.accent,weight:.semibold)
        }
        NSColor(calibratedWhite:0.8,alpha:0.13).setFill()
        NSRect(x:margin,y:83,width:bounds.width-2*margin,height:1).fill()
    }

    private func drawHome(_ r: NSRect) {
        let training = selectedGameID == DepthlineIdentity.trainingID
        let leftWidth = max(180, startButton.frame.minX-r.minX-72)
        let lower = NSRect(x:r.minX,y:r.midY,width:r.width,height:r.height/2)
        NSGradient(starting:NSColor(calibratedWhite:0,alpha:0),
                   ending:NSColor(calibratedRed:0.015,green:0.032,blue:0.035,alpha:0.94))?.draw(in:lower,angle:90)
        let upper = NSRect(x:r.minX,y:r.minY,width:r.width,height:r.height*0.32)
        NSGradient(starting:NSColor(calibratedWhite:0,alpha:0.58),
                   ending:NSColor(calibratedWhite:0,alpha:0))?.draw(in:upper,angle:90)
        launcherText(DepthlineIdentity.sector(selectedGameID),in:NSRect(x:r.minX+28,y:r.minY+23,width:leftWidth,height:48),
                     size:bounds.width < 1100 ? 31 : 36,weight:.bold,singleLine:true)
        let menu = NSRect(x:startButton.frame.minX-10,y:startButton.frame.minY-10,
                          width:startButton.frame.width+20,height:(menuButtons.last?.frame.maxY ?? startButton.frame.maxY)-startButton.frame.minY+20)
        NSColor(calibratedRed:0.025,green:0.045,blue:0.05,alpha:0.81).setFill()
        NSBezierPath(roundedRect:menu,xRadius:10,yRadius:10).fill()
        let titleY = training ? startButton.frame.midY - 18 : r.maxY-206
        launcherText(missionName(selectedGameID),in:NSRect(x:r.minX+28,y:titleY,width:leftWidth,height:36),
                     size:25,weight:.bold)
        if training { return }
        let brief = selectedGameID == "2000" ? DLoc.text("守住岸防炮位，阻击登滩部队。", "Defend the coastal gun emplacement against the landing force.") : DLoc.text("转动炮台，迎击山脊各处的攻势。", "Turn the turret to repel attacks from across the ridge.")
        launcherText(brief,in:NSRect(x:r.minX+30,y:titleY+40,width:leftWidth,height:43),
                     size:14,color:NSColor(calibratedWhite:0.91,alpha:1))
        launcherText(DLoc.text("玩家名", "Player name"),in:NSRect(x:r.minX+30,y:r.maxY-108,width:leftWidth,height:19),
                     size:12,color:LauncherPalette.muted)
        if let checkpoint = store.checkpoint(for:selectedGameID) {
            let scoreValue = CampaignStore.displayScore(gameID: selectedGameID, score: checkpoint.score)
            let score = selectedGameID == "2000" ? DLoc.text(" · \(scoreValue) 分", " · \(scoreValue) pts") : ""
            let progress = DLoc.text("检查点 · 第 \(checkpoint.level) 关", "Checkpoint · Mission \(checkpoint.level)") + " · " + checkpoint.playerName + score
            launcherText(progress,in:NSRect(x:r.minX+30,y:r.maxY-42,width:leftWidth,height:38),
                         size:11,color:LauncherPalette.muted)
        }
    }

    private func settingsColumns(_ r: NSRect) -> (left:NSRect,right:NSRect) {
        let width = (r.width-78)/2
        let left = NSRect(x:r.minX+30,y:r.minY+94,width:width,height:286)
        return (left, left.offsetBy(dx:width+18,dy:0))
    }

    private func drawSettings(_ r: NSRect) {
        launcherText(DLoc.text("全局设置", "Settings"),in:NSRect(x:r.minX+29,y:r.minY+25,width:r.width-60,height:43),size:29,weight:.bold)
        launcherText(DLoc.text("应用于所有战区", "Applies to all sectors"),in:NSRect(x:r.minX+31,y:r.minY+68,width:r.width-60,height:24),
                     size:13,color:LauncherPalette.muted)
        let columns = settingsColumns(r)
        for (column,title) in [(columns.left,DLoc.text("画面与声音", "Display and sound")),(columns.right,DLoc.text("鼠标与瞄准", "Mouse and aiming"))] {
            let panel = NSBezierPath(roundedRect:column,xRadius:9,yRadius:9)
            NSColor(calibratedWhite:0.85,alpha:0.04).setFill(); panel.fill()
            NSColor(calibratedWhite:0.8,alpha:0.12).setStroke(); panel.stroke()
            launcherText(title,in:NSRect(x:column.minX+22,y:column.minY+16,width:column.width-44,height:28),
                         size:17,color:LauncherPalette.accent,weight:.semibold)
        }
        func label(_ value:String,_ column:NSRect,offset:CGFloat) {
            launcherText(value,in:NSRect(x:column.minX+22,y:column.minY+offset,width:column.width-44,height:24),
                         size:14,color:.white,weight:.medium)
        }
        label(DLoc.text("抗锯齿", "Antialiasing"),columns.left,offset:49)
        label(DLoc.text("声音", "Sound"),columns.left,offset:117)
        label(DLoc.text("界面语言", "Interface language"), columns.left, offset: 208)
        label(DLoc.text("瞄准灵敏度", "Aiming sensitivity"),columns.right,offset:49)
        launcherText(settingsStatus.message,in:NSRect(x:r.minX+31,y:columns.left.maxY+15,width:r.width-62,height:28),
                     size:12,color:LauncherPalette.muted)
    }

    private func drawScores(_ r: NSRect) {
        launcherText(DLoc.text("\(DepthlineIdentity.sector(selectedGameID)) · 高分榜", "\(DepthlineIdentity.sector(selectedGameID)) · High scores"), in: NSRect(x: r.minX + 32, y: r.minY + 28, width: r.width - 64, height: 43),
                     size: 25, weight: .bold)
        if scoreEntries.isEmpty {
            launcherText(DLoc.text("尚无成绩", "No scores yet"), in: NSRect(x: r.minX + 34, y: r.minY + 133, width: r.width - 68, height: 40),
                         size: 22, color: LauncherPalette.accent, weight: .medium)
            launcherText(DLoc.text("完成一次战斗后，这里会显示本战区的实际成绩。", "Scores from completed runs in this sector will appear here."),
                         in: NSRect(x: r.minX + 34, y: r.minY + 184, width: r.width - 68, height: 58),
                         size: 14, color: LauncherPalette.muted)
        }
        let ranking = selectedGameID == "2002" ? DLoc.text("按到达关卡排名", "Ranked by mission reached") : DLoc.text("按分数排名", "Ranked by score")
        launcherText(ranking + DLoc.text("，保留本机最高 30 条。辅助标记表示使用过辅助功能。", ". Top 30 on this Mac. Assists indicates a cheat was used."),
                     in: NSRect(x: r.minX + 34, y: r.maxY - 110, width: r.width - 68, height: 40),
                     size: 11, color: LauncherPalette.muted)
    }

    private func drawSavedGames(_ r: NSRect) {
        launcherText(DLoc.text("\(DepthlineIdentity.sector(selectedGameID)) · 存档与载入", "\(DepthlineIdentity.sector(selectedGameID)) · Saved games"), in: NSRect(x: r.minX + 32, y: r.minY + 25, width: r.width - 64, height: 43),
                     size: 25, weight: .bold)
        launcherText(DLoc.text("\(savedGames.count) / \(CampaignStore.saveSlotCount(gameID: selectedGameID)) 个存档 · 保存关卡开始进度，载入后从该关开始。", "\(savedGames.count) / \(CampaignStore.saveSlotCount(gameID: selectedGameID)) slots used · Each save resumes at the start of its mission."),
                     in: NSRect(x: r.minX + 34, y: r.minY + 76, width: r.width - 68, height: 25),
                     size: 12, color: LauncherPalette.muted)
        launcherText(DLoc.text("存档名称", "Save name"), in: NSRect(x: r.minX + 34, y: r.maxY - 163, width: r.width - 68, height: 23),
                     size: 12, color: LauncherPalette.muted)
        let message: String
        if let saved = lastSave { message = DLoc.text("已保存到槽位 \(saved.slot) · 第 \(saved.checkpoint.level) 关开始", "Saved to slot \(saved.slot) · Start of mission \(saved.checkpoint.level)") }
        else if let checkpoint = store.checkpoint(for: selectedGameID) {
            message = DLoc.text("当前可保存：", "Current checkpoint: ") + checkpoint.playerName + DLoc.text(" · 第 \(checkpoint.level) 关开始", " · Mission \(checkpoint.level)") +
                (savedGames.count >= CampaignStore.saveSlotCount(gameID: selectedGameID) ? DLoc.text("。槽位已满，可选择已有记录覆盖。", ". Slots are full. Select a save to replace.") : "")
        } else { message = DLoc.text("暂无关卡进度。开始游戏后，可回到这里命名保存。", "Start a campaign to create a checkpoint you can save here.") }
        launcherText(message, in: NSRect(x: r.minX + 34, y: r.maxY - 101, width: r.width - 68, height: 26),
                     size: 11, color: LauncherPalette.muted)
    }

}
