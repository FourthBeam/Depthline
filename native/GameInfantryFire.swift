import SceneKit

enum InfantryFireObstruction {
    case cover(DepthlineCover.Hit)
    case ground(SIMD3<Float>)

    var position: SIMD3<Float> {
        switch self {
        case .cover(let hit): return hit.position
        case .ground(let point): return point
        }
    }
}

extension Game {
    /// The AI emits muzzle coordinates in centimetres. Both attack resolution and
    /// the search for a firing position test the same line to the player's eye.
    func infantryFireObstruction(from origin: SIMD3<Double>) -> InfantryFireObstruction? {
        guard assets.isDepthline else { return nil }
        return infantryObstruction(from: SIMD3<Float>(origin * 0.01), to: camera.simdWorldPosition)
    }

    func infantryObstruction(from start: SIMD3<Float>, to end: SIMD3<Float>) -> InfantryFireObstruction? {
        let wall = emplacementCover?.firstHit(from: start, to: end)
        let segment = OriginalProjectileSweep(kind: .ballistic(.machineGun), start: SCNVector3(start),
                                              end: SCNVector3(wall?.position ?? end))
        if let fraction = OriginalProjectiles.terrainFraction(sweep: segment, ground: assets.height) {
            return .ground(SIMD3<Float>(segment.position(at: fraction)))
        }
        return wall.map(InfantryFireObstruction.cover)
    }

    func handleInfantryRifle(from origin: SIMD3<Double>, damage: Int, voice: Int?) {
        playSound("Rifle")
        effects.emit(.muzzleFlash, at: origin, scale: version == .beach2002 ? .init(repeating: 0.25) : nil)
        switch infantryFireObstruction(from: origin) {
        case .cover(let hit):
            showCoverImpact(hit)
        case .ground(let point):
            effects.emit(.dirtHit, at: SIMD3<Double>(point) * 100)
        case nil:
            guard damage > 0, !isPlayingVictoryEffects else { return }
            combat.health = max(0, combat.health - damage)
            if version == .beach2002 || voice != nil { playOriginalPlayerBulletHitSound(bucket: voice) }
        }
    }
}
