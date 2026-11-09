import AppKit
import SceneKit

extension AppDelegate {
    /// New-resource regression suite. Historical extracted-asset assertions are
    /// intentionally kept in their old suite, never relabeled as Depthline evidence.
    func runDepthlineValidation() throws {
        func check(_ ok: @autoclosure () -> Bool, _ detail: String) throws {
            if !ok() { throw NSError(domain:"DepthlineValidation",code:1,userInfo:[NSLocalizedDescriptionKey:detail]) }
        }
        try mouseCaptureSelfTest()
        try originalInputModelSelfTest()
        try campaignStoreSelfTest()
        try originalCampaignSelfTest()
        try originalCampaignAssetSelfTest(resourceRoot2000: gameResourceRoot("2000"), resourceRoot2002: gameResourceRoot("2002"))
        var results: [CampaignRuntimeValidation.Mission] = []
        var projectionSamples: [[String:Any]] = []
        var helicopterFlights: [[String:Any]] = []
        var supplySamples: [[String:Any]] = []
        var infantrySamples: [[String:Any]] = []
        var coverSamples: [[String:Any]] = []
        var reticleSamples: [[String:Any]] = []
        let reportPath = arguments.firstIndex(of:"--depthline-report").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        let captureDirectory = reportPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        if let captureDirectory {
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        }
        for id in ["2000","2002"] {
            try startGame(id)
            guard let current=game else {throw NSError(domain:"DepthlineValidation",code:2)}
            current.timer?.invalidate();current.timer=nil;current.settings.soundEnabled=false
            try check(current.assets.levels.count == (id == "2000" ? 60 : 99), "Complete restored campaign")
            try check(current.assets.levels.allSatisfy { $0["source"] == nil && $0["commands"] == nil },
                      "Packaged missions contain normalized data without source paths or raw scripts")
            try check(current.assets.objects.allSatisfy { $0["sourceLine"] == nil },"No extracted geometry line references")
            try check(current.scene.rootNode.childNode(withName:"DepthlineEnvironment",recursively:false) != nil,"Original emplacement installed")
            try check(window.collectionBehavior.contains(.fullScreenPrimary),"Full-screen primary window")
            current.view.layoutSubtreeIfNeeded()
            current.updateOriginalHUD()
            window.displayIfNeeded()
            current.hud.displayIfNeeded()
            // AppKit may mark only the backing layer until the next display pass.
            func hudIsDirty() -> Bool { current.hud.needsDisplay || current.hud.layer?.needsDisplay() == true }
            try check(!hudIsDirty(), "Initial HUD layout and draw completed")
            current.updateOriginalHUD()
            try check(!hudIsDirty(), "An unchanged battle HUD leaves its backing layer clean")
            current.weapons.ammo.machineGun -= 1
            current.updateOriginalHUD()
            try check(hudIsDirty() && current.hud.weaponAmmo == current.weapons.ammo.machineGun,
                      "Spending a round refreshes the displayed ammunition")
            current.weapons.ammo.machineGun += 1
            current.updateOriginalHUD()
            try validateProjectileSlotReuse(current)
            coverSamples += try validatePlayerMachineGunCover(current)
            reticleSamples += try current.validateMachineGunReticle(output: captureDirectory)
            try validateMissionEquipment(current)
            if id == "2002" { try validateLastHelicopter(current) }
            if id == "2002" { try current.validateCarriageTraverse() }
            helicopterFlights.append(try current.validateDepthlineHelicopterFlight())
            infantrySamples.append(try current.validateDepthlineInfantry(output: captureDirectory))
            if id == "2000" {
                guard let field=current.assets.shoreline, let water=current.assets.waterContact else {
                    throw NSError(domain:"ShoreContact",code:1)
                }
                // At the same Z a shell can now hit the side headland or splash
                // in the open channel. The historical straight Z cutoff could not.
                let x1 = -100.0, x2 = 0.0, z=0.5*(field.z(at:x1)+field.z(at:x2))
                try check(field.z(at:x1)<z && z<field.z(at:x2),"Dry bluff and wet channel at the same depth")
                for (x,expected):(Double,OriginalEnemyImpactKind) in [(x1,.ground),(x2,.water)] {
                    let end=SIMD3<Double>(100*x,-10,100*z)
                    var contact: OriginalEnemyImpact?
                    let retired=OriginalSharedBallistics.resolve(version:.beach2000,bank:.shell,
                        sweep:.init(weapon:.cannon,start:end+SIMD3(0,500,0),end:end),
                        ground:{xx,zz in Double(current.assets.height(x:xx/100,z:zz/100))*100},waterAt:water,
                        onTerrain:{contact=$0},onPlayer:{_ in},hitTargets:{_ in false},hitInfantry:{false})
                    try check(retired && contact?.kind == expected,"Surface impact follows the visible bay")
                }
            }
            for level in (id == "2000" ? [1,12,60]:[1,11,65,99]) {
                results.append(try CampaignRuntimeValidation.run(current,level:level,ticks:1600))
            }
            for canopy in [false,true] {
                supplySamples.append(try current.validateSupplyGunfire(canopy:canopy,output:captureDirectory))
            }
            current.restart();current.settings.soundEnabled=false
            projectionSamples += try validateDepthlinePresentation(current)
            // Check the actual muzzle in a clear lane. The reticle regression
            // above separately exercises the low barrel beside a close sandbag.
            current.camera.eulerAngles = SCNVector3(8 * CGFloat.pi / 180, id == "2000" ? 0 : CGFloat.pi, 0)
            current.syncGunPose()
            let ammo=current.weapons.ammo.machineGun, shots=current.combat.shots
            // A restarted run preserves the weapon's cadence phase. Wait for
            // its next accepted shot instead of assuming the first phase fires.
            var accepted: OriginalFireAction?
            for _ in 0..<7 {
                if let action=current.weapons.step(triggerDown:true) {accepted=action;break}
            }
            guard let action=accepted else {throw NSError(domain:"DepthlineValidation",code:3)}
            current.weaponPresentation.tick(acceptedFire:action)
            current.fire(action)
            let firedBasis=current.weaponPresentation.basis(for:action)
            guard let tip=firedBasis.muzzle,let round=current.projectiles.snapshots.last else {
                throw NSError(domain:"DepthlineMuzzle",code:1)
            }
            let delta=SIMD3<Float>(Float(round.position.x-tip.x), Float(round.position.y-tip.y), Float(round.position.z-tip.z))
            try check(simd_length(delta)<0.001 && !current.muzzleLamp.isHidden && current.hud.damageFlash==0,
                      "Round and local flash start at the recoiling muzzle without a damage overlay")
            try check(current.combat.shots == shots+1 && current.weapons.ammo.machineGun == ammo-1,"Shot consumes ammo and enters production ballistics")
            current.togglePause();let tick=current.logicalTick;current.tick()
            try check(current.logicalTick==tick,"Pause freezes simulation")
            current.togglePause()
            current.combat.health-=1
            try check(current.hud.damageFlash==1,"Defence loss starts the damage overlay")
            for _ in 0..<5 { current.simulationTick() }
            try check(current.muzzleLamp.isHidden && current.hud.damageFlash==0,"Local light and damage feedback expire on the simulation clock")
            current.effects.clear()
            for kind in OriginalEffectKind.allCases where OriginalEffectProfile.recovered(kind,version:current.version) != nil {
                try check(current.effects.emit(kind,at:SIMD3(0,800,-1600)) != nil,"New effect emitted: \(kind.rawValue)")
            }
            try check(current.effects.missingTexturePaths.isEmpty,"No old sprite dependency")
            current.fragments.clear()
            try check(current.fragments.emit(objectID:id == "2000" ? 88:142,chunkSize:8,style:.airburst,position:SIMD3(0,800,-1600),rotationDegrees:.zero,random15:{12345}),"Original fragment geometry available")
            try check(current.fragments.activeCount>0,"Visible plate fragments")
            let before=current
            showLauncher()
            try check(game==nil && before.timer==nil && !before.view.mouseCapture.isCaptured,"Launcher cleans game and cursor")
        }
        let payload:[String:Any]=[
            "title":DepthlineIdentity.title,
            "scope":"Seven production missions including both final missions, 1600 ticks each with no player fire and health replenished for observation.",
            "aimMeasurements":projectionSamples,
            "helicopterFlights":helicopterFlights,
            "infantry":infantrySamples,
            "machineGunCover":coverSamples,
            "machineGunReticle":reticleSamples,
            "gunMount":"Hills mission two: 37 traverse headings at each of four pitch angles. Both ends of the support stay on their pins and the fork keeps its orientation relative to the receiver.",
            "airdropGunfire":supplySamples,
            "missionResults":try JSONSerialization.jsonObject(with:JSONEncoder().encode(results)),
            "checks":["capture state machine","direct input invariants","isolated named saves","new mission schemas","finite live entities and projectiles","64-degree camera and 55-percent HUD aim at 16:9 and 16:10","world-fixed lighting across four headings","gun offset follows aim","cloud and water simulation time and pause freeze","terrain versus water impacts across the bay","local muzzle and damage-only HUD","pause","shot and ammo","aimed machine-gun flight to falling cargo and canopy in both sectors, resource award and HUD receipt, miss and enemy-fire exclusions, single redemption","all effect kinds without legacy textures","new plate debris","launcher cleanup"]]
        let path = reportPath ?? "build/depthline-validation.json"
        try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        print("PASS: Depthline original resource integration, 7 missions / 11200 ticks")
    }

