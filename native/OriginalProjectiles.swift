import AppKit
import SceneKit

// Rendering/collision adapter for OriginalWeapons. Tick cadence and world scale
// belong to the host. No screen-space target selection and no launch-time damage.
// Source ballistics/guidance are recovered. GameSharedProjectiles owns the live
// collision pass, including swept shell contacts with Depthline actors/terrain.

enum OriginalProjectileKind: Equatable {
    case ballistic(OriginalWeapon)
    case missile(Int)

    var weapon: OriginalWeapon? { if case .ballistic(let weapon) = self { return weapon }; return nil }
    var missileSlot: Int? { if case .missile(let slot) = self { return slot }; return nil }
    var isCannon: Bool { weapon == .cannon }
}

struct OriginalProjectileSweep {
    let kind: OriginalProjectileKind
    let start: SCNVector3
    let end: SCNVector3

    func position(at fraction: CGFloat) -> SCNVector3 {
        SCNVector3(start.x + (end.x - start.x) * fraction,
                   start.y + (end.y - start.y) * fraction,
                   start.z + (end.z - start.z) * fraction)
    }
}

struct OriginalProjectileHit {
    let fraction: CGFloat
    let target: SCNNode?
    let originalPart: Int?
    var isGround = false
}

enum OriginalProjectileEvent {
    case impact(sweep: OriginalProjectileSweep, hit: OriginalProjectileHit)
    case missileEnded(slot: Int)
}

struct OriginalProjectileSnapshot {
    let kind: OriginalProjectileKind
    let position: SCNVector3
    let direction: SCNVector3
    let node: SCNNode
    let remainingMissileTicks: Int?
}

final class OriginalProjectiles {
    private final class Ballistic {
        let kind: OriginalProjectileKind
        let poolToken: OriginalProjectilePools.Token
        var state: OriginalBallisticState
        let node: SCNNode
        var previous: OriginalWeaponVector
        init(kind: OriginalProjectileKind, token: OriginalProjectilePools.Token, state: OriginalBallisticState, node: SCNNode) {
            self.poolToken = token; self.kind = kind; self.state = state; self.node = node; previous = state.position
        }
    }

    private final class Missile {
        let slot: Int
        let node: SCNNode
        var position: OriginalWeaponVector
        var previous: OriginalWeaponVector
        var forward: OriginalWeaponVector
        var pitchDegrees: Float
        var yawDegrees: Float
        var remainingTicks: Int
        let speedPerTick: Float
        init(launch: OriginalMissileLaunch, position: OriginalWeaponVector,
             forward: OriginalWeaponVector, node: SCNNode) {
            slot = launch.slot; self.position = position; previous = position
            self.forward = forward; self.node = node
            pitchDegrees = asin(max(-1, min(1, forward.y))) * 57.2957795
            yawDegrees = atan2(-forward.x, -forward.z) * 57.2957795
            remainingTicks = launch.lifeTicks; speedPerTick = launch.speedPerTick
        }
        func rebuildForward() {
            // Recovered I -> X -> Y matrix sequence, then negate third column:
            // 2000 0x416313/0x4163a8/0x416441; 2002 0x403ec6/0x404511/0x4045af.
            let p = pitchDegrees * Float(0.017453292), y = yawDegrees * Float(0.017453292)
            forward = .init(x: -cos(p) * sin(y), y: sin(p), z: -cos(p) * cos(y))
        }
    }

    let version: OriginalGameVersion
    let sourceToSceneScale: CGFloat
    let material: SCNMaterial
    private let parent: SCNNode
    private var bullets: [Int: Ballistic] = [:]
    private var shells: [Int: Ballistic] = [:]
    private var missiles: [Int: Missile] = [:]
    let sharedPools: OriginalProjectilePools

    // parent must be the untransformed scene root; physics stays in world space.
    init(version: OriginalGameVersion, textureURL: URL, parent: SCNNode,
         sourceToSceneScale: CGFloat = 0.01, sharedPools: OriginalProjectilePools? = nil) {
        precondition(sourceToSceneScale > 0 && sourceToSceneScale.isFinite)
        self.version = version; self.parent = parent; self.sourceToSceneScale = sourceToSceneScale
        self.sharedPools = sharedPools ?? OriginalProjectilePools(version: version)
        precondition(self.sharedPools.version == version)
        material = SCNMaterial()
        material.diffuse.contents = NSImage(contentsOf: textureURL)
        material.lightingModel = .constant; material.blendMode = .add
        material.isDoubleSided = true; material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        material.diffuse.wrapS = .clamp; material.diffuse.wrapT = .clamp
        material.diffuse.minificationFilter = .linear; material.diffuse.magnificationFilter = .linear
        // The exported original tracer's black edge is removed by additive blend.
        // Exact legacy render-mode state parity remains unconfirmed, as in BulletEffects.
    }

