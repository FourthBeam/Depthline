import SceneKit

extension Game {
    func validateDepthlineInfantry(output: URL?) throws -> [String: Any] {
        defer { restart() }
        return ["sector": assets.gameID,
                "cannon": try validateCannonAgainstSoldiers(output: output),
                "disembarkation": try validateArmoredTransport(output: output)]
    }

    /// Freeze the pose and other units to distinguish a strike on the skin from a
    /// later terrain explosion. Fire from the mounted cannon through its live pool.
    private func validateCannonAgainstSoldiers(output: URL?) throws -> [String: Any] {
        restart()
        for e in enemies { e.node.removeFromParentNode() }
        enemies.removeAll()
        weapons.cycleWeapon()
        let coast = version == .beach2000
        let standing = coast ? 14 : 19
        let prone = coast ? 18 : 29
        var nextSlot = 0
        func soldier(at p: SCNVector3, state: Int) -> Enemy {
            let e = Enemy(node: assets.model("INFANTRY"), type: "INFANTRY", flying: false)
            e.node.position = p
            e.slot = nextSlot
            nextSlot += 1
            e.sourceIndex = 0
            e.aiState = state
            _ = RemasteredInfantry.update(e.node, gameID: assets.gameID, state: state, frame: coast ? 15 : 88, direction: .init(0, 0, -1))
            scene.rootNode.addChildNode(e.node)
            enemies.append(e)
            return e
        }
        func retire(_ e: Enemy) {
            e.node.removeFromParentNode()
            enemies.removeAll { $0 === e }
        }
        func check(_ ok: Bool, _ why: String) throws {
            try CampaignRuntimeValidation.require(ok, "Infantry \(assets.gameID): \(why)")
        }
        func fireAt(_ point: SCNVector3) throws {
            let delta = SIMD3<Float>(point) - camera.simdWorldPosition
            camera.eulerAngles = SCNVector3(CGFloat(atan2(delta.y, hypot(delta.x, delta.z))), CGFloat(atan2(-delta.x, -delta.z)), 0)
            syncGunPose()
            var accepted: OriginalFireAction?
            for _ in 0..<36 {
                if let action = weapons.step(triggerDown: true) { accepted = action; break }
            }
            guard let action = accepted, action.weapon == .cannon else { throw NSError(domain: "InfantryCannonNotReady", code: 1) }
            weaponPresentation.tick(acceptedFire: action)
            fire(action)
            try check(projectiles.ballisticCount == 1, "Cannon must emit one live shell")
        }
        var hits: [[String: Any]] = []
        for (range, state) in [(20.0, standing), (52.0, prone)] {
            let x = 3.0, z = -range
            // A raised target at the longer range isolates a prone body from the
            // blast radius of the ground. The near target stands on the mission soil.
            let y = assets.height(x: x, z: z) + (state == prone ? 5 : 0)
            let target = soldier(at: SCNVector3(x, y, z), state: state)
            guard let actor = target.node as? RemasteredInfantryNode else { throw NSError(domain: "MissingInfantryRig", code: 1) }
            let torso = actor.bones[0].convertPosition(SCNVector3(0, 0.32, 0), to: nil)
            let direction = simd_normalize(SIMD3<Float>(torso) - camera.simdWorldPosition)
            let behind = soldier(at: SCNVector3(SIMD3<Float>(target.node.position) + direction * 10), state: state)
            let before = combat.score
            let directHits = combat.hits
            let force = campaign?.forceRemaining(sourceIndex: 0) ?? 0
            try fireAt(torso)
            var ticks = 0
            while projectiles.ballisticCount > 0 && ticks < 25 {
                updateOriginalSharedProjectiles()
                ticks += 1
            }
            try check(target.deathMode == .infantryDebris && behind.deathMode == .none,
                      "First visible \(state) body must stop the shell at \(range)m in \(ticks) ticks")
            try check(combat.hits == directHits + 1, "Direct contact was mistaken for a later terrain explosion")
            try check(projectiles.ballisticCount == 0 && ticks <= Int(ceil(range / 4)) + 1, "Shell continued beyond body")
            try check(combat.score == before + (coast ? 1 : 0) && campaign?.forceRemaining(sourceIndex: 0) == force - 1, "Lost or duplicate infantry award")
            if state == standing, let output {
                try validationPhoto(from: SIMD3<Float>(target.node.worldPosition) + SIMD3(5, 3, 6),
                                    at: SIMD3<Float>(torso), file: output.appendingPathComponent("\(assets.gameID)-炮弹命中.png"))
            }
            hits.append(["rangeMetres": range, "pose": state == standing ? "standing" : "prone", "impactTick": ticks,
                         "forceDebited": 1, "scoreDelta": combat.score - before])
            retire(target)
            retire(behind)
        }

        let point = SCNVector3(1, 12, -24)
        let witness = soldier(at: point, state: standing)
        let end = SCNVector3(point.x+1.6, point.y+1.0, point.z)
        try fireAt(end)
        for _ in 0..<12 { updateOriginalSharedProjectiles() }
        try check(projectiles.ballisticCount == 1 && witness.deathMode == .none, "Shell passing beside a body must continue")
        _ = projectiles.clear()
        retire(witness)

        // One shell step crosses an armor plate before it reaches the body.
        // Strike from the side so both are within the four-metre flight step.
        func armoredCover() -> Enemy {
            let apc = Enemy(node: assets.model("APC1"), type: "APC1", flying: false)
            apc.node.position = SCNVector3(0, 14, -22)
            apc.aiState = 6
            apc.sourceIndex = -1
            scene.rootNode.addChildNode(apc.node)
            enemies.append(apc)
            return apc
        }
        let apc = armoredCover()
        let covered = soldier(at: SCNVector3(1.42, 14, -22), state: standing)
        let throughPlate = OriginalProjectileSweep(kind: .ballistic(.cannon), start: SCNVector3(-2.25,15,-22), end: SCNVector3(1.75,15,-22))
        try check(depthlineInfantryContact(throughPlate)?.target === covered.node && resolveDepthlineInfantryShell(throughPlate),
                  "Shielding fixture must intersect both body and vehicle")
        try check(apc.aiState != 6 || apc.node.parent == nil, "Shell passed through the nearer armored hull")
        retire(apc)
        let priorCover = armoredCover()
        let earlier = OriginalProjectileSweep(kind: .ballistic(.cannon), start: SCNVector3(-3.5,15,-22), end: SCNVector3(0.5,15,-22))
        try check(depthlineInfantryContact(earlier) == nil && resolveDepthlineInfantryShell(earlier) &&
                  (priorCover.aiState != 6 || priorCover.node.parent == nil), "Armor must also intercept on a flight step before the soldier")
        retire(priorCover)
        let passenger = soldier(at: SCNVector3(1.42, 14, -22), state: coast ? 60 : 9)
        passenger.node.isHidden = true
        retire(covered)
        try check(depthlineInfantryContact(throughPlate) == nil, "Hidden passengers must not consume a direct hit")
        retire(passenger)

        // A real close ground strike must still catch a soldier beside the impact.
        let ground = assets.pointHeight(x: 1, z: -12)
        let surface = assets.height(x: 1, z: -12)
        let buried = soldier(at: SCNVector3(1, surface-2, -12), state: standing)
        let downslope = OriginalProjectileSweep(kind: .ballistic(.cannon), start: SCNVector3(1,surface+1,-12),
                                                end: SCNVector3(1,surface-3,-12))
        let directHits = combat.hits
        try check(depthlineInfantryContact(downslope)?.target === buried.node && resolveDepthlineInfantryShell(downslope) &&
                  combat.hits == directHits, "A nearer terrain surface must receive the shell before a body behind it")
        retire(buried)
        let bystander = soldier(at: SCNVector3(2, ground, -12), state: standing)
        let shell = OriginalFireAction(weapon: .cannon, barrel: .center, variant: 0, recoilTicks: 0, ballistic: weapons.profile.ballistic(.cannon))
        try check(projectiles.spawn(shell, from: SCNVector3(1, ground+3.8, -12), direction: SCNVector3(0,-1,0)), "Ground-strike shell unavailable")
        updateOriginalSharedProjectiles()
        try check(projectiles.ballisticCount == 0 && bystander.deathMode == .infantryDebris, "Terrain contact must still deliver blast damage")
        return ["aimedDirectHits": hits, "nearMissContinued": true, "groundBurst": true, "vehicleInterceptedFirst": true,
                "earlierVehicleStepIntercepted": true, "terrainInterceptedFirst": true, "hiddenPassengerIgnored": true]
    }