    private func validateProjectileSlotReuse(_ game: Game) throws {
        let original = game.enemies
        defer { game.enemies = original }
        let first = Enemy(node: SCNNode(), type: "TANK", flying: false)
        let second = Enemy(node: SCNNode(), type: "TANK", flying: false)
        game.enemies = [first, second]
        func visible() -> Enemy? { game.projectileTargets.visibleEnemy(at: 37) }
        try CampaignRuntimeValidation.require(visible() === first, "Matching slots retain original actor order")
        first.node.isHidden = true
        try CampaignRuntimeValidation.require(visible() === second, "A hidden actor immediately exposes the next slot occupant")
        first.node.isHidden = false
        game.enemies.removeFirst()
        try CampaignRuntimeValidation.require(visible() === second, "Removed slot occupants cannot take a later round")
        game.enemies = []
        try CampaignRuntimeValidation.require(visible() == nil, "An empty slot cannot take a round")
        game.enemies.append(first)
        try CampaignRuntimeValidation.require(visible() === first, "A reused slot can take a round on the same tick")
    }

    /// Real trigger, alternating barrels and production projectile steps. SceneKit's
    /// visible triangle is the independent reference for the decal and its normal.
    private func validatePlayerMachineGunCover(_ game: Game) throws -> [[String: Any]] {
        let coast = game.version == .beach2000
        func check(_ ok: Bool, _ detail: String) throws {
            try CampaignRuntimeValidation.require(ok, "Machine-gun cover \(game.assets.gameID): \(detail)")
        }
        let level = coast ? 1 : 14  // Both missions equip the twin mount.
        game.restart(level: level - 1)
        defer { game.restart() }
        SCNTransaction.flush()
        guard let cover = game.emplacementCover else { throw NSError(domain: "MissingEmplacementCover", code: level) }
        let yaw: CGFloat = coast ? 29 : 209
        let sandPitch: CGFloat = coast ? -6 : -9.5
        let shots: [(CGFloat, DepthlineCover.Surface?, String)] = [
            (sandPitch, .sandbag, "Sandbags"), (-12, .concrete, "Concrete"),
            (4, nil, "open"), (4, nil, "open")
        ]
        var samples: [[String: Any]] = [], openMuzzles: [SIMD3<Float>] = []
        let health = game.combat.health, ammo = game.weapons.ammo.machineGun
        for (pitch, expectedSurface, batch) in shots {
            game.camera.eulerAngles = SCNVector3(pitch * .pi / 180, yaw * .pi / 180, 0)
            game.syncGunPose()
            let before = game.combat.shots, previousMarks = game.coverImpacts.marks.count
            game.shooting = true
            for _ in 0..<12 where game.combat.shots == before { game.simulationTick() }
            game.shooting = false
            guard let round = game.projectiles.snapshots.first, round.kind == .ballistic(.machineGun) else {
                throw NSError(domain: "ExpectedPlayerTracer", code: level)
            }
            let muzzle = SIMD3<Float>(round.position), direction = game.camera.simdWorldFront
            let eye = game.camera.simdWorldPosition
            let hit = cover.firstHit(from: eye, to: eye + direction * 12)
            try check(game.combat.shots == before + 1 && hit?.surface == expectedSurface,
                      "Unexpected first surface at yaw \(yaw), pitch \(pitch): \(String(describing: hit?.surface))")
            for _ in 0..<3 { game.updateOriginalSharedProjectiles() }
            if let hit {
                guard let mesh = game.scene.rootNode.childNode(withName: "DepthlineEnvironment" + batch, recursively: true),
                      let mark = game.coverImpacts.marks.last else { throw NSError(domain: "MissingCoverMark", code: level) }
                let a = mark.simdWorldPosition + hit.normal * 0.04, b = mark.simdWorldPosition - hit.normal * 0.06
                let meshHit = mesh.hitTestWithSegment(from: mesh.convertPosition(SCNVector3(a), from: nil),
                                                      to: mesh.convertPosition(SCNVector3(b), from: nil),
                                                      options: [SCNHitTestOption.backFaceCulling.rawValue: false]).first
                try check(game.coverImpacts.marks.count == previousMarks + 1 && game.projectiles.ballisticCount == 0 &&
                          simd_distance(mark.simdWorldPosition, hit.position) < 0.025 && simd_dot(hit.normal, direction) < 0 &&
                          simd_dot(mark.simdWorldOrientation.act(SIMD3(0, 0, 1)), hit.normal) > 0.99 &&
                          meshHit.map { simd_distance(SIMD3<Float>($0.worldCoordinates), mark.simdWorldPosition) < 0.025 } == true,
                          "Shot must stop on the nearest rendered \(batch) triangle and leave a mark on its entry face")
            } else {
                try check(game.coverImpacts.marks.count == previousMarks && game.projectiles.ballisticCount == 1,
                          "The open firing lane must pass a live tracer without leaving a mark")
                _ = game.projectiles.clear()
                openMuzzles.append(muzzle)
            }
            samples.append(["sector": game.assets.gameID, "mission": level, "yaw": yaw, "pitch": pitch,
                            "surface": batch, "muzzleMetres": [muzzle.x, muzzle.y, muzzle.z]])
        }
        try check(openMuzzles.count == 2 && simd_distance(openMuzzles[0], openMuzzles[1]) > 0.10,
                  "Consecutive machine-gun rounds must come from the two physical barrels")
        try check(game.combat.health == health && game.weapons.ammo.machineGun == ammo - shots.count,
                  "Expected defence \(health), ammo \(ammo - shots.count); got \(game.combat.health), \(game.weapons.ammo.machineGun)")
        try validatePlayerShotOcclusion(game)
        game.restart(level: level - 1)
        try check(game.coverImpacts.marks.isEmpty, "A new mission must clear previous bullet holes")
        return samples
    }