    var ballisticCount: Int { bullets.count + shells.count }
    var missileCount: Int { missiles.count }
    var snapshots: [OriginalProjectileSnapshot] {
        let rounds = (bullets.keys.sorted().compactMap { bullets[$0] } + shells.keys.sorted().compactMap { shells[$0] }).map {
            OriginalProjectileSnapshot(kind: $0.kind, position: scene($0.state.position),
                                       direction: directionScene($0.state.velocity.normalized ?? .init(x:0,y:0,z:-1)),
                                       node: $0.node, remainingMissileTicks: nil)
        }
        return rounds + missiles.keys.sorted().compactMap { missiles[$0] }.map {
            OriginalProjectileSnapshot(kind: .missile($0.slot), position: scene($0.position),
                                       direction: directionScene($0.forward), node: $0.node,
                                       remainingMissileTicks: $0.remainingTicks)
        }
    }

    private func source(_ value: SCNVector3) -> OriginalWeaponVector {
        .init(x: Float(value.x / sourceToSceneScale), y: Float(value.y / sourceToSceneScale),
              z: Float(value.z / sourceToSceneScale))
    }
    private func scene(_ value: OriginalWeaponVector) -> SCNVector3 {
        .init(CGFloat(value.x) * sourceToSceneScale, CGFloat(value.y) * sourceToSceneScale,
              CGFloat(value.z) * sourceToSceneScale)
    }
    private func directionSource(_ value: SCNVector3) -> OriginalWeaponVector? {
        OriginalWeaponVector(x: Float(value.x), y: Float(value.y), z: Float(value.z)).normalized
    }
    private func directionScene(_ value: OriginalWeaponVector) -> SCNVector3 {
        .init(CGFloat(value.x), CGFloat(value.y), CGFloat(value.z))
    }
    private func sprite(sourceSize: CGFloat, name: String) -> SCNNode {
        RemasteredBallisticVisual.make(size: sourceSize * sourceToSceneScale, name: name)
    }

    // No collision callback runs here. New rounds first move on the next step.
    @discardableResult
    func spawn(_ action: OriginalFireAction, from position: SCNVector3, direction: SCNVector3) -> Bool {
        guard let profile = action.ballistic, let unit = directionSource(direction),
              action.weapon != .flare else { return false }
        let kind = OriginalProjectileKind.ballistic(action.weapon)
        let node = sprite(sourceSize: kind.isCannon ? 60 : 45,
                          name: kind.isCannon ? "original-cannon-projectile" : "original-tracer-projectile")
        node.position = position; parent.addChildNode(node)
        let token = sharedPools.claim(profile.sharedBulletPool ? .bullet : .shell,
                                      writePointerWrap: profile.writePointerWrap) { [weak self] old in
            guard let self else { return }
            if old.bank == .bullet {
                self.bullets.removeValue(forKey: old.slot)?.node.removeFromParentNode()
            } else {
                self.shells.removeValue(forKey: old.slot)?.node.removeFromParentNode()
            }
        }
        let shot = Ballistic(kind: kind, token: token,
                             state: .init(position: source(position), unitDirection: unit, profile: profile), node: node)
        RemasteredBallisticVisual.orient(node,direction:SIMD3(unit.x,unit.y,unit.z))
        if profile.sharedBulletPool { bullets[token.slot] = shot }
        else { shells[token.slot] = shot }
        sharedPools.registerAdvance(token) { [weak self] in self?.advanceSharedRound(token) }
        return true
    }

    private func advanceSharedRound(_ token:OriginalProjectilePools.Token)->OriginalSharedBallisticSweep? {
        guard sharedPools.isCurrent(token),
              let shot=(token.bank == .bullet ? bullets:shells)[token.slot],shot.poolToken==token else {return nil}
        shot.previous=shot.state.position
        let segment=shot.state.step();shot.node.position=scene(segment.end)
        RemasteredBallisticVisual.orient(shot.node,direction:SIMD3(shot.state.velocity.x,shot.state.velocity.y,shot.state.velocity.z))
        func p(_ value:OriginalWeaponVector)->SIMD3<Double> {.init(Double(value.x),Double(value.y),Double(value.z))}
        return .init(weapon:shot.kind.weapon!,start:p(segment.start),end:p(segment.end))
    }

