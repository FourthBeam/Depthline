import Foundation

// Beach Head 2000 supply rules recovered from Beachhead16.exe, SHA-256:
// 9890c65e128513c75382adb11334e625c9cc923b24b5310fcdac23d8753aad8b.
// Sources: analysis/bh2000/full-decompile/functions/{0x404b24,0x405d14,
// 0x406805,0x416a09,0x4163a8,0x416441,0x433bd0}.c. See the feature audit
// for exact line references. This is static reconstruction, not runtime capture.
//
// All positions, velocities and ground heights below are ORIGINAL source units;
// angles are degrees; one update is one original simulation tick, not a second.
// The SceneKit adapter alone divides source XYZ by 100. It must independently
// manage this plane, including when the level's C130 declaration has Visible 0.
// Object 207 is the plane root; 208...211 are its linked parts; 212/213 are boxes
// with parachutes. Geometry IDs and names are retained in scene.json.
//
// Integration order (original main 0x401165:571,580,626):
//   var supply = Beach2000Supply(delay: c130Wave.delay,
//                                initialMachineGunAmmo: levelAmmo[0])
//   var random = Beach2000Supply.Random(seed: 1) // share with other AI when ported
//   // One simulation tick, while gameplay is active:
//   consume(supply.updateAI(random: { random.next() },
//       terrainHeight: { x,z in Float(assets.height(x:CGFloat(x/100),
//                                     z:CGFloat(z/100))) * 100 },
//       smokeTick: simulationTick % 2 == 0))
//   // Projectile collision is between AI and scheduler. After mesh/segment hit:
//   let reward = supply.collect(objectID: hitID, by: .commonBullet,
//                               machineGunAmmo: combat.ammo[0], defense: combat.health)
//   // If reward != nil, assign BOTH returned ammo/defense values and reset the
//   // shared victory/defeat countdown to reward.transitionCounter (150).
//   // A C130 collision uses hitPlane(by: .commonBullet(part: originalPartIndex)),
//   // .cannon, or .missile. Consume its score/explosion events immediately.
//   // Update HUD / transitions, then only if still in the same active level:
//   consume(supply.updateScheduler())
//   // Read supply.plane and supply.parachutes to update transforms/visibility.
//
// AI initialization and scheduler activation are intentionally separate: the
// scheduler sets visible/state0; the following AI tick chooses its start pose.
// smokeTick corresponds to original global 0x44dc08 == 0, which alternates at
// the end of the main loop. Smoke consumes three draws from the same RNG.
// Collision geometry, projectile ownership, sounds and particle rendering are
// caller responsibilities; collect is NOT an automatic proximity pickup.
//
// Standalone tests (no SceneKit, no package/build-script changes required):
// swiftc -parse-as-library -module-cache-path /tmp/bh2000-supply-module-cache \
//   -D BEACH2000_SUPPLY_TESTS native/{SupplyDescent,Beach2000Supply}.swift -o /tmp/bh2000-supply-tests
// /tmp/bh2000-supply-tests
struct Beach2000Supply {
    struct Vector: Equatable {
        var x: Float
        var y: Float
        var z: Float
        static let zero = Vector(x: 0, y: 0, z: 0)
    }

    /// 0x433bd0: the original MSVC rand sequence, inclusive output 0...32767.
    struct Random {
        private(set) var state: UInt32
        init(seed: UInt32) { state = seed }
        mutating func next() -> UInt32 {
            state = state &* 214013 &+ 2531011
            return (state >> 16) & 0x7fff
        }
    }

    enum FlightState: Int, Equatable {
        case chooseApproach = 0, inbound = 1, awaitingDrop = 2, outbound = 3
        case beginCrash = 4, crashing = 5
    }

    struct Plane: Equatable {
        var isCrashing: Bool { visible && (state == .beginCrash || state == .crashing) }
        let objectID = 207
        var visible = false
        var position = Vector.zero
        var pitch: Float = 0
        var yaw: Float = 0
        var roll: Float = 0
        var speed: Float = 140
        var hp = 8
        var state = FlightState.chooseApproach
        var dropCountdown = 0
        var yawRate: Float = 0
        var targetYawRate: Float = 0
        var pitchRate: Float = 0
        var targetPitchRate: Float = 0
    }