    /// Put the same standing infantry target on either side of a wall crossed
    /// within one bullet step, so hit order cannot be inferred from the endpoint.
    private func validatePlayerShotOcclusion(_ game: Game) throws {
        let coast = game.version == .beach2000
        let forward = SIMD3<Float>(0, 0, coast ? -1 : 1)
        let start = forward * 5 + SIMD3(0, Float(game.assets.height(x: 0, z: 0)) + 0.22, 0)
        let action = OriginalFireAction(weapon: .machineGun, barrel: .left, variant: 0, recoilTicks: 0,
                                        ballistic: game.weapons.profile.ballistic(.machineGun))
        let end = start + forward * (coast ? 4 : 5)
        let sweep = OriginalProjectileSweep(kind: .ballistic(.machineGun), start: SCNVector3(start), end: SCNVector3(end))
        guard let wall = game.emplacementCover?.firstHit(from: start, to: end), wall.surface == .concrete else {
            throw NSError(domain: "MissingCoverBetweenActors", code: 1)
        }
        for shielded in [true, false] {
            let actor = Enemy(node: game.assets.model("INFANTRY"), type: "INFANTRY", flying: false)
            actor.aiState = coast ? 14 : 19
            guard let skin = actor.node as? RemasteredInfantryNode else { throw NSError(domain: "MissingInfantrySkin", code: 1) }
            skin.apply(state: actor.aiState, frame: coast ? 15 : 88, direction: .init(0, 0, 1))
            let chest = skin.bones[0].simdConvertPosition(SIMD3(0, 0.32, 0), to: skin)
            actor.node.simdPosition = wall.position + forward * (shielded ? 0.8 : -0.8) - chest
            game.scene.rootNode.addChildNode(actor.node)
            game.enemies.append(actor)
            defer { actor.node.removeFromParentNode(); game.enemies.removeAll { $0 === actor } }
            let eligible = game.hitCandidates(sweep).first { $0.target === actor.node }
            try CampaignRuntimeValidation.require(eligible.map { ($0.fraction > CGFloat(wall.fraction)) == shielded } == true,
                                                  "Occlusion fixture must cross the actor and the wall in the intended order")
            let marks = game.coverImpacts.marks.count, hits = game.combat.hits
            try CampaignRuntimeValidation.require(game.projectiles.spawn(action, from: sweep.start, direction: SCNVector3(forward)),
                                                  "Occlusion fixture must enter the live projectile pool")
            game.updateOriginalSharedProjectiles()
            try CampaignRuntimeValidation.require(game.projectiles.ballisticCount == 0 &&
                game.combat.hits == hits + (shielded ? 0 : 1) && game.coverImpacts.marks.count == marks + (shielded ? 1 : 0),
                "The first physical contact must receive the shot when infantry is \(shielded ? "behind" : "in front of") the parapet")
        }
    }

