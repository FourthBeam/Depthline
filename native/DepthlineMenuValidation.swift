import AppKit
import SceneKit

/// Exercise game input during the menu check without moving the developer's pointer.
final class MenuValidationCursor: CursorCaptureBackend {
    func captureContext(in view: NSView) -> (inside: Bool, active: Bool) { (true, view.window != nil) }
    func capture(at point: CGPoint) -> Bool { true }
    func release() {}
}

/// Model the window after a Spaces transition, without reconfiguring the
/// developer's displays or sending a global key event.
private final class FullScreenMenuValidationWindow: NSWindow {
    var simulatesFullScreen = false
    override var styleMask: NSWindow.StyleMask {
        get { simulatesFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue }
    }
}

private func menuCheck(_ condition: Bool, _ message: String) throws {
    guard condition else {
        throw NSError(domain: "DepthlineMenuValidation", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension AppDelegate {
    func runDepthlineMenuValidation() throws {
        let directory = arguments.firstIndex(of: "--menu-output").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        } ?? "build/menu-validation"
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try menuCheck(store.directory.lastPathComponent.hasPrefix("Depthline-Test-"), "Menu tests require a temporary campaign store")
        for (id, level, score) in [("2000", 7, 229), ("2002", 3, 41)] {
            try store.saveCheckpoint(gameID: id, level: level, score: score, playerName: "玩家")
            try store.recordScore(gameID: id, level: level, score: score, playerName: "玩家")
            _ = try store.saveCurrentCheckpoint(gameID: id, name: "独立检查点")
        }
        showLauncher()
        guard var home = launcher else { throw validationError("Launcher unavailable") }
        try menuCheck(home.selectedGameID == "training", "Fresh launcher must initially select the unfinished training sector")

        func layout(_ view: NSView) {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap { descendants($0) }
        }
        func visible(_ view: NSView, _ id: String) -> [NSView] {
            layout(view)
            return descendants(view).filter { $0.accessibilityIdentifier() == id && !$0.isHiddenOrHasHiddenAncestor }
        }
        func button(_ view: NSView, _ id: String) throws -> NSButton {
            let matches = visible(view, id)
            guard matches.count == 1, let control = matches.first as? NSButton else {
                throw validationError("Expected one visible button " + id)
            }
            try menuCheck(control.isEnabled, "Disabled button " + id)
            let frame = view.convert(control.bounds, from: control)
            try menuCheck(view.bounds.contains(frame) && frame.width >= 20 && frame.height >= 20,
                          "Button outside usable content: \(id) \(frame)")
            return control
        }
        func click(_ view: NSView, _ id: String) throws {
            let control = try button(view, id)
            control.performClick(nil)
        }
        func hittableButton(_ view: NSView, _ id: String) throws -> NSButton {
            let control = try button(view, id)
            let center = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: view.superview)
            guard let hit = view.hitTest(center), hit === control || hit.isDescendant(of: control) else {
                throw validationError("Control is obscured at its clickable center: " + id)
            }
            return control
        }
        func respondToQuit(confirm: Bool) throws {
            guard let sheet = window.attachedSheet, let content = sheet.contentView else {
                throw validationError("Quitting must first open a confirmation sheet")
            }
            let cancel = try button(content, "quit-cancel")
            let quit = try button(content, "quit-confirm")
            (confirm ? quit : cancel).performClick(nil)
            try menuCheck(window.attachedSheet == nil, "The quit confirmation did not close")
        }
        func shot(_ view: NSView, _ name: String) throws {
            layout(view)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw validationError("Could not capture " + name)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { throw validationError(name) }
            try data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
        func battleShot(_ live: Game, overlay: NSView, name: String) throws {
            // SceneKit snapshots omit the AppKit views above the Metal layer.
            // Draw that same visible overlay and its controls onto the native game frame.
            layout(live.view)
            let size = live.view.bounds.size
            let options = try NativeCaptureOptions(arguments: ["--capture-width", String(Int(size.width)),
                                                                "--capture-height", String(Int(size.height))])
            let wasPaused = live.hud.paused
            defer { live.hud.paused = wasPaused }
            guard let scene = NSImage(data: try live.captureNativePixels(options: options)),
                  let layer = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds),
                  let result = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                      bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: result) else { throw validationError("Missing capture for " + name) }
            overlay.cacheDisplay(in: overlay.bounds, to: layer)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            scene.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
            let frame = live.view.convert(overlay.bounds, from: overlay)
            let bottom = live.view.isFlipped ? size.height - frame.maxY : frame.minY
            layer.draw(in: NSRect(x: frame.minX, y: bottom, width: frame.width, height: frame.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            guard let data = result.representation(using: .png, properties: [:]) else { throw validationError(name) }
            try data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], chars: String = "") throws -> NSEvent {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else {
                throw validationError("Could not create key event")
            }
            return event
        }

        let sectorIDs = ["2000", "2002", "training"]
        func currentMenu() throws -> LauncherView {
            guard let menu = launcher, game == nil else { throw validationError("Expected a sector selection screen") }
            return menu
        }
        func chooseLanguage(_ page: LauncherView, _ language: DepthlineLanguage) throws {
            let choices = DepthlineLanguage.menuOrder
            guard let picker = visible(page, "language-picker").first as? NSPopUpButton,
                  picker.numberOfItems == choices.count, let index = choices.firstIndex(of: language) else {
                throw validationError("Missing language dropdown or option")
            }
            picker.selectItem(at: index)
            picker.sendAction(picker.action, to: picker.target)
            try menuCheck(store.settings.language == language &&
                          CampaignStore(directory: store.directory).settings.language == language,
                          "Language override was not saved")
        }
        func englishButton(_ view: NSView, _ id: String) throws {
            let control = try hittableButton(view, id)
            try menuCheck(control.title.range(of: "[A-Za-z]", options: .regularExpression) != nil &&
                          control.title.range(of: #"\p{Han}"#, options: .regularExpression) == nil,
                          "Untranslated English button " + id + ": " + control.title)
        }
        let addedLanguages: [(DepthlineLanguage, String)] = [
            (.korean, "ko-KR"), (.japanese, "ja-JP"), (.french, "fr-CA"),
            (.spanish, "es-MX"), (.portuguese, "pt-BR"), (.russian, "ru-RU"),
            (.indonesian, "id-ID"), (.vietnamese, "vi-VN"), (.thai, "th-TH")
        ]
        func checkProgress(_ completed: Set<String>) throws {
            let reopened = CampaignStore(directory: store.directory)
            for id in sectorIDs {
                let expected = completed.contains(id)
                try menuCheck(store.isSectorCompleted(id) == expected && reopened.isSectorCompleted(id) == expected,
                              "Incorrect completion in memory or on disk for " + id)
            }
        }
        func checkCards(_ expected: [String], completed: Set<String>) throws {
            let menu = try currentMenu()
            var origins: [CGFloat] = []
            for id in expected {
                let card = try button(menu, "select-game-" + id)
                origins.append(menu.convert(card.bounds, from: card).midY)
                let marker = completed.contains(id) ? "已完成" : "未完成"
                let value = card.accessibilityValue() as? String ?? ""
                try menuCheck(value.contains(marker), "Unexpected card completion for " + id + ": " + value)
            }
            try menuCheck(zip(origins, origins.dropFirst()).allSatisfy { $0.0 < $0.1 },
                          "Cards in wrong screen order. Expected " + expected.joined(separator: ", "))
            try checkProgress(completed)
        }
        func leave(_ live: Game) throws {
            live.view.keyDown(with: try key(53))
            try click(live.view, "pause-launcher")
            try menuCheck(window.contentView === launcher && game == nil && !live.view.mouseCapture.isCaptured,
                          "Pause menu did not release the game and return to the selection screen")
        }
        func checkBattleMenu(_ live: Game, sector: String) throws {
            let view = live.view
            let prompt = "gameplay-capture-prompt"
            guard let hint = visible(view, prompt).first else { throw validationError("Missing capture hint in " + sector) }
            let copy = ((hint as? NSTextField)?.stringValue ?? hint.accessibilityLabel() ?? "")
            try menuCheck(copy.contains("F8") && !view.mouseCapture.isCaptured, "Missing initial F8 instruction in " + sector)
            if sector == "2000" { try battleShot(live, overlay: hint, name: "窗口入场提示") }
            view.keyDown(with: try key(100, flags: [.function]))
            try menuCheck(view.mouseCapture.isCaptured && visible(view, prompt).isEmpty, "Initial F8 capture failed in " + sector)
            live.simulationTick()

            view.keyDown(with: try key(53))
            try menuCheck(live.paused && !view.mouseCapture.isCaptured, "Escape did not pause and unlock the mouse in " + sector)
            let tick = live.logicalTick, ammo = live.weapons.ammo.cannon, selected = live.weapons.selected
            let resume = "pause-resume", choose = "pause-launcher", settings = "pause-settings", quit = "pause-quit"
            let actions = [resume, choose, settings, quit]
            for action in actions { _ = try hittableButton(view, action) }
            let buttons = descendants(view).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
            try menuCheck(buttons.count == actions.count, "Unexpected number of visible pause buttons in " + sector)
            if sector == "2000", let overlay = visible(view, "gameplay-pause").first { try battleShot(live, overlay: overlay, name: "战斗暂停菜单") }
            try click(view, quit)
            try respondToQuit(confirm: false)
            try menuCheck(window.contentView === view && game === live && live.paused &&
                          live.weapons.ammo.cannon == ammo && !view.mouseCapture.isCaptured,
                          "Cancelling quit did not preserve the paused battle in " + sector)
            view.keyDown(with: try key(49, chars: " "))
            view.keyDown(with: try key(100, flags: [.function]))
            live.tick()
            try menuCheck(!view.mouseCapture.isCaptured && live.weapons.selected == selected && live.logicalTick == tick,
                          "Gameplay input or simulation ran while paused in " + sector)
            try click(view, settings)
            guard let page = window.contentView as? LauncherView, game === live && live.paused else {
                throw validationError("Pause settings lost the current game in " + sector)
            }
            try menuCheck(visible(page, "cheat-input").count == 1, "Missing in-battle command field in " + sector)
            for id in ["cheat-help", "cheat-submit"] { _ = try hittableButton(page, id) }
            let original = store.settings
            let sound = "sound-enabled"
            try menuCheck(try button(page, sound).state == (original.soundEnabled ? .on : .off), "Paused settings did not read global sound")
            try click(page, sound)
            try menuCheck(live.settings.soundEnabled != original.soundEnabled && live.settings == CampaignStore(directory: store.directory).settings,
                          "Paused game did not share global settings in " + sector)
            try click(page, sound)
            guard let antialiasing = visible(page, "antialiasing-samples").first as? NSSegmentedControl else {
                throw validationError("Paused settings lack antialiasing controls")
            }
            let previousSegment = antialiasing.selectedSegment
            antialiasing.selectedSegment = 0
            antialiasing.sendAction(antialiasing.action, to: antialiasing.target)
            try menuCheck(live.view.antialiasingMode == .none && live.settings == store.settings,
                          "Paused graphics changes did not reach the live renderer")
            antialiasing.selectedSegment = previousSegment
            antialiasing.sendAction(antialiasing.action, to: antialiasing.target)
            try click(page, "back-to-launcher")
            try menuCheck(window.contentView === view && window.firstResponder === view && game === live && live.paused &&
                          live.logicalTick == tick && live.weapons.ammo.cannon == ammo && live.settings == original && visible(view, prompt).isEmpty,
                          "Leaving settings did not preserve the paused battle in " + sector)
            try click(view, resume)
            try menuCheck(!live.paused && visible(view, resume).isEmpty && visible(view, prompt).isEmpty && game === live,
                          "Resume did not restore the battle in " + sector)
            if sector == "2000" {
                view.keyDown(with: try key(53))
                try click(view, settings)
                guard let settingsPage = window.contentView as? LauncherView else { throw validationError("Missing pause settings before language switch") }
                try chooseLanguage(settingsPage, .english)
                guard let translated = window.contentView as? LauncherView else { throw validationError("Language switch lost pause settings") }
                try englishButton(translated, "back-to-launcher")
                try click(translated, "back-to-launcher")
                try menuCheck(game === live && live.paused && live.logicalTick == tick && live.weapons.ammo.cannon == ammo,
                              "Changing language lost the current battle")
                for id in actions { try englishButton(view, id) }
                try click(view, settings)
                guard var languagePage = window.contentView as? LauncherView else { throw validationError("Missing translated settings") }
                for (language, locale) in addedLanguages {
                    try menuCheck(DepthlineLanguage.system.resolved(preferredLanguages: [locale]) == language,
                                  "System language did not resolve: " + locale)
                    try chooseLanguage(languagePage, language)
                    let submit = try hittableButton(languagePage, "cheat-submit")
                    try menuCheck(submit.title != "Submit" && !submit.title.isEmpty,
                                  "Missing localized submit button in " + locale)
                    let help = try hittableButton(languagePage, "cheat-help")
                    help.performClick(nil)
                    guard let popover = descendants(languagePage).compactMap({ $0 as? DepthlineCheatControls }).first?.helpPopover,
                          popover.isShown, let content = popover.contentViewController?.view else {
                        throw validationError("Missing command descriptions in " + locale)
                    }
                    let effects = descendants(content).compactMap { ($0 as? NSTextField)?.stringValue }
                    for code in ["fullammo", "fullhealth", "whosyourdaddy"] {
                        try menuCheck(effects.contains(code), "Translated help omitted the command " + code)
                    }
                    try menuCheck(effects.contains(where: { $0.contains("100") || $0.contains("๑๐๐") }) &&
                                  !effects.contains("Restore the position to 100% health."), "Missing translated health description in " + locale)
                    popover.close()
                    let mission = DLoc.text("第 \(37) 关完成", "Mission \(37) Complete")
                    try menuCheck(mission.contains("37") && !mission.contains("{0}") && mission != "Mission 37 Complete",
                                  "Interpolated mission completion did not localize in " + locale)
                    try click(languagePage, "back-to-launcher")
                    let primary = try hittableButton(view, resume)
                    try menuCheck(!primary.title.isEmpty && primary.title != "Resume" && live.paused,
                                  "Pause menu did not update to " + locale)
                    try click(view, settings)
                    guard let reopened = window.contentView as? LauncherView else { throw validationError("Could not reopen settings") }
                    languagePage = reopened
                }
                try chooseLanguage(languagePage, .simplifiedChinese)
                try click(window.contentView!, "back-to-launcher")
                try click(view, resume)
            }
        }
        let removed = ["game-help", "game-settings", "game-controls"]
        let settingsID = "global-settings"
        let quitID = "global-quit"
        let campaignActions = ["continue-game", "game-saved-games", "game-scores"]
        try menuCheck(store.settings.language == .system &&
                      DepthlineLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN"]) == .simplifiedChinese &&
                      DepthlineLanguage.system.resolved(preferredLanguages: ["zh_CN"]) == .simplifiedChinese &&
                      DepthlineLanguage.system.resolved(preferredLanguages: ["en-US"]) == .english &&
                      DepthlineLanguage.system.resolved(preferredLanguages: ["de-DE", "zh-Hans"]) == .english &&
                      DepthlineLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]) == .traditionalChinese &&
                      DepthlineLanguage.system.resolved(preferredLanguages: ["zh-HK"]) == .traditionalChinese,
                      "New installation did not follow the primary system language")
        window.setContentSize(.init(width: 1000, height: 625))
        try click(home, settingsID)
        guard let firstPicker = visible(home, "language-picker").first as? NSPopUpButton else {
            throw validationError("Language selector unavailable on first launch")
        }
        let nativeNames = DepthlineLanguage.menuOrder.map(\.menuTitle)
        try menuCheck(firstPicker.itemTitles == nativeNames && firstPicker.itemTitle(at: 0) == "English" && firstPicker.indexOfSelectedItem == 1,
                      "English must be the first option while a fresh installation follows the system")
        try chooseLanguage(home, .english)
        guard let englishSettings = window.contentView as? LauncherView else { throw validationError("English settings unavailable") }
        try englishButton(englishSettings, "back-to-launcher")
        try shot(englishSettings, "语言下拉设置")
        try click(englishSettings, "back-to-launcher")
        home = try currentMenu()
        for sector in sectorIDs { try englishButton(home, "select-game-" + sector) }
        try englishButton(home, "start-game")
        try shot(home, "英文最小窗口")
        try click(home, settingsID)
        try chooseLanguage(home, .traditionalChinese)
        try shot(window.contentView!, "繁體設定")
        try click(window.contentView!, "back-to-launcher")
        home = try currentMenu()
        let traditionalCard = try hittableButton(home, "select-game-2000")
        try menuCheck(traditionalCard.title.contains("戰區"), "Traditional Chinese did not reach the sector cards")
        try click(home, settingsID)
        try chooseLanguage(home, .simplifiedChinese)
        try click(window.contentView!, "back-to-launcher")
        home = try currentMenu()
        for size in [NSSize(width: 1000, height: 625), NSSize(width: 1280, height: 800)] {
            window.setContentSize(size)
            try checkCards(["training", "2000", "2002"], completed: [])
            let gear = try hittableButton(home, settingsID)
            let bounds = home.convert(gear.bounds, from: gear)
            try menuCheck(bounds.midX > home.bounds.width * 0.80 && bounds.midY < 110, "Gear outside header")
            let power = try hittableButton(home, quitID)
            let powerBounds = home.convert(power.bounds, from: power)
            try menuCheck(abs(powerBounds.midY - bounds.midY) < 1 && powerBounds.minX >= bounds.maxX &&
                          powerBounds.minX - bounds.maxX <= 24, "Power button must sit beside Settings")
            let cards = try sectorIDs.map { try button(home, "select-game-" + $0) }
            for (index, card) in cards.enumerated() {
                let siblings = cards.dropFirst(index + 1)
                try menuCheck(siblings.allSatisfy { !$0.frame.intersects(card.frame) }, "Overlapping sector buttons")
            }
            try menuCheck(removed.allSatisfy { visible(home, $0).isEmpty }, "Duplicate local settings or help action")
            try shot(home, size.width == 1280 ? "首页" : "最小窗口")
        }
        let original = store.settings
        let oldSettings = Data(#"{"soundEnabled":true,"sensitivityLevel":4,"invertY":false}"#.utf8)
        let migrated = try JSONDecoder().decode(CampaignStore.Settings.self, from: oldSettings)
        try menuCheck(migrated.antialiasingSamples == 4, "Existing settings must default to 4×")
        try click(home, settingsID)
        for id in ["cheat-input", "cheat-help", "cheat-submit"] {
            try menuCheck(visible(home, id).isEmpty, "Battle command leaked into launcher settings")
        }
        guard let credits = visible(home, "game-producers").first else {
            throw validationError("Missing producer credit in settings")
        }
        let producerText = descendants(credits).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
        for title in ["游戏制作人", "FourthBeam", "codex"] {
            try menuCheck(producerText.contains(title), "Producer credit missing " + title)
        }
        try menuCheck(!producerText.localizedCaseInsensitiveContains("liangping"), "Obsolete producer name shown in settings")
        var producerIcons = Set<Data>()
        for id in ["producer-fourthbeam-icon", "producer-codex-icon"] {
            guard let icon = visible(home, id).first as? NSImageView, let image = icon.image, image.isValid,
                  let pixels = image.tiffRepresentation else {
                throw validationError("Missing producer icon " + id)
            }
            let frame = home.convert(icon.bounds, from: icon)
            try menuCheck(frame.width >= 16 && frame.height >= 16 && home.bounds.contains(frame), "Unusable producer icon " + id)
            producerIcons.insert(pixels)
        }
        try menuCheck(producerIcons.count == 2, "Both producers displayed the same image")
        try shot(home, "全局设置")
        try click(home, "sound-enabled")
        try click(home, "invert-y")
        guard let sensitivity = visible(home, "mouse-sensitivity").first as? NSSegmentedControl else {
            throw validationError("Missing sensitivity control")
        }
        sensitivity.selectedSegment = 1
        sensitivity.sendAction(sensitivity.action, to: sensitivity.target)
        guard let antialiasing = visible(home, "antialiasing-samples").first as? NSSegmentedControl else {
            throw validationError("Missing antialiasing control")
        }
        antialiasing.selectedSegment = 1
        antialiasing.sendAction(antialiasing.action, to: antialiasing.target)
        let settings = store.settings
        try menuCheck(settings.soundEnabled != original.soundEnabled && settings.invertY != original.invertY && settings.antialiasingSamples == 2 &&
                      settings.sensitivityLevel == 2 && CampaignStore(directory: store.directory).settings == settings,
                      "Global settings must persist to temporary store")
        home.keyDown(with: try key(53))
        try menuCheck(visible(home, "game-producers").isEmpty, "Settings credit leaked into home screen")

        for id in sectorIDs {
            try click(home, "select-game-" + id)
            try menuCheck(home.selectedGameID == id, "Sector selection failed")
            try menuCheck(visible(home, "quit-game").isEmpty, "Obsolete sector quit button visible in " + id)
            try click(home, quitID)
            try respondToQuit(confirm: false)
            try menuCheck(window.contentView === home && home.selectedGameID == id && game == nil,
                          "Cancelling the power button did not preserve sector selection")
            try click(home, settingsID)
            try menuCheck(try button(home, "invert-y").state == (settings.invertY ? .on : .off), "Sector-specific settings leaked")
            try click(home, "back-to-launcher")
            try menuCheck(home.selectedGameID == id, "Settings did not return to the selected sector")
            if id == "training" {
                try menuCheck(campaignActions.allSatisfy { visible(home, $0).isEmpty } && visible(home, "player-name").isEmpty,
                              "Training must have its own menu actions")
            } else {
                for action in campaignActions { _ = try button(home, action) }
            }
        }
        var confirmedQuit = false
        DepthlineQuit.request(in: window) { confirmedQuit = true }
        try menuCheck(!confirmedQuit, "Quit action ran before confirmation")
        try respondToQuit(confirm: true)
        try menuCheck(confirmedQuit, "Confirming quit did not run the exit action")
        guard let assets = Bundle.main.resourceURL,
              let poster = NSImage(contentsOf: assets.appendingPathComponent("remastered-assets/menu-training.png")),
              poster.isValid else { throw validationError("Training poster missing from app resources") }
        try shot(home, "教学战区")
        func gameRecords() throws -> NSDictionary {
            let document = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
            guard let records = document?["games"] as? NSDictionary else { throw validationError("Missing campaign records") }
            return records
        }
        // Leaving a lesson already in progress must keep the tutorial first.
        do {
            try click(home, "start-game")
            guard let early = game, let lesson = early.training else { throw validationError("Missing initial lesson") }
            early.timer?.invalidate()
            try checkBattleMenu(early, sector: "training")
            try menuCheck(lesson.stage == .aim, "Early-exit test did not start the lesson")
            try leave(early)
            try checkCards(["training", "2000", "2002"], completed: [])
        }

        func checkVictoryMenu(_ live: Game, title: String, screenshot: String? = nil) throws {
            let view = live.view
            guard let overlay = visible(view, "gameplay-victory").first,
                  let heading = visible(view, "victory-title").first as? NSTextField else {
                throw validationError("Missing victory menu for " + title)
            }
            try menuCheck(heading.stringValue == title && !view.mouseCapture.isCaptured, "Wrong result or mouse still captured for " + title)
            try menuCheck(visible(view, "gameplay-pause").isEmpty && visible(view, "gameplay-capture-prompt").isEmpty,
                          "An unrelated overlay covered the result")
            for id in ["victory-sector", "victory-title"] {
                guard let label = visible(view, id).first as? NSTextField else { throw validationError("Missing result label " + id) }
                let center = NSPoint(x: label.bounds.midX, y: label.bounds.midY)
                try menuCheck(!label.isSelectable && !label.isEditable
                              && view.hitTest(label.convert(center, to: view.superview)) === overlay,
                              "The result label accepts mouse selection: " + id)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: label.convert(center, to: nil),
                                                         modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                         clickCount: 2, pressure: type == .leftMouseDown ? 1 : 0) else {
                        throw validationError("Cannot create a result-card double click")
                    }
                    window.sendEvent(event)
                }
                try menuCheck(label.currentEditor() == nil && !(window.firstResponder is NSTextView)
                              && live.isShowingVictoryChoice && !live.shooting, "Double-clicking result text changed the game or selected text")
            }
            for control in overlay.subviews.compactMap({ $0 as? NSButton }) where !control.isHidden {
                try menuCheck(control.cell?.isEditable == false && control.cell?.isSelectable == false
                              && control.currentEditor() == nil, "Result button title permits text selection")
            }
            _ = try hittableButton(view, "victory-launcher")
            if live.didCompleteCampaign { try menuCheck(visible(view, "victory-next").isEmpty, "Final mission offered a next level") }
            else { _ = try hittableButton(view, "victory-next") }
            let tick = live.logicalTick, elapsed = live.elapsed, weapons = live.weapons, score = live.combat.score
            let record = try gameRecords()
            view.keyDown(with: try key(49, chars: " "))
            view.keyDown(with: try key(46, chars: "m"))
            view.keyDown(with: try key(100, flags: [.function]))
            // Advance the production frame clock beyond the old automatic transition timeout.
            for _ in 0..<40 { live.previousTime -= 0.15; live.tick() }
            try menuCheck(live.logicalTick == tick && live.elapsed == elapsed && live.weapons == weapons &&
                          live.combat.score == score && !view.mouseCapture.isCaptured && !visible(view, "victory-launcher").isEmpty,
                          "Battle input, clocks or scores advanced while waiting for a victory choice")
            try menuCheck(try gameRecords().isEqual(record), "Waiting on victory wrote another checkpoint or score")
            if let screenshot { try battleShot(live, overlay: overlay, name: screenshot) }
        }

        func clearCampaign(_ id: String, completedBefore: Set<String>) throws {
            let menu = try currentMenu()
            try click(menu, "select-game-" + id)
            try click(menu, "continue-game")
            guard let live = game else { throw validationError("Continue did not start a campaign") }
            live.timer?.invalidate()
            try menuCheck(live.training == nil && live.assets.gameID == id && live.settings == settings &&
                          live.view.antialiasingMode == .multisampling2X, "Global settings did not reach campaign " + id)
            try checkBattleMenu(live, sector: id)
            let finalDay = live.assets.levels.count
            live.restart(level: finalDay - 2, score: 73)
            live.view.keyDown(with: try key(100, flags: [.function]))
            try menuCheck(live.view.mouseCapture.isCaptured, "Missing mouse capture before the penultimate win")
            try winCurrentMission(live)
            let earnedScore = live.combat.score
            let bonus = id == "2000" ? (live.campaign?.remainingSeconds ?? 0) / 10 : 0
            try menuCheck(live.campaign?.level == finalDay - 1 && earnedScore == 73 + bonus &&
                          store.checkpoint(for: id)?.level == finalDay && store.checkpoint(for: id)?.score == earnedScore,
                          "Win did not save next mission with the correct time bonus")
            try checkVictoryMenu(live, title: "第 \(finalDay - 1) 关完成", screenshot: id == "2000" ? "战役过关" : nil)
            try checkProgress(completedBefore)
            try click(live.view, "victory-next")
            try menuCheck(live.campaign?.level == finalDay && live.combat.score == earnedScore &&
                          visible(live.view, "gameplay-victory").isEmpty && game === live,
                          "Continue did not load the final mission exactly once")
            // A loss on the final map must not be interpreted as clearing that map.
            guard let finalMission = live.campaign, finalMission.remainingForce > 0 else {
                throw validationError("Expected opposition in final mission " + id)
            }
            live.combat.health = 0
            for _ in 0..<150 where !live.finished { live.simulationTick() }
            try menuCheck(live.finished && live.resultRecorded, "Missing final mission defeat")
            try menuCheck(visible(live.view, "gameplay-victory").isEmpty, "Defeat presented the victory choices")
            try checkProgress(completedBefore)
            live.view.keyDown(with: try key(15, flags: .command, chars: "r"))
            try menuCheck(live.campaign?.level == 1, "Campaign restart did not return to day one")
            live.restart(level: finalDay - 1, score: 101)
            try winCurrentMission(live)
            try checkProgress(completedBefore.union([id]))
            try checkVictoryMenu(live, title: "战区通关")
            let finalScore = live.combat.score
            let finalRun = live.runID
            try menuCheck(live.didCompleteCampaign && live.finished && live.pendingNextLevel == nil, "Campaign did not end")
            try click(live.view, "victory-launcher")
            let selection = try currentMenu()
            try menuCheck(selection.selectedGameID == id && !live.view.mouseCapture.isCaptured, "Returning did not select the cleared sector")
            let reopened = CampaignStore(directory: store.directory)
            let result = reopened.highScores(for: id).first { $0.id == finalRun }
            try menuCheck(reopened.checkpoint(for: id) == nil && result?.score == finalScore && result?.level == finalDay,
                          "Final score was lost or an out-of-range checkpoint survived")
            try click(selection, "start-game")
            guard let replay = game else { throw validationError("Could not reopen cleared sector") }
            replay.timer?.invalidate()
            try menuCheck(replay.campaign?.level == 1 && replay.combat.score == 0 &&
                          visible(replay.view, "gameplay-victory").isEmpty, "A new campaign must start at mission one")
            try checkProgress(completedBefore.union([id]))
            try leave(replay)
        }
        try clearCampaign("2000", completedBefore: [])
        try checkCards(["training", "2002", "2000"], completed: ["2000"])
        try shot(try currentMenu(), "海岸通关")
        let before = try gameRecords()
        let trainingMenu = try currentMenu()
        try click(trainingMenu, "select-game-training")
        try click(trainingMenu, "start-game")
        guard let course = game else { throw validationError("Start Training did not launch a game") }
        course.timer?.invalidate(); course.timer = nil
        try menuCheck(course.settings == settings && course.view.antialiasingMode == .multisampling2X,
                      "Training does not use global settings")
        course.view.keyDown(with: try key(15, flags: .command, chars: "r"))
        let stages = try exerciseTraining(course, output: output, key: key,
                                          checkUngraded: { try checkProgress(["2000"]) })
        try checkProgress(["2000", "training"])
        try checkVictoryMenu(course, title: "训练完成", screenshot: "教学完成")
        try menuCheck(try gameRecords().isEqual(before), "Training modified formal campaign checkpoints, scores or slots")
        let coastCheckpoint = store.checkpoint(for: "2000")
        try click(course.view, "victory-next")
        guard let coast = game, coast !== course, coast.training == nil, coast.assets.gameID == "2000" else {
            throw validationError("Graduation did not open the coast campaign")
        }
        coast.timer?.invalidate()
        try menuCheck(coast.campaign?.level == coastCheckpoint?.level && coast.combat.score == coastCheckpoint?.score,
                      "Graduation did not resume the player's coast checkpoint")
        try leave(coast)
        try checkCards(["2002", "2000", "training"], completed: ["2000", "training"])
        try shot(try currentMenu(), "教学与海岸通关")
        try clearCampaign("2002", completedBefore: ["2000", "training"])
        try checkCards(["2000", "2002", "training"], completed: Set(sectorIDs))
        try shot(try currentMenu(), "全部战区通关")

        // Enter from a sector selection window that is already fullscreen.
        // Its physical cursor backend remains local to the validation process.
        do {
            let originalWindow = window, selection = launcher, lastSelection = lastGameID
            let full = FullScreenMenuValidationWindow(contentRect: window.contentView!.bounds, styleMask: [.titled, .resizable],
                                                      backing: .buffered, defer: false)
            full.simulatesFullScreen = true
            window = full
            defer {
                game?.stop()
                game = nil
                full.contentView = nil
                full.simulatesFullScreen = false
                window = originalWindow
                launcher = selection
                lastGameID = lastSelection
            }
            showLauncher()
            for id in sectorIDs {
                let menu = try currentMenu()
                try click(menu, "select-game-" + id)
                try click(menu, id == "training" ? "start-game" : "continue-game")
                guard let live = game else { throw validationError("Missing fullscreen game in " + id) }
                live.timer?.invalidate()
                let view = live.view, hint = "gameplay-capture-prompt"
                try menuCheck(view.mouseCapture.isCaptured && visible(view, hint).isEmpty,
                              "Fullscreen launch must immediately capture the pointer and omit F8 in " + id)
                view.keyDown(with: try key(53))
                try menuCheck(live.paused && !view.mouseCapture.isCaptured && visible(view, hint).isEmpty,
                              "Fullscreen pause did not release the pointer in " + id)
                try click(view, "pause-resume")
                try menuCheck(!live.paused && view.mouseCapture.isCaptured && visible(view, hint).isEmpty,
                              "Fullscreen resume did not recapture the pointer in " + id)
                if let level = live.campaign?.level {
                    try winCurrentMission(live)
                    try checkVictoryMenu(live, title: "第 \(level) 关完成")
                    try click(view, "victory-next")
                    try menuCheck(live.campaign?.level == level + 1 && view.mouseCapture.isCaptured &&
                                  visible(view, hint).isEmpty && visible(view, "gameplay-victory").isEmpty,
                                  "Fullscreen next mission did not resume mouse control in " + id)
                }
                try leave(live)
            }
        }
        func exerciseCheats(_ id: String) throws {
            let selection = try currentMenu()
            try click(selection, "select-game-" + id)
            try click(selection, "continue-game")
            guard let live = game else { throw validationError("Missing battle for command checks") }
            live.timer?.invalidate()
            // Hills mission 11 is the first night defence in the restored campaign.
            let start = id == "2002" ? 11 : 1
            live.restart(level: start - 1)
            let view = live.view
            func settingsPage() throws -> LauncherView {
                view.keyDown(with: try key(53))
                try click(view, "pause-settings")
                guard let settings = window.contentView as? LauncherView else { throw validationError("Missing paused settings") }
                return settings
            }
            func submit(_ page: LauncherView, _ value: String, enter: Bool = false) throws -> String {
                guard let field = visible(page, "cheat-input").first as? NSTextField else { throw validationError("Missing command field") }
                if enter {
                    window.makeFirstResponder(field)
                    guard let editor = field.currentEditor() as? NSTextView else { throw validationError("Command field cannot be edited") }
                    editor.string = value
                    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                } else {
                    field.stringValue = value
                    if let editor = field.currentEditor() as? NSTextView { editor.string = value }
                    try click(page, "cheat-submit")
                }
                guard let response = visible(page, "cheat-feedback").first as? NSTextField,
                      !response.stringValue.isEmpty else { throw validationError("Missing command feedback") }
                return response.stringValue
            }
            func resume(_ page: LauncherView) throws {
                try click(page, "back-to-launcher")
                try click(view, "pause-resume")
            }
            func incomingHit() {
                live.applyOriginalSharedPlayerHit(23, bank: .bullet,
                    sweep: .init(weapon: .machineGun, start: SIMD3(0, 820, -30), end: SIMD3(0, 820, 0)))
            }
            live.combat.health = 38
            live.weapons.ammo = .init(machineGun: 1, cannon: 1, missile: 1, handgun: 1, flare: 0)
            let page = try settingsPage()
            if id == "2000" {
                try click(page, "cheat-help")
                guard let popover = descendants(page).compactMap({ $0 as? DepthlineCheatControls }).first?.helpPopover, popover.isShown,
                      let content = popover.contentViewController?.view else { throw validationError("Help button did not open command descriptions") }
                let descriptions = descendants(content).compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSTextView)?.string }.joined(separator: " ").lowercased()
                for term in ["fullammo", "fullhealth", "whosyourdaddy", "弹药", "防御", "免受伤害"] {
                    try menuCheck(descriptions.contains(term), "Missing command or effect in help: " + term)
                }
                popover.close()
            }
            let unsupported = try submit(page, "invalid-command", enter: true)
            try menuCheck(!live.usedCheats && live.combat.health == 38 && live.weapons.ammo.handgun == 1 &&
                          store.checkpoint(for: id)?.usedCheats != true, "Invalid command altered state or marked the run")
            let support = live.weapons.supportAvailable
            let ammoFeedback = try submit(page, " FullAmmo ")
            if id == "2000" { try shot(page, "本关秘籍设置") }
            let ammo = live.weapons.ammo
            let full: OriginalAmmo = id == "2002" ? .init(machineGun: 500, cannon: 20, missile: 20, handgun: 15, flare: 20)
                                                  : .init(machineGun: 150, cannon: 8, missile: 3, handgun: 15, flare: 0)
            try menuCheck(ammo == full &&
                          live.weapons.supportAvailable == support && ammoFeedback != unsupported, "Ammo refill missed an equipped weapon or changed support")
            _ = try submit(page, "FuLlHeAlTh", enter: true)
            try menuCheck(live.combat.health == 100, "Return key did not refill defense")
            _ = try submit(page, "whosyourdaddy")
            try resume(page)
            incomingHit()
            try menuCheck(live.combat.health == 100, "Invulnerability allowed incoming bullet damage")
            let reentered = try settingsPage()
            _ = try submit(reentered, "whosyourdaddy")
            try resume(reentered)
            incomingHit()
            try menuCheck(live.combat.health == 77, "Submitting invulnerability again did not restore damage")
            let third = try settingsPage()
            _ = try submit(third, "whosyourdaddy")
            try resume(third)
            try winCurrentMission(live)
            try click(view, "victory-next")
            incomingHit()
            let next = CampaignStore(directory: store.directory).checkpoint(for: id)
            try menuCheck(live.combat.health == 77 && next?.level == start + 1 && next?.usedCheats == true,
                          "Next mission kept invulnerability or lost the assisted marker")
            let run = live.runID
            live.combat.health = 0
            for _ in 0..<150 where !live.finished { live.simulationTick() }
            let result = CampaignStore(directory: store.directory).highScores(for: id).first { $0.id == run }
            try menuCheck(live.finished && result?.usedCheats == true, "Defeat score lost its assisted marker")
            try leave(live)
        }
        for id in CampaignStore.supportedGames { try exerciseCheats(id) }

        let record: [String: Any] = [
            "globalSettingsPersisted": true, "selectedSectors": sectorIDs, "campaignRecordsUnchanged": true,
            "quitConfirmation": ["header power button beside Settings", "cancel preserves sector and paused game", "confirm runs exit action"],
            "windowedCaptureAndPauseMenu": sectorIDs,
            "fullscreenLaunchPauseAndRecapture": sectorIDs,
            "languageSettings": ["system resolves the first preferred supported language, or English for unsupported locales",
                                 "native dropdown opens with English first and system selected", "manual overrides survive reopening",
                                 "English launcher at minimum size", "additional languages in live pause settings, command descriptions and variable mission titles"],
            "victoryChoices": ["both buttons clickable in coast, hills and training", "double-clicking result labels cannot select text or activate a choice", "waiting freezes simulation and score",
                               "next mission resumes battle control", "return to launcher preserves next mission and score",
                               "final flag awarded before choice", "training continues into saved coast mission"],
            "pauseCommandsChecked": ["battle-only controls and help", "button and Return submissions", "unknown command feedback",
                                     "ammo and defense replenishment", "invulnerability toggle, real incoming damage and next-level reset",
                                     "assisted checkpoint and high score on disk"],
            "trainingSteps": stages, "trainingShots": course.combat.shots, "finalDefence": course.combat.health,
            "liveFireChecks": ["wrong aim and weapon rejected on cannon target", "cannon shell hits range target",
                               "empty launcher and missed missile do not graduate", "cannon, machine gun and handgun each down a helicopter and trigger a replacement",
                               "guided missile destroys replacement helicopter and awards graduation"],
            "antialiasingSamplesInAllSectors": settings.antialiasingSamples, "legacyAntialiasingSamples": migrated.antialiasingSamples,
            "completionCheckedThrough": ["early tutorial exit", "coast defeat and victory", "tutorial graduation", "hills defeat and victory", "restart and reload"],
            "cursorBackend": "Simulated physical cursor capture; native input and game logic",
            "windowContentPoints": [[1000,625],[1280,800]]
        ]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("validation.json"), options: .atomic)
        print("PASS: global settings, launcher layout, training, campaign outcomes, persistent completion flags and card order")
    }
}

