import AppKit
import SceneKit

// Recovered from BH2.exe: 30-unit sprite, scales 1.5 / 2.0,
// velocity 500 (machine gun) / 400 (cannon, pistol) units per update,
// vertical velocity decrement 0.16 per update. The enabled original limiter
// waits for >28 ms. Mapping that minimum to 29 ms is a port timing choice;
// the original's actual update rate remains machine dependent.
struct BulletFlight {
    static let referenceTick = 0.029
    let origin: SCNVector3
    let direction: SCNVector3
    let weapon: Int
    let maximumDistance: CGFloat
    var age: TimeInterval = 0
    var speedPerTick: CGFloat { weapon == 0 ? 5 : 4 }
    var size: CGFloat { weapon == 1 ? 0.6 : 0.45 }
    var lifetime: Double { Double(maximumDistance / speedPerTick) * Self.referenceTick }
    var alive: Bool { age < lifetime }
    var position: SCNVector3 {
        let ticks = CGFloat(age / Self.referenceTick)
        let complete = floor(ticks), fraction = ticks - complete
        // Original order: position += velocity, then velocity.y -= 0.16.
        let drop = 0.0016 * (complete * (complete - 1) / 2 + complete * fraction)
        return SCNVector3(origin.x + direction.x * speedPerTick * ticks,
                          origin.y + direction.y * speedPerTick * ticks - drop,
                          origin.z + direction.z * speedPerTick * ticks)
    }
    mutating func advance(_ dt: Double) { age = min(lifetime, age + max(0, dt)) }
}

final class BulletEffects {
    final class Shot {
        var flight: BulletFlight
        let node: SCNNode
        init(_ flight: BulletFlight, node: SCNNode) { self.flight = flight; self.node = node }
    }
    private(set) var shots: [Shot] = []
    let material: SCNMaterial
    init(textureURL: URL) {
        material = SCNMaterial()
        material.diffuse.contents = NSImage(contentsOf: textureURL)
        material.lightingModel = .constant
        // The source has black edges and uses engine mode 5. Additive blending
        // reproduces that glow; exact legacy mode-5 state mapping is unverified.
        material.blendMode = .add
        material.isDoubleSided = true
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        material.diffuse.wrapS = .clamp; material.diffuse.wrapT = .clamp
        material.diffuse.minificationFilter = .linear
        material.diffuse.magnificationFilter = .linear
    }
    func spawn(from: SCNVector3, to: SCNVector3, weapon: Int, parent: SCNNode) {
        let delta = SCNVector3(to.x - from.x, to.y - from.y, to.z - from.z)
        let distance = sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
        guard distance > 0.001 else { return }
        let direction = SCNVector3(delta.x / distance, delta.y / distance, delta.z / distance)
        let flight = BulletFlight(origin: from, direction: direction, weapon: weapon, maximumDistance: min(250, distance))
        // The original maintains separate rings of 80 tracer / 6 cannon sprites.
        let cannon = weapon == 1, capacity = cannon ? 6 : 80
        let samePool = shots.filter { ($0.flight.weapon == 1) == cannon }
        if samePool.count >= capacity, let oldest = samePool.first {
            oldest.node.removeFromParentNode(); shots.removeAll { $0 === oldest }
        }
        let plane = SCNPlane(width: flight.size, height: flight.size)
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.name = cannon ? "original-cannon-sprite" : "original-tracer-sprite"
        let facing = SCNBillboardConstraint(); facing.freeAxes = .all
        node.constraints = [facing]; node.position = from
        parent.addChildNode(node); shots.append(Shot(flight, node: node))
    }
    func update(_ dt: Double, paused: Bool, ground: ((CGFloat, CGFloat) -> CGFloat)? = nil) {
        guard !paused else { return }
        for shot in shots {
            shot.flight.advance(dt); shot.node.position = shot.flight.position
            if let ground = ground, shot.node.position.y < ground(shot.node.position.x, shot.node.position.z) {
                shot.flight.age = shot.flight.lifetime
            }
        }
        shots.removeAll { shot in
            if !shot.flight.alive { shot.node.removeFromParentNode(); return true }
            return false
        }
    }
    func clear() { shots.forEach { $0.node.removeFromParentNode() }; shots.removeAll() }
}

func testBulletFlight() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "BulletTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let start = SCNVector3(0, 8, 0), forward = SCNVector3(0, 0, -1)
    var a = BulletFlight(origin: start, direction: forward, weapon: 0, maximumDistance: 100)
    var b = a
    a.advance(0.29); for _ in 0..<29 { b.advance(0.01) }
    try check(abs(a.position.z + 50) < 0.0001 && abs(a.position.y - 7.928) < 0.0001, "source velocity and discrete gravity")
    try check(abs(a.position.z - b.position.z) < 0.0001 && abs(a.position.y - b.position.y) < 0.0001, "frame partition independent motion")
    print("PASS: recovered bullet speed/gravity and frame partition independent motion")
}

func testBulletEffects(textureURL: URL) throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "BulletTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let start = SCNVector3(0, 8, 0)
    let effects = BulletEffects(textureURL: textureURL), scene = SCNScene()
    effects.spawn(from: start, to: SCNVector3(0,8,-100), weapon: 0, parent: scene.rootNode)
    try check(effects.shots.first?.node.geometry is SCNPlane, "finite source sprite, not a line")
    effects.update(0.1, paused: false); let before = effects.shots[0].node.position
    effects.update(1, paused: true)
    try check(effects.shots.count == 1 && effects.shots[0].node.position.z == before.z, "pause freezes tracer simulation")
    let camera = SCNNode(); scene.rootNode.addChildNode(camera); camera.eulerAngles.y = 1
    try check(effects.shots[0].node.parent === scene.rootNode && effects.shots[0].node.worldPosition.z == before.z, "camera rotation cannot move world trajectory")
    effects.update(2, paused: false)
    try check(effects.shots.isEmpty, "expired projectiles removed")
    for _ in 0..<85 { effects.spawn(from: start, to: SCNVector3(0,8,-100), weapon: 0, parent: scene.rootNode) }
    for _ in 0..<9 { effects.spawn(from: start, to: SCNVector3(0,8,-100), weapon: 1, parent: scene.rootNode) }
    try check(effects.shots.count == 86, "original sprite pool capacities")
    effects.clear(); try check(effects.shots.isEmpty && scene.rootNode.childNodes.count == 1, "clear removes all projectile nodes")
    print("PASS: original bullet sprite, recovered speed/gravity, timestep independence, pause, world trajectory, expiry and 80/6 pools")
}