    /// A loaded CH-53 loses its last six force points on the lethal bullet,
    /// several frames before it hits the ground. Drive the actual hit and crash paths.
    private func validateLastHelicopter(_ game: Game) throws {
        defer { game.restart() }
        game.restart(level: 10)
        for _ in 0..<55 { game.simulationTick() }
        guard let mission = game.campaign, let heli = game.enemies.first(where: { $0.type == "CH53" && !$0.node.isHidden }),
              let objects = game.levelDefinition?["objects"] as? [[String: Any]] else {
            throw NSError(domain: "MissingCH53", code: 11)
        }
        for i in objects.indices where i != heli.sourceIndex {
            mission.resolveForce(sourceIndex: i, amount: mission.forceRemaining(sourceIndex: i))
        }
        let p = heli.node.position
        let sweep = OriginalProjectileSweep(kind: .ballistic(.machineGun), start: p, end: p)
        while heli.hp > 0 {
            let previous = heli.hp
            game.applySharedObjectHit(.init(fraction: 1, target: heli.node, originalPart: 1), sweep: sweep, enemy: heli)
            try CampaignRuntimeValidation.require(heli.hp < previous, "Lethal CH-53 fixture must take bullet damage")
        }
        try CampaignRuntimeValidation.require(mission.remainingForce == 0 && heli.node.parent != nil, "A loaded CH-53 falls after its force is removed")
        game.simulationTick()
        try CampaignRuntimeValidation.require(game.isPlayingVictoryEffects && !game.isShowingVictoryChoice && !game.acceptsBattleInput, "No menu over the falling helicopter")
        let health = game.combat.health, score = game.combat.score, waves = mission.activeTicks
        var sawImpact = false, sawDebris = false
        for _ in 0..<1200 where game.isPlayingVictoryEffects {
            game.simulationTick()
            sawImpact = sawImpact || game.effects.snapshots.contains { [.groundExplosion, .explosion].contains($0.token.kind) }
            sawDebris = sawDebris || game.fragments.hasMovingDebris
        }
        try CampaignRuntimeValidation.require(sawImpact && sawDebris && heli.node.parent == nil &&
            !game.hasPendingVictoryEffects && game.pendingNextLevel == 12 && game.isShowingVictoryChoice,
            "CH-53 must crash, explode and finish throwing debris before showing the next mission")
        try CampaignRuntimeValidation.require(game.combat.health == health && game.combat.score == score && mission.activeTicks == waves,
            "Playing the crash must not restart combat or alter its outcome")
        print("PASS: final CH-53 falls, explodes and settles before the victory menu")
    }