private func validationError(_ message: String) -> NSError {
    NSError(domain: "DepthlineMenuValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
}

/// Three captures of one simulation tick isolate the ring and the glyph from
/// scenery, the HUD sight and the support effects behind them.
private func checkSupportMarker(marked: Data, ringOnly: Data, plain: Data, name: String,
                                beforeCall: Bool) throws -> Set<Int> {
    let frames = [marked, ringOnly, plain].compactMap { NSBitmapImageRep(data: $0) }
    guard frames.count == 3, let first = frames.first,
          frames.allSatisfy({ $0.pixelsWide == first.pixelsWide && $0.pixelsHigh == first.pixelsHigh &&
                              !$0.isPlanar && $0.bitsPerSample == 8 && $0.samplesPerPixel == 4 &&
                              !$0.bitmapFormat.contains(.alphaFirst) && $0.bitmapData != nil }) else {
        throw validationError("Could not read marker screenshots for " + name)
    }
    var ring = [CGPoint](), glyph = [CGPoint]()
    for y in 0..<first.pixelsHigh {
        let rows = frames.map { $0.bitmapData!.advanced(by: y * $0.bytesPerRow) }
        let (full, circle, background) = (rows[0], rows[1], rows[2])
        for x in 0..<first.pixelsWide {
            let i = 4 * x
            let red = Int(circle[i]), excess = red - max(Int(circle[i+1]), Int(circle[i+2]))
            if red >= 135 && excess >= 50 &&
                excess - (Int(background[i]) - max(Int(background[i+1]), Int(background[i+2]))) >= 35 {
                ring.append(CGPoint(x: x, y: y))
            }
            let difference = abs(Int(full[i]) - Int(circle[i])) + abs(Int(full[i+1]) - Int(circle[i+1])) +
                             abs(Int(full[i+2]) - Int(circle[i+2]))
            if difference > 110 && full[i] >= 155 && full[i+1] >= 115 && full[i+2] >= 80 {
                glyph.append(CGPoint(x: x, y: y))
            }
        }
    }
    func bounds(_ pixels: [CGPoint]) -> CGRect {
        pixels.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: CGSize(width: 1, height: 1))) }
    }
    let oval = bounds(ring)
    try menuCheck(ring.count >= 80 && oval.width > 45 && oval.height > 12 && oval.width > 1.2 * oval.height,
                  "Missing visible red ellipse in " + name)
    if beforeCall {
        var octants = Set<Int>(), curvedPixels = 0
        for point in ring {
            let x = (point.x - oval.midX) / (oval.width / 2), y = (point.y - oval.midY) / (oval.height / 2)
            if (0.75...1.16).contains(hypot(x, y)) {
                curvedPixels += 1
                octants.insert(Int((atan2(y,x) + .pi) * 4 / .pi) % 8)
            }
        }
        try menuCheck(octants.count == 8 && curvedPixels > ring.count * 3 / 4,
                      "Red marker did not follow an elliptical arc in " + name)
    }
    let inside = oval.insetBy(dx: oval.width * 0.17, dy: oval.height * 0.06)
    let centralGlyph = glyph.filter(inside.contains)
    let symbol = bounds(centralGlyph)
    try menuCheck(centralGlyph.count >= 32 && symbol.width >= 6 && symbol.height >= 9 &&
                  abs(symbol.midX - oval.midX) < oval.width * 0.16 &&
                  abs(symbol.midY - oval.midY) < oval.height * 0.25,
                  "The support icon is missing or off-centre in " + name)
    // Uniform scaling preserves each icon's aspect ratio for the shape comparison.
    let scale = 19 / max(symbol.width, symbol.height)
    return Set(centralGlyph.map { point in
        let x = Int((point.x - symbol.midX) * scale + 10)
        let y = Int((point.y - symbol.midY) * scale + 10)
        return y * 20 + x
    })
}

