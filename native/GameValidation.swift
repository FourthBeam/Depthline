import AppKit
import SceneKit

/// Exercises the production Game simulation and scene adapters, rather than a
/// second implementation of the AI/scheduler. Health is restored before each
/// tick only to keep passive observation alive; no target is killed by the test.
/// This is bounded integration coverage, not proof of original-runtime parity
/// or player completion of these missions.
struct CampaignRuntimeValidation {
    struct Mission: Codable {
        let gameID: String
        let requestedLevel: Int
        let sourceLevel: Int
        let seed: UInt32
        let ticks: Int
        let lastLevel: Int
        let peakEnemyCount: Int
        let peakInfantryCount: Int
        let peakAirborneTroopers: Int
        let peakEnemyProjectiles: Int
        let peakEffects: Int
        let uniqueInfantryIDs: Int
        let highestInfantryID: Int?
        let movedEnemyTypes: [String]
        let visibleSupplyObserved: Bool
        let healthLossObserved: Bool
        let initialForce: Double
        let finalForce: Double
        let finalRNGState: UInt32
        let missingResourceExpected: Bool
    }
    struct Report: Encodable {
        let schemaVersion = 1
        let scope = "Real Game.simulationTick with fixed RNG seeds, original mission data, no player fire, health replenished before each tick; bounded native integration, not Windows parity or victory."
        let minimumTicks: Int
        let missions: [Mission]
        let cleanupPassed: Bool
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "CampaignRuntimeValidation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    static func finite(_ v: SCNVector3) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
    static func finite(_ v: SIMD3<Double>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

    static func run(_ game: Game, level: Int, ticks: Int) throws -> Mission {
        let id = game.assets.gameID
        let seed = UInt32(id)! &* 65_537 &+ UInt32(level)
        game.timer?.invalidate(); game.timer = nil
        game.view.rendersContinuously = false
        game.settings.soundEnabled = false
        game.random = Beach2000Supply.Random(seed: seed)
        game.originalClock = OriginalTickClock()
        game.restart(level: level - 1)
        let sourceLevel = OriginalCampaign.sourceLevel(gameID: id, level: level,
                                                       finite: game.assets.isDepthline)
        func check(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
            try require(condition(), "\(id) level \(level), tick \(game.logicalTick): \(detail)")
        }
        if game.assets.isDepthline ? level > game.assets.levels.count : (id == "2002" && level == 109) {
            try check(sourceLevel == (game.assets.isDepthline ? level : 100) && game.levelDefinition == nil, "no mission beyond the last file")
            try check(game.finished && !game.supplyMessage.isEmpty, "missing-resource path stops with a visible explanation")
            try check(game.campaign == nil && game.supply2000 == nil && game.supply2002 == nil && game.bombers.isEmpty,
                      "missing-resource path must not retain the previous mission's AI or supply state")
            try check(game.enemies.isEmpty && game.supplyNodes.isEmpty && game.flareNodes.isEmpty,
                      "missing-resource path clears previous mission nodes")
            try check(game.projectiles.ballisticCount == 0 && game.projectiles.missileCount == 0 && game.enemyOrdnance.rounds.isEmpty,
                      "missing-resource path clears flight state")
            return Mission(gameID: id, requestedLevel: level, sourceLevel: sourceLevel, seed: seed, ticks: 0,
                           lastLevel: game.level + 1, peakEnemyCount: 0, peakInfantryCount: 0, peakAirborneTroopers: 0,
                           peakEnemyProjectiles: 0, peakEffects: 0, uniqueInfantryIDs: 0, highestInfantryID: nil,
                           movedEnemyTypes: [], visibleSupplyObserved: false, healthLossObserved: false,
                           initialForce: 0, finalForce: 0, finalRNGState: game.random.state, missingResourceExpected: true)
        }
        try check(!game.finished && game.campaign != nil && game.levelDefinition != nil, "authored mission loads")
        try check((game.levelDefinition?["number"] as? Int) == sourceLevel, "production loader uses recovered loop mapping")
        let initialForce = game.campaign!.initialForce
        try check(initialForce > 0 && initialForce.isFinite, "authored initial force is positive and finite")
        var peakEnemies = 0, peakInfantry = 0, peakAirborne = 0, peakRounds = 0, peakEffects = 0
        var seenInfantry = Set<Int>(), movedTypes = Set<String>()
        var previousPositions: [String: SCNVector3] = [:]
        var previousCampaign = game.campaign
        var previousForce = initialForce
        var sawSupply = false, sawDamage = false
        for tick in 0..<ticks {
            try autoreleasepool {
                game.combat.health = 100
                game.simulationTick()
                sawDamage = sawDamage || game.combat.health < 100
                try check(!game.finished, "passive health-maintained simulation unexpectedly ended")
                try check(game.elapsed.isFinite && finite(game.camera.position) && finite(game.gun.eulerAngles), "finite camera/time")
                guard let campaign = game.campaign else { try check(false, "campaign disappeared during an authored mission"); return }
                try check(campaign.remainingForce.isFinite && campaign.remainingForce >= 0 && campaign.remainingForce <= campaign.initialForce,
                          "force remains within authored bounds")
                if campaign === previousCampaign { try check(campaign.remainingForce <= previousForce, "force cannot grow after cargo unload") }
                previousCampaign = campaign; previousForce = campaign.remainingForce
                try check(campaign.pendingSpawnCount >= 0, "pending activation count stays nonnegative")
                let infantry = game.enemies.filter { $0.type == "INFANTRY" }
                let airborne = game.supply2002?.airborneTroopers.filter(\.visible) ?? []
                let soldierIDs = infantry.compactMap { game.originalObjectIndex($0) }
                let allSoldierIDs = soldierIDs + airborne.map(\.objectID)
                try check(Set(allSoldierIDs).count == allSoldierIDs.count, "ground and airborne infantry must not share a live object ID")
                if id == "2002" {
                    try check(allSoldierIDs.allSatisfy(Beach2002Supply.isTrooperID), "infantry allocation must not overlap supply boxes or child meshes")
                    seenInfantry.formUnion(allSoldierIDs)
                } else { seenInfantry.formUnion(soldierIDs) }
                try check(Set(game.enemies.map { ObjectIdentifier($0.node) }).count == game.enemies.count, "enemies cannot share a scene root")
                for enemy in game.enemies {
                    try check(finite(enemy.node.position) && finite(enemy.node.eulerAngles), "finite \(enemy.type) pose, source \(enemy.sourceIndex), slot \(enemy.slot)")
                    try check(enemy.node.parent != nil, "tracked enemy remains attached to scene")
                    if let previous = previousPositions[enemy.id] {
                        let p = enemy.node.position
                        if abs(p.x - previous.x) + abs(p.y - previous.y) + abs(p.z - previous.z) > 0.00001 { movedTypes.insert(enemy.type) }
                    }
                    previousPositions[enemy.id] = enemy.node.position
                }
                for node in game.supplyNodes.values { try check(finite(node.worldPosition), "finite supply pose") }
                for shot in game.projectiles.snapshots { try check(finite(shot.position) && finite(shot.direction), "finite player projectile") }
                for round in game.enemyOrdnance.rounds {
                    try check(finite(round.state.position) && finite(round.state.velocity), "finite enemy \(round.state.kind.rawValue)")
                    try check(round.node.parent != nil, "live enemy ordnance remains attached")
                }
                try check(Set(game.enemyOrdnance.rounds.map(\.key)).count == game.enemyOrdnance.rounds.count, "enemy projectile pool slot is unique")
                for effect in game.effects.snapshots { try check(finite(effect.node.position) && finite(effect.node.scale), "finite original visual effect") }
                peakEnemies = max(peakEnemies, game.enemies.count); peakInfantry = max(peakInfantry, infantry.count)
                peakAirborne = max(peakAirborne, airborne.count); peakRounds = max(peakRounds, game.enemyOrdnance.rounds.count)
                peakEffects = max(peakEffects, game.effects.activeCount)
                sawSupply = sawSupply || (game.supply2000?.plane.visible ?? false) || (game.supply2002?.planes.contains(where: \.visible) ?? false)
                if tick == ticks / 2 {
                    let before = game.logicalTick
                    let rounds = game.enemyOrdnance.rounds.map { $0.state.position }
                    let effectCounters = game.effects.snapshots.map { $0.state.counter }
                    game.togglePause(); game.tick()
                    try check(game.logicalTick == before && game.enemyOrdnance.rounds.map({ $0.state.position }) == rounds && game.effects.snapshots.map({ $0.state.counter }) == effectCounters,
                              "pause freezes the production tick, ordnance and effect clocks")
                    game.togglePause()
                }
            }
        }
        try check(!movedTypes.isEmpty, "at least one authored enemy moves during the observation window")
        if id == "2002" && level == 1 { try check(!sawSupply, "level 1 does not invent a C130") }
        if id == "2000" && level == 1 { try check(sawSupply, "implicit level-1 C130 enters the production simulation") }
        return Mission(gameID: id, requestedLevel: level, sourceLevel: sourceLevel, seed: seed, ticks: ticks,
                       lastLevel: game.level + 1, peakEnemyCount: peakEnemies, peakInfantryCount: peakInfantry,
                       peakAirborneTroopers: peakAirborne, peakEnemyProjectiles: peakRounds, peakEffects: peakEffects,
                       uniqueInfantryIDs: seenInfantry.count, highestInfantryID: seenInfantry.max(), movedEnemyTypes: movedTypes.sorted(),
                       visibleSupplyObserved: sawSupply, healthLossObserved: sawDamage, initialForce: initialForce,
                       finalForce: game.campaign?.remainingForce ?? 0, finalRNGState: game.random.state, missingResourceExpected: false)
    }
}

extension AppDelegate {
    /// Call after creating the real application window on the main thread.
    /// --campaign-ticks may increase (never reduce) the default 1000 ticks.
    /// --campaign-report <path> writes a reviewable JSON result on success.
    /// --campaign-game 2002 and --campaign-levels 65,96 restrict repeat runs.
    /// --campaign-complete-delays runs through each selected mission's last
    /// authored delay plus 1000 ticks; it does not claim every cargo has landed.
    func runCampaignValidation() throws {
        var ticks = 1000
        if let i = arguments.firstIndex(of: "--campaign-ticks"), i + 1 < arguments.count,
           let requested = Int(arguments[i + 1]) { ticks = max(1000, requested) }
        var results: [CampaignRuntimeValidation.Mission] = []
        defer { game?.stop() }
        let selectedID: String? = {
            guard let i = arguments.firstIndex(of: "--campaign-game"), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }()
        let selectedLevels: Set<Int>? = {
            guard let i = arguments.firstIndex(of: "--campaign-levels"), i + 1 < arguments.count else { return nil }
            return Set(arguments[i + 1].split(separator: ",").compactMap { Int($0) })
        }()
        for id in ["2000", "2002"] where selectedID == nil || selectedID == id {
            try startGame(id)
            guard let current = game else { throw NSError(domain: "CampaignRuntimeValidation", code: 2) }
            // Validation never persists a campaign reached by its health fixture.
            current.onCheckpoint = nil; current.onRunEnded = nil; current.onSettingsChanged = nil
            let levels: [Int]
            if let selectedLevels { levels = selectedLevels.sorted() }
            else if arguments.contains("--campaign-all-levels") {
                var authored = Set(current.assets.levels.compactMap { $0["number"] as? Int }.filter { $0 > 0 })
                if arguments.contains("--campaign-include-boundaries") {
                    authored.formUnion(id == "2000" ? [61, 69, 70] : [100, 108, 109])
                }
                levels = authored.sorted()
            } else { levels = id == "2000" ? [1, 24, 30, 60, 61] : [1, 6, 32, 61, 65, 79, 86, 96, 99, 100, 109] }
            for level in levels {
                var missionTicks = ticks
                if arguments.contains("--campaign-complete-delays") {
                    let sourceLevel = OriginalCampaign.sourceLevel(gameID: id, level: level,
                                                                   finite: current.assets.isDepthline)
                    let definition = current.assets.levels.first { $0["number"] as? Int == sourceLevel }
                    let objects = definition?["objects"] as? [[String: Any]] ?? []
                    let lastDelay = objects.compactMap { $0["delay"] as? Int }.max() ?? 0
                    missionTicks = max(ticks, lastDelay + 1000)
                }
                let result = try CampaignRuntimeValidation.run(current, level: level, ticks: missionTicks)
                results.append(result)
                print("PASS campaign \(id) level \(level) -> source \(result.sourceLevel): \(result.ticks) ticks, peak \(result.peakEnemyCount) enemies / \(result.peakInfantryCount) infantry / \(result.peakEnemyProjectiles) rounds; force \(result.initialForce)->\(result.finalForce)\(result.missingResourceExpected ? " (expected missing resource)" : "")")
                fflush(stdout)
            }
            let previousTimer = current.timer
            showLauncher()
            try CampaignRuntimeValidation.require(game == nil && previousTimer?.isValid != true && current.timer == nil && !current.view.mouseCapture.isCaptured,
                                                  "\(id) return to launcher releases timer and cursor")
            try CampaignRuntimeValidation.require(current.projectiles.ballisticCount == 0 && current.projectiles.missileCount == 0 && current.enemyOrdnance.rounds.isEmpty && current.effects.activeCount == 0,
                                                  "\(id) return to launcher clears projectiles and effects")
            try CampaignRuntimeValidation.require(!current.view.rendersContinuously, "\(id) stopped game no longer renders continuously")
        }
        let report = CampaignRuntimeValidation.Report(minimumTicks: ticks, missions: results, cleanupPassed: true)
        if let i = arguments.firstIndex(of: "--campaign-report"), i + 1 < arguments.count {
            let url = URL(fileURLWithPath: arguments[i + 1])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
            print("Campaign runtime report: \(url.path)")
        }
        try CampaignRuntimeValidation.require(!results.isEmpty, "campaign test filter matched no missions")
        print("PASS: \(results.filter { !$0.missingResourceExpected }.count) authored/looped missions, \(results.reduce(0) { $0 + $1.ticks }) production ticks, \(results.filter(\.missingResourceExpected).count) expected missing resource, pause and library cleanup")
    }
}

extension Game {
    /// Cross-module regression for ignition -> infantry AI -> force -> fire
    /// lifetime, including the unusual source-local airborne coordinate rule.
    func burningIntegrationTest() throws {
        guard assets.gameID == "2002" else { return }
        let savedCheckpoint = onCheckpoint, savedEnd = onRunEnded
        let savedSound = settings.soundEnabled
        onCheckpoint = nil; onRunEnded = nil; settings.soundEnabled = false
        defer {
            restart(); onCheckpoint = savedCheckpoint; onRunEnded = savedEnd
            settings.soundEnabled = savedSound
        }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            try CampaignRuntimeValidation.require(condition(), "2002 burning integration: \(message)")
        }
        func isolatedBattle() {
            restart()
            enemies.forEach { $0.node.removeFromParentNode() }; enemies = []
            supplyNodes.values.forEach { $0.removeFromParentNode() }; supplyNodes = [:]
            supply2002 = nil; bombers = []; pendingEnemyShots = []; pendingOrdnance = []
            campaign = OriginalCampaign(gameID: "2002", level: 1, definition: [
                "objects": [["type": "C130", "slot": 0, "troops1": 4]]
            ])
            _ = campaign?.takeInitialSpawns()
            random = Beach2000Supply.Random(seed: 0xB002)
        }
        isolatedBattle()
        let p = SIMD3<Double>(2000, 0, -2000)
        for (slot, state) in [(0, 17), (1, 30)] {
            let soldier = Enemy(node: assets.model("INFANTRY"), type: "INFANTRY", flying: false)
            soldier.slot = slot; soldier.sourceIndex = 0; soldier.force = 1; soldier.aiState = state
            soldier.node.position = SCNVector3(p.x * 0.01, p.y * 0.01, p.z * 0.01)
            soldier.infantryAI = Original2002InfantryAI(position: p, initialState: state)
            scene.rootNode.addChildNode(soldier.node); enemies.append(soldier)
        }
        let forceBefore = campaign!.remainingForce
        burning.request(sourceObjectID: 9999, position: p)
        consumeBurningPhase()
        try check(campaign!.remainingForce == forceBefore - 1, "prone soldier resolves force immediately; standing death is deferred")
        try check(enemies.count == 1 && enemies[0].infantryAI?.state == 56 && burningTokens.count == 1,
                  "standing soldier enters recovered burn animation with one attached flame")
        // A second nearby explosion cannot charge the removed prone soldier or
        // restart a soldier whose source state already entered the burn family.
        burning.request(sourceObjectID: 9999, position: p); consumeBurningPhase()
        try check(campaign!.remainingForce == forceBefore - 1 && burningTokens.count == 1, "repeat ignition has no extra immediate force debit")
        for _ in 0..<240 { combat.health = 100; simulationTick() }
        try check(campaign!.remainingForce == forceBefore - 2, "standing animation completion debits exactly once")
        try check(burningTokens.isEmpty && !effects.snapshots.contains { $0.token.kind == .fire }, "burn animation completion removes owned flame")
        for _ in 0..<30 { combat.health = 100; simulationTick() }
        try check(campaign!.remainingForce == forceBefore - 2, "expired burn does not debit force again")