    /// Snapshot from the rear quarter so the door, tracks and the soldier's feet
    /// are visible together. Restore the player camera before resuming simulation.
    private func validationPhoto(from eye: SIMD3<Float>, at target: SIMD3<Float>, file: URL) throws {
        let saved = camera.simdTransform
        defer { camera.simdTransform = saved }
        camera.simdPosition = eye
        camera.look(at: SCNVector3(target))
        SCNTransaction.flush()
        var options = try NativeCaptureOptions(arguments: [])
        options.hideHUD = true
        try captureNativePixels(options: options).write(to: file, options: .atomic)
    }
}

private extension Game {
    func validateArmoredTransport(output: URL?) throws -> [String: Any] {
        let coast = version == .beach2000, mission = coast ? 25 : 1
        func deploy() {
            random = Beach2000Supply.Random(seed: 9013)
            originalClock = OriginalTickClock()
            restart(level: mission - 1)
        }
        func advance() {
            combat.health = 100
            autoreleasepool { simulationTick() }
        }
        deploy()
        guard let source = (levelDefinition?["objects"] as? [[String: Any]])?.firstIndex(where: { $0["type"] as? String == "APC1" && $0["slot"] as? Int == 0 }) else {
            throw NSError(domain: "MissingAPCInMission", code: mission)
        }
        func carrier() -> Enemy? {
            enemies.first { $0.type.hasPrefix("APC") && $0.sourceIndex == source && !$0.node.isHidden }
        }
        func visiblePassengers() -> [Enemy] {
            enemies.filter { e in
                guard e.type == "INFANTRY", !e.node.isHidden, e.deathMode == .none else { return false }
                return coast ? (48..<54).contains(e.aggregateSoldierSlot ?? -1) : e.sourceIndex == source
            }
        }
        var appeared: [Int: Int] = [:], previous: [Int: SIMD3<Float>] = [:]
        var gatePoints: [[Float]] = [], endTick = 0, maxStep: Float = 0, sawClosedCarrier = false
        while logicalTick < 4600 && !finished {
            advance()
            guard let apc = carrier() else { continue }
            let passengers = visiblePassengers()
            // Track the first unit carried by this vehicle generation.
            if passengers.isEmpty && appeared.isEmpty { sawClosedCarrier = true }
            for soldier in passengers {
                let key = soldier.slot, world = soldier.node.simdWorldPosition
                let local = apc.node.simdConvertPosition(world, from: nil)
                if appeared[key] == nil {
                    try CampaignRuntimeValidation.require(local.z > 1.28 && local.z < 3.4 && abs(local.x) < 0.90,
                        "\(assets.gameID) first rendered step came through the hull: \(local) at \(logicalTick)")
                    appeared[key] = logicalTick
                    gatePoints.append([local.x, local.y, local.z])
                    if appeared.count == 3, let output {
                        let eye = apc.node.simdConvertPosition(.init(5.5,3.2,7), to: nil)
                        let aim = apc.node.simdConvertPosition(.init(0,0.8,1.55), to: nil)
                        try validationPhoto(from: eye, at: aim, file: output.appendingPathComponent("\(assets.gameID)-载员从车尾步出.png"))
                    }
                }
                if logicalTick - (appeared[key] ?? logicalTick) < 100 {
                    try CampaignRuntimeValidation.require(abs(local.x) > (coast ? 0.84 : 0.95) || local.z >= 1.28 || local.z < (coast ? -1.6 : -2.6),
                        "\(assets.gameID) exiting soldier reentered the armored hull: \(local)")
                    if let p = previous[key] { maxStep = max(maxStep, simd_distance(p, world)) }
                }
                previous[key] = world
            }
            if appeared.count == 6 {
                if endTick == 0 { endTick = logicalTick + 100 }
                if logicalTick >= endTick { break }
            }
        }
        let times = appeared.values.sorted()
        try CampaignRuntimeValidation.require(sawClosedCarrier && times.count == 6 && Set(times).count == 6 && maxStep < 0.6,
            "APC egress must show six staggered soldiers with continuous positions in \(assets.gameID): \(times), maximum step \(maxStep)")

        // Destroy the same transport on the first man's way down. Use the
        // direct vehicle hit to isolate the cargo rules from nearby blast damage.
        deploy()
        while logicalTick < 4600 && visiblePassengers().isEmpty && !finished { advance() }
        guard let apc = carrier(), let first = visiblePassengers().first, let missionState = campaign,
              visiblePassengers().count == 1 else { throw NSError(domain: "MissingPartialDisembarkation", code: mission) }
        let force = missionState.forceRemaining(sourceIndex: source)
        let context = OriginalDamageContext(version: version, type: apc.type, hitPoints: apc.hp, aiState: apc.aiState,
                                           originalObjectIndex: originalObjectIndex(apc))
        applyDamage(OriginalDamage.resolve(context, weapon: .cannon, part: 0), to: apc)
        advance()
        try CampaignRuntimeValidation.require(visiblePassengers().count == 1 && visiblePassengers()[0] === first &&
            missionState.forceRemaining(sourceIndex: source) == force - 5, "A destroyed APC must remove just its five occupied seats")
        applyInfantryExplosion(first, at: first.node.worldPosition, weapon: .cannon)
        for _ in 0..<100 {
            advance()
            try CampaignRuntimeValidation.require(visiblePassengers().isEmpty, "Dead soldier resumed the APC exit path")
        }
        try CampaignRuntimeValidation.require(missionState.forceRemaining(sourceIndex: source) == force - 6,
                                              "Repeated force charge after losing carrier and its last man")
        return ["mission": mission, "unit": "APC1 slot 0", "firstVisibleTicks": times, "gatePositionsLocalMetres": gatePoints,
                "maxVisibleStepMetres": maxStep, "hiddenInTransit": sawClosedCarrier, "occupiedSeatsLostWithCarrier": 5,
                "deadSoldierStayedRemoved": true]
    }
}
