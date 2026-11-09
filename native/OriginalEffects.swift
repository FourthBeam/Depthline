import AppKit
import SceneKit

// Recovered texture streams, sprite templates and tick rules. See
// analysis/original-effects.json for source locations and renderer boundaries.
// All public positions, velocities and template sizes use ORIGINAL world units.
// There are no SCNActions: the host calls tick once, at the END of each original
// simulation tick (after impacts/emissions), and does not call it while paused.
enum OriginalEffectKind: String, CaseIterable, Hashable {
    case explosion, groundExplosion, waterSplash, impactFlash, muzzleFlash
    case dirtHit, blood, whiteSmoke, blackSmoke, smokeBurst, fire, missileFlame
}

struct OriginalBlastSmokeRecipe {
    let horizontalVelocityFactor:Double
    let upwardVelocityFactor:Double
    static func groundImpact(version:OriginalGameVersion)->Self {
        version == .beach2000 ? .init(horizontalVelocityFactor:0.003,upwardVelocityFactor:0.002)
            : .init(horizontalVelocityFactor:0.004,upwardVelocityFactor:0.003)
    }
    static let vehicle2000=Self(horizontalVelocityFactor:0.002,upwardVelocityFactor:0.002)
}

struct OriginalEffectProfile {
    let version: OriginalGameVersion
    let kind: OriginalEffectKind
    let sequence: String
    let frameCount: Int
    let poolCount: Int
    let templateSize: SIMD2<Double>
    let initialScale: SIMD2<Double>
    let bottomAnchored: Bool
    let yawOnly: Bool
    let lastCounter: Int
    let loops: Bool
    var staticSmoke: Bool { version == .beach2002 && isSmoke }
    var isSmoke: Bool { [.whiteSmoke, .blackSmoke, .smokeBurst].contains(kind) }
    var darkSmoke: Bool { kind == .blackSmoke || kind == .smokeBurst }

    static func recovered(_ kind: OriginalEffectKind, version: OriginalGameVersion) -> Self? {
        func make(_ sequence: String, _ frames: Int, _ pool: Int, _ width: Double,
                  _ height: Double, _ sx: Double = 1, _ sy: Double = 1,
                  bottom: Bool = false, yaw: Bool = false, last: Int? = nil,
                  loops: Bool = false) -> Self {
            .init(version: version, kind: kind, sequence: sequence, frameCount: frames,
                  poolCount: pool, templateSize: .init(width, height),
                  initialScale: .init(sx, sy), bottomAnchored: bottom, yawOnly: yaw,
                  lastCounter: last ?? frames - 1, loops: loops)
        }
        if version == .beach2000 {
            switch kind {
            case .explosion: return make("Explosion128x4096", 32, 8, 400, 400, 4, 4)
            case .groundExplosion: return make("ExplosionB128x1536", 12, 8, 400, 400, 1.5, 1.5, bottom: true, yaw: true)
            case .waterSplash: return make("WaterExplosion128x2560", 20, 8, 400, 400, 2.5, 3, bottom: true, yaw: true)
            case .impactFlash: return make("FlashExplosion128x2048", 16, 8, 200, 200, 2.5, 3, yaw: true)
            case .muzzleFlash: return make("FlashExplosion128x2048", 16, 8, 50, 50, last: 4)
            case .dirtHit: return make("DirtHit128x1536", 12, 8, 80, 100, 2, 2, bottom: true, yaw: true)
            case .blood: return make("Blood128x1280", 10, 4, 200, 200, 0.5, 0.5)
            case .whiteSmoke: return make("BlackSmoke64x5400", 60, 120, 100, 100)
            case .blackSmoke: return make("BlackSmoke64x5400", 60, 120, 100, 100, 4, 4)
            case .smokeBurst: return make("BlackSmoke64x5400", 60, 36, 400, 400)
            // The 2000 updater visits 16 fire slots, but init and all recovered
            // fire writers use 12. Keep the reachable writer pool here.
            case .fire: return make("Fire64x4560", 38, 12, 280, 360, bottom: true, yaw: true, last: 36, loops: true)
            case .missileFlame: return make("FlashExplosion128x2048", 16, 12, 50, 50, 2, 2, last: 3, loops: true)
            }
        }
        switch kind {
        case .explosion:
            // Init scale is 1. The aircraft fragmentation emitter 0x4232fa
            // explicitly sets 4; explosion requests represent that emitter.
            return make("ExplodeA128x4096", 32, 8, 400, 400, 4, 4)
        case .groundExplosion: return make("ExplodeVShape128x1536", 12, 8, 800, 800, bottom: true)
        case .waterSplash: return nil // No corresponding 2002 resource/rule found.
        case .impactFlash: return make("ExplodeF128x2048", 16, 8, 200, 200)
        case .muzzleFlash: return make("ExplodeF128x2048", 16, 8, 200, 200, 0.25, 0.25, last: 4)
        case .dirtHit: return make("DirtHit64x640", 10, 8, 80, 100, 2, 2, bottom: true)
        case .blood: return make("Blood64x640", 10, 4, 200, 200, 0.5, 0.5)
        case .whiteSmoke: return make("SmokeW64x64", 1, 120, 200, 200, last: 59)
        case .blackSmoke: return make("SmokeW64x64", 1, 120, 400, 400, last: 59)
        case .smokeBurst: return make("SmokeW64x64", 1, 36, 400, 400, last: 50)
        case .fire: return make("Fire64x2432", 38, 12, 280, 360, bottom: true, yaw: true, loops: true)
        case .missileFlame: return make("ExplodeF128x2048", 16, 16, 200, 200, last: 4, loops: true)
        }
    }