    struct Parachute: Equatable {
        let objectID: Int
        var visible = false
        var position = Vector.zero
        var pitch: Float = 0
        var yaw: Float = 0
        var angularVelocity: Float = 0
        var reward: RewardKind?
    }

    enum CollectionWeapon: Equatable { case commonBullet, cannon }
    enum PlaneWeapon: Equatable {
        /// Original collision return value, not a guessed anatomical part name.
        case commonBullet(part: Int)
        case cannon, missile
    }
    enum RewardKind: Equatable { case machineGunAmmo, defense }

    struct Collection: Equatable {
        let objectID: Int
        let kind: RewardKind
        /// Original code assigns the cap even if existing MG ammunition is
        /// already higher. Use these final values, not max(0, reward delta).
        let machineGunAmmo: Int
        let defense: Int
        let transitionCounter = 150
    }

    enum Event: Equatable {
        case planeActivated
        case planeDeparted
        case parachuteReleased(objectID: Int, position: Vector)
        case parachuteLanded(objectID: Int, position: Vector)
        case scoreChanged(Int)
        /// Airborne cannon/missile kill. Original effects include debris.
        case planeDestroyed(position: Vector, weapon: PlaneWeapon)
        /// Bullet-damaged plane impacts ground; score was charged in state4.
        case planeCrashed(position: Vector)
        case smoke(position: Vector)
    }

    private(set) var plane = Plane()
    private(set) var parachutes = [Parachute(objectID: 212), Parachute(objectID: 213)]
    let delay: Int
    let initialMachineGunAmmo: Int
    let cargoDescent: SupplyDescent
    private(set) var countdown: Int
    /// Original DAT_0044ed58. Release uses its old value for the object slot,
    /// then toggles it; collection reads its CURRENT value for either object.
    private(set) var alternateFlag = 0
    private(set) var ammunitionCollected = false
    private(set) var defenseCollected = false

    init(delay: Int, initialMachineGunAmmo: Int, cargoDescent: SupplyDescent = .original) {
        self.delay = delay
        self.cargoDescent = cargoDescent
        self.countdown = delay
        self.initialMachineGunAmmo = initialMachineGunAmmo
    }

    /// The range officer drops a real defence crate in front of the trainee.
    /// Descent, projectile intersection, collection and the reward use the
    /// same paths as a crate released by a campaign transport.
    static func trainingDrop(at position: Vector, initialMachineGunAmmo: Int) -> Beach2000Supply {
        var supply = Beach2000Supply(delay: .max, initialMachineGunAmmo: initialMachineGunAmmo, cargoDescent: .depthlineCargo)
        supply.parachutes[0].visible = true
        supply.parachutes[0].position = position
        supply.parachutes[0].pitch = SupplyDescent.depthlineCargo.releasePitch(original: 75)
        supply.parachutes[0].reward = .defense
        return supply
    }