        isolatedBattle()
        supply2002 = Beach2002Supply(declarations: [.init(sourceIndex: 0, slot: 0, troops1: 1)], direction: .north)
        for _ in 0..<1200 {
            updateSupply2002()
            if supply2002?.airborneTroopers.contains(where: \.visible) == true { break }
        }
        guard let payload = supply2002?.airborneTroopers.first(where: \.visible),
              let originalNode = supplyNodes[payload.objectID], let originalParent = originalNode.parent else {
            try check(false, "production C130 update must actually release an airborne infantry fixture"); return
        }
        let local = SIMD3<Double>(Double(payload.position.x), Double(payload.position.y), Double(payload.position.z))
        let airborneForce = campaign!.remainingForce
        burning.request(sourceObjectID: 9999, position: local); consumeBurningPhase()
        try check(supply2002?.airborneTroopers.isEmpty == true, "burn transfer retires supply-owned payload")
        try check(enemies.count == 1 && enemies[0].node === originalNode && enemies[0].node.parent === originalParent,
                  "airborne ignition transfers the original node once and retains its chute parent")
        try check(enemies[0].infantryAI?.state == 56 && campaign!.remainingForce == airborneForce,
                  "airborne state1 enters deferred burning without immediate force loss")
        var duplicate = false
        for _ in 0..<700 {
            combat.health = 100; simulationTick()
            duplicate = duplicate || enemies.filter { originalObjectIndex($0) == payload.objectID }.count > 1
        }
        try check(!duplicate && nextTrooperOrdinal == 1, "falling retired chute cannot spawn a second soldier")
        try check(campaign!.remainingForce == airborneForce - 1, "airborne burn resolves the original source force exactly once")
        try check(burningTokens.isEmpty && !effects.snapshots.contains { $0.token.kind == .fire }, "airborne burn leaves no fire node")

