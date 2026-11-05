import AppKit

enum DepthlineTrainingHUD {
    enum Action { case guide }

    private static let gold = NSColor(srgbRed: 0.94, green: 0.81, blue: 0.51, alpha: 1)
    private static let ink = NSColor(srgbRed: 0.92, green: 0.94, blue: 0.90, alpha: 1)
    private static let muted = NSColor(srgbRed: 0.70, green: 0.77, blue: 0.76, alpha: 1)
    private static let ground = NSColor(srgbRed: 0.035, green: 0.070, blue: 0.079, alpha: 0.94)

    private struct Layout {
        let scale: CGFloat, w: CGFloat, h: CGFloat
        init(_ size: CGSize) {
            scale = max(0.3, min(1.3, size.width / 990, size.height / 600))
            w = size.width / scale; h = size.height / scale
        }
        var guide: NSRect { NSRect(x: w - 164, y: 24, width: 140, height: 38) }
        var lesson: NSRect { NSRect(x: 24, y: 24, width: 436, height: 158) }
        var sheet: NSRect { NSRect(x: (w - 900) / 2, y: (h - 506) / 2, width: 900, height: 506) }
        var dismiss: NSRect { NSRect(x: sheet.maxX - 144, y: sheet.minY + 19, width: 118, height: 36) }
    }

    static func panels(in size: CGSize) -> [CGRect] {
        let layout = Layout(size)
        let transform = CGAffineTransform(scaleX: layout.scale, y: layout.scale)
        return [layout.lesson, layout.guide].map { $0.applying(transform) }
    }