    func relativeTexturePath(frame: Int) -> String {
        if staticSmoke { return "textures/\(sequence).png" }
        // Smoke uses the source intensity as a mask; original indexed darken /
        // lighten modes cannot be reconstructed by sampling palette RGB alone.
        let suffix = isSmoke ? ".png" : ".keyed.png"
        return "frames/\(sequence)/" + String(format: "%03d", frame) + suffix
    }
}

struct OriginalEffectState {
    let profile: OriginalEffectProfile
    var position: SIMD3<Double>
    var velocity: SIMD3<Double>
    var scale: SIMD2<Double>
    var opacity: Double
    private(set) var counter = 0
    private(set) var displayFrame = 0
    private(set) var active = true

    init(profile: OriginalEffectProfile, position: SIMD3<Double>,
         scale: SIMD2<Double>? = nil, velocity: SIMD3<Double> = .zero,
         opacity: Double = 1, initialFrame: Int = 0) {
        self.profile = profile; self.position = position; self.velocity = velocity
        self.scale = scale ?? profile.initialScale; self.opacity = opacity
        counter = max(0, min(profile.staticSmoke ? profile.lastCounter + 1 : profile.frameCount - 1, initialFrame))
        displayFrame = profile.staticSmoke ? 0 : counter
    }

    mutating func resetCounter(_ value: Int) { counter = value }

