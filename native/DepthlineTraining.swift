import AppKit
import SceneKit

final class DepthlineTraining {
    enum Stage: Int {
        case capture, aim, fire, switchWeapon, cannonAim, cannonFire, handgun, supply, missile, complete
    }

    static let lessonCount = Stage.complete.rawValue
    private let practiceMissiles = 2
    private(set) var stage = Stage.capture
    private(set) var guideOpen = false
    private var pausedBeforeGuide = false
    private(set) var dropsReleased = 0
    private let rifleTarget = SCNNode()
    private let cannonTarget = SCNNode()
    private(set) var helicopter: DepthlineTrainingHelicopter?
    private var nextHelicopterTick: Int?
    private var replacedHelicopter = false
    var target: SCNNode {
        switch stage {
        case .switchWeapon, .cannonAim, .cannonFire: return cannonTarget
        default: return rifleTarget
        }
    }
    private let targetRadius: CGFloat = 1.45

    func install(in game: Game) {
        stage = .capture
        guideOpen = false
        dropsReleased = 0
        helicopter = nil
        nextHelicopterTick = nil
        replacedHelicopter = false
        game.view.mouseCapture.release()
        game.inputLocked = false
        game.elapsed = 0
        game.logicalTick = 0
        game.logicalAccumulator = 0
        game.finished = false
        game.paused = false
        game.night = false
        game.shooting = false
        game.combat.health = 75
        game.hud.damageFlash = 0
        game.camera.eulerAngles = SCNVector3(-4 * CGFloat.pi / 180, 0, 0)
        game.input.setAngles(yawDegrees: 0, pitchDegrees: -4)
        game.applyLight(.day, searchlight: false)
        game.configureWeapons(["ammo": [240, 32, 0]])
        game.hud.trainingGame = game
        game.hud.refreshLanguage()
        for (board, x, z, scale) in [(rifleTarget, CGFloat(7), CGFloat(-39), CGFloat(1)),
                                     (cannonTarget, -12, -53, 1.35)] {
            let forCannon = board === cannonTarget
            if board.childNodes.isEmpty { buildTarget(board, forCannon: forCannon) }
            board.position = SCNVector3(x, game.assets.height(x: x, z: z) + 2.1 * scale, z)
            board.eulerAngles = SCNVector3(0, atan2(-x, -z), 0)
            board.scale = SCNVector3(scale, scale, scale)
            board.isHidden = forCannon
            if board.parent == nil { game.scene.rootNode.addChildNode(board) }
        }
        game.syncGunPose()
        game.updateHUD()
    }

    func noteMouseCapture(_ captured: Bool) {
        if captured && !guideOpen && stage == .capture { stage = .aim }
    }

    func advance(in game: Game) {
        guard !guideOpen else { return }
        // A trainee can keep practising after using the last round.
        if game.weapons.ammo.machineGun == 0 { game.weapons.ammo.machineGun = 240 }
        if game.weapons.ammo.cannon == 0 { game.weapons.ammo.cannon = 32 }
        if game.weapons.ammo.handgun == 0 { game.weapons.ammo.handgun = 15 }
        switch stage {
        case .aim, .cannonAim:
            if stage == .cannonAim && game.weapons.selected != .cannon { break }
            let eye = game.camera.simdWorldPosition
            let end = eye + 160 * game.camera.simdWorldFront
            if intersectTarget(from: SCNVector3(eye), to: SCNVector3(end)) != nil {
                stage = stage == .aim ? .fire : .cannonFire
            }
        case .switchWeapon:
            if game.weapons.selected == .cannon { stage = .cannonAim }
        case .supply:
            if game.supply2000?.defenseCollected == true {
                stage = .missile
                game.weapons.ammo.missile = practiceMissiles
                helicopter = DepthlineTrainingHelicopter(in: game)
                break
            }
            _ = game.supply2000?.updateAI(random: { game.random.next() }, terrainHeight: { x, z in
                Float(game.assets.pointHeight(x: CGFloat(x) / 100, z: CGFloat(z) / 100)) * 100
            }, smokeTick: false)
            if game.supply2000?.parachutes.first?.visible != true { releaseDrop(in: game) }
        case .missile:
            if let nextHelicopterTick, game.logicalTick >= nextHelicopterTick {
                self.nextHelicopterTick = nil
                helicopter = DepthlineTrainingHelicopter(in: game)
                game.weapons.ammo.missile = practiceMissiles
            }
            helicopter?.hover(tick: game.logicalTick)
            if game.weapons.ammo.missile == 0 && game.weapons.missileSlots.allSatisfy({ !$0.active }) {
                game.weapons.ammo.missile = practiceMissiles
            }
        default:
            break
        }
    }