    private func validateMissionEquipment(_ game: Game) throws {
        defer { game.restart() }
        let coast = game.version == .beach2000
        for number in coast ? [1, 11, 60] : [1, 9, 21, 25, 38] {
            game.restart(level: number - 1)
            guard let mission = game.levelDefinition, let rounds = mission["ammo"] as? [Int],
                  rounds.count == (coast ? 3 : 4) else {
                throw NSError(domain: "MissingMissionEquipment", code: number)
            }
            let flags = mission["flags"] as? [String] ?? []
            let ammo = OriginalAmmo(machineGun: rounds[0], cannon: rounds[1], missile: rounds[2],
                                    handgun: 15, flare: coast ? 0 : rounds[3])
            let pistol = !coast && ammo.machineGun == 0
            let support = coast ? mission["artillery"] as? Int == 1 : flags.contains("Bombers")
            let timer = coast ? mission["time"] as? Int : nil
            let context = "\(game.assets.gameID) mission \(number)"
            try CampaignRuntimeValidation.require(game.weapons.ammo == ammo && game.combat.health == 100 &&
                game.weapons.selected == (pistol ? .handgun : .machineGun), "Authored weapon loadout for " + context)
            try CampaignRuntimeValidation.require(game.hud.weaponSight == (pistol ? "handgun" : "machineGun") &&
                game.hud.weaponAmmo == (pistol ? 15 : ammo.machineGun) && game.hud.missileAmmo == ammo.missile &&
                game.hud.flareAmmo == ammo.flare && game.hud.remainingTime == timer &&
                game.hud.supportCount == (support ? 1 : 0), "Battle HUD at entry to " + context)
            game.requestSupport()
            if coast {
                try CampaignRuntimeValidation.require((game.barrage != nil) == support, "Ground barrage for " + context)
            } else if support {
                try CampaignRuntimeValidation.require(game.bombers.filter(\.active).count == 9, "Nine-bomber support for " + context)
            }
            try CampaignRuntimeValidation.require(!game.weapons.supportAvailable, "Single support allotment for " + context)
        }
    }