    mutating func tick(parity: Int, night: Bool) {
        guard active else { return }
        if profile.kind == .smokeBurst {
            position += velocity + SIMD3(0, 3, 0)
            velocity *= SIMD3(0.75, 0.85, 0.75)
        } else if profile.kind == .whiteSmoke ||
                    (profile.kind == .blackSmoke && profile.version == .beach2000) {
            position.y -= 2
        }
        if profile.version == .beach2002 {
            switch profile.kind {
            // DAT_00462240 == 1 means Daytime (loader), not night.
            case .whiteSmoke: scale += SIMD2(repeating: 0.015); opacity -= night ? 0.004 : 0.016
            case .blackSmoke: scale += SIMD2(repeating: 0.015); opacity -= 0.016
            case .smokeBurst: opacity -= 0.02
            default: break
            }
        }
        displayFrame = profile.staticSmoke ? 0 : counter
        var increment = 1
        if profile.version == .beach2000 {
            if profile.kind == .muzzleFlash || (profile.kind == .impactFlash && scale.x == 1) { increment = 2 }
            if profile.kind == .waterSplash && parity & 1 != 0 { increment = 0 }
        }
        counter += increment
        // Source increments the texture counter and removes an expired effect
        // BEFORE expanding sprite geometry. The terminal texture is not drawn
        // for a non-looping, full-rate stream (e.g. explosion frames 0...30).
        if counter > profile.lastCounter {
            if profile.loops { counter = 0 } else { active = false }
        }
    }
}

// Pure player launch formula. The weapon mount remains at (0,800,0) even though
// the eye is (0,820,0). forward/right are the original unit matrix columns after
// recoil/aim; mountRight is the parent yaw-only right used by 2002 variant 2.
// Scene-space camera offsets must not replace this source-space anchor.
func originalGunMuzzle(version: OriginalGameVersion, action: OriginalFireAction,
                       forward: SIMD3<Double>, right: SIMD3<Double>,
                       mountRight: SIMD3<Double>? = nil,
                       mount: SIMD3<Double> = .init(0, 800, 0)) -> SIMD3<Double>? {
    switch action.weapon {
    case .machineGun:
        if version == .beach2002 && action.variant != 0 {
            return mount + forward * 81 + (action.variant == 2 ? mountRight ?? right : right) * 8
        }
        let side: Double = action.barrel == .left ? -30 : 30
        return mount + forward * 221 + right * side
    case .cannon: return mount + forward * 266
    case .handgun: return mount + forward * 101 + right * 5
    case .flare: return nil // OriginalFlares owns its independent launch origin.
    }
}

struct OriginalMuzzleFlash {
    let position: SIMD3<Double>
    let scale: SIMD2<Double>
}

func originalGunFlash(version: OriginalGameVersion, action: OriginalFireAction,
                      muzzle: SIMD3<Double>) -> OriginalMuzzleFlash? {
    let dy: Double, size: Double
    switch action.weapon {
    case .machineGun: dy = version == .beach2002 && action.variant != 0 ? 10 : 0; size = version == .beach2000 ? 1 : 0.15
    case .cannon: dy = 10; size = version == .beach2000 ? 2 : 0.6
    case .handgun: dy = 4; size = version == .beach2000 ? 1 : 0.25
    case .flare: return nil
    }
    return .init(position: muzzle + SIMD3(0, dy, 0), scale: .init(repeating: size))
}

final class OriginalEffectsRenderer {
    struct Token: Hashable { let kind: OriginalEffectKind; let slot: Int; let generation: Int }
    struct Snapshot { let token: Token; let state: OriginalEffectState; let node: SCNNode }
    private final class Entry {
        let token: Token, node: SCNNode, facingNode: SCNNode, material: SCNMaterial
        var state: OriginalEffectState
        var shownFrame = -1
        var remastered: RemasteredEffectVisual?
        init(token: Token, state: OriginalEffectState, node: SCNNode, facingNode: SCNNode, material: SCNMaterial) {
            self.token = token; self.state = state; self.node = node; self.facingNode = facingNode; self.material = material
        }
    }
    let version: OriginalGameVersion
    let sourceToSceneScale: Double
    let resourceRoot: URL
    private let parent: SCNNode
    private var entries: [OriginalEffectKind: [Int: Entry]] = [:]
    private var writePointers: [OriginalEffectKind: Int] = [:]
    private var serial = 0
    private var tickParity = 0
    private var retainedFireCursors: [Int: Int] = [:]
    private var retainedBlackSmokeAges: [Int: Int] = [:]
    private var retainedWhiteSmokeAges: [Int: Int] = [:]
    private var images: [String: NSImage] = [:]
    private(set) var missingTexturePaths: Set<String> = []
    private var cameraEuler = SCNVector3Zero
    private let ground: ((CGFloat,CGFloat)->CGFloat)?
    private let remastered: RemasteredEffects