    // Supply the decoded Missile1/MISSILE model at its asset-export scale. A
    // tracer point is only a visible adapter fallback if no source mesh is supplied.
    @discardableResult
    func spawnMissile(_ launch: OriginalMissileLaunch, from position: SCNVector3,
                      direction: SCNVector3, model: SCNNode? = nil) -> Bool {
        guard (0..<2).contains(launch.slot), missiles[launch.slot] == nil,
              let unit = directionSource(direction) else { return false }
        let node = model ?? sprite(sourceSize: 45, name: "missile-mesh-missing-fallback")
        node.name = "original-missile-\(launch.slot)"; node.position = position
        let missile = Missile(launch: launch, position: source(position), forward: unit, node: node)
        orient(missile)
        parent.addChildNode(node); missiles[launch.slot] = missile
        return true
    }

    private func orient(_ missile: Missile) {
        // SceneKit's no-roll X/Y orientation shares the recovered source forward.
        missile.node.eulerAngles = SCNVector3(CGFloat(missile.pitchDegrees) * .pi / 180,
                                             CGFloat(missile.yawDegrees) * .pi / 180, 0)
    }

    // One ORIGINAL logical tick. All targets supplied for guidance use original
    // world units (not scene units) and their original object-slot IDs.
    func step(hitCandidates: (OriginalProjectileSweep) -> [OriginalProjectileHit],
              missileTargets: [OriginalMissileTarget] = [],
              ground: ((CGFloat, CGFloat) -> CGFloat)? = nil,
              onMissileTrail: ((SIMD3<Double>) -> Void)? = nil,
              includeBallistics:Bool = true,
              missileTargetProvider:(()->[OriginalMissileTarget])? = nil,
              resolveMissile:((OriginalProjectileSweep)->Bool)? = nil,
              onEvent:((OriginalProjectileEvent)->Void)? = nil) -> [OriginalProjectileEvent] {
        var events: [OriginalProjectileEvent] = []
        func emit(_ event:OriginalProjectileEvent) {events.append(event);onEvent?(event)}
        func advance(_ pool: inout [Int: Ballistic]) {
            for index in pool.keys.sorted() {
                guard let shot = pool[index] else { continue }
                shot.previous = shot.state.position
                let segment = shot.state.step()
                shot.node.position = scene(segment.end)
                RemasteredBallisticVisual.orient(shot.node,direction:SIMD3(shot.state.velocity.x,shot.state.velocity.y,shot.state.velocity.z))
                if segment.end.outsideOriginalProjectileBounds || (version == .beach2000 && shot.kind.isCannon && segment.end.y > 8000) {
                    sharedPools.release(shot.poolToken); shot.node.removeFromParentNode(); pool.removeValue(forKey: index); continue
                }
                let sweep = OriginalProjectileSweep(kind: shot.kind, start: scene(segment.start), end: scene(segment.end))
                if let hit = nearestHit(sweep, candidates: hitCandidates(sweep), ground: ground) {
                    sharedPools.release(shot.poolToken); shot.node.removeFromParentNode(); pool.removeValue(forKey: index)
                    emit(.impact(sweep: sweep, hit: hit))
                }
            }
        }
        if includeBallistics {advance(&bullets);advance(&shells)}
        for slot in missiles.keys.sorted() {
            guard let missile = missiles[slot] else { continue }
            missile.previous = missile.position
            // Original 2000 0x416a09:1823..1835 / 2002 0x4154b7:1525..1548
            // emits at the OLD position before guidance, flight and terminal
            // collision. Even the last flight tick contributes one smoke puff.
            onMissileTrail?(.init(Double(missile.position.x), Double(missile.position.y), Double(missile.position.z)))
            if let target = OriginalMissileGuidance.bestTarget(version: version, remainingTicks: missile.remainingTicks,
                position: missile.position, unitForward: missile.forward, candidates: missileTargetProvider?() ?? missileTargets),
               let targetDirection = (target.position - missile.position).normalized {
                let turn = OriginalMissileGuidance.turn(version: version, unitForward: missile.forward,
                                                        unitTargetDirection: targetDirection)
                missile.pitchDegrees += turn.pitchDegrees; missile.yawDegrees += turn.yawDegrees
                missile.rebuildForward(); orient(missile)
            }
            missile.position = missile.position + missile.forward * missile.speedPerTick
            missile.remainingTicks -= 1
            missile.node.position = scene(missile.position)
            var ended = missile.position.outsideOriginalProjectileBounds
            let sweep = OriginalProjectileSweep(kind: .missile(slot), start: scene(missile.previous), end: scene(missile.position))
            if let resolveMissile {ended=resolveMissile(sweep) || ended}
            else if !ended {
                if let hit = nearestHit(sweep, candidates: hitCandidates(sweep), ground: ground) {
                    emit(.impact(sweep: sweep, hit: hit)); ended = true
                }
            }
            if ended || missile.remainingTicks <= 0 {
                missile.node.removeFromParentNode(); missiles.removeValue(forKey: slot)
                emit(.missileEnded(slot: slot))
            }
        }
        return events
    }