    private static func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat,
                             color: NSColor = ink, weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .left,
                             wrappedHeight: CGFloat? = nil) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = wrappedHeight == nil ? .byTruncatingTail : .byWordWrapping
        let baseFont = NSFont.systemFont(ofSize: size, weight: weight)
        let font = wrappedHeight == nil ? baseFont.fitting(value, in: width) : baseFont
        let rect = NSRect(x: x, y: y, width: width, height: wrappedHeight ?? size * 1.8)
        (value as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [
            .paragraphStyle: style, .font: font, .foregroundColor: color
        ])
    }

    private static func plate(_ rect: NSRect, tint: NSColor = ground, border: NSColor = NSColor(white: 1, alpha: 0.18)) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        tint.setFill(); shape.fill()
        border.setStroke(); shape.lineWidth = 1; shape.stroke()
    }

    private static func button(_ rect: NSRect, _ title: String, primary: Bool = false) {
        plate(rect, tint: primary ? gold : ground, border: primary ? gold : muted.withAlphaComponent(0.65))
        text(title, x: rect.minX+4, y: rect.midY-10, width: rect.width-8, size: 14,
             color: primary ? ground : ink, weight: .semibold, alignment: .center)
    }

    static func action(at location: NSPoint, hud: OriginalHUD, training: DepthlineTraining) -> Action? {
        let layout = Layout(hud.bounds.size)
        let point = NSPoint(x: location.x / layout.scale, y: location.y / layout.scale)
        guard training.stage != .complete else { return nil }
        if training.guideOpen { return layout.dismiss.contains(point) ? .guide : nil }
        if layout.guide.contains(point) { return .guide }
        return nil
    }

    static func draw(_ hud: OriginalHUD, game: Game, training: DepthlineTraining) {
        let layout = Layout(hud.bounds.size)
        NSGraphicsContext.saveGraphicsState()
        let tx = NSAffineTransform(); tx.scale(by: layout.scale); tx.concat()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let w = layout.w, h = layout.h
        if training.guideOpen {
            NSColor(white: 0.015, alpha: 0.57).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
            drawGuide(layout)
            return
        }

        if training.stage == .complete { return }

        plate(layout.lesson)
        text(DLoc.text("教学战区", "Training Sector"), x: 43, y: 36, width: 180, size: 12, color: gold, weight: .semibold)
        let lessonCount = DepthlineTraining.lessonCount
        text(DLoc.text("课目  \(training.stage.rawValue+1) / \(lessonCount)", "Lesson  \(training.stage.rawValue+1) / \(lessonCount)"), x: 306, y: 35, width: 133, size: 12, color: muted, alignment: .right)
        text(training.title, x: 42, y: 54, width: 396, size: 25, weight: .bold)
        text(training.prompt(in: game), x: 43, y: 89, width: 394, size: 14, wrappedHeight: 40)
        if training.stage == .missile {
            var note = DLoc.text("机枪、火炮和手枪也能击毁直升机。", "Guns can also down helicopters.")
            if let bearing = training.bearing(in: game) { note += "   " + bearing }
            text(note, x: 43, y: 131, width: 395, size: 12, color: gold, wrappedHeight: 34)
        } else if let bearing = training.bearing(in: game) {
            text(bearing, x: 43, y: 131, width: 395, size: 12, color: gold)
        }
        let stepWidth = 400 / CGFloat(lessonCount)
        for index in 0..<lessonCount {
            (index <= training.stage.rawValue ? gold : muted.withAlphaComponent(0.3)).setFill()
            NSBezierPath(roundedRect: .init(x: 43+CGFloat(index)*stepWidth, y: 169, width: stepWidth-6, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }
        button(layout.guide, DLoc.text("按键速查   Tab", "Controls   Tab"))
        let showMissiles = training.stage == .missile
        var status = "\(hud.weaponLabel)  \(hud.weaponAmmo)"
        if showMissiles { status += DLoc.text("   ·   导弹  \(hud.missileAmmo)", "   ·   Missiles  \(hud.missileAmmo)") }
        status += DLoc.text("   ·   防御  \(Int((hud.health*100).rounded()))%", "   ·   Defense  \(Int((hud.health*100).rounded()))%")
        let statusWidth = (status as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).width
        let footer = NSRect(x: 24, y: h-71, width: max(showMissiles ? 302 : 200, ceil(statusWidth) + 32), height: 47)
        plate(footer)
        text(status, x: footer.minX+15, y: footer.minY+12, width: footer.width-30, size: 15, weight: .semibold)
        text(DLoc.text("⌘L 离开教学", "⌘L  Leave training"), x: w-330, y: h-53, width: 306, size: 13, alignment: .right)
        if !game.paused {
            RemasteredHUD.reticle(at: NSPoint(x: w/2, y: h*hud.sightVerticalFraction), weapon: hud.weaponSight)
        }
    }

    private static func drawGuide(_ layout: Layout) {
        let rect = layout.sheet
        plate(rect)
        let x = rect.minX+28, y = rect.minY+23
        text(DLoc.text("按键速查", "Controls"), x: x, y: y, width: 320, size: 25, weight: .bold)
        button(layout.dismiss, DLoc.text("返回教学  Esc", "Back  Esc"))
        let columns: [(String, [(String,String)])] = [
            (DLoc.text("瞄准与射击", "Aiming & weapons"), [
                ("F8 / ⌃⌥M",DLoc.text("鼠标移入后锁定，再按一次释放", "Point inside to lock or release")),
                (DLoc.text("移动 / 左键", "Move / Left click"),DLoc.text("转向瞄准 / 按住连续射击", "Aim / Hold to fire")),
                (DLoc.text("空格 / G", "Space / G"),DLoc.text("切换机枪与火炮 / 切换手枪", "Cycle guns / Draw pistol")),
                ("M",DLoc.text("消耗一枚导弹发射", "Fire one missile")),
                (DLoc.text("A · 海岸", "A · Coast"),DLoc.text("呼叫本关配给的炮兵支援", "Call artillery, if available")),
                (DLoc.text("B / F · 丘陵", "B / F · Hills"),DLoc.text("呼叫轰炸机 / 夜间发射照明弹", "Call bombers / Fire a flare at night")),
                (DLoc.text("+ / − · 海岸", "+ / − · Coast"),DLoc.text("提高 / 降低鼠标灵敏度", "Increase / decrease sensitivity")),
                (DLoc.text("1 / 2 / = · 丘陵", "1 / 2 / = · Hills"),DLoc.text("弹药不减 / 护盾辅助 / 清场", "Infinite ammo / Shield / Clear sector"))
            ]),
            (DLoc.text("界面与进度", "Menus & progress"), [
                ("P / Esc",DLoc.text("暂停或继续", "Pause or resume")),
                (DLoc.text("Tab · 教学", "Tab · Training"),DLoc.text("打开或收起按键速查", "Show or hide controls")),
                ("S",DLoc.text("开关音效", "Toggle sound")),
                (DLoc.text("I 或 R", "I or R"),DLoc.text("反转纵向瞄准", "Invert vertical aim")),
                ("⌃⌘F",DLoc.text("切换全屏", "Toggle full screen")),
                ("⌘R",DLoc.text("从第一关或本次教学重新开始", "Restart the campaign or training")),
                ("⌘L",DLoc.text("返回战区选择", "Return to sector select")),
                ("⌘Q",DLoc.text("退出游戏", "Quit the game"))
            ])
        ]
        for (column, group) in columns.enumerated() {
            let columnWidth = (rect.width - 56) / 2
            let left = x + CGFloat(column)*columnWidth
            text(group.0, x: left, y: y+55, width: 336, size: 15, color: gold, weight: .semibold)
            for (index, row) in group.1.enumerated() {
                let top = y+90+CGFloat(index)*31
                text(row.0, x: left, y: top, width: 130, size: 13, color: ink, weight: .semibold)
                text(row.1, x: left+137, y: top, width: columnWidth-148, size: 12.5, color: muted)
            }
        }
        muted.withAlphaComponent(0.25).setFill()
        NSRect(x: x, y: y+345, width: rect.width-56, height: 1).fill()
        text(DLoc.text("正式战区", "Combat sectors"), x: x, y: y+362, width: 130, size: 14, color: gold, weight: .semibold)
        text(DLoc.text("清除来敌后，可继续下一关或返回游戏选择。下次继续时从已解锁的关卡开始。", "Clear the enemy force to unlock the next mission. You can play it now or resume it later."), x: x, y: y+389, width: rect.width-56, size: 13, wrappedHeight: 36)
        text(DLoc.text("海岸按得分排名，丘陵按到达关卡排名。使用秘籍的成绩会标记。", "Coastal rankings use score. Hills rankings use the mission reached. Scores earned with cheats are marked."), x: x, y: y+428, width: rect.width-56, size: 13, color: muted, wrappedHeight: 36)
    }
}