    init(resourceRoot: URL, parent: SCNNode, version: OriginalGameVersion, sourceToSceneScale: Double = 0.01, ground: ((CGFloat,CGFloat)->CGFloat)? = nil) {
        self.ground = ground
        precondition(sourceToSceneScale > 0)
        self.resourceRoot = resourceRoot; self.parent = parent; self.version = version
        self.sourceToSceneScale = sourceToSceneScale
        remastered = RemasteredEffects(resourceRoot: resourceRoot.deletingLastPathComponent().appendingPathComponent("remastered-assets"))
    }
    var snapshots: [Snapshot] {
        OriginalEffectKind.allCases.flatMap { kind in
            (entries[kind] ?? [:]).keys.sorted().compactMap { slot in
                entries[kind]?[slot].map { Snapshot(token: $0.token, state: $0.state, node: $0.node) }
            }
        }
    }
    var activeCount: Int { entries.values.reduce(0) { $0 + $1.count } }
    func isActive(_ token: Token) -> Bool { entries[token.kind]?[token.slot]?.token == token }
    var hasOneShotEffects: Bool {
        entries.values.contains { $0.values.first?.state.profile.loops == false }
    }

    private func texture(_ profile: OriginalEffectProfile, frame: Int) -> NSImage? {
        let path = profile.relativeTexturePath(frame: frame)
        if let cached = images[path] { return cached }
        guard let image = NSImage(contentsOf: resourceRoot.appendingPathComponent(path)) else {
            missingTexturePaths.insert(path); return nil
        }
        images[path] = image; return image
    }

    // Explicit slots are useful for attached missile flames/fire. Otherwise the
    // source ring writer is used. Generation guards prevent an old owner from
    // moving/removing a later effect which reused its slot.
    @discardableResult
    func emit(_ kind: OriginalEffectKind, at position: SIMD3<Double>,
              scale: SIMD2<Double>? = nil, velocity: SIMD3<Double> = .zero,
              opacity: Double = 1, slot requestedSlot: Int? = nil,
              initialFrame: Int? = nil) -> Token? {
        guard let profile = OriginalEffectProfile.recovered(kind, version: version) else { return nil }
        let slot = requestedSlot ?? writePointers[kind, default: 0]
        guard (0..<profile.poolCount).contains(slot) else { return nil }
        if requestedSlot == nil { writePointers[kind] = (slot + 1) % profile.poolCount }
        let oldFireCursor = entries[.fire]?[slot]?.state.counter ?? retainedFireCursors[slot, default: 0]
        // 2000 burning assignment never resets the texture cursor. 2002's
        // caller explicitly seeds its new fire with rand>>10 (0...31).
        let firstFrame = initialFrame ?? (kind == .fire && version == .beach2000 ? oldFireCursor : 0)
        entries[kind]?[slot]?.node.removeFromParentNode()
        serial += 1
        let token = Token(kind: kind, slot: slot, generation: serial)
        let state = OriginalEffectState(profile: profile, position: position, scale: scale, velocity: velocity, opacity: opacity, initialFrame: firstFrame)
        let plane = SCNPlane(width: CGFloat(profile.templateSize.x * sourceToSceneScale),
                             height: CGFloat(profile.templateSize.y * sourceToSceneScale))
        let (material, atlas) = remastered.material(for: profile)
        plane.materials = [material]
        let planeNode = SCNNode(geometry: plane)
        if profile.bottomAnchored { planeNode.position.y = CGFloat(profile.templateSize.y * sourceToSceneScale * 0.5) }
        let node = SCNNode(); node.name = "original-effect-\(kind.rawValue)-\(slot)"
        // Source helper rotates the template first, then scales WORLD X/Z by
        // sx and WORLD Y by sy. Separate nodes preserve that S*R order even
        // for nonuniform sizes and camera pitch.
        let facingNode = SCNNode(); facingNode.addChildNode(planeNode)
        node.addChildNode(facingNode)
        let entry = Entry(token: token, state: state, node: node, facingNode: facingNode, material: material)
        entry.remastered = RemasteredEffectVisual(profile: profile, plane: planeNode, material: material, root: node,
                                                  facing: facingNode, atlas: atlas, seed: serial + slot * 31, sourceScale: sourceToSceneScale)
        // A local terrain tangent softens the bottom of smoke and spray cards on
        // sloping ground. Sample on emission, never read back a depth texture.
        if let ground, profile.isSmoke || [.groundExplosion,.dirtHit,.waterSplash].contains(kind) {
            let x=CGFloat(position.x*sourceToSceneScale), z=CGFloat(position.z*sourceToSceneScale)
            let dx=(ground(x+1,z)-ground(x-1,z))/2, dz=(ground(x,z+1)-ground(x,z-1))/2
            let plane=SCNVector3(dx,dz,ground(x,z)-dx*x-dz*z)
            material.setValue(NSValue(scnVector3:plane),forKey:"dlFXGround")
        }
        entries[kind, default: [:]][slot] = entry
        render(entry)
        parent.addChildNode(node)
        return token
    }