    private func validateDepthlinePresentation(_ current: Game) throws -> [[String:Any]] {
        func check(_ ok: @autoclosure () -> Bool, _ detail: String) throws {
            if !ok() {throw NSError(domain:"DepthlinePresentation",code:1,userInfo:[NSLocalizedDescriptionKey:detail])}
        }
        func near(_ a: Double, _ b: Double, tolerance: Double = 0.0001) -> Bool {abs(a-b)<tolerance}
        let originalSize=current.view.frame.size, originalAngles=current.camera.eulerAngles
        defer {
            current.camera.eulerAngles=originalAngles
            current.view.setFrameSize(originalSize)
            current.updateHUD()
        }
        guard let camera=current.camera.camera else {throw NSError(domain:"DepthlinePresentation",code:2)}
        var projectionSamples: [[String:Any]] = []
        let renderer = SCNRenderer(device: current.view.device, options: nil)
        renderer.scene = current.scene
        renderer.pointOfView = current.camera
        let marker = SCNNode(geometry: SCNSphere(radius: 0.009))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.magenta
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        marker.geometry?.materials = [material]
        marker.renderingOrder = 5000
        marker.castsShadow = false
        // The marker is fixed in the world on the actual forward firing ray.
        // projectPoint uses the last presented camera, so render the changed
        // pose before comparing it with the model or reading the HUD.
        marker.position = current.camera.convertPosition(SCNVector3(0,0,-1.5),to:nil)
        current.scene.rootNode.addChildNode(marker)
        defer { marker.removeFromParentNode() }
        for size in [NSSize(width:1600,height:900),NSSize(width:1600,height:1000)] {
            current.view.setFrameSize(size)
            current.updateHUD()
            let projection=camera.projectionTransform
            let horizontalDegrees=2*atan(1/Double(projection.m11))*180 / Double.pi
            try check(near(horizontalDegrees,64),"Depthline horizontal FOV is 64 degrees")
            try check(near(Double(projection.m22/projection.m11),Double(size.width/size.height)),"Projection uses the current viewport aspect")
            SCNTransaction.flush()
            let windowFrame = current.view.snapshot()
            let projected = current.view.projectPoint(marker.position)
            let port = current.view.currentViewport
            let projectedFraction = CGPoint(x:(projected.x-port.minX)/port.width,
                                            y:1-(projected.y-port.minY)/port.height)
            let hudFraction = CGPoint(x:0.5,y:current.hud.sightVerticalFraction)
            let windowSample = try measureAimMarker(windowFrame, near:hudFraction)
            let offscreenFrame = renderer.snapshot(atTime:current.elapsed,with:size,antialiasingMode:.none)
            let captureSample = try measureAimMarker(offscreenFrame, near:hudFraction)
            try check(near(Double(hudFraction.y),0.55),"HUD requests 55 percent from the top")
            try check(abs(projectedFraction.x-hudFraction.x)*port.width <= 1 &&
                      abs(projectedFraction.y-hudFraction.y)*port.height <= 1,
                      "Presented world point meets HUD: \(projectedFraction) versus \(hudFraction)")
            for sample in [windowSample,captureSample] {
                try check(abs(sample.center.x-hudFraction.x*sample.size.width) <= 1.25 &&
                          abs(sample.center.y-hudFraction.y*sample.size.height) <= 1.25,
                          "Rendered world marker meets HUD in backing pixels: \(sample)")
            }
            projectionSamples.append([
                "game":current.assets.gameID,"windowPoints":[size.width,size.height],
                "worldMarkerMetres":[marker.position.x,marker.position.y,marker.position.z],
                "sceneKitViewport":[port.minX,port.minY,port.width,port.height],
                "sceneKitProjectedBottomLeft":[projected.x,projected.y],
                "windowPixels":[windowSample.size.width,windowSample.size.height],
                "windowPixelCenterTopLeft":[windowSample.center.x,windowSample.center.y],
                "capturePixels":[captureSample.size.width,captureSample.size.height],
                "capturePixelCenterTopLeft":[captureSample.center.x,captureSample.center.y],
                "hudCenterTopLeftPoints":[hudFraction.x*size.width,hudFraction.y*size.height]
            ])
        }
        marker.removeFromParentNode()

        let root=current.scene.rootNode
        guard let bounce=root.childNode(withName:"DepthlineSkyBounce",recursively:false),
              let day=root.childNode(withName:"RemasteredSkyDay",recursively:false),
              let night=root.childNode(withName:"RemasteredSkyNight",recursively:false) else {
            throw NSError(domain:"DepthlinePresentation",code:3,userInfo:[NSLocalizedDescriptionKey:"World lighting and sky nodes exist"])
        }
        try check(current.sun.parent === root && bounce.parent === root,"Sun and sky bounce belong to the world")
        var cameraLights:[SCNNode]=[]
        current.camera.enumerateChildNodes {node,_ in if node.light != nil {cameraLights.append(node)}}
        try check(cameraLights.allSatisfy {$0 === current.spotlight},"Only the intentional night searchlight follows the camera")
        let fixedNodes=[current.sun,bounce,day,night]
        let fixedTransforms=fixedNodes.map(\.worldTransform)
        for degrees in [0.0,90.0,180.0,270.0] {
            let yaw=degrees * .pi / 180
            current.camera.eulerAngles=SCNVector3(0,yaw,0)
            current.syncGunPose()
            for (node,transform) in zip(fixedNodes,fixedTransforms) {
                try check(SCNMatrix4EqualToMatrix4(node.worldTransform,transform),"World light and sky transforms remain fixed while aiming")
            }
            let offset=current.depthlineGunOffset, position=current.gun.position
            let local=current.camera.convertVector(offset,from:nil)
            if current.usesOffsetTwinMount {
                try check(local.x < -0.5 && local.z < -1 && local.y < 0,"Feed side remains visible while traversing")
                let zero=current.camera.simdConvertPosition(.init(0,0,-80),to:nil)
                let along=current.gun.simdWorldPosition+current.gun.simdWorldFront*simd_distance(zero,current.gun.simdWorldPosition)
                try check(simd_distance(along,zero)<0.001,"Midpoint of twin bore axes crosses the HUD ray at the sight zero")
            } else {
                try check(local.x>0 && local.z < 0,"Support weapon stays on the feed-side sightline while traversing")
            }
            try check(near(Double(position.x),Double(offset.x)) && near(Double(position.y),8+Double(offset.y)) && near(Double(position.z),Double(offset.z)),"Gun world position is mount plus aim displacement")
        }

        var seen=Set<ObjectIdentifier>(), timed:[(SCNMaterial,String)]=[]
        root.enumerateChildNodes {node,_ in
            for material in node.geometry?.materials ?? [] where seen.insert(ObjectIdentifier(material)).inserted {
                if material.name == "HD:terrain" || material.name == "HD:water" {timed.append((material,"bhTime"))}
                if node === day || node === night {timed.append((material,"skyTime"))}
            }
        }
        try check(timed.filter {$0.1 == "skyTime"}.count==2,"Both skies receive simulation time")
        try check(timed.contains {$0.0.name == "HD:terrain"},"Terrain time material is installed")
        if current.assets.gameID == "2000" {try check(timed.contains {$0.0.name == "HD:water"},"Coast water time material is installed")}
        func clocks() throws -> [Double] {
            try timed.map {material,key in
                guard let value=material.value(forKey:key) as? NSNumber,value.doubleValue.isFinite else {
                    throw NSError(domain:"DepthlinePresentation",code:4,userInfo:[NSLocalizedDescriptionKey:"Initialized finite material clock: \(key)"])
                }
                return value.doubleValue
            }
        }
        current.updateHUD()
        let before=try clocks(), beforeElapsed=current.elapsed
        current.simulationTick();current.updateHUD()
        let advanced=try clocks()
        try check(current.elapsed>beforeElapsed && zip(before,advanced).allSatisfy {$0.1>$0.0},"Cloud and water clocks advance with production simulation")
        try check(advanced.allSatisfy {near($0,current.elapsed)},"Every material clock matches elapsed simulation time")
        current.togglePause()
        let frozenElapsed=current.elapsed, frozenTick=current.logicalTick
        for _ in 0..<3 {current.previousTime-=0.1;current.tick()}
        let frozen=try clocks()
        let pauseWasFrozen=current.elapsed==frozenElapsed && current.logicalTick==frozenTick && frozen==advanced
        current.togglePause()
        try check(pauseWasFrozen,"Pause freezes simulation, water and both cloud clocks")
        print("PASS: Depthline camera/HUD aspects, world lighting, rotating gun offset, cloud/water clocks and pause")
        return projectionSamples
    }