/// Finish a mission through the production frame loop, including any spare ticks in the same frame.
private func winCurrentMission(_ game: Game) throws {
    guard let mission = game.campaign, let sources = game.levelDefinition?["objects"] as? [[String: Any]] else {
        throw validationError("Missing campaign mission")
    }
    for index in sources.indices {
        mission.resolveForce(sourceIndex: index, amount: mission.forceRemaining(sourceIndex: index))
    }
    try menuCheck(mission.remainingForce == 0, "Could not resolve all mission force")
    // Also cover non-aircraft effects. A late incoming shell can finish flying
    // while the display is open, but must not inflict damage after the win.
    game.effects.emit(.groundExplosion, at: .init(0, 0, -500))
    game.previousTime -= 0.15
    game.tick()
    try menuCheck(game.isPlayingVictoryEffects && game.victoryMenu.isHidden, "An explosion was cut off by the menu")
    let health = game.combat.health, score = game.combat.score, seconds = mission.remainingSeconds
    game.enemyOrdnance.spawn(.init(version: game.version, kind: .shell,
                                   position: .init(0,800,-600), velocity: .init(0,0,200)))
    for _ in 0..<360 where !game.isShowingVictoryChoice {
        game.previousTime -= 0.15
        game.tick()
    }
    try menuCheck(game.isShowingVictoryChoice && !game.hasPendingVictoryEffects && game.combat.health == health &&
                  game.combat.score == score && mission.remainingSeconds == seconds, "Late effects did not finish cleanly")
}

