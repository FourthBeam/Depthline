import AppKit

/// Crisp point-based tactical display. Paths and type are rasterized at the
/// current backing scale, including the native 3840 x 2160 capture path.
enum RemasteredHUD {
    private static let ink = NSColor(srgbRed: 0.93, green: 0.95, blue: 0.88, alpha: 1)
    private static let muted = NSColor(srgbRed: 0.66, green: 0.74, blue: 0.73, alpha: 1)
    private static let accent = NSColor(srgbRed: 0.88, green: 0.78, blue: 0.47, alpha: 1)
    private static let panel = NSColor(srgbRed: 0.025, green: 0.045, blue: 0.052, alpha: 0.78)

    private static func text(_ value: String, _ rect: NSRect, _ size: CGFloat,
                             _ color: NSColor = ink, bold: Bool = false,
                             align: NSTextAlignment = .left, mono: Bool = false, fit: Bool = false) {
        let style = NSMutableParagraphStyle(); style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
                        : NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        (value as NSString).draw(in: rect, withAttributes: [.font: fit ? font.fitting(value, in: rect.width) : font,
                                                          .foregroundColor: color, .paragraphStyle: style])
    }
    private static func box(_ rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        panel.setFill(); path.fill()
        NSColor(white: 1, alpha: 0.13).setStroke(); path.lineWidth = 1; path.stroke()
    }
    private static func bar(_ rect: NSRect, fraction: CGFloat, color: NSColor) {
        NSColor(white: 1, alpha: 0.12).setFill(); NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        let fill = NSRect(x: rect.minX, y: rect.minY, width: rect.width * min(1, max(0, fraction)), height: rect.height)
        color.setFill(); NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }
    static func draw(_ hud: OriginalHUD) {
        let scale = max(0.65, min(1.25, hud.bounds.width / 1280, hud.bounds.height / 720))
        NSGraphicsContext.saveGraphicsState()
        let tx = NSAffineTransform(); tx.scale(by: scale); tx.concat()
        let w = hud.bounds.width / scale, h = hud.bounds.height / scale
        let margin: CGFloat = 22
        box(NSRect(x: margin, y: margin, width: 214, height: 66))
        text(DLoc.text("阵地防御", "Defenses"), NSRect(x: margin + 14, y: margin + 10, width: 140, height: 20), 12, muted)
        text("\(Int(max(0, hud.health) * 100))%", NSRect(x: margin + 132, y: margin + 8, width: 68, height: 24), 18, bold: true, align: .right, mono: true)
        bar(NSRect(x: margin + 14, y: margin + 44, width: 186, height: 6), fraction: hud.health,
            color: hud.health < 0.3 ? NSColor(srgbRed: 0.94, green: 0.30, blue: 0.20, alpha: 1) : accent)

        box(NSRect(x: w - margin - 214, y: margin, width: 214, height: 66))
        text(DLoc.text("敌军兵力", "Enemy force"), NSRect(x: w - margin - 200, y: margin + 10, width: 130, height: 20), 12, muted)
        text("\(Int(max(0, hud.forceFraction) * 100))%", NSRect(x: w - margin - 80, y: margin + 8, width: 66, height: 24), 18, bold: true, align: .right, mono: true)
        bar(NSRect(x: w - margin - 200, y: margin + 44, width: 186, height: 6), fraction: CGFloat(hud.forceFraction),
            color: NSColor(srgbRed: 0.79, green: 0.39, blue: 0.28, alpha: 1))

        box(NSRect(x: w / 2 - 104, y: margin, width: 208, height: 62))
        text("\(DepthlineIdentity.sector(hud.gameID))  /  \(String(format: "%02d", hud.level))", NSRect(x: w / 2 - 96, y: margin + 9, width: 192, height: 18), 11, muted, align: .center)
        let time: String
        if let seconds = hud.remainingTime { time = String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60) }
        else { time = hud.isNight ? DLoc.text("夜间防守", "Night defense") : DLoc.text("守住防线", "Hold the line") }
        text(time, NSRect(x: w / 2 - 96, y: margin + 28, width: 192, height: 31), 21,
             bold: true, align: .center, mono: true, fit: hud.remainingTime == nil)