    @discardableResult
    func emitGunFlash(action: OriginalFireAction, muzzle: SIMD3<Double>) -> Token? {
        guard let flash = originalGunFlash(version: version, action: action, muzzle: muzzle) else { return nil }
        return emit(.muzzleFlash, at: flash.position, scale: flash.scale)
    }

    // BH2002 wreck smoke's source writer increments first, then resets the NEXT
    // slot's age. This can prolong an older still-visible puff. Preserve it here
    // instead of silently treating all black smoke spawns as age0.
    @discardableResult
    func emitAircraftSmoke(at position: SIMD3<Double>, scale: Double) -> Token? {
        guard version == .beach2002 else { return nil }
        let slot = writePointers[.blackSmoke, default: 0]
        let age = entries[.blackSmoke]?[slot]?.state.counter ?? retainedBlackSmokeAges[slot, default: 0]
        let token = emit(.blackSmoke, at: position, scale: .init(repeating: scale), initialFrame: age)
        guard token != nil else { return nil }
        let next = writePointers[.blackSmoke, default: 0]
        entries[.blackSmoke]?[next]?.state.resetCounter(0)
        retainedBlackSmokeAges[next] = 0
        return token
    }

    // 2000 0x416a09:1823..1835; 2002 0x4154b7:1525..1548. This is the
    // player's homing-missile trail; enemy rockets have a separate flame bank.
    // BH2002 shares the aircraft-smoke next-slot age-reset quirk, but has its own
    // 120-slot WHITE bank. Night changes initial opacity as well as fade speed.
    @discardableResult
    func emitPlayerMissileSmoke(at position: SIMD3<Double>, night: Bool) -> Token? {
        if version == .beach2000 { return emit(.whiteSmoke, at: position) }
        let slot = writePointers[.whiteSmoke, default: 0]
        let age = entries[.whiteSmoke]?[slot]?.state.counter ?? retainedWhiteSmokeAges[slot, default: 0]
        let token = emit(.whiteSmoke, at: position, scale: .init(repeating: 0.2),
                         opacity: night ? 0.25 : 1, initialFrame: age)
        guard token != nil else { return nil }
        let next = writePointers[.whiteSmoke, default: 0]
        entries[.whiteSmoke]?[next]?.state.resetCounter(0)
        retainedWhiteSmokeAges[next] = 0
        return token
    }

