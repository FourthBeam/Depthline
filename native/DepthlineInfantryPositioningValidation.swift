import SceneKit

extension Game {
    func validateInfantryFiringPositions() throws -> [[String: Any]] {
        try validateCoverContacts()
        let coastal = version == .beach2000
        let sign: Double = coastal ? 1 : -1
        func check(_ ok: Bool, _ reason: String) throws {
            try CampaignRuntimeValidation.require(ok, "Infantry firing position \(assets.gameID): \(reason)")
        }
        func trial(at start: SIMD2<Double>, slot: Int, corner: Bool) throws -> [String: Any] {
            guard let field = infantryPositioningField else { throw NSError(domain: "MissingInfantryField", code: slot) }
            let foot = field.foot(at: start * sign)
            try check(!field.openShot(foot), "fixture must start behind hard cover")
            let coast = coastal ? Original2000EnemyAI.infantryPositioningFixture(slot: slot, at: foot) : nil
            let hills = coastal ? nil : Original2002InfantryAI(position: foot, initialState: 38)
            var previous = foot, firing: SIMD3<Double>?, shots = 0, firstShot = 0
            var moved = 0.0
            var deepestZ = start.y
            for tick in 1...3200 {
                let point: SIMD3<Double>, muzzles: [SIMD3<Double>]
                if let coast {
                    let events = coast.tick(terrainHeight: field.ground, viewPitchDegrees: 0, random: { 0 }, infantryField: field)
                    point = coast.soldiers[slot].position
                    muzzles = events.compactMap { if case .rifleFlash(_, _, let origin, _, _) = $0 { return origin }; return nil }
                } else if let hills {
                    let update = hills.tick(terrainHeight: field.ground, random: { 0 }, infantryField: field, slot: slot)
                    point = update.position
                    muzzles = update.events.compactMap { if case .rifleFlash(let origin, _) = $0 { return origin }; return nil }
                } else { preconditionFailure() }
                let before = SIMD2(previous.x, previous.z), after = SIMD2(point.x, point.z)
                deepestZ = min(deepestZ, point.z * sign)
                if corner, abs(point.x) > 130 {
                    try check(deepestZ < -1395, "trooper left the passage before clearing the end of its side walls")
                }
                let step = simd_distance(before, after)
                if step > 0.001 {
                    try check(step <= 4.001 && field.canWalk(before, after),
                              "trooper crossed cover or jumped at tick \(tick), \(before) → \(after), length \(step)")
                    moved += step
                }
                if let firing { try check(simd_distance(point, firing) < 0.01, "trooper abandoned an open firing position") }
                for muzzle in muzzles {
                    try check(infantryFireObstruction(from: muzzle) == nil && field.openShot(point), "fired from a blind corner")
                    if firing == nil { firing = point; firstShot = tick }
                    shots += 1
                }
                previous = point
                if shots >= 2 && tick - firstShot >= 150 { break }
            }
            try check(shots >= 2 && moved > 75 && firing != nil, "trooper never resumed sustained fire")
            let post = SIMD2(previous.x, previous.z)
            if corner {
                try check(deepestZ < -1395 && !field.canWalk(start * sign, post) && moved > simd_distance(start * sign, post) + 45,
                          "the dogleg must force a walk around a solid corner")
            }
            return ["slot": slot, "dogleg": corner, "distanceWalkedM": moved / 100,
                    "postM": [post.x / 100, post.y / 100], "deepestLocalZM": deepestZ / 100,
                    "firstShotTick": firstShot, "shots": shots]
        }

        var samples = [try trial(at: .init(500, 130), slot: 3, corner: false)]
        // The real side wall above tests the stage itself. Use a taller,
        // U-shaped obstacle to force a route with at least one actual turn.
        let saved = emplacementCover
        defer { emplacementCover = saved }
        let scene = SCNScene(), root = scene.rootNode
        let barrier = DepthlineCover(root: root)
        var mesh = NativeDetailMesh()
        let floor = Float(assets.height(x: 0, z: 0)), tint = SIMD3<Float>(repeating: 0.5)
        for (x, z, width, depth): (Float, Float, Float, Float) in [
            (0, -8.0, 7.0, 0.35), (-1.15, -10.9, 0.30, 6.1), (1.15, -10.9, 0.30, 6.1)
        ] {
            // The coast falls over a metre along this passage. Sink the
            // foundations beneath its lowest point while keeping the same top.
            mesh.box(center: SIMD3(x * Float(sign), floor, z * Float(sign)), size: SIMD3(width, 6.6, depth), color: tint)
        }
        barrier.register(mesh, as: .concrete)
        emplacementCover = barrier
        samples.append(try trial(at: .init(0, -920), slot: 6, corner: true))
        return samples
    }

    private func validateCoverContacts() throws {
        let root = SCNNode()
        root.simdPosition = SIMD3(3, 4, -2)
        root.eulerAngles.y = version == .beach2000 ? 0 : .pi
        let cover = DepthlineCover(root: root)
        for (offset, surface): (Float, DepthlineCover.Surface) in [(0.5, .sandbag), (0, .metal)] {
            var mesh = NativeDetailMesh()
            mesh.triangle(.init(-1, -1, offset), .init(1, -1, offset), .init(0, 1, offset), color: .one)
            // Smooth lighting normals are deliberately different from the physical face normal.
            mesh.normals = Array(repeating: SIMD3(0, 1, 0), count: 3)
            cover.register(mesh, as: surface)
        }
        for (start, end, expectedZ, surface): (Float, Float, Float, DepthlineCover.Surface) in [
            (-1, 1, 0, .metal), (1, -1, 0.5, .sandbag), (0.25, -1, 0, .metal)
        ] {
            func world(_ z: Float) -> SIMD3<Float> { root.simdConvertPosition(.init(0, 0, z), to: nil) }
            let hit = cover.firstHit(from: world(start), to: world(end))
            let towardSource = simd_normalize(world(start) - world(end))
            let correct = hit.map {
                $0.surface == surface && simd_distance($0.position, world(expectedZ)) < 0.00001
                    && abs($0.fraction - (expectedZ - start) / (end - start)) < 0.00001
                    && simd_dot($0.normal, towardSource) > 0.99999
            } ?? false
            try CampaignRuntimeValidation.require(correct, "Nearest two-sided cover contact in world coordinates")
        }
        let edge = root.simdConvertPosition(.init(1.1, 0, 0), to: nil)
        try CampaignRuntimeValidation.require(
            cover.firstHit(from: edge - SIMD3(0, 0, 1), to: edge + SIMD3(0, 0, 1)) == nil,
            "Cover ray outside the triangles")
    }
}
