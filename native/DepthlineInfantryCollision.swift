import SceneKit

/// The skin binds each triangle to one bone. Store its rest triangles once,
/// then transform the projectile segment into the current pose of each body part.
struct DepthlineInfantryBodyPart {
    let bone: Int
    let shape: OriginalCollision.Shape

    static func build(mesh: NativeDetailMesh, pivots: [SIMD3<Float>]) -> [Self] {
        // The final bone carries the rifle, whose barrel is outside the body.
        var parts = Array(repeating: [OriginalCollision.Polygon](), count: pivots.count - 1)
        for base in stride(from: 0, to: mesh.indices.count, by: 3) {
            let first = Int(mesh.indices[base]), bone = Int(mesh.boneIndices[first])
            guard parts.indices.contains(bone) else { continue }
            let points = (base..<(base + 3)).map { SIMD3<Double>(mesh.positions[Int(mesh.indices[$0])] - pivots[bone]) }
            guard let polygon = OriginalCollision.Polygon(part: bone, points: points) else { continue }
            parts[bone].append(polygon)
        }
        return parts.enumerated().compactMap { bone, polygons in
            OriginalCollision.Shape(polygons).map { Self(bone: bone, shape: $0) }
        }
    }
}

extension Game {
    func exposedToDepthlineShell(_ enemy: Enemy) -> Bool {
        guard enemy.type == "INFANTRY", !enemy.node.isHidden, enemy.deathMode == .none else { return false }
        if version == .beach2000 {
            // State 3 has cleared the landing craft's bow. States 62/63 are
            // troops already emerging from an APC or descending from a CH53.
            return (3...20).contains(enemy.aiState) || (26...37).contains(enemy.aiState) || (62...63).contains(enemy.aiState)
        }
        return (2..<42).contains(enemy.aiState)
    }

    func depthlineInfantryContact(_ sweep: OriginalProjectileSweep) -> OriginalProjectileHit? {
        let start = SIMD3<Float>(sweep.start), direction = SIMD3<Float>(sweep.end) - start
        let lengthSquared = simd_length_squared(direction)
        guard lengthSquared > 0 else { return nil }
        var closest: OriginalProjectileHit?
        let bullet = sweep.kind == .ballistic(.machineGun)
        for enemy in enemies {
            guard let actor = enemy.node as? RemasteredInfantryNode else { continue }
            if bullet {
                guard !actor.isHidden, enemy.aiState > 1 else { continue }
                if version == .beach2000, enemy.aiState >= 46 || (21...25).contains(enemy.aiState) { continue }
            } else if !exposedToDepthlineShell(enemy) { continue }
            // Cheap world-space rejection before testing the animated skin.
            let origin = actor.simdWorldPosition
            let t = max(0, min(1, simd_dot(origin - start, direction) / lengthSquared))
            let reach = 2.5 * simd_reduce_max(simd_abs(actor.simdScale))
            guard simd_distance_squared(start + direction * t, origin) <= reach * reach else { continue }
            for part in RemasteredInfantry.template.bodyParts {
                guard let hit = part.shape.hit(node: actor.bones[part.bone], start: sweep.start, end: sweep.end),
                      hit.fraction < (closest?.fraction ?? .infinity) else { continue }
                closest = .init(fraction: hit.fraction, target: actor, originalPart: part.bone)
            }
        }
        return closest
    }

    /// Resolve every player shell step in flight order. Cover can be crossed
    /// a full tick before the shell would reach an exposed soldier behind it.
    func resolveDepthlineInfantryShell(_ sweep: OriginalProjectileSweep) -> Bool {
        var contact = hitCandidates(sweep).min { $0.fraction < $1.fraction }
        let soldier = depthlineInfantryContact(sweep)
        if let soldier, soldier.fraction < (contact?.fraction ?? .infinity) { contact = soldier }
        let beforeContact = OriginalProjectileSweep(kind: sweep.kind, start: sweep.start,
                                                    end: sweep.position(at: contact?.fraction ?? 1))
        let waterAt = assets.waterContact
        if let t = OriginalProjectiles.terrainFraction(sweep: beforeContact, ground: { x, z in
            waterAt?(Double(x * 100), Double(z * 100)) == true ? 0 : self.assets.height(x: x, z: z)
        }) {
            let p = beforeContact.position(at: t)
            let position = SIMD3<Double>(p.x, p.y, p.z) * 100
            let water = waterAt?(position.x, position.z) ?? false
            let profile = OriginalDamage.splashProfile(version: version, weapon: .cannon)
            applyOriginalSharedTerrain(.init(kind: water ? .water : .ground, position: position,
                    infantryRadius: profile.map { Double($0.radius) }, horizontalOnly: profile?.horizontalOnly ?? false,
                    infantryCenter: position, includesEmbarkedInfantry: false), weapon: .cannon, exposedOnly: true)
            return true
        }
        guard let contact else { return false }
        if let soldier, contact.target === soldier.target {
            let point = beforeContact.end
            combat.hits += 1
            applySplash(at: point, weapon: .cannon, directTarget: contact.target)
            playOriginalGroundImpactSound(weapon: .cannon, at: SIMD3<Double>(point.x, point.y, point.z) * 100)
        } else {
            let enemy = enemies.first { $0.node === contact.target }
            applySharedObjectHit(contact, sweep: sweep, enemy: enemy)
        }
        return true
    }
}