    /// Read actual sRGB raster pixels around the sight, independent of the
    /// projection API, backing scale or a window system's bottom-left origin.
    private func measureAimMarker(_ image: NSImage, near aim: CGPoint) throws -> (center: CGPoint, size: CGSize) {
        let error = NSError(domain:"DepthlinePresentation",code:5,
                            userInfo:[NSLocalizedDescriptionKey:"Cannot find the world marker beside the HUD sight in the rendered frame"])
        var rect = NSRect(origin:.zero,size:image.size)
        guard let full = image.cgImage(forProposedRect:&rect,context:nil,hints:nil) else { throw error }
        let crop = CGRect(x:floor(CGFloat(full.width)*aim.x)-20,y:floor(CGFloat(full.height)*aim.y)-20,
                          width:40,height:40)
        guard let patch = full.cropping(to:crop) else { throw error }
        var rgba = [UInt8](repeating:0,count:40*40*4)
        try rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data:bytes.baseAddress,width:40,height:40,bitsPerComponent:8,
                                          bytesPerRow:160,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                                          bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw error }
            context.draw(patch,in:CGRect(x:0,y:0,width:40,height:40))
        }
        var x:CGFloat=0,y:CGFloat=0,count:CGFloat=0
        for i in 0..<1600 {
            let r=Int(rgba[i*4]),g=Int(rgba[i*4+1]),b=Int(rgba[i*4+2])
            if r>100 && b>100 && r>3*g && b>3*g {
                x+=CGFloat(i%40)+0.5; y+=CGFloat(i/40)+0.5; count+=1
            }
        }
        guard count>=12 else { throw error }
        return (CGPoint(x:crop.minX+x/count,y:crop.minY+y/count), CGSize(width:full.width,height:full.height))
    }
}
