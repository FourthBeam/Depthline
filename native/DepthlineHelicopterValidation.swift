import SceneKit

extension Game {
    func validateDepthlineHelicopterFlight() throws -> [String: Any] {
        guard let terrain = flightTerrain else { throw NSError(domain:"MissingFlightTerrain",code:1) }
        try terrain.validate(in: scene, gameID: assets.gameID)
        var minimumPatrol = Double.infinity, minimumTransport = Double.infinity
        var farthest = 0.0, landingHeight = 0.0, leftArea = false, tickCount = 0
        func measure(_ p: SIMD3<Double>) -> Double {
            farthest = max(farthest, hypot(p.x,p.z) / 100)
            return (p.y - terrain.groundForFlight(p.x,p.z)) / 100
        }
        var generator = Beach2000Supply.Random(seed: 7919)
        func next() -> UInt32 { generator.next() }
        let ground: (Double,Double) -> Double = { [assets] x,z in Double(assets.pointHeight(x:x*0.01,z:z*0.01))*100 }

        if assets.gameID == "2000" {
            guard let patrol = aircraft2000, let carriers = original2000AI else {
                throw NSError(domain:"MissingCoastalAircraft",code:1)
            }
            patrol.activate(kind:.cobra,slot:0,sourceIndex:-1,random:next)
            carriers.activateHelicopter(slot:0,sourceIndex:-1)
            for _ in 0..<6000 {
                tickCount += 1
                _ = patrol.tick(terrainHeight:ground,random:next)
                minimumPatrol = min(minimumPatrol, measure(patrol.cobras[0].position))
                _ = carriers.tick(terrainHeight:ground,viewPitchDegrees:0,random:next,soundEnabled:false)
                let ch = carriers.helicopters[0]
                if !ch.visible { leftArea = true; break }
                let clearance = measure(ch.position)
                minimumTransport = min(minimumTransport, clearance)
                if ch.state == 11 { landingHeight = clearance }
            }
        } else {
            func spawnPilot(_ type: String) throws -> OriginalEnemyAI {
                spawn(.init(type:type,slot:0,sourceIndex:-1,cargoFamily:nil,direction:"North",force:0,generation:0))
                guard let pilot=enemies.last?.originalAI else { throw NSError(domain:"MissingHillsAircraft",code:1) }
                return pilot
            }
            let patrol = try spawnPilot("COBRA"), carrier = try spawnPilot("CH53")
            for _ in 0..<6000 {
                tickCount += 1
                let attack = patrol.tick(terrainHeight:ground,random:next)
                minimumPatrol = min(minimumPatrol, measure(attack.position))
                let transport = carrier.tick(terrainHeight:ground,terrainMaterial:assets.terrainMaterial,random:next)
                if !transport.isActive { leftArea = true; break }
                let clearance = measure(transport.position)
                minimumTransport = min(minimumTransport, clearance)
                if transport.events.contains(where: { if case .cargo(let troops) = $0 { return troops.count == 6 }; return false }) {
                    landingHeight = clearance
                }
            }
        }
        try CampaignRuntimeValidation.require(minimumPatrol > 9.45 && minimumTransport > 3.35,
            "Airframe clearance above rendered land: patrol \(minimumPatrol), transport \(minimumTransport), sector \(assets.gameID)")
        try CampaignRuntimeValidation.require(abs(landingHeight-3.38)<0.15 && leftArea && farthest>250,
            "Transport must land, unload and leave after a distant approach: \(landingHeight), \(leftArea), \(farthest), sector \(assets.gameID)")
        var report: [String: Any] = ["sector":assets.gameID,"ticks":tickCount,"minimumCobraClearanceMetres":minimumPatrol,
                "minimumTransportClearanceMetres":minimumTransport,"landingClearanceMetres":landingHeight,
                "farthestDistanceMetres":farthest,"transportDeparted":leftArea]
        if assets.gameID == "2002" {
            report["ridgeCrossings"] = try compareHillsApproaches(terrain:terrain)
        }
        restart()
        return report
    }

    /// Repeat the same production Cobra spawn on each compass approach. The
    /// reference pilot retains its original fixed-altitude patrol. Compare the
    /// two against the *same* rendered mountain triangles at the same X/Z.
    private func compareHillsApproaches(terrain: DepthlineFlightTerrain) throws -> [[String: Any]] {
        var routes: [[String: Any]] = [], worstOriginal = Double.infinity
        for heading in ["North","East","South","West"] {
            let reference = OriginalEnemyAI(type:"COBRA",slot:0,direction:heading,aggression:[])!
            let guided = OriginalEnemyAI(type:"COBRA",slot:0,direction:heading,aggression:[])!
            guided.helicopterAltitude = terrain.flightAltitude
            var rngA = OriginalEnemyAI.Random(seed:19), rngB = rngA
            var minimumOriginal = Double.infinity, minimumGuided = Double.infinity, maximumSurface = 0.0
            for _ in 0..<180 {
                let a = reference.tick(terrainHeight:terrain.groundForFlight,random:{rngA.next()}).position
                let b = guided.tick(terrainHeight:terrain.groundForFlight,random:{rngB.next()}).position
                guard hypot(a.x,a.z)>26500 else {continue}
                try CampaignRuntimeValidation.require(hypot(a.x-b.x,a.z-b.z)<1,
                    "Reference and terrain-following helicopter diverged horizontally")
                let top = terrain.groundForFlight(a.x,a.z)
                maximumSurface = max(maximumSurface, top/100)
                minimumOriginal = min(minimumOriginal, (a.y-top)/100)
                minimumGuided = min(minimumGuided, (b.y-top)/100)
            }
            worstOriginal = min(worstOriginal, minimumOriginal)
            try CampaignRuntimeValidation.require(minimumGuided > 9.45 && minimumGuided.isFinite, "Distant approach \(heading) crossed a summit")
            routes.append(["heading":heading,"peakMetres":maximumSurface,"originalMinimumClearanceMetres":minimumOriginal,
                           "correctedMinimumClearanceMetres":minimumGuided])
        }
        try CampaignRuntimeValidation.require(worstOriginal < -1, "Fixture must reproduce original flight into a rendered distant ridge")
        return routes
    }
}