    func hitTarget(_ sweep: OriginalProjectileSweep, in game: Game) -> Bool {
        let requiredWeapon: OriginalWeapon
        switch stage {
        case .fire: requiredWeapon = .machineGun
        case .cannonFire: requiredWeapon = .cannon
        case .handgun: requiredWeapon = .handgun
        default: return false
        }
        guard sweep.kind.weapon == requiredWeapon, let impact = intersectTarget(from: sweep.start, to: sweep.end) else { return false }
        let p = SIMD3<Double>(impact.x, impact.y, impact.z) * 100
        game.effects.emit(.impactFlash, at: p)
        game.playSound("Prize")
        target.isHidden = true
        switch stage {
        case .fire:
            stage = .switchWeapon
            cannonTarget.isHidden = false
        case .cannonFire:
            stage = .handgun
            rifleTarget.isHidden = false
        default:
            stage = .supply
            releaseDrop(in: game)
        }
        return true
    }

    func helicopterDestroyed(byMissile: Bool, in game: Game) {
        guard stage == .missile, helicopter != nil else { return }
        helicopter = nil
        if byMissile {
            stage = .complete
            game.shooting = false
            game.inputLocked = true
            game.view.mouseCapture.release()
            game.onSectorCompleted?()
            game.sound.stopAll()
            game.refreshBattleOverlays()
        } else {
            replacedHelicopter = true
            nextHelicopterTick = game.logicalTick + 45
        }
    }

