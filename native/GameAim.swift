import AppKit
import SceneKit

extension Game {
    /// The gun is physically beside and below the sight. When the reticle is
    /// on a soldier, converge the shell on that point at its actual range.
    /// The round still leaves the muzzle and can hit cover or miss a moving target.
    func playerShotDirection(for action: OriginalFireAction, muzzle: SCNVector3, forward: SCNVector3) -> SCNVector3 {
        guard assets.isDepthline, action.weapon == .cannon, let profile = action.ballistic else {
            return supplyLead(for: action, muzzle: muzzle) ?? forward
        }
        let eye = camera.simdWorldPosition
        let sight = OriginalProjectileSweep(kind: .ballistic(.cannon), start: SCNVector3(eye),
                                            end: SCNVector3(eye + camera.simdWorldFront * 250))
        guard let body = depthlineInfantryContact(sight) else {
            return supplyLead(for: action, muzzle: muzzle) ?? forward
        }
        if let supply = supplyLead(for: action, muzzle: muzzle, sightRange: 250 * Float(body.fraction)) {
            return supply
        }
        let delta = SIMD3<Float>(sight.position(at: body.fraction)) - SIMD3<Float>(muzzle)
        guard simd_dot(delta, camera.simdWorldFront) > 0 else { return forward }
        let speed = profile.initialSpeedPerTick * 0.01
        let gravity = profile.downwardVelocityChangePerTick * 0.01
        var aim = delta
        for _ in 0..<2 {
            let time = simd_length(aim) / speed
            let steps = floor(time)
            aim.y = delta.y + gravity * steps * (time - (steps + 1) / 2)
        }
        return SCNVector3(simd_normalize(aim))
    }

    var usesOffsetTwinMount: Bool {
        assets.isDepthline && weapons.selected == .machineGun &&
            (version == .beach2000 || weapons.machineGunVariant == 0)
    }

    /// The gunner looks over the feed side of the twin mount. Keep the
    /// separate hand-held and centre-mounted guns on their own sightline.
    var depthlineGunOffset: SCNVector3 {
        guard assets.isDepthline else { return SCNVector3Zero }
        guard usesOffsetTwinMount else {
            let local:SCNVector3
            switch weapons.selected {
            case .machineGun: local=SCNVector3(0.30,-0.075,-0.65)
            case .cannon: local=SCNVector3(0.39,-0.10,-1.06)
            case .handgun,.flare: local=SCNVector3(0.20,0.075,-0.25)
            }
            var offset=camera.convertVector(local,to:nil)
            if weapons.selected == .cannon {
                // Keep the full 2.65 m barrel above the floor at maximum
                // depression; the elevating arm follows the higher trunnion.
                let floor=assets.height(x:0,z:0)
                offset.y=max(offset.y,floor+0.20-8-2.65*CGFloat(camera.simdWorldFront.y))
            }
            return offset
        }
        // Draw the carriage in over its base when depressing the barrels.
        // At full depression this keeps the tips inside the wall and above
        // the concrete floor. The normal seaward view uses the full reach.
        let down = CGFloat(-camera.simdWorldFront.y)
        let t = min(1,max(0,(down-0.14)/0.25))
        let travel = t*t*(3-2*t)
        var offset = camera.convertVector(SCNVector3(-0.78,-0.18,-1.65+1.20*travel),to:nil)
        offset.y=max(offset.y,-0.42+0.48*travel)
        return offset
    }
    func syncGunPose() {
        let offset=depthlineGunOffset
        gun.position=SCNVector3(offset.x,8+offset.y,offset.z)
        gun.simdOrientation=camera.simdWorldOrientation
        if assets.isDepthline {
            // Train the mount at the 80 m sight zero. Its physical bores supply
            // the same direction to the projectile and the rendered weapon.
            let zero = camera.simdConvertPosition(SIMD3(0,0,-80),to:nil)
            let forward = simd_normalize(zero-gun.simdWorldPosition)
            gun.simdOrientation=simd_quatf(from:camera.simdWorldFront,to:forward)*camera.simdWorldOrientation
            let pin:SIMD3<Float>?
            let compactMount = weapons.selected == .machineGun && weapons.machineGunVariant == 1 && version == .beach2002
            switch weapons.selected {
            case .machineGun where usesOffsetTwinMount: pin = gun.simdConvertPosition(.init(0,-0.37,-0.57), to:nil)
            case .machineGun where compactMount:
                // The M60's trunnion sits against the underside of its receiver.
                pin = weaponPresentation.nodes[23]?.simdConvertPosition(.init(0,-0.032,-0.15), to:nil)
            case .machineGun: pin = gun.simdConvertPosition(.init(0.08,-0.01,-0.32), to:nil)
            case .cannon:
                let slide=weaponPresentation.nodes[version == .beach2000 ? 143:24]?.simdPosition.z ?? 0
                pin = gun.simdConvertPosition(.init(0,-0.24,-0.46+slide), to:nil)
            case .handgun,.flare: pin=nil
            }
            gunCarriage.connect(to:pin, traverseRight:camera.simdWorldRight, narrowFork:compactMount)
        }
    }
    /// Render/input cadence is independent of the 29 ms gameplay step. Mouse movement
    /// immediately updates both the view and the actual weapon direction used by firing.
    func applyDirectAim(deltaX: Double, deltaY: Double) {
        guard view.mouseCapture.isCaptured, !paused, !finished, !inputLocked, combat.health > 0 else { return }
        let angles = input.applyDirectLook(deltaX: deltaX, deltaY: deltaY,
                                           sensitivityLevel: settings.sensitivityLevel, invertY: settings.invertY)
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        camera.eulerAngles = SCNVector3(angles.pitchDegrees * .pi / 180, angles.yawDegrees * .pi / 180, 0)
        syncGunPose()
        updateMuzzleFeedback()
        SCNTransaction.commit()
        if InteractiveInputTrace.enabled {
            InteractiveInputTrace.record("aim", ["dx": deltaX, "dy": deltaY,
                "yaw": angles.yawDegrees, "pitch": angles.pitchDegrees])
        }
    }
}