    // Common six-puff ground explosion recipe. The host decides WHEN this
    // source branch applies (many impact branches don't emit this cluster).
    // The near-bunker abs(x)/abs(z)>400 guard also belongs to the host.
    func emitBlastSmoke(at position: SIMD3<Double>,recipe:OriginalBlastSmokeRecipe = .groundImpact(version:.beach2000),random15: () -> Int) {
        for _ in 0..<6 {
            let dx = Double(random15() - 16384) * 0.004
            let dz = Double(random15() - 16384) * 0.004
            let vx = Double(random15() - 16384) * recipe.horizontalVelocityFactor
            let vz = Double(random15() - 16384) * recipe.horizontalVelocityFactor
            let vy = Double(random15()) * recipe.upwardVelocityFactor
            emit(.smokeBurst, at: position + SIMD3(dx, 0, dz), velocity: SIMD3(vx, vy, vz))
        }
    }

    func move(_ token: Token, to position: SIMD3<Double>, scale:SIMD2<Double>?=nil) {
        guard let entry = entries[token.kind]?[token.slot], entry.token == token else { return }
        entry.state.position = position
        if let scale {entry.state.scale=scale}
        render(entry)
    }
    func remove(_ token: Token) {
        guard let entry = entries[token.kind]?[token.slot], entry.token == token else { return }
        if token.kind == .fire { retainedFireCursors[token.slot] = entry.state.counter }
        if token.kind == .blackSmoke { retainedBlackSmokeAges[token.slot] = entry.state.counter }
        if token.kind == .whiteSmoke { retainedWhiteSmokeAges[token.slot] = entry.state.counter }
        entry.node.removeFromParentNode(); entries[token.kind]?.removeValue(forKey: token.slot)
    }
    func clear() {
        for bank in entries.values { for entry in bank.values {
            if entry.token.kind == .fire { retainedFireCursors[entry.token.slot] = entry.state.counter }
            if entry.token.kind == .blackSmoke { retainedBlackSmokeAges[entry.token.slot] = entry.state.counter }
            if entry.token.kind == .whiteSmoke { retainedWhiteSmokeAges[entry.token.slot] = entry.state.counter }
            entry.node.removeFromParentNode()
        } }
        entries.removeAll()
        // Writer pointers and the global parity are process state. No inferred
        // level-reset behavior is applied; new renderer instances reset both.
    }

    func tick(cameraEuler: SCNVector3, night: Bool, parity: Int? = nil) {
        self.cameraEuler = cameraEuler
        for kind in OriginalEffectKind.allCases {
            for slot in (entries[kind] ?? [:]).keys.sorted() {
                guard let entry = entries[kind]?[slot] else { continue }
                entry.state.tick(parity: parity ?? tickParity, night: night)
                if !entry.state.active { remove(entry.token) } else { render(entry) }
            }
        }
        tickParity = 1 - tickParity
    }
    // Camera changes may update billboard orientation without advancing time.
    func faceCamera(_ euler: SCNVector3) {
        cameraEuler = euler
        for bank in entries.values { for entry in bank.values { orient(entry) } }
    }
    private func orient(_ entry: Entry) {
        // Original sprites use CAMERA ROTATION, not a look-at vector from each
        // particle to the eye. This avoids off-axis rotation of big explosions.
        entry.facingNode.eulerAngles = .init(entry.state.profile.yawOnly ? 0 : cameraEuler.x, cameraEuler.y, 0)
    }
    private func render(_ entry: Entry) {
        let s = entry.state
        entry.node.position = .init(CGFloat(s.position.x * sourceToSceneScale), CGFloat(s.position.y * sourceToSceneScale), CGFloat(s.position.z * sourceToSceneScale))
        entry.node.scale = .init(CGFloat(s.scale.x), CGFloat(s.scale.y), CGFloat(s.scale.x))
        entry.node.opacity = CGFloat(max(0, min(1, s.opacity)))
        orient(entry)
        if let visual = entry.remastered { visual.update(s) }
        else if entry.shownFrame != s.displayFrame {
            entry.material.diffuse.contents = texture(s.profile, frame: s.displayFrame)
            entry.shownFrame = s.displayFrame
        }
    }
}