        // The save callback must preserve the score recorded at level start,
        // even when a cheat is toggled after earning points in that mission.
        restart(level: 5, score: 17)
        var checkpoint: (Int, Int)?
        onCheckpoint = { checkpoint = ($0, $1) }
        combat.score = 91; applyCheat(1)
        try check(checkpoint?.0 == 6 && checkpoint?.1 == 17 && usedCheats,
                  "cheat marker cannot turn mid-mission score into the restart checkpoint")
        print("PASS: standing/prone/airborne burn force ownership, original chute transfer, flame cleanup and cheat checkpoint score")
    }
}


extension Game {
    /// Uses the production phase coordinator and AI, not a second FSM. The
    /// source case7 APC payload is immediately visited in infantry case5.
    func aiPhaseIntegrationTest() throws {
        if assets.gameID == "2000" { try original2000CrashIntegrationTest(); return }
        guard assets.gameID == "2002" else { return }
        func check(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
            try CampaignRuntimeValidation.require(condition(), "AI phase integration: " + detail)
        }
        settings.soundEnabled = false
        random = Beach2000Supply.Random(seed: 2002)
        originalClock = OriginalTickClock()
        restart(level: 31)
        // Only update through the actual AI coordinator: shooting and enemy
        // ordnance must not destroy a carrier before the unload assertion.
        var observedSameTickCargo = false, observedLanding = false
        for _ in 0..<1800 {
            let oldIDs = Set(enemies.filter { $0.type == "INFANTRY" }.map { $0.slot })
            updateOriginal2002AI()
            for soldier in enemies where soldier.type == "INFANTRY" && !oldIDs.contains(soldier.slot) && !infantryLandedThisTick.contains(soldier.slot + 358) {
                try check(soldier.age == Self.logicalStep, "new APC/CH53 infantry must execute exactly once in its birth tick")
                observedSameTickCargo = true
            }
            for soldier in enemies where soldier.type == "INFANTRY" && infantryLandedThisTick.contains(soldier.slot + 358) {
                try check(soldier.infantryAI?.frameIndex == 230 && soldier.aiState == 2 && soldier.age == 0,
                          "chute landing executes case1 only, preserving frame230 until next tick")
                observedLanding = true
            }
            pendingEnemyEmitters.removeAll(); pendingBomberDrops.removeAll()
            pendingEnemyShots.removeAll(); pendingOrdnance.removeAll(); pendingGrenades.removeAll()
            for event in campaign?.tick() ?? [] { spawn(event) }
            consumeSupply2002Events(supply2002?.updateScheduler() ?? [])
            originalClock.advance()
            if observedSameTickCargo && observedLanding { break }
        }
        try check(observedSameTickCargo, "authored Level32 APC must unload within the observation bound")
        try check(observedLanding, "authored Level32 C130 must land infantry within the observation bound")
        // A newly produced grenade must be in flight before the old-flight pass.
        pendingOrdnance = [(.init(version: .beach2002, kind: .grenade, position: .init(500, 500, 500), velocity: .init(1, 1, 1)), "GRENADES", nil)]
        let previousRounds = enemyOrdnance.rounds.count
        flushPendingInfantryGrenades()
        try check(pendingOrdnance.isEmpty && enemyOrdnance.rounds.count == previousRounds + 1, "grenade is allocated during AI, before flight traversal")
        restart()
        print("PASS production AI phases: same-tick APC/CH53 cargo, landing case1 frame and grenade-before-flight allocation")
    }
}