    /// Original 0x406805:2456...2640. Run BEFORE projectile collisions.
    /// Supply slots move before C130; a newly released box falls next tick.
    @discardableResult
    mutating func updateAI(random: () -> UInt32,
                           terrainHeight: (Float, Float) -> Float,
                           smokeTick: Bool, deathsOnly: Bool = false) -> [Event] {
        var events: [Event] = []
        if deathsOnly && !plane.isCrashing { return events }
        for index in parachutes.indices where !deathsOnly && parachutes[index].visible {
            let swing = cargoDescent.nextSwing(pitch: parachutes[index].pitch, velocity: parachutes[index].angularVelocity)
            parachutes[index].pitch = swing.0
            parachutes[index].angularVelocity = swing.1
            let ground = terrainHeight(parachutes[index].position.x, parachutes[index].position.z)
            parachutes[index].position.y -= cargoDescent.centimetresPerTick
            if parachutes[index].position.y - 500 < ground {
                parachutes[index].visible = false
                events.append(.parachuteLanded(objectID: parachutes[index].objectID,
                                               position: parachutes[index].position))
            }
        }
        guard plane.visible else { return events }

        switch plane.state {
        case .chooseApproach:
            plane.position.y = Float(4000 + (draw(random) >> 4))
            // The source intentionally excludes neither the entire negative-Z
            // half-plane nor a symmetric four-sided square: preserve its OR.
            repeat {
                plane.position.x = Float(draw(random) * 4 - 65536)
                plane.position.z = Float(draw(random) * 4 - 32768)
            } while !(plane.position.x < -32000 || plane.position.x > 32000
                      || plane.position.z > 32000)
            let dx = Float((draw(random) >> 2) - 4096) - plane.position.x
            let dz = Float((draw(random) >> 2) - 4096) - plane.position.z
            let distance = sqrt(Double(dx * dx + dz * dz))
            let cosine = -(dz * Float(1 / distance))
            plane.yaw = Float(acos(Double(cosine)) * 57.2957795)
            if dx > 0 { plane.yaw = -plane.yaw }
            plane.state = .inbound
        case .inbound:
            if abs(plane.position.x) < 4296 && abs(plane.position.z) < 4296 {
                plane.dropCountdown = draw(random) >> 9
                plane.state = .awaitingDrop
            }
        case .awaitingDrop:
            plane.dropCountdown -= 1
            if plane.dropCountdown < 1 {
                plane.state = .outbound
                // Slower cargo can overlap passes. The scheduler reserves at
                // least one free slot; retain the old box and its own reward.
                let slot = cargoDescent == .depthlineCargo && parachutes[alternateFlag].visible ? 1-alternateFlag : alternateFlag
                parachutes[slot].visible = true
                parachutes[slot].position = plane.position
                parachutes[slot].yaw = plane.yaw
                parachutes[slot].pitch = cargoDescent.releasePitch(original: 75)
                parachutes[slot].angularVelocity = 0
                parachutes[slot].reward = alternateFlag == 0 ? .defense : .machineGunAmmo
                alternateFlag ^= 1
                events.append(.parachuteReleased(objectID: parachutes[slot].objectID,
                                                 position: parachutes[slot].position))
            }
        case .outbound:
            if abs(plane.position.x) > 30000 || abs(plane.position.z) > 30000 {
                plane.visible = false
                events.append(.planeDeparted)
            }
        case .beginCrash:
            plane.targetPitchRate = -0.5
            plane.state = .crashing
            events.append(.scoreChanged(-10))
        case .crashing:
            if plane.pitch < -20 { plane.targetPitchRate = 0 }
            let ground: Float
            if abs(plane.position.x) < 15000 && abs(plane.position.z) < 7500 {
                ground = terrainHeight(plane.position.x, plane.position.z)
            } else {
                ground = 0
            }
            if smokeTick {
                let position = Vector(
                    x: plane.position.x + Float((draw(random) >> 8) - 64),
                    y: plane.position.y + Float((draw(random) >> 9) - 32),
                    z: plane.position.z + Float((draw(random) >> 8) - 64))
                events.append(.smoke(position: position))
            }
            if plane.position.y < ground + 100 {
                plane.visible = false
                // Original 0x46a520=3 and 0x46a480=5 feed later effect handling.
                // The adapter uses this event for that explosion/audio effect.
                plane.dropCountdown = 5
                events.append(.planeCrashed(position: plane.position))
            }
        }

        // The source still performs this integration when the switch just hid
        // the plane. Event positions above precede this final movement.
        plane.yawRate = Float(Double(plane.targetYawRate) * 0.08 + Double(plane.yawRate) * 0.92)
        plane.pitchRate = Float(Double(plane.targetPitchRate) * 0.08 + Double(plane.pitchRate) * 0.92)
        plane.pitch += plane.pitchRate
        plane.yaw += plane.yawRate
        if plane.yaw > 180 { plane.yaw -= 360 }
        if plane.yaw < -180 { plane.yaw += 360 }
        // Original identity -> Z roll -> X pitch -> Y yaw. C130 roll stays0.
        // Negative third matrix column is its forward direction.
        let pitchCos = Float(cos(Double(plane.pitch) * 0.017453292))
        let pitchSin = Float(sin(Double(plane.pitch) * 0.017453292))
        let yawCos = Float(cos(Double(plane.yaw) * 0.017453292))
        let yawSin = Float(sin(Double(plane.yaw) * 0.017453292))
        plane.position.x += (-pitchCos * yawSin) * plane.speed
        plane.position.y += pitchSin * plane.speed
        plane.position.z += (-pitchCos * yawCos) * plane.speed
        return events
    }