    // Optional render interpolation, independent of simulation and collision. It
    // never changes physical state or feeds camera motion back into trajectories.
    func interpolate(alpha: CGFloat) {
        let a = Float(max(0, min(1, alpha)))
        for shot in Array(bullets.values) + Array(shells.values) {
            shot.node.position = scene(shot.previous + (shot.state.position - shot.previous) * a)
        }
        for missile in missiles.values {
            missile.node.position = scene(missile.previous + (missile.position - missile.previous) * a)
        }
    }

    // Returns active missile slots so a host retaining its weapon state can free
    // them. During level replacement the host can instead replace weapon state.
    @discardableResult
    func clear() -> [Int] {
        let slots = missiles.keys.sorted()
        for shot in Array(bullets.values) + Array(shells.values) {
            sharedPools.release(shot.poolToken); shot.node.removeFromParentNode()
        }
        missiles.values.forEach { $0.node.removeFromParentNode() }
        bullets.removeAll(); shells.removeAll(); missiles.removeAll()
        return slots
    }

    private func nearestHit(_ sweep: OriginalProjectileSweep, candidates: [OriginalProjectileHit],
                            ground: ((CGFloat, CGFloat) -> CGFloat)?) -> OriginalProjectileHit? {
        var valid = candidates.filter { $0.fraction.isFinite && (0...1).contains($0.fraction) }
        if let ground, let fraction = Self.terrainFraction(sweep: sweep, ground: ground) {
            valid.append(.init(fraction: fraction, target: nil, originalPart: nil, isGround: true))
        }
        // Keep caller order for exactly equal fractions. Geometry-part priority
        // can consequently be supplied without assuming original zone semantics.
        return valid.enumerated().min { lhs, rhs in
            lhs.element.fraction == rhs.element.fraction ? lhs.offset < rhs.offset : lhs.element.fraction < rhs.element.fraction
        }?.element
    }

    // Slab intersection for host fallback volumes; returns earliest segment t.
    // The caller can transform the segment into model-local space to use an OBB.
    static func segmentAABB(start: SCNVector3, end: SCNVector3,
                            minimum: SCNVector3, maximum: SCNVector3) -> CGFloat? {
        let starts = [start.x,start.y,start.z], ends = [end.x,end.y,end.z]
        let mins = [minimum.x,minimum.y,minimum.z], maxs = [maximum.x,maximum.y,maximum.z]
        var entry: CGFloat = 0, exit: CGFloat = 1
        for axis in 0..<3 {
            guard starts[axis].isFinite && ends[axis].isFinite && mins[axis].isFinite && maxs[axis].isFinite,
                  mins[axis] <= maxs[axis] else { return nil }
            let direction = ends[axis] - starts[axis]
            if abs(direction) < 1e-12 {
                if starts[axis] < mins[axis] || starts[axis] > maxs[axis] { return nil }
            } else {
                let first = (mins[axis] - starts[axis]) / direction
                let second = (maxs[axis] - starts[axis]) / direction
                entry = max(entry, min(first,second)); exit = min(exit, max(first,second))
                if entry > exit { return nil }
            }
        }
        return entry
    }