        box(NSRect(x: margin, y: h - margin - 98, width: 250, height: 98))
        text(hud.weaponLabel, NSRect(x: margin + 16, y: h - margin - 85, width: 134, height: 20), 13, accent, bold: true)
        text(DLoc.text("当前弹药", "Ammunition"), NSRect(x: margin + 16, y: h - margin - 24, width: 220, height: 18), 11, muted)
        text("\(max(0, hud.weaponAmmo))", NSRect(x: margin + 14, y: h - margin - 65, width: 138, height: 42), 36, bold: true, mono: true)
        text("/ \(hud.weaponCapacity)", NSRect(x: margin + 140, y: h - margin - 48, width: 93, height: 20), 15, muted, mono: true)
        box(NSRect(x: w - margin - 250, y: h - margin - 98, width: 250, height: 98))
        text(DLoc.text("导弹", "Missiles"), NSRect(x: w - margin - 234, y: h - margin - 84, width: 150, height: 20), 13, accent, bold: true)
        text("\(hud.missileAmmo)", NSRect(x: w - margin - 90, y: h - margin - 87, width: 74, height: 35), 29, bold: true, align: .right, mono: true)
        let ready = hud.missileReadySlots?.filter { $0 }.count ?? 2
        text(DLoc.text("就绪 \(ready) / 2   ·   支援 \(hud.supportCount)", "Ready \(ready) / 2   ·   Support \(hud.supportCount)"), NSRect(x: w - margin - 234, y: h - margin - 48, width: 220, height: 20), 12, muted)
        if hud.isNight && hud.gameID == "2002" {
            text(DLoc.text("照明弹  \(hud.flareAmmo)", "Flares  \(hud.flareAmmo)"), NSRect(x: w - margin - 234, y: h - margin - 25, width: 220, height: 19), 11, muted)
        }

        if hud.gameID == "2000" {
            text(DLoc.text("分数  \(hud.score)0", "Score  \(hud.score)0"), NSRect(x: w / 2 - 140, y: h - 91, width: 280, height: 25), 18, bold: true, align: .center, mono: true)
        }
        if !hud.message.isEmpty {
            box(NSRect(x: w / 2 - 230, y: 108, width: 460, height: 38))
            text(hud.message, NSRect(x: w / 2 - 216, y: 118, width: 432, height: 23), 13, accent, align: .center)
        }
        if !hud.paused && !hud.finished && !hud.victorious && hud.health > 0 {
            reticle(at: NSPoint(x: w / 2, y: h * hud.sightVerticalFraction), weapon: hud.weaponSight)
        }
        if hud.damageFlash > 0 {
            NSColor(srgbRed: 0.85, green: 0.13, blue: 0.05, alpha: min(1, hud.damageFlash) * 0.10).setFill()
            NSRect(x: 0, y: 0, width: w, height: h).fill()
        }
        if !hud.paused && (hud.finished || hud.health <= 0) {
            NSColor(white: 0.015, alpha: 0.47).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
            let title = DLoc.text("防线失守", "Defenses overrun")
            let detail = DLoc.text("⌘R 重新开始   ·   ⌘L 返回游戏选择", "⌘R  Restart   ·   ⌘L  Sector select")
            text(title, NSRect(x: w / 2 - 240, y: h / 2 - 35, width: 480, height: 50), 34, bold: true, align: .center)
            text(detail, NSRect(x: w / 2 - 260, y: h / 2 + 24, width: 520, height: 28), 15, muted, align: .center)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func reticle(at p: NSPoint, weapon: String) {
        // Composite the whole sight once. Overlapping cross, circle and outline
        // must not add opacity over a small distant target.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(0.50)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer(); context.restoreGState() }
        let line = NSBezierPath()
        func segment(_ a: NSPoint, _ b: NSPoint) { line.move(to: NSPoint(x: p.x + a.x, y: p.y + a.y)); line.line(to: NSPoint(x: p.x + b.x, y: p.y + b.y)) }
        let outer: CGFloat = weapon == "handgun" ? 13 : 24
        let gap: CGFloat = weapon == "handgun" ? 5 : 12
        segment(NSPoint(x: -outer, y: 0), NSPoint(x: -gap, y: 0)); segment(NSPoint(x: gap, y: 0), NSPoint(x: outer, y: 0))
        segment(NSPoint(x: 0, y: -outer), NSPoint(x: 0, y: -gap)); segment(NSPoint(x: 0, y: gap), NSPoint(x: 0, y: outer))
        if weapon == "machineGun" { line.appendOval(in: NSRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)) }
        if weapon == "cannon" {
            for i in 1...3 { let y = CGFloat(i * 8 + 21); segment(NSPoint(x: -CGFloat(i * 3), y: y), NSPoint(x: CGFloat(i * 3), y: y)) }
        }
        NSColor(white: 0.02, alpha: 0.8).setStroke(); line.lineWidth = 3.2; line.stroke()
        ink.withAlphaComponent(0.95).setStroke(); line.lineWidth = 1.25; line.stroke()
        ink.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 1.25, y: p.y - 1.25, width: 2.5, height: 2.5)).fill()
    }
}