    private func intersectTarget(from start: SCNVector3, to end: SCNVector3) -> SCNVector3? {
        let a = target.convertPosition(start, from: nil)
        let b = target.convertPosition(end, from: nil)
        guard a.z >= 0, b.z <= 0, a.z > b.z else { return nil }
        let t = a.z / (a.z - b.z)
        let local = SCNVector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, 0)
        guard hypot(local.x, local.y) <= targetRadius else { return nil }
        return target.convertPosition(local, to: nil)
    }

    private func releaseDrop(in game: Game) {
        dropsReleased += 1
        // From the target lane, the canopy falls to the right of the lesson card.
        game.supply2000 = .trainingDrop(at: .init(x: 1350, y: 1750, z: -4100), initialMachineGunAmmo: 240)
        game.syncSupplyNodes()
    }

    private func buildTarget(_ target: SCNNode, forCannon: Bool) {
        target.name = forCannon ? "TrainingCannonTarget" : "TrainingRangeTarget"
        func install(_ geometry: SCNGeometry, _ color: NSColor, x: CGFloat = 0, y: CGFloat = 0, z: CGFloat = 0, disk: Bool = false, reflectivePaint: Bool = false) {
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.roughness.contents = 0.83
            if reflectivePaint {
                material.emission.contents = color
                material.emission.intensity = 0.28
            }
            geometry.materials = [material]
            let piece = SCNNode(geometry: geometry)
            piece.position = SCNVector3(x,y,z)
            if disk { piece.eulerAngles.x = .pi / 2 }
            target.addChildNode(piece)
        }
        let graphite = NSColor(srgbRed: 0.22, green: 0.24, blue: 0.22, alpha: 1)
        let ivory = NSColor(srgbRed: 0.98, green: 0.96, blue: 0.90, alpha: 1)
        let ringColor = forCannon ? NSColor(srgbRed: 0.99, green: 0.76, blue: 0.16, alpha: 1)
                                  : NSColor(srgbRed: 0.91, green: 0.28, blue: 0.13, alpha: 1)
        let stripe = forCannon ? graphite : ivory
        for x: CGFloat in [-0.46, 0.46] {
            install(SCNBox(width: 0.13, height: 2.5, length: 0.14, chamferRadius: 0.02), graphite, x: x, y: -1.18, z: -0.13)
        }
        for (i, ring) in [(targetRadius, ringColor), (1.36, stripe), (1.05, ringColor), (0.78, stripe), (0.45, ringColor)].enumerated() {
            let disk = SCNCylinder(radius: ring.0, height: 0.045)
            disk.radialSegmentCount = 48
            install(disk, ring.1, z: CGFloat(i) * 0.044, disk: true, reflectivePaint: i > 0)
        }
    }

    func toggleGuide(in game: Game) {
        if guideOpen {
            guideOpen = false
            if !pausedBeforeGuide && game.paused { game.togglePause() }
        } else {
            pausedBeforeGuide = game.paused
            if !game.paused { game.togglePause() }
            game.view.mouseCapture.release()
            guideOpen = true
        }
        game.refreshBattleOverlays()
        game.hud.needsDisplay = true
    }

    var title: String {
        switch stage {
        case .capture: return DLoc.text("锁定鼠标", "Lock the mouse")
        case .aim: return DLoc.text("瞄准环形靶", "Aim at the ring target")
        case .fire: return DLoc.text("用机枪命中靶面", "Fire the machine gun")
        case .switchWeapon: return DLoc.text("切换到火炮", "Switch to the cannon")
        case .cannonAim: return DLoc.text("瞄准火炮远靶", "Aim at the far target")
        case .cannonFire: return DLoc.text("用炮弹命中远靶", "Hit the far target with a shell")
        case .handgun: return DLoc.text("用手枪命中靶面", "Hit the target with the pistol")
        case .supply: return DLoc.text("领取空投补给", "Collect the supply drop")
        case .missile: return DLoc.text("用导弹击毁直升机", "Shoot down the helicopter")
        case .complete: return DLoc.text("训练完成", "Training complete")
        }
    }

    func prompt(in game: Game) -> String {
        switch stage {
        case .capture: return DLoc.text("锁定后，移动鼠标即可转动炮口。", "Once locked, move the mouse to aim.")
        case .aim: return DLoc.text("移动鼠标，让准星对准岸边的红白环形靶。", "Move the crosshair onto the red and white target.")
        case .fire:
            return game.weapons.selected == .machineGun
                ? DLoc.text("保持瞄准，按住左键，用机枪击中红白靶。", "Hold the left mouse button to hit the red and white target.")
                : DLoc.text("按空格切回机枪，再瞄准红白靶开火。", "Press Space for the machine gun, then shoot the target.")
        case .switchWeapon: return DLoc.text("红白靶已命中。按空格，换到火炮。", "Target hit. Press Space to switch to the cannon.")
        case .cannonAim, .cannonFire:
            if game.weapons.selected != .cannon { return DLoc.text("按空格切回火炮，把十字准星中心对准黄黑靶心。", "Press Space for the cannon. Aim at the yellow bullseye.") }
            return stage == .cannonAim ? DLoc.text("移动鼠标转动炮口，把十字准星中心对准黄黑远靶。", "Aim the crosshair at the far yellow and black target.")
                                       : DLoc.text("保持准星对住黄黑靶心，按住左键发射炮弹。", "Aim at the yellow bullseye and hold the left button to fire.")
        case .handgun:
            return game.weapons.selected == .handgun
                ? DLoc.text("瞄准红白环形靶，单击左键。松开左键后可再射。", "Aim at the ring target. Click once per shot.")
                : DLoc.text("按 G 切换到手枪，再单击左键命中红白环形靶。", "Press G for the pistol. Click to hit the ring target.")
        case .supply:
            if dropsReleased > 1 { return DLoc.text("补给已重新投放。瞄准伞面或箱体开火。", "New drop inbound. Shoot the parachute or crate.") }
            if game.weapons.selected == .handgun { return DLoc.text("击中伞面或箱体领取补给。可按 G 换回机枪。", "Shoot the chute or crate. Press G for the machine gun.") }
            return DLoc.text("瞄准降落伞或悬挂的箱体，开火领取防御补给。", "Shoot the parachute or crate to repair your defenses.")
        case .missile:
            if helicopter == nil { return DLoc.text("靶机已被击毁。下一架请练习用导弹击毁。", "Target down. Use a missile on the next helicopter.") }
            return replacedHelicopter ? DLoc.text("新靶机已就位。准星对准机身，按 M 发射导弹。", "New helicopter in position. Aim at its body and press M.")
                                      : DLoc.text("准星对准悬停直升机的机身，按 M 发射导弹。", "Aim at the hovering helicopter and press M to fire a missile.")
        case .complete: return DLoc.text("导弹已击毁靶机，可以进入正式战区。", "Missile hit confirmed. You can now enter a combat sector.")
        }
    }

    func bearing(in game: Game) -> String? {
        let point: SIMD3<Float>
        switch stage {
        case .aim, .fire, .cannonAim, .cannonFire, .handgun: point = target.simdWorldPosition
        case .supply:
            guard let drop = game.supplyNodes[212] else { return nil }
            point = drop.simdConvertPosition(.init(0,-2,0), to: nil)
        case .missile:
            guard let helicopter else { return nil }
            point = SIMD3<Float>(helicopter.aimPoint)
        default: return nil
        }
        let local = game.camera.simdConvertPosition(point, from: nil)
        let azimuth = atan2(local.x, -local.z) * 180 / .pi
        let elevation = atan2(local.y, hypot(local.x,local.z)) * 180 / .pi
        if abs(azimuth) > 5 {
            return azimuth > 0 ? DLoc.text("目标在右侧  →", "Target to the right →") : DLoc.text("←  目标在左侧", "← Target to the left")
        }
        if abs(elevation) > 4 { return elevation > 0 ? DLoc.text("向上瞄准  ↑", "Aim higher ↑") : DLoc.text("向下瞄准  ↓", "Aim lower ↓") }
        return DLoc.text("目标在准星附近", "Target near the crosshair")
    }
}

extension Game {
    /// Shortcuts specific to the firing range. Escape returns directly from
    /// the reference sheet, preserving a pause that preceded opening it.
    func handleTrainingKey(_ event: NSEvent) -> Bool {
        guard let training else { return false }
        if event.modifierFlags.contains(.command) { return false }
        if event.keyCode == 48 || (training.guideOpen && event.keyCode == 53) {
            if !event.isARepeat { training.toggleGuide(in: self) }
            return true
        }
        if training.guideOpen { return true }
        return false
    }
}
