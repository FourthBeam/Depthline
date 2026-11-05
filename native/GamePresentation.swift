import AppKit
import SceneKit

/// Bridges the recovered HUD/audio rules to the live simulation. Original
/// quantities stay in their source units; only SceneKit coordinates use /100.
extension Game {
    func updateOriginalHUD() {
        hud.health = CGFloat(combat.health) / 100
        hud.level = level + 1
        hud.score = combat.score
        hud.remainingTime = campaign?.remainingSeconds
        hud.forceFraction = (campaign?.remainingForce ?? 0) / max(0.0001, campaign?.initialForce ?? 1)
        let capacity = ammunitionCapacity
        switch weapons.selected {
        case .machineGun:
            hud.weaponLabel = DLoc.text("机枪", "Machine gun"); hud.weaponSight = "machineGun"
            hud.weaponAmmo = weapons.ammo.machineGun
            hud.weaponCapacity = capacity.machineGun
        case .cannon:
            hud.weaponLabel = DLoc.text("火炮", "Cannon"); hud.weaponSight = "cannon"
            hud.weaponAmmo = weapons.ammo.cannon
            hud.weaponCapacity = capacity.cannon
        case .handgun:
            hud.weaponLabel = DLoc.text("手枪", "Pistol"); hud.weaponSight = "handgun"
            hud.weaponAmmo = weapons.ammo.handgun
            hud.weaponCapacity = capacity.handgun
        case .flare:
            hud.weaponLabel = DLoc.text("照明枪", "Flare gun"); hud.weaponSight = "flare"
            hud.weaponAmmo = weapons.ammo.flare
            hud.weaponCapacity = capacity.flare
        }
        hud.missileAmmo = weapons.ammo.missile
        hud.missileCapacity = capacity.missile
        hud.missileReadySlots = weapons.missileSlots.map(\.ready)
        hud.supportCount = weapons.supportAvailable ? 1 : 0
        hud.flareAmmo = weapons.ammo.flare
        hud.isNight = night
        hud.cameraFieldOfView = Double(camera.camera?.fieldOfView ?? CGFloat(OriginalScenePresentation.horizontalFieldOfView))
        hud.sightVerticalFraction = (1 + (camera.camera?.projectionTransform.m32 ?? 0)) / 2
        hud.paused = paused
        hud.mouseCaptured = view.mouseCapture.isCaptured
        // A missing authored level is a loading failure, not an original defeat.
        hud.finished = finished && combat.health <= 0
        hud.victorious = combat.health > 0 && (campaign?.remainingForce ?? 1) <= 0.0001
        if elapsed < supplyMessageUntil { hud.message = supplyMessage }
        else if inputLocked && !isShowingVictoryChoice && combat.health > 0 { hud.message = DLoc.text("弹药耗尽", "Out of ammunition") }
        else { hud.message = "" }
        hud.needsDisplay = true
    }

    func playOriginalSound(_ name: String) {
        sound.enabled = settings.soundEnabled && !paused && !finished
        sound.play(name)
    }

    func updateOriginalEngineSounds() {
        sound.enabled = settings.soundEnabled && !paused && !finished
        guard sound.enabled else { return }
        // After player death only stop engines, so the last impact can finish.
        guard combat.health > 0 else { sound.updateEngines([]); return }
        var sources = enemies.compactMap { enemy -> OriginalEngineSound.Source? in
            guard let id = enemy.aggregateVehicleID ?? enemy.aggregateAircraftID ?? originalObjectIndex(enemy) else { return nil }
            let p = enemy.node.position
            return .init(objectID: id, state: enemy.aiState,
                         position: SIMD3(Double(p.x * 100), Double(p.y * 100), Double(p.z * 100)),
                         visible: !enemy.node.isHidden)
        }
        if let plane = supply2000?.plane {
            let p = plane.position
            sources.append(.init(objectID: plane.objectID, state: plane.state.rawValue,
                                 position: SIMD3(Double(p.x), Double(p.y), Double(p.z)), visible: plane.visible))
        }
        for plane in supply2002?.planes ?? [] {
            let p = plane.position
            sources.append(.init(objectID: plane.objectID, state: plane.state.rawValue,
                                 position: SIMD3(Double(p.x), Double(p.y), Double(p.z)), visible: plane.visible))
        }
        sound.updateEngines(sources)
    }

    func captureOriginalScreenshot() -> NSImage {
        hud.composited(over: view.snapshot())
    }
}
