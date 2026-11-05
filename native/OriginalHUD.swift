import AppKit

/// Original HUD coordinates from 2000 FUN_00402a02 and 2002 FUN_004021c4/00402a1c.
/// The originals use GDI text, not a numeric sprite sheet. Native text substitutes that rasterizer;
/// icons and the 2002 sight are the shipped pixels. Original 2000 uses its weapon's physical sight.
final class OriginalHUD: NSView {
    let gameID: String
    var remastered = true
    var health: CGFloat = 1
    var level = 1
    var score = 0                         // Original internal score units, before 2000's trailing0.
    var remainingTime: Int?
    var forceFraction = 1.0
    var weaponAmmo = 0
    var weaponCapacity = 1
    var missileAmmo = 0
    var missileCapacity = 20
    var missileReadySlots: [Bool]?        // Pass OriginalWeaponState.missileSlots.map(\.ready).
    var supportCount = 0
    var flareAmmo = 0
    var isNight = false
    var crosshairVisible = true
    var weaponLabel = DLoc.text("机枪", "Machine gun")
    var weaponSight = "machineGun"
    var sightVerticalFraction = DepthlineCamera.sightFractionFromTop
    var cameraFieldOfView = 53.13010235415598 // Horizontal; source focal=viewport width.
    var paused = false
    var finished = false
    var victorious = false
    var message = ""
    weak var trainingGame: Game?
    var mouseCaptured = false {
        didSet { if mouseCaptured != oldValue { updateCaptureDescription() } }
    }
    var damageFlash: CGFloat = 0
    private(set) var assetWarnings: [String] = []
    private var images: [String: NSImage] = [:]
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let game = trainingGame, let training = game.training, !game.view.mouseCapture.isCaptured else { return nil }
        let local = convert(point, from: superview)
        return DepthlineTrainingHUD.action(at: local, hud: self, training: training) == nil ? nil : self
    }
    override func mouseDown(with event: NSEvent) {
        guard let game = trainingGame, let training = game.training else { return }
        switch DepthlineTrainingHUD.action(at: convert(event.locationInWindow, from: nil), hud: self, training: training) {
        case .guide: training.toggleGuide(in: game); window?.makeFirstResponder(game.view)
        case nil: break
        }
    }

    init(frame: NSRect, gameID: String, resourceRoot: URL) {
        self.gameID = gameID
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        refreshLanguage()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshLanguage() {
        if trainingGame != nil {
            setAccessibilityLabel(DepthlineIdentity.sector(DepthlineIdentity.trainingID))
            setAccessibilityHelp(DLoc.text("Tab 打开按键速查，Command L 离开教学",
                                           "Tab opens the controls. Command L leaves training."))
        } else {
            let sector = DepthlineIdentity.sector(gameID)
            setAccessibilityLabel(DLoc.text("\(sector) 战斗状态", "\(sector) battle status"))
        }
        updateCaptureDescription()
        needsDisplay = true
    }

    private func updateCaptureDescription() {
        setAccessibilityValue(mouseCaptured ? DLoc.text("鼠标已捕获", "Mouse locked")
                                            : DLoc.text("鼠标已释放", "Mouse released"))
    }

    /// SCNView.snapshot excludes AppKit overlays. Draw the HUD in the same
    /// top-left coordinate system used by NSView, including text and icon crops;
    /// calling draw directly in an ordinary NSImage context inverted the HUD.
    func composited(over background: NSImage) -> NSImage {
        let result = NSImage(size: bounds.size)
        result.lockFocusFlipped(true)
        background.draw(in: bounds, from: .zero, operation: .copy, fraction: 1,
                        respectFlipped: true, hints: nil)
        draw(bounds)
        result.unlockFocus()
        return result
    }

    /// Draw text/paths directly into the requested backing pixels, with the
    /// same logical point layout as a Retina view. Never enlarge a HUD snapshot.
    func compositePNG(over background: NSImage, pixels: CGSize, points: CGSize) throws -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw NSError(domain: "HUDCapture", code: 1)
        }
        let oldBounds = bounds
        setBoundsSize(points)
        NSGraphicsContext.saveGraphicsState()
        let cg = context.cgContext
        cg.translateBy(x: 0, y: pixels.height)
        cg.scaleBy(x: pixels.width / points.width, y: -pixels.height / points.height)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        background.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.none])
        draw(bounds)
        NSGraphicsContext.restoreGraphicsState()
        bounds = oldBounds
        guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "HUDCapture", code: 2) }
        return data
    }

    /// Decode the original black-key pixels; for CrosshairAlpha use the original white mask with
    /// Geometry.3D's Color255,0,32. No new artwork is generated and colored atlas pixels stay intact.
    private static func prepare(_ source: NSImage, mask: Bool) -> NSImage? {
        var rect = NSRect(origin: .zero, size: source.size)
        guard let cg = source.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let original = NSBitmapImageRep(cgImage: cg)
        for y in 0..<cg.height { for x in 0..<cg.width {
            guard let color = original.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
            if mask {
                out.setColor(NSColor(deviceRed: 1, green: 0, blue: 32.0 / 255,
                                     alpha: max(r, max(g, b))), atX: x, y: y)
            } else {
                out.setColor(NSColor(deviceRed: r, green: g, blue: b,
                                     alpha: r == 0 && g == 0 && b == 0 ? 0 : color.alphaComponent), atX: x, y: y)
            }
        } }
        let result = NSImage(size: NSSize(width: cg.width, height: cg.height))
        result.addRepresentation(out)
        return result
    }

    private func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat = 200,
                      size: CGFloat = 12, color: NSColor = NSColor(calibratedWhite: 0.88, alpha: 1),
                      alignment: NSTextAlignment = .left, bold: Bool = false) {
        let style = NSMutableParagraphStyle(); style.alignment = alignment; style.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: size * 1.5),
                                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular),
                                                 .foregroundColor: color, .paragraphStyle: style])
    }
    private func fill(_ rect: NSRect, _ color: NSColor) { color.setFill(); rect.fill() }
    private func meterColor(_ value: Double) -> NSColor {
        if value < 26 { return NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1) }
        if value <= 50 { return NSColor(calibratedRed: 160.0 / 255, green: 144.0 / 255, blue: 0, alpha: 1) }
        return NSColor(calibratedRed: 0, green: 128.0 / 255, blue: 0, alpha: 1)
    }
    private func meter(x: CGFloat, y: CGFloat, fraction: Double, enemy: Bool = false, width: CGFloat = 100) {
        fill(NSRect(x: x, y: y, width: width + 8, height: 22), .black)
        let percent = min(100, max(0, fraction * 100))
        if percent > (gameID == "2000" ? 1 : 0) {
            fill(NSRect(x: x + 4, y: y + 4, width: width * CGFloat(percent / 100), height: 14),
                 enemy ? NSColor(calibratedRed: 1, green: 64.0 / 255, blue: 0, alpha: 1) : meterColor(percent))
        }
    }
    private func image(_ name: String, at destination: NSRect, cropTopLeft: NSRect? = nil) {
        guard let image = images[name] else { return }
        var source = NSRect(origin: .zero, size: image.size)
        if let cropTopLeft {
            source = NSRect(x: cropTopLeft.minX, y: image.size.height - cropTopLeft.maxY,
                            width: cropTopLeft.width, height: cropTopLeft.height)
        }
        image.draw(in: destination, from: source, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: remastered ? NSImageInterpolation.high : NSImageInterpolation.none])
    }
    private func icon2002(_ number: Int, x: CGFloat, y: CGFloat) {
        // Atlas UVs and displayed extents from FUN_00402d84; GameOver intentionally stretches2×.
        let crops: [Int: NSRect] = [0: NSRect(x: 0, y: 0, width: 39, height: 31),
                                   1: NSRect(x: 56, y: 0, width: 7, height: 31),
                                   3: NSRect(x: 0, y: 32, width: 63, height: 31),
                                   4: NSRect(x: 63, y: 32, width: 64, height: 31),
                                   5: NSRect(x: 0, y: 64, width: 127, height: 31),
                                   6: NSRect(x: 0, y: 96, width: 127, height: 31)]
        guard let crop = crops[number] else { return }
        let size = number == 6 ? NSSize(width: 255, height: 48)
            : NSSize(width: number == 4 ? 63 : crop.width, height: crop.height)
        image("Icons128x128", at: NSRect(origin: NSPoint(x: x, y: y), size: size), cropTopLeft: crop)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let game = trainingGame, let training = game.training {
            DepthlineTrainingHUD.draw(self, game: game, training: training)
            return
        }
        if remastered { RemasteredHUD.draw(self); return }
        let scale = min(bounds.width / 640, bounds.height / 480)
        guard scale > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
        let w = bounds.width / scale, h = bounds.height / scale
        meter(x: 4, y: 4, fraction: Double(health))
        meter(x: w - 112, y: 4, fraction: forceFraction, enemy: true)
        meter(x: 4, y: h - 26, fraction: Double(weaponAmmo) / Double(max(1, weaponCapacity)))
        text(DLoc.text("防御力", "SHIELD"), x: 34, y: 6, width: 76)
        text(DLoc.text("敌  军", "ENEMY"), x: w - 84, y: 6, width: 76)
        if gameID == "2000" { draw2000(w: w, h: h) } else { draw2002(w: w, h: h) }

        // The original2000 sight belongs to weapon geometry. The2002 plane projects with native FOV.
        if gameID == "2002", crosshairVisible, !paused, !finished, !victorious {
            let radians = min(170, max(1, cameraFieldOfView)) * .pi / 360
            let focal = w / 2 / CGFloat(tan(radians))
            let size = focal * 1000 / 14000
            image("CrosshairAlpha64x64", at: NSRect(x: w / 2 - size / 2 + focal * 8 / 14000,
                                                    y: h / 2 - size / 2, width: size, height: size))
        }
        if health <= 0 || finished {
            if gameID == "2000" { image("IconGameOver256x35", at: NSRect(x: w / 2 - 128, y: h / 2 - 20, width: 256, height: 35)) }
            else { icon2002(6, x: w / 2 - 128, y: h / 2 - 24) }
            text(DLoc.text("防线失守 · ⌘R 重新开始 · ⌘L 返回选择", "Defenses overrun · ⌘R Restart · ⌘L Sector select"), x: w / 2 - 190, y: h / 2 + 34, width: 380, alignment: .center)
        }
        text(DLoc.text("P 暂停 · ⌘L 返回", "P Pause · ⌘L Sector select"), x: 8, y: h - 52, width: min(460, w - 16), size: 9)
        if !message.isEmpty { text(message, x: 8, y: h - 67, width: w - 16, size: 10) }
        if damageFlash > 0 { fill(NSRect(x: 0, y: 0, width: w, height: h), NSColor(calibratedRed: 1, green: 0.72, blue: 0.24, alpha: min(1, damageFlash) * 0.18)) }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw2000(w: CGFloat, h: CGFloat) {
        meter(x: w - 112, y: h - 26, fraction: Double(missileAmmo) / Double(max(1, missileCapacity)))
        let blue = NSColor(calibratedRed: 0, green: 0, blue: 64.0 / 255, alpha: 1)
        fill(NSRect(x: 116, y: h - 26, width: 34, height: 22), blue)
        fill(NSRect(x: w - 150, y: h - 26, width: 34, height: 22), blue)
        text(DLoc.text("弹药", "Ammo"), x: 38, y: h - 23, width: 66)
        text(String(weaponAmmo), x: 120, y: h - 23, width: 30)
        text(DLoc.text("导弹", "Missiles"), x: w - 90, y: h - 23, width: 80)
        text(String(missileAmmo), x: w - 146, y: h - 23, width: 30)
        text(DLoc.text("分数  \(score)0", "Score  \(score)0"), x: w / 2 - 66, y: h - 23, width: 165)
        if supportCount > 0 {
            image("IconHowitzer64x30", at: NSRect(x: 168, y: h - 34, width: 64, height: 30))
            text("×\(supportCount)", x: 233, y: h - 22, width: 31, size: 10)
        }
        let seconds = max(0, remainingTime ?? 0)
        fill(NSRect(x: w / 2 - (seconds == 0 ? 30 : 60), y: 4, width: seconds == 0 ? 80 : 120, height: 22), .black)
        text(DLoc.text("关卡 \(level)", "Level \(level)"), x: w / 2 - (seconds == 0 ? 24 : 50), y: 6, width: 68)
        if seconds > 0 {
            text(String(format: "%d:%02d", seconds / 60, seconds % 60), x: w / 2 + 20, y: 6, width: 45,
                 color: NSColor(calibratedRed: 0, green: 224.0 / 255, blue: 0, alpha: 1))
        }
    }
    private func draw2002(w: CGFloat, h: CGFloat) {
        fill(NSRect(x: w / 2 - 44, y: 4, width: 88, height: 22), NSColor(calibratedRed: 0, green: 0, blue: 64.0 / 255, alpha: 1))
        text(DLoc.text("关卡 \(level)", "Level \(level)"), x: w / 2 - 34, y: 6, width: 78, color: NSColor(calibratedRed: 224.0 / 255, green: 32.0 / 255, blue: 16.0 / 255, alpha: 1))
        text(DLoc.text("弹药", "AMMO"), x: 24, y: h - 23, width: 50)
        text(String(weaponAmmo), x: 72, y: h - 23, width: 38)
        if isNight && flareAmmo > 0 {
            meter(x: 116, y: h - 26, fraction: Double(flareAmmo) / 20, width: 80)
            text(DLoc.text("照明弹 \(flareAmmo)", "FLARES \(flareAmmo)"), x: 124, y: h - 23, width: 80, size: 11)
        }
        if missileAmmo > 0 {
            icon2002(0, x: w / 2 - 20, y: h - 34)
            let ready = missileReadySlots ?? [missileAmmo > 0, missileAmmo > 1]
            if ready.first == true { icon2002(1, x: w / 2 - 18, y: h - 34) }
            if ready.dropFirst().first == true { icon2002(1, x: w / 2 + 10, y: h - 34) }
            let reserve = missileAmmo - ready.prefix(2).filter { $0 }.count
            if reserve > 0 {
                for i in 0..<min(20, reserve) { icon2002(1, x: w / 2 + 32 + CGFloat(i) * 12, y: h - 34) }
            }
        }
        if supportCount > 0 {
            icon2002(4, x: w / 2 - 96, y: h - 34)
            text("×\(supportCount)", x: w / 2 - 42, y: h - 50, width: 40, size: 10)
        }
    }
}