    /// Original 0x405d14:174...189. Run AFTER AI, collisions and HUD processing.
    /// Countdown keeps decreasing while airborne. There is no Revive/Visible
    /// declaration gate, and HP deliberately does not reset between passes.
    @discardableResult
    mutating func updateScheduler() -> [Event] {
        countdown -= 1
        guard countdown < 1 && !plane.visible && plane.hp > 0 else { return [] }
        if cargoDescent == .depthlineCargo && parachutes.allSatisfy(\.visible) { return [] }
        plane.visible = true
        plane.pitch = 0
        plane.roll = 0
        countdown = delay
        plane.speed = 140
        plane.state = .chooseApproach
        plane.yawRate = 0
        plane.targetYawRate = 0
        plane.pitchRate = 0
        plane.targetPitchRate = 0
        return [.planeActivated]
    }

    /// Call only after a confirmed original mesh/segment collision. The source
    /// common bullet damages parts0/1 by2 and part2 by1, while other returned
    /// part indices still consume the projectile but do not reduce HP.
    /// Cannon/missile immediately hide all five parts and charge10 score.
    /// An already crashing, still visible plane can be destroyed by a cannon
    /// or missile and incur another10-point penalty, as in the original branch.
    @discardableResult
    mutating func hitPlane(by weapon: PlaneWeapon) -> [Event] {
        guard plane.visible else { return [] }
        switch weapon {
        case .commonBullet(let part):
            guard plane.hp > 0 else { return [] }
            if part == 2 { plane.hp -= 1 }
            if part == 0 || part == 1 { plane.hp -= 2 }
            if plane.hp < 1 { plane.state = .beginCrash }
            return []
        case .cannon, .missile:
            plane.hp = 0
            plane.visible = false
            return [.planeDestroyed(position: plane.position, weapon: weapon), .scoreChanged(-10)]
        }
    }

    /// A successful segment hit on a visible parachute (original collision
    /// part-set9, broad phase<600, collision parameter400) collects it. It is
    /// the GLOBAL current toggle that chooses the historical reward. Depthline
    /// fixes the reward on release, including when two boxes overlap.
    /// Missile pickup is intentionally absent: no such branch was established.
    mutating func collect(objectID: Int, by weapon: CollectionWeapon,
                          machineGunAmmo: Int, defense: Int) -> Collection? {
        guard let slot = parachutes.firstIndex(where: { $0.objectID == objectID }),
              parachutes[slot].visible else { return nil }
        parachutes[slot].visible = false
        let kind = cargoDescent == .depthlineCargo ? parachutes[slot].reward : (alternateFlag == 0 ? .machineGunAmmo : .defense)
        if kind == .machineGunAmmo {
            ammunitionCollected = true
            let increased = machineGunAmmo + 100
            let result = weapon == .commonBullet ? min(initialMachineGunAmmo, increased) : increased
            return Collection(objectID: objectID, kind: .machineGunAmmo,
                              machineGunAmmo: result, defense: defense)
        }
        defenseCollected = true
        return Collection(objectID: objectID, kind: .defense,
                          machineGunAmmo: machineGunAmmo, defense: min(100, defense + 25))
    }

    private func draw(_ random: () -> UInt32) -> Int {
        let value = random()
        precondition(value <= 32767, "Beach Head 2000 RNG must return 0...32767")
        return Int(value)
    }
}

