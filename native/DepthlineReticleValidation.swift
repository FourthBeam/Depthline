import AppKit
import SceneKit

extension Game {
    /// Hold the mouse button on a visible, posed soldier just beyond the parapet.
    /// Only the cursor backend is replaced, so the test cannot warp the desktop pointer.
    func validateMachineGunReticle(output: URL?) throws -> [[String: Any]] {
        let coast = version == .beach2000
        let missions = coast ? [1] : [14, 1]
        let eye = camera.simdWorldPosition
        guard let cover = emplacementCover else { throw NSError(domain: "MissingReticleCover", code: 1) }
        let inputView = GameView(frame: view.bounds, cursorBackend: MenuValidationCursor())
        inputView.game = self
        defer { inputView.mouseCapture.release(); restart() }
        let button = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type -> NSEvent in
            guard let event = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw NSError(domain: "ReticleTrigger", code: 1)
            }
            return event
        }
        func check(_ ok: Bool, _ detail: String) throws {
            try CampaignRuntimeValidation.require(ok, "Reticle \(assets.gameID) mission \(level + 1): \(detail)")
        }
        func fireOne() throws -> OriginalProjectileSnapshot {
            let fired = combat.shots, ammo = weapons.ammo.machineGun
            inputView.mouseDown(with: button[0])
            defer { inputView.mouseUp(with: button[1]) }
            for _ in 0..<12 where combat.shots == fired { simulationTick() }
            try check(combat.shots == fired + 1 && weapons.ammo.machineGun == ammo - 1, "A trigger press fires exactly once")
            guard let shot = projectiles.snapshots.first(where: { $0.kind == .ballistic(.machineGun) }) else {
                throw NSError(domain: "ReticleMissingShot", code: level + 1)
            }
            return shot
        }
        func aim(at p: SIMD3<Float>) {
            let delta = p - eye
            camera.eulerAngles = SCNVector3(CGFloat(atan2(delta.y, hypot(delta.x, delta.z))), CGFloat(atan2(-delta.x, -delta.z)), 0)
            syncGunPose()
        }
        var records: [[String: Any]] = []
        for mission in missions {
            restart(level: mission - 1)
            if !inputView.mouseCapture.isCaptured {
                try check(inputView.mouseCapture.toggle(pointerInside: true, windowActive: true, anchor: .zero), "Fixture input capture")
            }
            SCNTransaction.flush()
            let bearing: Float = coast ? 29 : 209
            let yaw = bearing * .pi / 180
            let range: Float = coast ? 19 : mission == 14 ? 9 : 8.5
            let x = -sin(yaw) * range, z = -cos(yaw) * range
            let foot = SIMD3<Float>(x, Float(assets.height(x: CGFloat(x), z: CGFloat(z))), z)
            let soldier = RemasteredInfantryNode(gameID: assets.gameID)
            let actor = Enemy(node: soldier, type: "INFANTRY", flying: false)
            let standing = coast ? 14 : 19
            soldier.apply(state: standing, frame: coast ? 15 : 88, direction: .init(0, 0, 1))
            soldier.simdPosition = foot
            scene.rootNode.addChildNode(soldier)
            enemies.append(actor)
            defer { soldier.removeFromParentNode(); enemies.removeAll { $0 === actor } }
            let head = coast
            let at = soldier.bones[head ? 1 : 0].simdConvertPosition(head ? .init(0, 0.125, 0) : .init(0, 0.32, 0), to: nil)
            aim(at: at)
            let sight = camera.simdWorldFront
            let sweep = OriginalProjectileSweep(kind: .ballistic(.machineGun), start: SCNVector3(eye), end: SCNVector3(eye + sight * 40))
            let bag = (1...12).compactMap { adjustment -> DepthlineCover.Hit? in
                var lower = sight
                lower.y -= Float(adjustment) * 0.005
                return cover.firstHit(from: eye, to: eye + lower * 12)
            }.first { $0.surface == .sandbag }
            guard let bag else { throw NSError(domain: "ReticleMustGrazeSandbag", code: mission) }
            let clearance = acos(min(1, max(-1, simd_dot(sight, simd_normalize(bag.position - eye))))) * 180 / .pi
            for barrel in 0..<(usesOffsetTwinMount ? 2 : 1) {
                actor.aiState = standing
                actor.deathMode = .none
                soldier.isHidden = false
                let body = depthlineInfantryContact(sweep)
                try check(body?.target === soldier && cover.firstHit(from: eye, to: at) == nil,
                          "The sight must clear cover and meet the rendered soldier")
                if barrel == 0, let output {
                    updateHUD()
                    SCNTransaction.flush()
                    let capture = try NativeCaptureOptions(arguments: [])
                    try captureNativePixels(options: capture).write(to: output.appendingPathComponent("\(assets.gameID)-\(mission)-沙袋上沿瞄准.png"))
                }
                let hits = combat.hits, marks = coverImpacts.marks.count
                let shot = try fireOne()
                let barrels: [OriginalBarrel] = usesOffsetTwinMount ? [.left, .right] : [.center]
                let tips = barrels.compactMap { barrel in
                    weaponPresentation.basis(for: OriginalFireAction(weapon: .machineGun, barrel: barrel,
                        variant: weapons.machineGunVariant, recoilTicks: 0, ballistic: nil)).muzzle
                }
                try check(!muzzleLamp.isHidden && tips.contains { simd_distance(muzzleLamp.simdWorldPosition, SIMD3<Float>($0)) < 0.001 },
                          "Close-cover aim must keep the muzzle flash attached to a firing barrel")
                let direction = SIMD3<Float>(shot.direction), origin = SIMD3<Float>(shot.position)
                for _ in 0..<16 where projectiles.ballisticCount > 0 { updateOriginalSharedProjectiles() }
                let offset = simd_length(simd_cross(at - origin, direction))
                try check(combat.hits == hits + 1 && actor.deathMode == .infantryDeath && projectiles.ballisticCount == 0 &&
                          coverImpacts.marks.count == marks,
                          "Visible \(head ? "head" : "chest") must take this shot once, with no hole below the reticle (marks \(coverImpacts.marks.count-marks), initial line error \(offset) m)")
                records.append(["sector": assets.gameID, "mission": mission, "shot": barrel + 1, "bearingDegrees": bearing,
                                "rangeMetres": range, "aim": head ? "head" : "chest", "clearanceDegrees": clearance,
                                "initialLineErrorMetres": offset, "bodyHits": combat.hits - hits, "coverMarks": coverImpacts.marks.count - marks])
            }
            // The same near-edge sight must also clear cover when there is no actor to attract the shot.
            soldier.isHidden = true
            let marks = coverImpacts.marks.count
            _ = try fireOne()
            for _ in 0..<2 { updateOriginalSharedProjectiles() }
            try check(projectiles.ballisticCount == 1 && coverImpacts.marks.count == marks,
                      "Empty sightline immediately above the bag must pass the tracer")
            _ = projectiles.clear()
            let below = simd_normalize(bag.position - eye)
            aim(at: eye + below * 12)
            _ = try fireOne()
            for _ in 0..<4 { updateOriginalSharedProjectiles() }
            try check(projectiles.ballisticCount == 0 && coverImpacts.marks.count == marks + 1 &&
                      coverImpacts.marks.last.map { simd_distance($0.simdWorldPosition, bag.position) < 0.10 } == true,
                      "Lowering the sight onto the bag must leave a hole on its visible face")
        }
        return records
    }
}