private func exerciseTraining(_ game: Game, output: URL,
                              key: (UInt16, NSEvent.ModifierFlags, String) throws -> NSEvent,
                              checkUngraded: () throws -> Void) throws -> [String] {
    guard let training = game.training else { throw validationError("Expected a training game") }
    func tick(_ count: Int = 1) {
        for _ in 0..<count { game.simulationTick() }
        game.updateHUD()
    }
    func look(at point: SCNVector3) {
        let eye = game.camera.worldPosition
        let x = point.x-eye.x, y = point.y-eye.y, z = point.z-eye.z
        var yaw = Double(atan2(-x,-z)) * 180 / .pi - game.input.angles.yawDegrees
        if yaw > 180 { yaw -= 360 } else if yaw < -180 { yaw += 360 }
        let pitch = Double(atan2(y,hypot(x,z))) * 180 / .pi - game.input.angles.pitchDegrees
        let gain = OriginalInputModel.directRadiansPerPoint(level: game.settings.sensitivityLevel) * 180 / .pi
        game.applyDirectAim(deltaX: -yaw/gain, deltaY: (game.settings.invertY ? pitch : -pitch)/gain)
    }
    func trigger(down: Bool) throws {
        guard let event = NSEvent.mouseEvent(with: down ? .leftMouseDown : .leftMouseUp,
                    location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: game.view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: down ? 1 : 0) else { throw validationError("Cannot construct trigger event") }
        if down { game.view.mouseDown(with: event) } else { game.view.mouseUp(with: event) }
    }
    let capture = try NativeCaptureOptions(arguments: ["--capture-width", "1280", "--capture-height", "800"])
    @discardableResult func screenshot(_ name: String) throws -> Data {
        let data = try game.captureNativePixels(options: capture)
        try data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        return data
    }
    var artilleryGlyph: Set<Int>?
    func supportShot(_ name: String) throws -> SCNNode {
        let artillery = training.stage == .artillery
        let expected = artillery ? "TrainingSupportArtilleryIcon" : "TrainingSupportBombingIcon"
        let other = artillery ? "TrainingSupportBombingIcon" : "TrainingSupportArtilleryIcon"
        guard let marker = game.scene.rootNode.childNode(withName: "TrainingSupportArea", recursively: true), !marker.isHidden,
              let ring = marker.childNode(withName: "TrainingSupportRing", recursively: true), !ring.isHidden,
              let icon = marker.childNode(withName: expected, recursively: true), !icon.isHidden,
              marker.childNode(withName: other, recursively: true) == nil else {
            throw validationError("Missing support ring or incorrect icon in " + name)
        }
        let center = marker.worldPosition
        if training.availableSupport != nil {
            let side = abs(center.z - game.camera.worldPosition.z) * 1.5
            look(at: SCNVector3(center.x - side, center.y, center.z))
            game.updateHUD()
            try menuCheck(game.hud.lesson?.bearing == DLoc.text("目标在右侧  →", "Target to the right →"),
                          "Looking away to the left did not point the trainee back to " + name)
            look(at: SCNVector3(center.x + side, center.y, center.z))
            game.updateHUD()
            try menuCheck(game.hud.lesson?.bearing == DLoc.text("←  目标在左侧", "← Target to the left"),
                          "Looking away to the right did not point the trainee back to " + name)
        }
        look(at: center)
        game.updateHUD()
        try menuCheck(game.hud.lesson?.bearing == DLoc.text("目标在准星附近", "Target near the crosshair"),
                      "Aiming back at the ground outline did not settle the bearing in " + name)
        SCNTransaction.flush()
        let marked = try screenshot(name)
        icon.isHidden = true
        defer { marker.isHidden = false; icon.isHidden = false; SCNTransaction.flush() }
        SCNTransaction.flush()
        let ringOnly = try game.captureNativePixels(options: capture)
        marker.isHidden = true
        SCNTransaction.flush()
        let plain = try game.captureNativePixels(options: capture)
        let beforeCall = training.availableSupport != nil
        let glyph = try checkSupportMarker(marked: marked, ringOnly: ringOnly, plain: plain,
                                           name: name, beforeCall: beforeCall)
        if beforeCall {
            if artillery { artilleryGlyph = glyph }
            else {
                guard let artilleryGlyph else { throw validationError("Missing artillery icon comparison") }
                try menuCheck(glyph.symmetricDifference(artilleryGlyph).count > glyph.union(artilleryGlyph).count / 6,
                              "The artillery and bombing markers render the same silhouette")
            }
        }
        return marker
    }
    func finishSupport(_ stage: DepthlineTraining.Stage, marker: SCNNode, limit: Int, groundImpactShot: String? = nil) throws -> Int {
        var checked: Set<OriginalEffectsRenderer.Token> = []
        var shot = groundImpactShot
        let anchor = marker.simdWorldPosition
        func visibleBlasts() -> [OriginalEffectsRenderer.Snapshot] {
            game.effects.snapshots.filter { [.groundExplosion, .waterSplash, .explosion].contains($0.token.kind) }
        }
        for _ in 0..<limit where training.stage == stage {
            let blasts = visibleBlasts()
            for blast in blasts { checked.insert(blast.token) }
            if !blasts.isEmpty {
                try menuCheck(!marker.isHidden && marker.parent != nil && simd_distance(anchor, marker.simdWorldPosition) < 0.01,
                              "The support marker moved or disappeared during an impact")
            }
            if let name = shot, blasts.contains(where: { $0.token.kind == .groundExplosion && $0.state.displayFrame >= 3 }) {
                try menuCheck(try supportShot(name) === marker, "The bombing marker was replaced during the run")
                shot = nil
            }
            tick()
        }
        try menuCheck(shot == nil, "No developed ground explosion was visible for the bomber lesson")
        try menuCheck(visibleBlasts().isEmpty, "The \(stage) lesson ended before its last explosion finished")
        return checked.count
    }
    try menuCheck(training.stage == .capture, "Training did not start at mouse capture")
    game.view.keyDown(with: try key(48, [], "\t"))
    try menuCheck(training.guideOpen, "Training field guide did not open")
    try screenshot("操作速查")
    game.view.keyDown(with: try key(48, [], "\t"))
    try menuCheck(!training.guideOpen && training.stage == .capture, "Closing the field guide changed the lesson")
    let controller = game.view.mouseCapture
    try menuCheck(controller.toggle(pointerInside: true, windowActive: true, anchor: .zero),
                  "Training mouse capture failed")
    defer { controller.release() }
    tick()
    try menuCheck(training.stage == .aim, "Capturing did not reveal the aim lesson")
    try screenshot("训练场")
    look(at: training.target.worldPosition)
    for _ in 0..<20 where training.stage == .aim { tick() }
    try menuCheck(training.stage == .fire, "Aiming the view at the target did not start the firing lesson")
    let nearTarget = training.target.worldPosition
    game.applyDirectAim(deltaX: 260, deltaY: 0)
    try trigger(down: true); tick(5); try trigger(down: false); tick(24)
    let missedShots = game.combat.shots
    try menuCheck(missedShots > 0 && training.stage == .fire, "Shooting away from the target must not pass")
    look(at: training.target.worldPosition)
    try trigger(down: true)
    for _ in 0..<80 where training.stage == .fire { tick() }
    try trigger(down: false)
    try menuCheck(training.stage == .switchWeapon && game.combat.shots > missedShots,
                  "Firing live rounds through the target did not advance")
    game.view.keyDown(with: try key(49, [], " "))
    tick()
    try menuCheck(training.stage == .cannonAim && game.weapons.selected == .cannon,
                  "Switching to the cannon must start its aiming lesson")
    let cannonTarget = training.target.worldPosition
    try menuCheck(simd_distance(SIMD3<Float>(cannonTarget), SIMD3<Float>(nearTarget)) > 5,
                  "Cannon practice needs a new point of aim")
    let initialShells = game.weapons.ammo.cannon
    try trigger(down: true); tick(35); try trigger(down: false); tick(30)
    try menuCheck(training.stage == .cannonAim && game.weapons.ammo.cannon < initialShells,
                  "Firing the cannon at the previous mark passed the aiming lesson")
    try screenshot("火炮瞄准")
    look(at: cannonTarget)
    tick()
    try menuCheck(training.stage == .cannonFire, "Putting the cannon sight on the far target did not advance")
    try screenshot("火炮击靶")
    game.view.keyDown(with: try key(49, [], " "))
    try trigger(down: true); tick(24); try trigger(down: false); tick(30)
    try menuCheck(training.stage == .cannonFire && game.weapons.selected == .machineGun,
                  "Machine gun rounds passed the cannon exercise")
    game.view.keyDown(with: try key(49, [], " "))
    look(at: nearTarget)
    try trigger(down: true); tick(35); try trigger(down: false); tick(30)
    try menuCheck(training.stage == .cannonFire, "Missing the far target with the cannon passed the exercise")
    look(at: cannonTarget)
    let shellsBeforeHit = game.weapons.ammo.cannon
    try trigger(down: true)
    for _ in 0..<100 where training.stage == .cannonFire { tick() }
    try trigger(down: false)
    try menuCheck(training.stage == .handgun && game.weapons.ammo.cannon < shellsBeforeHit,
                  "A live cannon hit on the far target did not open the handgun lesson")
    try screenshot("手枪教学")
    look(at: training.target.worldPosition)
    let cannonAmmo = game.weapons.ammo.cannon
    try trigger(down: true); tick(35); try trigger(down: false); tick(24)
    try menuCheck(game.weapons.ammo.cannon < cannonAmmo && training.stage == .handgun,
                  "Other weapons must not pass the handgun lesson")
    game.view.keyDown(with: try key(5, [], "g"))
    tick()
    try menuCheck(game.weapons.selected == .handgun && training.stage == .handgun,
                  "Handgun lesson must require a hit after selection")
    let handgunAmmo = game.weapons.ammo.handgun
    look(at: training.target.worldPosition)
    try trigger(down: true)
    for _ in 0..<80 where training.stage == .handgun { tick() }
    try trigger(down: false)
    try menuCheck(training.stage == .supply && game.weapons.ammo.handgun < handgunAmmo,
                  "A live handgun hit did not open the supply lesson")
    game.view.keyDown(with: try key(46, [], "m"))
    try menuCheck(game.projectiles.missileCount == 0 && training.stage == .supply,
                  "Pressing M with an empty launcher advanced the course")
    guard let chute = game.supplyNodes[212], !chute.isHidden else { throw validationError("Training box is absent") }
    let viewport = game.hud.bounds
    let panels = DepthlineTrainingHUD.panels(in: viewport.size)
    let projection = game.camera.camera!.projectionTransform
    // Test both painted objects from the actual firing position before the
    // trainee turns. Project into the top-left HUD coordinate system.
    for height in [CGFloat(0.55), -4.5] {
        let point = game.camera.convertPosition(SCNVector3(0, height, 0), from: chute)
        try menuCheck(point.z < 0, "New supply is behind the firing lane")
        let x = (1 - point.x / point.z * projection.m11 - projection.m31) * viewport.width * 0.5
        let y = (1 + point.y / point.z * projection.m22 + projection.m32) * viewport.height * 0.5
        let spot = NSRect(x: x - 7, y: y - 7, width: 14, height: 14)
        try menuCheck(viewport.contains(spot) && !panels.contains { $0.intersects(spot) },
                      "Instruction panel covers the new supply at \(spot)")
    }
    try screenshot("补给教学")
    try menuCheck(game.scene.rootNode.childNode(withName: "TrainingSupportArea", recursively: true) == nil,
                  "The supply lesson must not reveal a support area")
    game.view.keyDown(with: try key(49, [], " "))
    look(at: chute.convertPosition(SCNVector3(0,0.55,0), to: nil))
    try trigger(down: true)
    for _ in 0..<120 where training.stage == .supply {
        look(at: chute.convertPosition(SCNVector3(0,0.55,0), to: nil))
        tick()
    }
    try trigger(down: false)
    try menuCheck(training.stage == .artillery && !game.supplyMessage.isEmpty && chute.isHidden,
                  "Collecting the supply should issue one coastal artillery call")
    let artilleryMarker = try supportShot("海岸炮兵呼叫前")
    // Keep the real support runs and their observation screenshots reproducible.
    game.random = Beach2000Supply.Random(seed: 20_001_102)
    game.view.keyDown(with: try key(11, [], "b"))
    try menuCheck(training.availableSupport == .beach2000GroundBarrage && game.bombers.isEmpty,
                  "The bomber key must not consume the artillery lesson")
    game.view.keyDown(with: try key(0, [], "a"))
    tick(25)
    let remaining = game.barrage?.remainingTicks
    game.view.keyDown(with: try key(0, [], "a"))
    try menuCheck(remaining == 475 && game.barrage?.remainingTicks == remaining && training.availableSupport == nil,
                  "A starts a single production barrage and cannot restart its approach")
    for _ in 0..<475 where game.barrage?.impactCount == 0 { tick() }
    try menuCheck((game.barrage?.impactCount ?? 0) > 0 && training.stage == .artillery,
                  "Observe real artillery impacts before the lesson advances")
    try menuCheck(game.effects.snapshots.contains(where: { [.groundExplosion, .waterSplash, .explosion].contains($0.token.kind) }),
                  "The barrage reached the beach without a visible impact")
    tick(3)
    try menuCheck(try supportShot("海岸炮兵支援教学") === artilleryMarker,
                  "The artillery outline moved after the call")
    let shellsObserved = try finishSupport(.artillery, marker: artilleryMarker, limit: 260)
    try menuCheck(shellsObserved == 24, "Expected 24 actual training shell impacts, saw \(shellsObserved)")
    try menuCheck(training.stage == .bombers && training.availableSupport == .beach2002NineBomberAirstrike,
                  "Finishing the barrage should issue a hill-sector bombing run")
    let bombingMarker = try supportShot("丘陵轰炸机呼叫前")
    game.view.keyDown(with: try key(0, [], "a"))
    try menuCheck(game.barrage == nil && training.availableSupport == .beach2002NineBomberAirstrike,
                  "The artillery key must not consume the bombing run")
    game.view.keyDown(with: try key(11, [], "b"))
    tick()
    let formation = game.bombers
    game.view.keyDown(with: try key(11, [], "b"))
    try menuCheck(formation.count == 9 && formation.allSatisfy { $0.active } && formation[0] === game.bombers.first &&
                  training.availableSupport == nil, "B dispatches one nine-plane formation")
    for _ in 0..<1500 where !game.enemyOrdnance.rounds.contains(where: { $0.state.kind == .bomb }) { tick() }
    guard let bomb = game.enemyOrdnance.rounds.first(where: { $0.state.kind == .bomb }) else {
        throw validationError("No live bomb released from the training formation")
    }
    try menuCheck(bomb.state.version == .beach2002 && training.stage == .bombers, "Training bombs must use hill-sector ballistics")
    let bombsObserved = try finishSupport(.bombers, marker: bombingMarker, limit: 1900, groundImpactShot: "丘陵轰炸机支援教学")
    try menuCheck(bombsObserved == training.airstrikeImpacts, "Some training bomb impacts were not observed")
    try menuCheck(training.airstrikeImpacts > 0 && training.stage == .missile && game.bombers.isEmpty &&
                  !game.enemyOrdnance.rounds.contains(where: { $0.state.kind == .bomb }),
                  "The missile range opens after actual bomb impacts and the strike finishes")
    try menuCheck(game.scene.rootNode.childNode(withName: "TrainingSupportArea", recursively: true) == nil,
                  "The completed bombing run left its target outline in the missile lesson")
    print("PASS training support ellipses and distinct centred icons: \(shellsObserved) artillery and \(bombsObserved) bomber impacts observed")
    try checkUngraded()
    guard let firstAircraft = training.helicopter else { throw validationError("Final helicopter is absent") }
    look(at: firstAircraft.aimPoint)
    tick()
    try screenshot("直升机导弹教学")

    // A live missile launched away from the helicopter must expire without awarding a flag.
    let eye = game.camera.worldPosition
    let farSide = SCNVector3(eye.x, eye.y + 30, eye.z + 100)
    look(at: farSide)
    let missilesBeforeMiss = game.weapons.ammo.missile
    game.view.keyDown(with: try key(46, [], "m"))
    try menuCheck(training.stage == .missile && game.projectiles.missileCount == 1 &&
                  game.weapons.ammo.missile < missilesBeforeMiss, "The final lesson must wait for impact")
    tick(140)
    try menuCheck(game.projectiles.missileCount == 0 && training.stage == .missile &&
                  training.helicopter?.enemy === firstAircraft.enemy, "A missed missile advanced the helicopter lesson")
    try checkUngraded()

    // Use the selected cannon against the aircraft. It must be destructible while the
    // course keeps the missile objective and provides a fresh airborne target.
    try menuCheck(game.weapons.selected == .cannon, "Expected the cannon used to collect the supply")
    look(at: firstAircraft.aimPoint)
    try trigger(down: true)
    for _ in 0..<160 where training.helicopter?.enemy === firstAircraft.enemy { tick() }
    try trigger(down: false)
    try menuCheck(training.stage == .missile && training.helicopter?.enemy !== firstAircraft.enemy,
                  "Cannon fire must destroy the helicopter and leave the final exercise open")
    try checkUngraded()
    for _ in 0..<120 where training.helicopter == nil { tick() }
    guard let secondAircraft = training.helicopter, secondAircraft.enemy !== firstAircraft.enemy else {
        throw validationError("Missing replacement helicopter after a cannon kill")
    }
    look(at: secondAircraft.aimPoint)
    try screenshot("直升机补靶")
    for weapon in [OriginalWeapon.machineGun, .handgun] {
        guard let aircraft = training.helicopter else { throw validationError("Missing target for \(weapon)") }
        let handgun = weapon == .handgun
        game.view.keyDown(with: try key(handgun ? 5 : 49, [], handgun ? "g" : " "))
        try menuCheck(game.weapons.selected == weapon, "Could not select \(weapon) against the helicopter")
        look(at: aircraft.aimPoint)
        // Each pistol shot needs a fresh click. Short bursts also leave time
        // to watch the live target, without firing into its replacement.
        for _ in 0..<24 where training.helicopter?.enemy === aircraft.enemy {
            try trigger(down: true); tick(8); try trigger(down: false); tick(9)
        }
        try menuCheck(training.stage == .missile && training.helicopter?.enemy !== aircraft.enemy,
                      "\(weapon) did not down the helicopter while keeping the lesson open")
        for _ in 0..<120 where training.helicopter == nil { tick() }
        try checkUngraded()
    }
    guard let replacement = training.helicopter else { throw validationError("Missing final missile target") }
    let recordGraduation = game.onSectorCompleted
    var graduations = 0
    game.onSectorCompleted = { graduations += 1; recordGraduation?() }
    defer { game.onSectorCompleted = recordGraduation }

    // Aim just above the fuselage. Record the round's direction change on its
    // way to the replacement to verify the same missile guidance used in play.
    let centre = replacement.aimPoint
    look(at: SCNVector3(centre.x, centre.y + 4, centre.z))
    game.view.keyDown(with: try key(46, [], "m"))
    func missileDirection() -> SIMD3<Float>? {
        game.projectiles.snapshots.first(where: { $0.kind.missileSlot != nil }).map { SIMD3<Float>($0.direction) }
    }
    guard let launchDirection = missileDirection(), training.stage == .missile else {
        throw validationError("Could not launch a missile at the replacement helicopter")
    }
    var guided = false
    for _ in 0..<145 where training.stage == .missile {
        tick()
        if let flightDirection = missileDirection(), simd_distance(flightDirection, launchDirection) > 0.005 {
            guided = true
        }
    }
    try menuCheck(guided && training.stage == .complete && game.projectiles.missileCount == 0,
                  "The guided missile must destroy the helicopter before graduation")
    try menuCheck(graduations == 1 && game.isPlayingVictoryEffects && !game.isShowingVictoryChoice &&
                  game.victoryMenu.isHidden && !game.acceptsBattleInput && game.hasPendingVictoryEffects,
                  "The missile hit must save graduation and leave its effects visible before the training menu")
    let finalScore = game.combat.score
    var effectTicks = 0
    while game.isPlayingVictoryEffects && effectTicks < 1800 {
        try menuCheck(game.victoryMenu.isHidden, "The training menu covered the last hit")
        tick()
        effectTicks += 1
    }
    try menuCheck(effectTicks > 0 && !game.hasPendingVictoryEffects && game.isShowingVictoryChoice &&
                  !game.victoryMenu.isHidden && graduations == 1 && game.combat.score == finalScore &&
                  game.pendingNextLevel == nil && !game.didCompleteCampaign && !game.resultRecorded,
                  "Finishing the training effects must show graduation exactly once without a campaign result")
    return ["capture","aim","fire","switchWeapon","cannonAim","cannonFire","handgun","supply","artillery","bombers","missile","complete"]
}