func testOriginalEffects(resource2000: URL, resource2002: URL) throws {
    enum Failure: Error { case failed(String) }
    func check(_ condition: @autoclosure () -> Bool, _ text: String) throws {
        if !condition() { throw Failure.failed(text) }
    }
    try check(RemasteredEffects(resourceRoot:resource2002.deletingLastPathComponent().appendingPathComponent("remastered-assets")).loadedAtlasCount == 3,
              "all three generated remastered FX atlases are bundled and readable")
    for version in [OriginalGameVersion.beach2000, .beach2002] {
        let root = version == .beach2000 ? resource2000 : resource2002
        for kind in OriginalEffectKind.allCases {
            guard let p = OriginalEffectProfile.recovered(kind, version: version) else { continue }
            for frame in 0..<p.frameCount {
                try check(FileManager.default.fileExists(atPath: root.appendingPathComponent(p.relativeTexturePath(frame: frame)).path), "missing original frame \(version) \(kind) \(frame)")
            }
        }
        let p = OriginalEffectProfile.recovered(.explosion, version: version)!
        var state = OriginalEffectState(profile: p, position: .zero)
        for i in 0..<31 { state.tick(parity: i & 1, night: false) }
        try check(state.active && state.displayFrame == 30, "air explosion visible terminal frame")
        state.tick(parity: 1, night: false)
        try check(!state.active, "air explosion retires before frame31 draw")
    }
    var water = OriginalEffectState(profile: .recovered(.waterSplash, version: .beach2000)!, position: .zero)
    for i in 0..<38 { water.tick(parity: i & 1, night: false) }
    try check(water.active && water.counter == 19, "water half-rate clock")
    water.tick(parity: 0, night: false)
    try check(!water.active, "water expiry depends on global parity")
    var smoke = OriginalEffectState(profile: .recovered(.smokeBurst, version: .beach2002)!, position: .zero, velocity: SIMD3(4, 10, -4))
    smoke.tick(parity: 0, night: false)
    try check(smoke.position == SIMD3(4, 13, -4) && smoke.velocity == SIMD3(3, 8.5, -3), "source smoke drift and damping")
    var daytime = OriginalEffectState(profile: .recovered(.whiteSmoke, version: .beach2002)!, position: .zero)
    var nighttime = daytime
    daytime.tick(parity: 0, night: false); nighttime.tick(parity: 0, night: true)
    try check(abs(daytime.opacity - 0.984) < 1e-9 && abs(nighttime.opacity - 0.996) < 1e-9, "Daytime flag is not night flag")
    let action = OriginalFireAction(weapon: .machineGun, barrel: .left, variant: 0, recoilTicks: 0, ballistic: nil)
    try check(originalGunMuzzle(version: .beach2000, action: action, forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0)) == SIMD3(-30, 800, -221), "fixed mount launch origin")
    let scene = SCNNode()
    let renderer = OriginalEffectsRenderer(resourceRoot: resource2002, parent: scene, version: .beach2002)
    let first = renderer.emit(.muzzleFlash, at: .zero)!
    for _ in 0..<8 { renderer.emit(.muzzleFlash, at: SIMD3(1, 2, 3)) }
    try check(renderer.activeCount == 8 && scene.childNodes.count == 8, "ring overwrites node")
    renderer.remove(first)
    try check(renderer.activeCount == 8, "stale token cannot delete replacement")
    renderer.faceCamera(.init(0.2, 0.4, 0))
    try check(renderer.snapshots.allSatisfy { $0.state.counter == 0 && !$0.node.hasActions }, "pause preserves counters; no wall-clock actions")
    for _ in 0..<5 { renderer.tick(cameraEuler: .init(0, 0, 0), night: false) }
    try check(renderer.activeCount == 0 && scene.childNodes.isEmpty, "expired nodes removed")
    let fire2000 = OriginalEffectsRenderer(resourceRoot: resource2000, parent: SCNNode(), version: .beach2000)
    let oldFire = fire2000.emit(.fire, at: .zero, slot: 3)!
    for _ in 0..<7 { fire2000.tick(cameraEuler: .init(0, 0, 0), night: false) }
    fire2000.remove(oldFire)
    fire2000.emit(.fire, at: .zero, slot: 3)
    try check(fire2000.snapshots.first!.state.counter == 7, "2000 fire reuse retains cursor")
    renderer.emit(.fire, at: .zero, initialFrame: 31)
    renderer.tick(cameraEuler: .init(0, 0, 0), night: false)
    try check(renderer.snapshots.first!.state.displayFrame == 31, "2002 fire random initial frame")
    renderer.clear()
    renderer.emit(.blackSmoke, at: .zero, slot: 1, initialFrame: 20)
    renderer.emitAircraftSmoke(at: .zero, scale: 0.6)
    try check(renderer.snapshots.first(where: { $0.token.kind == .blackSmoke && $0.token.slot == 1 })!.state.counter == 0, "wreck writer resets next slot age")
    renderer.emit(.whiteSmoke, at: .zero, slot: 1, initialFrame: 19)
    renderer.emitPlayerMissileSmoke(at: SIMD3(1, 2, 3), night: true)
    let trail = renderer.snapshots.first { $0.token.kind == .whiteSmoke && $0.token.slot == 0 }!
    try check(trail.state.position == SIMD3(1, 2, 3) && trail.state.opacity == 0.25 && trail.state.scale == SIMD2(repeating: 0.2), "2002 missile night trail initial position/size/opacity")
    try check(renderer.snapshots.first(where: { $0.token.kind == .whiteSmoke && $0.token.slot == 1 })!.state.counter == 0, "missile writer resets next white slot age")
    renderer.tick(cameraEuler: .init(0, 0, 0), night: true)
    let aged = renderer.snapshots.first { $0.token == trail.token }!.state
    try check(aged.position == SIMD3(1, 0, 3) && abs(aged.opacity - 0.246) < 1e-9 && abs(aged.scale.x - 0.215) < 1e-9, "2002 missile trail source drift/growth/night fade")
    fire2000.clear()
    fire2000.emitPlayerMissileSmoke(at: SIMD3(1, 2, 3), night: false)
    let oldTrail = fire2000.snapshots.first!.state
    try check(oldTrail.scale == SIMD2(repeating: 1) && oldTrail.opacity == 1 && oldTrail.counter == 0, "2000 trail retains its original init scale and zero cursor")
    for source in [fire2000,renderer] {
        source.clear();var draws=0
        let sequence=[0,16384,32767,0,16384]
        source.emitBlastSmoke(at:.init(1000,80,2000),recipe:.groundImpact(version:source.version),random15:{defer{draws+=1};return sequence[draws%5]})
        let puffs=source.snapshots.filter {$0.token.kind == .smokeBurst}
        let sx=source.version == .beach2000 ? 0.003:0.004,sy=source.version == .beach2000 ? 0.002:0.003
        try check(draws==30 && puffs.count==6,"ground blast consumes original six-times-five random draws")
        try check(puffs.allSatisfy {abs($0.state.position.x-934.464)<1e-8 && $0.state.position.y==80 && $0.state.position.z==2000 && abs($0.state.velocity.x-16383*sx)<1e-8 && abs($0.state.velocity.z+16384*sx)<1e-8 && abs($0.state.velocity.y-16384*sy)<1e-8},"version-specific blast smoke factors and X/Z/vX/vZ/vY draw order")
    }
    print("PASS original effects: assets, source lifetimes, smoke, muzzle, rings, pause")
}
