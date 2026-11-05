import Foundation
import SceneKit

/// The source stores enemy rocket flames separately from missile smoke.
/// BH2000 0x416a09:2476..2503,3953..3967; BH2002 0x4154b7:2079..2115,
/// 2309..2350,2529..2533,3878..3889. Positions are original world units.
/// BH2002's APC and airborne rockets really reuse flame slots 16..23; the later
/// APC loop can hide an airborne rocket's flame even when the APC slot is empty.
final class OriginalRocketFlames {
    struct Frame {
        let slot: Int
        let groundRocket: Bool
        let previous: SIMD3<Double>
        let velocity: SIMD3<Double>
        let wasActive: Bool
        let remainsActive: Bool
    }
    let version: OriginalGameVersion
    let effects: OriginalEffectsRenderer
    private var tokens: [Int: OriginalEffectsRenderer.Token] = [:]

    init(version: OriginalGameVersion, effects: OriginalEffectsRenderer) {
        self.version = version; self.effects = effects
    }

    /// Call after advancing existing enemy projectiles, before appending new
    /// shots. Pass both the old position and resulting active flag for every
    /// existing rocket. Missing slots are the original inactive object entries.
    func step(_ frames: [Frame]) {
        func apply(slot: Int, ground: Bool) {
            let frame = frames.first { $0.slot == slot && $0.groundRocket == ground }
            if let frame, frame.wasActive {
                // Source uses forward *200, where velocity = forward *280.
                // This places the flame 80 units behind the advanced rocket.
                let position = frame.previous + frame.velocity * (200.0 / 280.0)
                if let token = tokens[slot] { effects.move(token, to: position) }
                else { tokens[slot] = effects.emit(.missileFlame, at: position, slot: slot, initialFrame: 2) }
            }
            if frame?.remainsActive != true {
                if let token = tokens.removeValue(forKey: slot) { effects.remove(token) }
            }
        }
        for slot in 0..<(version == .beach2000 ? 12 : 16) { apply(slot: slot, ground: false) }
        if version == .beach2002 { for slot in 0..<8 { apply(slot: slot, ground: true) } }
    }

    func clear() {
        for token in tokens.values { effects.remove(token) }
        tokens.removeAll()
    }
}

func testOriginalRocketFlames(resource2000: URL, resource2002: URL) throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "OriginalRocketFlames", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    for version in [OriginalGameVersion.beach2000, .beach2002] {
        let renderer = OriginalEffectsRenderer(resourceRoot: version == .beach2000 ? resource2000 : resource2002,
                                               parent: SCNNode(), version: version)
        let flames = OriginalRocketFlames(version: version, effects: renderer)
        let slot = version == .beach2000 ? 0 : 8
        let frame = OriginalRocketFlames.Frame(slot: slot, groundRocket: false, previous: SIMD3(0, 1000, -1000),
                                               velocity: SIMD3(0, 0, 280), wasActive: true, remainsActive: true)
        flames.step([frame])
        try check(renderer.snapshots.count == 1 && renderer.snapshots[0].state.position == SIMD3(0, 1000, -800) &&
                  renderer.snapshots[0].state.counter == 2, "rocket flame starts at frame2, eighty units behind advanced rocket")
        renderer.tick(cameraEuler: SCNVector3Zero, night: false)
        flames.step([frame])
        try check(renderer.snapshots[0].state.counter == 3, "moving attached flame does not restart texture animation")
        flames.step([])
        try check(renderer.snapshots.isEmpty, "retired source slot removes flame")
        if version == .beach2002 {
            let air = OriginalRocketFlames.Frame(slot: 0, groundRocket: false, previous: SIMD3(100, 1000, -1000), velocity: SIMD3(0, 0, 280), wasActive: true, remainsActive: true)
            flames.step([air])
            try check(renderer.snapshots.isEmpty, "inactive later APC slot clears aliased airborne flame")
            let ground = OriginalRocketFlames.Frame(slot: 0, groundRocket: true, previous: SIMD3(200, 1000, -1000), velocity: SIMD3(0, 0, 280), wasActive: true, remainsActive: true)
            flames.step([air, ground])
            try check(renderer.snapshots.count == 1 && renderer.snapshots[0].state.position.x == 200, "later APC flame wins shared slot")
        }
        flames.clear()
        try check(renderer.snapshots.isEmpty, "cleanup removes all attached flames")
    }
    print("PASS original rocket flames: exact offset, initial frame, animation continuity, retirement and shared source slot precedence")
}