    static func terrainFraction(sweep: OriginalProjectileSweep,
                                ground: (CGFloat, CGFloat) -> CGFloat) -> CGFloat? {
        func clearance(_ t: CGFloat) -> CGFloat {
            let point = sweep.position(at: t)
            return point.y - ground(point.x, point.z)
        }
        if clearance(0) <= 0 { return 0 }
        // Port choice: half of the current scene's 0.2-unit heightmap grid spacing.
        // This detects an intervening ridge even when both segment ends are above
        // ground. The host may return its own exact terrain candidates instead.
        let horizontal = hypot(sweep.end.x - sweep.start.x, sweep.end.z - sweep.start.z)
        let samples = max(1, Int(ceil(horizontal / 0.1)))
        var previous: CGFloat = 0
        for sample in 1...samples {
            let t = CGFloat(sample) / CGFloat(samples)
            if clearance(t) <= 0 {
                var low = previous, high = t
                for _ in 0..<12 {
                    let middle = (low + high) * 0.5
                    if clearance(middle) > 0 { low = middle } else { high = middle }
                }
                return high
            }
            previous = t
        }
        return nil
    }
}

func testOriginalProjectiles(textureURL: URL) throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "OriginalProjectiles", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let scene = SCNScene()
    let effects = OriginalProjectiles(version: .beach2002, textureURL: textureURL, parent: scene.rootNode)
    let start = SCNVector3(0,10,0), forward = SCNVector3(0,0,-1)
    var weapons = OriginalWeaponState(version: .beach2002, machineGunAmmo: 100, cannonAmmo: 10, missileAmmo: 3)
    let action = weapons.step(triggerDown: true)!
    try check(effects.spawn(action, from: start, direction: forward) && effects.ballisticCount == 1, "spawn retains projectile without hitting immediately")
    try check(effects.snapshots[0].position.z == 0 && effects.snapshots[0].node.childNode(withName:"remastered-tracer-head",recursively:false)?.geometry is SCNPlane, "finite glowing point head at muzzle")
    var callbacks = 0
    let near = SCNNode(), far = SCNNode()
    let events = effects.step(hitCandidates: { sweep in
        callbacks += 1
        return [.init(fraction: 0.8, target: far, originalPart: nil),
                .init(fraction: 0.2, target: near, originalPart: 2),
                .init(fraction: -0.1, target: far, originalPart: nil)]
    })
    try check(callbacks == 1 && events.count == 1 && effects.ballisticCount == 0, "one swept query and one terminal impact")
    if case .impact(let sweep, let hit) = events[0] {
        try check(hit.target === near && hit.originalPart == 2 && sweep.kind.weapon == .machineGun &&
                  abs(sweep.position(at:hit.fraction).z + 1) < 0.0001, "nearest valid hit carries original firing weapon and hit part")
    } else { try check(false, "expected ordinary impact") }
    let aabb = OriginalProjectiles.segmentAABB(start: SCNVector3(0,0,0), end: SCNVector3(0,0,-10),
                                               minimum: SCNVector3(-1,-1,-6), maximum: SCNVector3(1,1,-4))
    try check(aabb != nil && abs(aabb! - 0.4) < 0.00001, "swept slab crosses thin target without tunneling")
    try check(OriginalProjectiles.segmentAABB(start: SCNVector3(2,0,0), end: SCNVector3(2,0,-10),
              minimum: SCNVector3(-1,-1,-6), maximum: SCNVector3(1,1,-4)) == nil, "parallel segment outside box misses")
    _ = effects.spawn(action, from: SCNVector3(0,1,0), direction: SCNVector3(0,-1,0))
    let terrain = effects.step(hitCandidates: { _ in [.init(fraction: 0.8, target: far, originalPart:nil)] }, ground: { _,_ in 0 })
    if case .impact(let sweep, let hit) = terrain[0] {
        try check(hit.isGround && abs(sweep.position(at:hit.fraction).y) < 0.002, "nearer terrain occludes farther target")
    } else { try check(false, "expected ground impact") }
    weapons.prepareMissileSlots()
    let left = weapons.requestMissile()!, right = weapons.requestMissile()!
    try check(effects.spawnMissile(left, from: start, direction: forward), "left visible missile")
    try check(effects.spawnMissile(right, from: start, direction: forward), "right visible missile")
    try check(!effects.spawnMissile(left, from: start, direction: forward) && effects.missileCount == 2, "two-slot occupancy enforced")
    let target = OriginalMissileTarget(originalObjectIndex: 0x75, position: .init(x: 200,y: 1200,z: -7000), active: true)
    var trail: [SIMD3<Double>] = []
    for _ in 0..<11 { _ = effects.step(hitCandidates: { _ in [] }, missileTargets: [target], onMissileTrail: { trail.append($0) }) }
    try check(trail.count == 22 && trail[0] == SIMD3(0, 1000, 0) && trail[1] == SIMD3(0, 1000, 0) &&
              trail[2] == SIMD3(0, 1000, -280), "each missile emits its source-unit trail before moving")
    try check(abs(effects.snapshots[0].direction.x) < 0.00001 && effects.snapshots[0].remainingMissileTicks == 119,
              "missile gate holds direction for first eleven updates")
    _ = effects.step(hitCandidates: { _ in [] }, missileTargets: [target])
    try check(effects.snapshots[0].direction.x > 0 && effects.snapshots[0].direction.y > 0,
              "recovered matrix turns missile toward eligible target")
    let missileEvents = effects.step(hitCandidates: { _ in [.init(fraction:0.5,target:near,originalPart:1)] }, onMissileTrail: { trail.append($0) })
    var endedSlots: [Int] = [], impacts = 0
    for event in missileEvents {
        switch event { case .missileEnded(let slot): endedSlots.append(slot); case .impact: impacts += 1 }
    }
    try check(endedSlots == [0,1] && impacts == 2 && effects.missileCount == 0, "missile impacts emit slot release exactly once")
    try check(trail.count == 24, "terminal missile tick retains its smoke emission")
    try check(effects.step(hitCandidates: { _ in [] }, onMissileTrail: { trail.append($0) }).isEmpty && trail.count == 24, "retired missiles never repeat hits or smoke")
    for _ in 0..<85 { _ = effects.spawn(action, from:start, direction:forward) }
    try check(effects.ballisticCount == 80, "80-entry shared source tracer ring")
    let before = effects.snapshots[0].position
    _ = effects.step(hitCandidates: { _ in [] })
    effects.interpolate(alpha:0.5)
    try check(abs(effects.snapshots[0].node.position.z - (before.z - 2.5)) < 0.0001 &&
              effects.snapshots[0].position.z == before.z - 5, "interpolation never changes physical position")
    effects.clear()
    try check(effects.ballisticCount == 0 && effects.missileCount == 0 && scene.rootNode.childNodes.isEmpty, "clear removes every owned node")
    let oldScene = SCNScene(), old = OriginalProjectiles(version: .beach2000, textureURL:textureURL,parent:oldScene.rootNode)
    var oldState = OriginalWeaponState(version:.beach2000,machineGunAmmo:200,cannonAmmo:8,missileAmmo:0)
    let oldAction = oldState.step(triggerDown:true)!
    for _ in 0..<81 { _ = old.spawn(oldAction,from:start,direction:forward) }
    try check(old.ballisticCount == 60, "2000 MG insertion wraps at 60")
    old.clear()
    let oldCannon = OriginalFireAction(weapon: .cannon, barrel: .center, variant: 0, recoilTicks: 0,
                                      ballistic: OriginalWeaponProfile(version: .beach2000).ballistic(.cannon))
    _ = old.spawn(oldCannon, from: SCNVector3(0,79,0), direction: SCNVector3(0,1,0))
    _ = old.step(hitCandidates: { _ in [] })
    try check(old.ballisticCount == 0, "2000 cannon upperY8000 differs from bullet10000")
    let shared = OriginalProjectilePools(version: .beach2002)
    let sharedScene = SCNScene()
    let sharedRenderer = OriginalProjectiles(version: .beach2002, textureURL: textureURL,
                                            parent: sharedScene.rootNode, sharedPools: shared)
    _ = sharedRenderer.spawn(action, from: start, direction: forward)
    for _ in 0..<80 { _ = shared.claim(.bullet) }
    try check(sharedRenderer.ballisticCount == 0 && sharedScene.rootNode.childNodes.isEmpty,
              "enemy allocation overwrites and removes player slot across renderers")
    var enemyRemoved = false
    let enemy = shared.claim(.shell, onEvict: { _ in enemyRemoved = true })
    let cannon = OriginalFireAction(weapon: .cannon, barrel: .center, variant: 0, recoilTicks: 0,
                                   ballistic: OriginalWeaponProfile(version: .beach2002).ballistic(.cannon))
    for _ in 0..<6 { _ = sharedRenderer.spawn(cannon, from: start, direction: forward) }
    try check(enemyRemoved && !shared.isCurrent(enemy), "player cannon overwrites enemy shared shell slot")
    sharedRenderer.clear()
    print("PASS: projectile travel before impact, nearest swept hit, terrain occlusion, finite sprites, original ring pools, visible two-slot missiles, guidance, slot release and render interpolation")
}
