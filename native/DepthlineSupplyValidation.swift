import SceneKit

/// Aim at an actual mission drop using the player sight. The near-miss, pickup
/// and repeated shot all run through the shared projectile pool.
extension Game {
    func validateSupplyGunfire(canopy: Bool, output: URL? = nil) throws -> [String: Any] {
        let coast = version == .beach2000
        let levelNumber = coast ? 1 : 6
        let seed: UInt32 = coast ? 20001102 : 200203
        let surface = canopy ? "canopy" : "crate"
        func check(_ ok: Bool, _ detail: String) throws {
            try CampaignRuntimeValidation.require(ok, "\(assets.gameID) level \(levelNumber), \(surface), tick \(logicalTick): \(detail)")
        }
        random = Beach2000Supply.Random(seed:seed)
        originalClock = OriginalTickClock()
        restart(level:levelNumber - 1)
        try check(supplyMessage.isEmpty && supplyMessageUntil == 0,"Level restart retained a supply receipt")
        defer { shooting = false }
        func liveCargoID() -> Int? {
            if coast { return supply2000?.parachutes.first(where: { $0.visible })?.objectID }
            return supply2002?.boxes.first(where: { $0.visible })?.parentParachuteID
        }
        while liveCargoID() == nil && logicalTick < 2200 && !finished {
            combat.health = 100
            autoreleasepool { simulationTick() }
        }
        guard let id = liveCargoID(), let chute = supplyNodes[id] else {
            throw NSError(domain:"DepthlineSupply",code:1,userInfo:[NSLocalizedDescriptionKey:"No mission cargo in \(assets.gameID) with seed \(seed)"])
        }
        let released = logicalTick
        let releasePosition = [chute.worldPosition.x,chute.worldPosition.y,chute.worldPosition.z]
        print("Airdrop \(assets.gameID) \(surface), seed \(seed), chute \(id), tick \(released), release position \(releasePosition)")
        let payloadID = supply2002?.parachutes.first(where: { $0.objectID == id })?.payloadID
        let cargo = coast ? chute.childNode(withName:"RemasteredSupplyPayload", recursively:false) : payloadID.flatMap { supplyNodes[$0] }
        guard let cargo else { throw NSError(domain:"DepthlineSupply",code:2,userInfo:[NSLocalizedDescriptionKey:"Missing visible cargo on chute \(id)"]) }
        let mark = coast ? DepthlineSupplyMark.coast(supply2000?.parachutes.first { $0.objectID == id }?.reward) :
            DepthlineSupplyMark.hills(supply2002?.parachutes.first { $0.objectID == id }?.payloadKind)
        let faces = cargo.childNode(withName:"cargo-stencil",recursively:false)?.childNodes ?? []
        let ink = faces.first?.geometry?.firstMaterial
        try check(mark != nil && ink?.name == mark.map { "supply-sign-" + $0.rawValue } &&
                  faces.count == 4 && faces.allSatisfy { $0.geometry?.firstMaterial === ink },
                  "All four crate faces must identify this particular reward")
        // Coast stores the painted box in the mesh itself. Inland places a
        // separate payload node under the parachute.
        let bounds = cargo.boundingBox
        let center = SCNVector3((bounds.min.x+bounds.max.x)/2,(bounds.min.y+bounds.max.y)/2,(bounds.min.z+bounds.max.z)/2)
        func targetPoint() -> SCNVector3 {
            canopy ? chute.convertPosition(SCNVector3(0,0.55,0),to:nil) : cargo.convertPosition(center,to:nil)
        }
        func aim(_ point: SCNVector3, yawOffset: CGFloat = 0) {
            let eye = camera.worldPosition
            let x = point.x-eye.x, y = point.y-eye.y, z = point.z-eye.z
            camera.eulerAngles = SCNVector3(atan2(y,hypot(x,z)),atan2(-x,-z)+yawOffset,0)
            syncGunPose()
        }
        for _ in 0..<42 { simulationTick() } // Allow the aircraft to clear the target.
        let cross = targetPoint()
        let axis = SIMD3<Double>(1,0,0)
        let point = SIMD3<Double>(cross.x,cross.y,cross.z)*100
        enemyOrdnance.spawn(.init(version:version,kind:.bullet,position:point-axis*200,velocity:axis*400))
        updateOriginalSharedProjectiles()
        try check(!chute.isHidden && supplyMessageUntil == 0,"Enemy round through cargo claimed the supply")

        if let output, !canopy {
            aim(targetPoint())
            SCNTransaction.flush()
            let path = output.appendingPathComponent("\(assets.gameID)-airdrop-sight.png")
            try captureNativePixels(options: NativeCaptureOptions(arguments: [])).write(to:path,options:.atomic)
        }
        let shots = combat.shots
        combat.health = 50
        weapons.ammo.machineGun = 100; weapons.ammo.cannon = 3; weapons.ammo.missile = 1
        aim(cross,yawOffset:.pi/3)
        shooting = true
        for _ in 0..<8 where combat.shots == shots { simulationTick() }
        shooting = false
        for _ in 0..<28 { simulationTick() }
        try check(combat.shots == shots+1 && weapons.ammo.machineGun == 99 && !chute.isHidden && supplyMessageUntil == 0,
                  "An intentional miss must spend one round and leave the box available")
        // Track the painted target through a short burst, like keeping the
        // crosshair on the falling cargo while holding the trigger.
        var receiptAmmo = weapons.ammo
        var receiptHealth = combat.health
        let burstStart = logicalTick
        let firstAim = targetPoint()
        let range = simd_distance(camera.simdWorldPosition, SIMD3(Float(firstAim.x),Float(firstAim.y),Float(firstAim.z)))
        shooting = true
        while logicalTick-burstStart < 55 && !chute.isHidden {
            receiptAmmo = weapons.ammo
            receiptHealth = combat.health
            aim(targetPoint())
            simulationTick()
        }
        shooting = false
        let impactTick = logicalTick
        let receipt = supplyMessageUntil
        let shotsInBurst = combat.shots-shots-1
        let resourceIncreased = combat.health > receiptHealth || weapons.ammo.machineGun > receiptAmmo.machineGun ||
            weapons.ammo.cannon > receiptAmmo.cannon || weapons.ammo.missile > receiptAmmo.missile
        try check(chute.isHidden && receipt > elapsed && resourceIncreased && shotsInBurst > 0,
                  "Tracked burst failed to redeem the visible \(surface) at \(range) m (\(shotsInBurst) rounds, message: \(supplyMessage))")
        updateHUD()
        try check(!hud.message.isEmpty && hud.message == supplyMessage,"Visible HUD did not show the pickup receipt")
        // A further projectile traverses the collected object's last position.
        let ammo = weapons.ammo, health = combat.health
        let action = OriginalFireAction(weapon:.machineGun,barrel:.left,variant:0,recoilTicks:0,ballistic:weapons.profile.ballistic(.machineGun))
        let last = targetPoint()
        _ = projectiles.spawn(action,from:SCNVector3(last.x-2,last.y,last.z),direction:SCNVector3(1,0,0))
        updateOriginalSharedProjectiles()
        try check(receipt == supplyMessageUntil && weapons.ammo == ammo && health == combat.health && chute.isHidden,
                  "A second impact at the collected position awarded another supply")
        return ["game":assets.gameID,"level":levelNumber,"seed":seed,"surface":surface,"chuteID":id,
                "releasedAtTick":released,"releasePositionMetres":releasePosition,
                "burstStartTick":burstStart,"aimAtBurstStartMetres":[firstAim.x,firstAim.y,firstAim.z],"pickupTick":impactTick,
                "shotsInBurst":shotsInBurst,"rangeMetres":range,"message":hud.message,"mark":mark!.rawValue,
                "defenceBeforeAndAfter":[receiptHealth,combat.health],"machineGunBeforeAndAfter":[receiptAmmo.machineGun,ammo.machineGun],
                "cannonBeforeAndAfter":[receiptAmmo.cannon,ammo.cannon],"missileBeforeAndAfter":[receiptAmmo.missile,ammo.missile],
                "enemyRoundIgnored":true,"wideShotMissed":true,"repeatIgnored":true]
    }
}