// Source-rule tests live in this file so the standalone compiler check does
// not require changing project build files or a package manifest.
extension Beach2000Supply {
    struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func runTests() throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw TestFailure(description: message) }
        }
        func close(_ a: Float, _ b: Float, _ tolerance: Float = 0.001) -> Bool {
            abs(a - b) <= tolerance
        }
        let flat: (Float, Float) -> Float = { _,_ in 0 }
        let zero: () -> UInt32 = { 0 }
        func fixture(_ state: FlightState, _ position: Vector = Vector(x: 0, y: 4000, z: 0)) -> Beach2000Supply {
            var supply = Beach2000Supply(delay: 200, initialMachineGunAmmo: 150)
            supply.plane.visible = true
            supply.plane.state = state
            supply.plane.position = position
            return supply
        }
        func release(_ supply: inout Beach2000Supply) -> [Event] {
            supply.plane.visible = true
            supply.plane.state = .awaitingDrop
            supply.plane.dropCountdown = 1
            return supply.updateAI(random: zero, terrainHeight: flat, smokeTick: false)
        }

        // Independently documented MSVC seed1 sequence, including uint32 wrap.
        var rng = Random(seed: 1)
        try check((0..<5).map { _ in rng.next() } == [41, 18467, 6334, 26500, 19169], "Original rand sequence")

        // Level_01 has C130 Visible0 and Delay200. It must still activate.
        var supply = Beach2000Supply(delay: 200, initialMachineGunAmmo: 150)
        var draws = 0
        for _ in 0..<199 {
            try check(supply.updateAI(random: { draws += 1; return 0 }, terrainHeight: flat, smokeTick: false).isEmpty,
                      "Hidden plane does not initialize approach")
            try check(supply.updateScheduler().isEmpty, "No activation before Delay200")
        }
        try check(draws == 0 && !supply.plane.visible, "Invisible supply consumes no RNG")
        try check(supply.updateScheduler() == [.planeActivated], "Activation at exact scheduler count200")
        try check(supply.plane.state == .chooseApproach && supply.countdown == 200, "Activation defers approach to AI")
        var sequence: [UInt32] = [0, 16384, 24576, 16384, 16384]
        _ = supply.updateAI(random: { sequence.removeFirst() }, terrainHeight: flat, smokeTick: false)
        try check(sequence.isEmpty && supply.plane.state == .inbound, "Five random draws select direct approach")
        try check(supply.plane.position == Vector(x: 0, y: 4000, z: 65396), "Source spawn and same-tick movement")

        // Drop gate has strict coordinate bounds, followed by its own countdown.
        supply = fixture(.inbound, Vector(x: 4296, y: 4000, z: 0))
        _ = supply.updateAI(random: { 32767 }, terrainHeight: flat, smokeTick: false)
        try check(supply.plane.state == .inbound, "At4296 does not enter drop gate")
        supply.plane.position.x = 4295
        _ = supply.updateAI(random: { 32767 }, terrainHeight: flat, smokeTick: false)
        try check(supply.plane.state == .awaitingDrop && supply.plane.dropCountdown == 63, "Delay uses rand>>9")
        for _ in 0..<62 { _ = supply.updateAI(random: zero, terrainHeight: flat, smokeTick: false) }
        try check(!supply.parachutes[0].visible, "Box waits until countdown decrements below1")
        let releaseEvents = supply.updateAI(random: zero, terrainHeight: flat, smokeTick: false)
        try check(releaseEvents.contains { if case .parachuteReleased(objectID: 212, position: _) = $0 { return true }; return false },
                  "First release is original object212")
        try check(supply.parachutes[0].position.y == 4000 && supply.parachutes[0].pitch == 75 && supply.alternateFlag == 1,
                  "New box does not fall until next AI tick; global flag flips immediately")
        _ = supply.updateAI(random: zero, terrainHeight: flat, smokeTick: false)
        try check(supply.parachutes[0].position.y == 3990 && close(supply.parachutes[0].pitch, 74.4), "Parachute spring and descent")
        let health = supply.collect(objectID: 212, by: .commonBullet, machineGunAmmo: 20, defense: 90)
        try check(health?.kind == .defense && health?.defense == 100 && health?.machineGunAmmo == 20,
                  "First released box heals25 capped100")
        try check(health?.transitionCounter == 150 && supply.defenseCollected, "Collection resets shared countdown and flag")
        try check(supply.collect(objectID: 212, by: .cannon, machineGunAmmo: 20, defense: 90) == nil,
                  "Already collected box cannot be collected again")

        // Shared-toggle quirk: second drop changes the still-falling first box.
        supply = fixture(.awaitingDrop)
        _ = release(&supply)
        _ = release(&supply)
        try check(supply.parachutes.allSatisfy(\.visible) && supply.alternateFlag == 0, "Both box slots can coexist")
        let capped = supply.collect(objectID: 212, by: .commonBullet, machineGunAmmo: 140, defense: 40)
        let uncapped = supply.collect(objectID: 213, by: .cannon, machineGunAmmo: 140, defense: 40)
        try check(capped?.kind == .machineGunAmmo && capped?.machineGunAmmo == 150,
                  "Old first box now gives MG according to shared flag")
        try check(uncapped?.machineGunAmmo == 240 && uncapped?.defense == 40 && supply.ammunitionCollected,
                  "Cannon MG reward deliberately has no initial-ammo cap")
        _ = release(&supply)
        _ = release(&supply)
        let overCap = supply.collect(objectID: 212, by: .commonBullet, machineGunAmmo: 240, defense: 40)
        try check(overCap?.machineGunAmmo == 150, "Common bullet cap assigns150 even if ammo was already240")

        // Landing removes the box without any pickup; exact equality survives.
        supply = Beach2000Supply(delay: 200, initialMachineGunAmmo: 150)
        supply.parachutes[0].visible = true
        supply.parachutes[0].position.y = 510
        _ = supply.updateAI(random: zero, terrainHeight: flat, smokeTick: false)
        try check(supply.parachutes[0].visible && supply.parachutes[0].position.y == 500, "Ground comparison is strictly less")
        let landed = supply.updateAI(random: zero, terrainHeight: flat, smokeTick: false)
        try check(landed == [.parachuteLanded(objectID: 212, position: Vector(x: 0, y: 490, z: 0))], "Uncollected box disappears at ground")
        try check(!supply.ammunitionCollected && !supply.defenseCollected, "Landing grants no automatic reward")

        // Flat 40 m release through actual open, descent and natural landing.
        // On the same trajectory the original has 351 ticks; modern cargo 637.
        for (motion, expected) in [(SupplyDescent.original,351),(.depthlineCargo,637)] {
            var cargo=Beach2000Supply(delay:1,initialMachineGunAmmo:150,cargoDescent:motion)
            cargo.plane.position=Vector(x:2000,y:4000,z:0)
            _=release(&cargo); cargo.plane.visible=false
            var airborne=0
            repeat {
                _=cargo.updateAI(random:zero,terrainHeight:flat,smokeTick:false);airborne+=1
            } while cargo.parachutes[0].visible && airborne<1000
            try check(airborne==expected,"Uncollected 40 m cargo landing time for \(motion)")
        }
        var overlap=Beach2000Supply(delay:1,initialMachineGunAmmo:150,cargoDescent:.depthlineCargo)
        overlap.plane.position=Vector(x:2000,y:4000,z:0)
        _=release(&overlap);_=release(&overlap);overlap.plane.visible=false
        try check(overlap.updateScheduler().isEmpty,"Two live boxes reserve both slots")
        try check(overlap.collect(objectID:212,by:.commonBullet,machineGunAmmo:15,defense:10)?.defense==35,
                  "Older health box keeps its reward after ammo drop")
        try check(overlap.updateScheduler()==[.planeActivated],"A freed slot releases the waiting flight")
        try check(overlap.collect(objectID:213,by:.commonBullet,machineGunAmmo:15,defense:10)?.machineGunAmmo==115,
                  "Overlapping second box preserves its own ammo reward")

        // Damage persists across passes; active flight does not stop the timer.
        supply = fixture(.outbound, Vector(x: 30001, y: 4000, z: 0))
        _ = supply.hitPlane(by: .commonBullet(part: 0))
        for _ in 0..<201 { _ = supply.updateScheduler() }
        try check(supply.plane.hp == 6 && supply.countdown == -1, "HP persists and active-flight timer continues")
        try check(supply.updateAI(random: zero, terrainHeight: flat, smokeTick: false) == [.planeDeparted], "Departure outside30000")
        try check(supply.updateScheduler() == [.planeActivated] && supply.plane.hp == 6, "Overdue next pass keeps damaged HP")
        supply = fixture(.outbound, Vector(x: 30000, y: 4000, z: 0))
        _ = supply.updateAI(random: zero, terrainHeight: flat, smokeTick: false)
        try check(supply.plane.visible, "At exactly30000 does not depart")

        // Common hits use part-based damage and defer score to next AI tick.
        supply = fixture(.inbound)
        _ = supply.hitPlane(by: .commonBullet(part: 2))
        _ = supply.hitPlane(by: .commonBullet(part: 1))
        _ = supply.hitPlane(by: .commonBullet(part: 3))
        try check(supply.plane.hp == 5, "Part2 costs1, part1 costs2, part3 costs0")
        supply.plane.hp = 1
        try check(supply.hitPlane(by: .commonBullet(part: 0)).isEmpty && supply.plane.hp == -1,
                  "Fatal common hit may leave negative HP and no immediate score event")
        try check(supply.plane.state == .beginCrash && supply.plane.visible, "Bullet kill keeps aircraft visible")
        let doomed = supply.updateAI(random: zero, terrainHeight: flat, smokeTick: false)
        try check(doomed == [.scoreChanged(-10)] && supply.plane.state == .crashing, "Crash initiation charges score next tick")
        try check(close(supply.plane.pitch, -0.04) && supply.plane.position.y < 4000, "Pitch smoothing produces downward flight")
        let continued = supply.updateAI(random: zero, terrainHeight: flat, smokeTick: false)
        try check(continued.isEmpty, "Ordinary continued crash does not repeat score penalty")
        let destroyed = supply.hitPlane(by: .cannon)
        try check(destroyed.contains(.scoreChanged(-10)) && !supply.plane.visible && supply.plane.hp == 0,
                  "Original cannon branch can impose a second penalty on a crashing plane")
        for _ in 0..<1000 { try check(supply.updateScheduler().isEmpty, "Destroyed C130 never returns this level") }
        try check(supply.hitPlane(by: .missile).isEmpty, "Invisible plane cannot take another hit")

        // Direct missile destruction does not run the bullet crash state.
        supply = fixture(.inbound)
        let missileEvents = supply.hitPlane(by: .missile)
        try check(missileEvents.count == 2 && missileEvents.contains(.scoreChanged(-10)) && !supply.plane.visible,
                  "Missile immediately destroys and penalizes")
        try check(supply.updateAI(random: zero, terrainHeight: flat, smokeTick: false).isEmpty,
                  "Direct kill cannot issue deferred bullet penalty")

        // Crash smoke uses three RNG draws; ground event reports pre-move pose.
        supply = fixture(.crashing, Vector(x: 0, y: 109, z: 0))
        supply.plane.hp = 0
        sequence = [0, 32767, 16384]
        let crash = supply.updateAI(random: { sequence.removeFirst() }, terrainHeight: { _,_ in 10 }, smokeTick: true)
        try check(sequence.isEmpty && crash.first == .smoke(position: Vector(x: -64, y: 140, z: 0)), "Original smoke offsets and draw order")
        try check(crash.contains(.planeCrashed(position: Vector(x: 0, y: 109, z: 0))) && !supply.plane.visible,
                  "Crash threshold uses terrain+100 before movement")
        supply = fixture(.crashing, Vector(x: 15000, y: 100, z: 0))
        _ = supply.updateAI(random: zero, terrainHeight: { _,_ in 9999 }, smokeTick: false)
        try check(supply.plane.visible, "At terrain boundary15000 crash uses sea0 and strict100 threshold")

        // Check transform handedness independently with cardinal directions.
        supply = fixture(.outbound)
        supply.plane.yaw = 90
        _ = supply.updateAI(random: zero, terrainHeight: flat, smokeTick: false)
        try check(close(supply.plane.position.x, -140) && close(supply.plane.position.z, 0), "Yaw90 flies negativeX")
        supply = fixture(.outbound)
        supply.plane.pitch = 90
        _ = supply.updateAI(random: zero, terrainHeight: flat, smokeTick: false)
        try check(close(supply.plane.position.y, 4140), "Positive pitch climbs in original matrix convention")

        // Public API long run: a real RNG, original Delay200, multiple flights.
        supply = Beach2000Supply(delay: 200, initialMachineGunAmmo: 150)
        rng = Random(seed: 42)
        var releasedIDs: [Int] = []
        for tick in 0..<5000 {
            let events = supply.updateAI(random: { rng.next() }, terrainHeight: flat, smokeTick: tick % 2 == 0)
            for event in events {
                if case .parachuteReleased(let objectID, _) = event { releasedIDs.append(objectID) }
            }
            _ = supply.updateScheduler()
            try check(supply.plane.position.x.isFinite && supply.plane.position.y.isFinite && supply.plane.position.z.isFinite,
                      "Long-flight transform remains finite")
        }
        try check(releasedIDs.count >= 3 && releasedIDs.enumerated().allSatisfy { $0.element == 212 + $0.offset % 2 },
                  "Real scheduler repeatedly visits and alternates original object slots")
    }
}

#if BEACH2000_SUPPLY_TESTS
@main
private struct Beach2000SupplyTestRunner {
    static func main() throws {
        try Beach2000Supply.runTests()
        print("PASS: BH2000 supply RNG, scheduling, source flight, drops, shared rewards, damage and crash rules")
    }
}
#endif
