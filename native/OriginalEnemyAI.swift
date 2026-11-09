import Foundation

/// BH2002 ground vehicles, Cobra, Jet and CH53 updates from FUN_004051c8.
/// Coordinates are original world units, rotations degrees, velocities per original tick.
/// Rendering converts positions by0.01 and angles by.pi/180. This module emits projectiles;
/// it never applies periodic automatic damage to the player.
final class OriginalEnemyAI {
    struct Random {
        private(set) var state: UInt32
        init(seed: UInt32) { state = seed }
        mutating func next() -> UInt32 {
            state = state &* 214013 &+ 2531011
            return (state >> 16) & 0x7fff
        }
    }
    enum ShotKind: String { case bullet, shell, rocket, bomb }
    struct Shot {
        let kind: ShotKind
        let origin: SIMD3<Double>
        let velocity: SIMD3<Double>
        let gravityPerTick: Double
        let lifetimeTicks: Int?
        let damage: Int
        let playerHitRadius: Double
        let originalEmitterObject: Int
        let bombHorizontalSpeed: Double?
        let bombForward: SIMD3<Double>?
        var velocityPerTick: SIMD3<Double> { velocity }
        init(kind: ShotKind, origin: SIMD3<Double>, velocity: SIMD3<Double>, gravityPerTick: Double,
             lifetimeTicks: Int?, damage: Int, playerHitRadius: Double, originalEmitterObject: Int,
             bombHorizontalSpeed: Double? = nil, bombForward: SIMD3<Double>? = nil) {
            self.kind = kind; self.origin = origin; self.velocity = velocity
            self.gravityPerTick = gravityPerTick; self.lifetimeTicks = lifetimeTicks
            self.damage = damage; self.playerHitRadius = playerHitRadius
            self.originalEmitterObject = originalEmitterObject
            self.bombHorizontalSpeed = bombHorizontalSpeed; self.bombForward = bombForward
        }
    }
    struct Trooper {
        let position: SIMD3<Double>
        let direction: SIMD3<Double>
        let speedPerTick: Double
        let initialState: Int
        // REA assembly0x40739e/0x40fc61: Int(unloadOffset)-130(APC)/310(CH53).
        let initialDelay: Int?
    }
    enum Event {
        case fire(Shot)
        case smoke(position: SIMD3<Double>, scale: Double)
        case cargo([Trooper])
        case terminal(force: Double, shieldDamage: Int)
    }
    struct Neighbor {
        let type: String
        let slot: Int
        let position: SIMD3<Double>
    }
    struct Update {
        let position: SIMD3<Double>
        let eulerDegrees: SIMD3<Double>
        let turretYawDegrees: Double
        let barrelPitchDegrees: Double
        let rampPitchDegrees: Double
        let state: Int
        let cargoLoaded: Bool
        let isActive: Bool
        let events: [Event]
    }
    static let supportedTypes = ["TANK", "APC1", "APC2", "APC3", "COBRA", "JET", "CH53"]
    let type: String
    let slot: Int
    let originalObjectIndex: Int
    private let direction: String?
    private let groundAggression: Int
    private let cobraAggression: Int
    private let jetAggression: Int
    private var randomState: Random
    private(set) var position = SIMD3<Double>(repeating: 0)
    private(set) var eulerDegrees = SIMD3<Double>(repeating: 0)
    private(set) var turretYawDegrees = 0.0
    private(set) var barrelPitchDegrees = 0.0
    private(set) var rampPitchDegrees = 0.0
    private(set) var state = 1
    private(set) var cargoLoaded = false
    private(set) var isActive = true
    private(set) var initialized = false
    private(set) var speedPerTick = 0.0
    private var acceleration = 0.0
    private var steering = 0.0
    private var steeringTarget = 0.0
    private var pitchOffset = 0.0
    private var pitchTarget = 0.0
    private var verticalSpeed = 0.0
    private var terrainLift = 0.0
    var helicopterAltitude: ((SIMD3<Double>, Double, Double, Bool, inout Double) -> Double)?
    var helicopterGround: ((Double, Double) -> Double)?
    private var verticalTarget = 0.0
    private var fallingSpeed = 0.0
    private var target = SIMD3<Double>(repeating: 0)
    private var counter = 0
    private var unloadCountdown = 0
    private var elevationDirectionCounter = 0
    private var missileCount = 2
    private var bombCount: Int
    private var rollSpeed = 0.0
    private var tickCount = 0
    private var currentGlobalParity = 0
    private var hoverPhases = SIMD4<Double>.zero
    private var rocketSide = 1.0
    private var pendingFires: [Int] = []

    init?(type: String, slot: Int, direction: String?, aggression: [Int], seed: UInt32 = 1,
          initialBombCount: Int = 0) {
        let type = type.uppercased()
        guard Self.supportedTypes.contains(type) else { return nil }
        let capacity = ["TANK": 12, "APC1": 4, "APC2": 4, "APC3": 4, "JET": 16, "COBRA": 12, "CH53": 8][type]!
        guard (0..<capacity).contains(slot) else { return nil }
        self.type = type; self.slot = slot; self.direction = direction
        self.originalObjectIndex = (["TANK": 37, "APC1": 73, "APC2": 77, "APC3": 81, "JET": 117, "COBRA": 142, "CH53": 178][type] ?? 0) + slot
        self.groundAggression = 320 + (aggression.indices.contains(0) ? aggression[0] : 0)
        self.cobraAggression = 40 + (aggression.indices.contains(2) ? aggression[2] : 0)
        self.jetAggression = 500 + (aggression.indices.contains(1) ? aggression[1] : 0)
        self.bombCount = initialBombCount
        self.randomState = Random(seed: seed)
    }

    /// Damage ownership remains with OriginalDamage. Call for a Cobra's recovered crash state14.
    /// Its force10 is removed when it reaches the ground, through terminal, not twice on the hit.
    func beginCrash() {
        guard isActive else { return }
        let start = type == "JET" ? 15 : type == "CH53" ? 13 : 14
        if ["JET", "CH53", "COBRA"].contains(type), state < start { state = start }
    }
    func remove() { isActive = false }
    /// Preserve active state0 hulls. Tank first destruction sets forward acceleration
    /// to-1 and barrel pitch to-20 without clearing current speed (0x4154b7).
    func applyDamageState(_ state: Int, active: Bool, cargoLoaded: Bool? = nil) {
        if type == "TANK",self.state != 0,state == 0 {
            acceleration = -1;barrelPitchDegrees = -20
        }
        self.state = state; self.isActive = active
        if let cargoLoaded { self.cargoLoaded = cargoLoaded }
    }
    var landingTarget: SIMD3<Double>? { type == "CH53" && state > 2 ? target : nil }

    /// terrainHeight returns original-unit bilinear height; material reads the original MMap byte.
    /// neighbors should contain all active Tank/APC hulls. A shared RNG callback is supported,
    /// though full original replay also requires matching global object/effect call order.
    func tick(terrainHeight: (Double, Double) -> Double,
              terrainMaterial: (Double, Double) -> UInt8 = { _, _ in 0 },
              neighbors: [Neighbor] = [], earlierLandingTargets: [SIMD3<Double>] = [],
              random: (() -> UInt32)? = nil, globalParity: Int? = nil,
              hoverPhasesDegrees: SIMD4<Double>? = nil, deferSharedPhases: Bool = false) -> Update {
        guard isActive else { return snapshot(events: []) }
        let rng: () -> Int = {
            Int((random?() ?? self.randomState.next()) & 0x7fff)
        }
        // The host should supply the shared original loop parity, especially
        // for objects spawned after tick0. Local fallback is for isolated tests.
        currentGlobalParity = (globalParity ?? tickCount) & 1
        tickCount += 1; pendingFires.removeAll(keepingCapacity: true)
        hoverPhases = hoverPhasesDegrees ?? SIMD4(4.1, 6, 9.5, 12.2) * Double(tickCount)
        var events: [Event] = []
        if type == "COBRA" {
            updateCobra(random: rng, height: terrainHeight, events: &events)
            if initialized, isActive, state < 14, let helicopterAltitude {
                position.y = helicopterAltitude(position, eulerDegrees.y, speedPerTick, false, &terrainLift)
            }
        } else if type == "JET" {
            updateJet(random: rng, height: terrainHeight, events: &events)
        } else if type == "CH53" {
            updateCH53(random: rng, height: terrainHeight, material: terrainMaterial,
                       earlierLandingTargets: earlierLandingTargets, events: &events)
            if initialized, isActive, state < 13, let helicopterAltitude {
                let approach = (5...6).contains(state) && hypot(target.x-position.x,target.z-position.z)<4830
                let landing = approach || (7...10).contains(state)
                position.y = helicopterAltitude(position,eulerDegrees.y,speedPerTick,landing,&terrainLift)
            }
        } else {
            updateGround(random: rng, material: terrainMaterial, events: &events)
            if initialized {
                moveGround()
                if !deferSharedPhases {
                    avoidGroundObstacles(neighbors: neighbors, random: rng)
                    alignGround(height: terrainHeight)
                }
            }
        }
        if isActive && initialized && !deferSharedPhases {
            for flag in pendingFires { events.append(.fire(makeShot(flag: flag, random: rng))) }
            // The original global object transform pass adds angular velocity after projectiles.
            eulerDegrees.z += rollSpeed
        }
        return snapshot(events: events)
    }

    /// Separate source loops: all hulls move before avoidance, and terrain
    /// alignment follows infantry. These must not run per hull inline.
    var isDyingAircraft: Bool {
        guard isActive else { return false }
        switch type {
        case "COBRA": return (14...15).contains(state)
        case "JET": return (15...16).contains(state)
        case "CH53": return (13...14).contains(state)
        default: return false
        }
    }
    var isGroundVehicle: Bool { type == "TANK" || type.hasPrefix("APC") }
    var hasPendingShots: Bool { !pendingFires.isEmpty }
    func finishGroundAvoidance(neighbors: [Neighbor], random: () -> UInt32) -> Update {
        if isActive && initialized && isGroundVehicle {
            avoidGroundObstacles(neighbors: neighbors, random: { Int(random() & 0x7fff) })
        }
        return snapshot(events: [])
    }
    func finishGroundAlignment(terrainHeight: (Double, Double) -> Double) -> Update {
        if isActive && initialized && isGroundVehicle { alignGround(height: terrainHeight) }
        return snapshot(events: [])
    }
    func advanceObjectTransform() -> Update {
        if isActive && initialized { eulerDegrees.z += rollSpeed }
        return snapshot(events: [])
    }
    /// Launch flags survive destruction in the preceding projectile pass, just
    /// as the emitter flags in the source object array do. Consume them once.
    func takeShots(random: () -> UInt32) -> [Shot] {
        let flags = pendingFires; pendingFires.removeAll(keepingCapacity: true)
        return flags.map { makeShot(flag: $0, random: { Int(random() & 0x7fff) }) }
    }

    private func snapshot(events: [Event]) -> Update {
        Update(position: position, eulerDegrees: eulerDegrees, turretYawDegrees: turretYawDegrees,
               barrelPitchDegrees: barrelPitchDegrees, rampPitchDegrees: rampPitchDegrees,
               state: state, cargoLoaded: cargoLoaded, isActive: isActive && initialized, events: events)
    }
    private func spawnHeading(random: () -> Int) -> Double {
        switch direction?.lowercased() {
        case "north": return 180
        case "south": return 0
        case "east": return 90
        case "west": return 270
        default: return [180.0, 0, 90, 270][random() >> 13]
        }
    }
    private func spawnGround(random: () -> Int, material: (Double, Double) -> UInt8) -> Bool {
        let heading = spawnHeading(random: random)
        for _ in 0..<512 { // Native guard against a corrupt/all-blocked map; retry state1 next tick.
            var x: Double, z: Double
            if heading == 90 || heading == 270 {
                x = Double(random() >> 4) + 7500
                z = Double(random() >> 1) - 8192
                if heading == 270 { x = -x }
            } else {
                x = Double(random() >> 1) - 8192
                z = Double(random() >> 4) + 7500
                if heading == 180 { z = -z }
            }
            if material(x, z) < 32 {
                position = SIMD3(x, 0, z); eulerDegrees.y = wrap(heading)
                initialized = true; return true
            }
        }
        return false
    }
    private func updateGround(random: () -> Int, material: (Double, Double) -> UInt8, events: inout [Event]) {
        let tank = type == "TANK"
        switch state {
        case 0: break // APC1 stays parked with its ramp open after unloading.
        case 1:
            guard spawnGround(random: random, material: material) else { return }
            if !tank { cargoLoaded = true; missileCount = 2 }
            state = 2
        case 2:
            if !tank { unloadCountdown = (random() >> 8) + 400 }
            acceleration = 0.5; state = 3
        case 3:
            let chance = random() >> 6
            if tank ? (chance == 310 || chance == 311) : (chance == 320 || chance == 321) {
                steeringTarget = Double(random() >> 11) - 7.5
                counter = (random() >> 9) + 30; state = 6
            }
            if tank && chance > 319 && chance <= groundAggression { acceleration = -0.5; state = 7 }
            if abs(position.x) > 10000 || abs(position.z) > 10000 {
                target = SIMD3(Double(random() >> 3) - 2048, 0, Double(random() >> 3) - 2048)
                steeringTarget = headingError(to: target) < 0 ? -24 : 24; state = 4
            } else if !tank && cargoLoaded {
                unloadCountdown -= 1
                if unloadCountdown < 0 || hypot(position.x, position.z) < 2800 { state = 7 }
            } else if !tank && state != 6 {
                if type == "APC3" && missileCount > 0 {
                    let attack = random() >> 6
                    if attack > 159 && attack < 164 { acceleration = -0.5; state = 12 }
                } else if type == "APC2" {
                    let attack = random() >> 6
                    if attack > 319 && attack <= groundAggression { acceleration = -0.5; state = 12 }
                }
            }
        case 4:
            if headingDot(to: target) > 0.99 { state = 5; steeringTarget = 0 }
            if tank { centerTurret(pitchStep: 0.5) }
        case 5:
            // Assembly0x405a61–0x405ab1 confirms original fabs(bool(z<10000)).
            if abs(position.x) < 10000 && position.z < 10000 { state = 3 }
        case 6:
            counter -= 1
            if counter == 0 { steeringTarget = 0; state = 3 }
        case 7:
            if tank {
                if speedPerTick == 0 { target = SIMD3(0, 860, 0); state = 8 }
            } else if abs(position.x) > 10000 || abs(position.z) > 10000 { state = 3 }
            else { acceleration = -0.5; state = 8 }
        case 8:
            if tank { aimTurret(nextState: 9) }
            else if speedPerTick == 0 { state = 9 }
        case 9:
            if tank { aimElevation(nextState: 10, wait: 75) }
            else {
                rampPitchDegrees += 2
                if rampPitchDegrees == 120 {
                    counter = 90; cargoLoaded = false; state = 10
                    let forward = flatForward
                    let troops = (0..<6).map { i in
                        Trooper(position: position + SIMD3(0, 40, 0) - forward * Double(110 - i * 60),
                                direction: -forward, speedPerTick: 6, initialState: 9, initialDelay: 110 - i * 60 - 130)
                    }
                    events.append(.cargo(troops))
                }
            }
        case 10:
            counter -= 1
            if tank && counter == 15 { pendingFires.append(1) }
            if counter == 0 { state = tank || type != "APC1" ? 11 : 0 }
        case 11:
            if tank { acceleration = 0.5; state = 3 }
            else {
                rampPitchDegrees -= 2
                if rampPitchDegrees == 0 { acceleration = 0.5; state = 3 }
            }
        case 12:
            if !tank && speedPerTick == 0 { target = SIMD3(0, type == "APC3" ? 840 : 860, 0); state = 13 }
        case 13: aimTurret(nextState: 14)
        case 14: aimElevation(nextState: type == "APC3" ? 18 : 15, wait: 60)
        case 15:
            counter -= 1
            if [20, 18, 16, 14].contains(counter) { pendingFires.append(1) }
            if counter == 0 { state = 16 }
        case 16: acceleration = 0.5; state = 3
        case 17: break // Vehicle avoidance is handled after movement, as in the original.
        case 18:
            counter -= 1
            if counter == 20 { missileCount -= 1; pendingFires.append(2) }
            if counter == 0 { state = 16 }
        default: break
        }
    }
    private func aimTurret(nextState: Int) {
        let difference = wrap(headingError(to: target) - turretYawDegrees)
        if abs(difference) <= 0.25 { elevationDirectionCounter = 0; state = nextState }
        else { turretYawDegrees += clamp(difference, -1.5, 1.5) }
    }
    private var gunPivot: SIMD3<Double> {
        let offset = type == "TANK" ? SIMD3(0.0, 119, -110) :
                     type == "APC2" ? SIMD3(0.0, 175.5, -47) : SIMD3(0.0, 192, 0)
        return position + rotate(rotate(offset, pitch: 0, yaw: turretYawDegrees, roll: 0),
                                 pitch: eulerDegrees.x, yaw: eulerDegrees.y, roll: eulerDegrees.z)
    }
    private var barrelForward: SIMD3<Double> {
        let local = forward(pitch: barrelPitchDegrees, yaw: turretYawDegrees)
        return rotate(local, pitch: eulerDegrees.x, yaw: eulerDegrees.y, roll: eulerDegrees.z)
    }
    private func aimElevation(nextState: Int, wait: Int) {
        let desired = unit(target - gunPivot)
        let barrel = barrelForward
        if dot(desired, barrel) >= 0.9996 { counter = wait; state = nextState; return }
        let old = elevationDirectionCounter
        if desired.y <= barrel.y { barrelPitchDegrees -= 0.5; elevationDirectionCounter -= 1 }
        else { barrelPitchDegrees += 0.5; elevationDirectionCounter += 1 }
        // Source unsigned comparison detects the elevation step crossing its direction history.
        if old != 0 && UInt32(bitPattern: Int32(elevationDirectionCounter)) < UInt32(bitPattern: Int32(old)) {
            counter = wait; state = nextState
        }
    }
    private func centerTurret(pitchStep: Double) {
        turretYawDegrees -= clamp(turretYawDegrees, -1.5, 1.5)
        if barrelPitchDegrees > 1 { barrelPitchDegrees -= pitchStep }
        else if barrelPitchDegrees < -1 { barrelPitchDegrees += pitchStep }
        else { barrelPitchDegrees = 0 }
    }
    private func moveGround() {
        steering = steeringTarget * 0.1 + steering * 0.9
        eulerDegrees.y = wrap(eulerDegrees.y + steering * speedPerTick * 0.0035)
        speedPerTick += acceleration
        if speedPerTick > 20 { speedPerTick = 20; acceleration = 0 }
        if speedPerTick < 0 { speedPerTick = 0; acceleration = 0 }
        position += flatForward * speedPerTick
        if state == 3 && (type == "TANK" || type == "APC2" || type == "APC3") { centerTurret(pitchStep: 1) }
    }
    private func avoidGroundObstacles(neighbors: [Neighbor], random: () -> Int) {
        let avoidState = type == "TANK" ? 12 : 17
        guard state == 3 || state == avoidState else { return }
        var obstacles = neighbors.filter { ["TANK", "APC1", "APC2", "APC3"].contains($0.type) && !($0.type == type && $0.slot == slot) }
            .map { ($0.position, 0.95) }
        for x in [-200.0, 200] { for z in [-200.0, 200] { obstacles.append((SIMD3(x, 0, z), 0.9)) } }
        var blocked = false
        for (point, threshold) in obstacles {
            let delta = point - position
            let distance = hypot(delta.x, delta.z)
            if abs(delta.x) < 1500 && abs(delta.z) < 1500 && distance > 0 &&
                (flatForward.x * delta.x + flatForward.z * delta.z) / distance > threshold {
                blocked = true
                if state != avoidState { steeringTarget = random() < 16384 ? -12 : 12; state = avoidState }
            }
        }
        if !blocked && state == avoidState { steeringTarget = 0; state = 3 }
    }
    private func alignGround(height: (Double, Double) -> Double) {
        let yaw = eulerDegrees.y * .pi / 180, s = sin(yaw), c = cos(yaw)
        func h(_ x: Double, _ z: Double) -> Double { height(position.x + s * z + c * x, position.z + c * z - s * x) }
        let fr = h(100, -150), fl = h(-100, -150), bl = h(-100, 150), br = h(100, 150)
        eulerDegrees.x = atan2((fr + fl - br - bl) * 0.5, 300) * 180 / .pi
        eulerDegrees.z = atan2((fr + br - fl - bl) * 0.5, 200) * 180 / .pi
        position.y = (fr + fl + bl + br) * 0.25
    }

    private func updateCobra(random: () -> Int, height: (Double, Double) -> Double, events: inout [Event]) {
        switch state {
        case 0: isActive = false; return
        case 1:
            position.y = Double(random() >> 5) + 1500
            let lateral = Double(random() >> 1) - 8192, distance = Double(random() >> 1) + 32000
            eulerDegrees = SIMD3(0, wrap(spawnHeading(random: random)), 0)
            let yaw = eulerDegrees.y * .pi / 180
            position.x = cos(yaw) * lateral + sin(yaw) * distance
            position.z = cos(yaw) * distance - sin(yaw) * lateral
            speedPerTick = 140; acceleration = 0; state = 2; initialized = true
        case 2:
            let chance = random() >> 7
            if chance == 20 && abs(position.x) < 15000 && abs(position.z) < 15000 {
                steeringTarget = Double(random() >> 13) - 1.5; counter = (random() >> 7) + 30; state = 5
            }
            if chance == 30 {
                target.y = Double(random() >> 5) + 1000
                verticalTarget = target.y <= position.y ? -1 : 1; state = 6
            }
            if chance > 39 && chance <= cobraAggression && abs(position.x) <= 12000 &&
                position.z <= 3000 && position.z >= -12000 &&
                (abs(position.x) > 4000 || abs(position.z) > 4000) && speedPerTick >= 130 {
                target.x = 0; target.z = 0; steeringTarget = headingError(to: target) < 0 ? -2 : 2
                pitchTarget = 25; acceleration = -2; state = 11
            }
            if chance > 49 && chance < 54 && (abs(position.x) > 10000 || abs(position.z) > 10000) && speedPerTick >= 130 {
                target.x = 0; target.z = 0; steeringTarget = headingError(to: target) < 0 ? -2 : 2
                counter = 150; state = 9
            }
        case 3:
            if headingDot(to: target) > 0.98 { state = 4; steeringTarget = 0 }
        case 4:
            if abs(position.x) < 20000 && abs(position.z) < 20000 { state = 2 }
        case 5:
            counter -= 1; if counter == 0 { state = 2; steeringTarget = 0 }
        case 6:
            // Assembly0x40d872–0x40d8dd confirms opposite <= branches, hence one-tick exit.
            verticalTarget = 0; state = 2
        case 7:
            counter -= 1
            if counter == 0 { counter = 60; acceleration = 2; pitchTarget = -25; state = 8 }
        case 8:
            counter -= 1; if counter == 0 { state = 2 }
        case 9:
            counter -= 1
            if counter == 0 { steeringTarget = 0; state = 2 }
            else { aimCobra(nextState: 10, random: random) }
        case 10:
            if counter & 7 == 0 { pendingFires.append(2) }
            counter -= 1; if counter == 0 { state = 2 }
        case 11: aimCobra(nextState: 12, random: random)
        case 12:
            counter -= 1
            if counter == 0 {
                target = SIMD3(Double(random() >> 7) - 128, Double(random() >> 7) + 672, Double(random() >> 7) - 128)
                counter = (random() >> 10) + 16; state = 13
            }
        case 13:
            if counter & 3 == 0 { pendingFires.append(1) }
            counter -= 1
            if counter == 0 { counter = 60; acceleration = 2; pitchTarget = -25; state = 8 }
        case 14:
            acceleration = -1; verticalTarget = -1
            steeringTarget = Double(random() >> 13); pitchTarget = Double((random() >> 10) - 16)
            fallingSpeed = 0; state = 15
        case 15:
            emitWreckSmoke(scale: 0.4, random: random, events: &events)
            fallingSpeed -= 1; position.y += fallingSpeed
            let ground = helicopterGround?(position.x,position.z) ?? (abs(position.x) < 15000 && abs(position.z) < 15000 ? height(position.x, position.z) : 0)
            if position.y < ground + 200 {
                isActive = false
                events.append(.terminal(force: 10, shieldDamage: abs(position.x) < 300 && abs(position.z) < 300 ? 5 : 0))
                return
            }
        default: break
        }
        guard initialized else { return }
        steering = steeringTarget * 0.05 + steering * 0.95
        pitchOffset = pitchTarget * 0.05 + pitchOffset * 0.95
        if !(9...10).contains(state) && abs(pitchOffset) > 22 { pitchTarget = 0 }
        eulerDegrees.x = speedPerTick * -0.05 + pitchOffset
        let oldYaw = eulerDegrees.y
        eulerDegrees.y = wrap(eulerDegrees.y + steering)
        eulerDegrees.z = (eulerDegrees.y - oldYaw) * speedPerTick * 0.215
        if speedPerTick < 30 {
            let f = 1 / (speedPerTick + 1)
            let a = sin(hoverPhases.x * .pi / 180), b = sin(hoverPhases.y * .pi / 180)
            let c = sin(hoverPhases.z * .pi / 180), d = sin(hoverPhases.w * .pi / 180)
            eulerDegrees.z += (c + d) * f * 2; eulerDegrees.x += (a + c + b) * f * 1.5
            position += SIMD3((a + c) * f * 2, (a + b) * f * 2, (b + c) * f * 2)
        }
        let heading = forward(pitch: eulerDegrees.x, yaw: eulerDegrees.y)
        speedPerTick += acceleration
        if speedPerTick > 140 { speedPerTick = 140; acceleration = 0 }
        if speedPerTick < 0 { speedPerTick = 0; acceleration = 0 }
        verticalSpeed = verticalTarget * 0.1 + verticalSpeed * 0.9
        position.x += heading.x * speedPerTick; position.z += heading.z * speedPerTick
        position.y += heading.y * verticalSpeed
        if state == 2 && (abs(position.x) > 20000 || abs(position.z) > 20000) {
            state = 3; steeringTarget = random() < 16385 ? -2 : 2
            target.x = Double(random() >> 4) - 1024; target.z = Double(random() >> 4) - 1024
        }
    }
    private func aimCobra(nextState: Int, random: () -> Int) {
        let error = headingError(to: target)
        if abs(error) < 0.5 {
            steeringTarget = 0; steering = 0; eulerDegrees.y = heading(to: target)
            state = nextState; counter = nextState == 10 ? 34 : (random() >> 9) + 60
        } else if abs(error) < 32 { steering = error * 0.0625 }
    }

    private func spawnAircraft(altitude: Double, speed: Double, random: () -> Int) {
        let lateral = Double(random() >> 1) - 8192, distance = Double(random() >> 1) + 32000
        eulerDegrees = SIMD3(0, wrap(spawnHeading(random: random)), 0)
        let yaw = eulerDegrees.y * .pi / 180
        position = SIMD3(cos(yaw) * lateral + sin(yaw) * distance, altitude,
                         cos(yaw) * distance - sin(yaw) * lateral)
        speedPerTick = speed; acceleration = 0; initialized = true; state = 2
    }

    private func updateJet(random: () -> Int, height: (Double, Double) -> Double, events: inout [Event]) {
        switch state {
        case 0: isActive = false; return
        case 1:
            let altitude = Double(random() >> 3) + 2000, speed = Double(random() >> 10) + 160
            spawnAircraft(altitude: altitude, speed: speed, random: random)
        case 2:
            let chance = random() >> 6, inside = abs(position.x) < 20000 && abs(position.z) < 20000
            if chance == 100 && inside {
                steeringTarget = (Double(random() >> 12) - 3.5) * 0.75
                counter = (random() >> 9) + 30; state = 5
            }
            if chance == 300 && inside {
                steeringTarget = Double(random() >> 13) - 1.5; counter = (random() >> 9) + 30; state = 7
                if position.y > 6000 { pitchTarget = -1 }; if position.y < 4000 { pitchTarget = 1 }
            }
            if chance == 400 {
                target.y = Double(random() >> 4) + 2000
                pitchTarget = target.y <= position.y ? -1 : 1; state = 8
            }
            if chance > 499 && chance <= jetAggression && (abs(position.x) > 16000 || abs(position.z) > 16000) {
                target = SIMD3(0, 800, 0); steeringTarget = headingError(to: target) < 0 ? -2 : 2
                counter = 180; state = 9
            }
        case 3: if headingDot(to: target) > 0.99 { state = 4; steeringTarget = 0 }
        case 4: if abs(position.x) < 25000 && abs(position.z) < 25000 { state = 2 }
        case 5:
            counter -= 1; if counter == 0 { state = 6; steeringTarget = 0 }
        case 6:
            if abs(eulerDegrees.x) < 0.5 { eulerDegrees.x = 0; state = 2 }
            if abs(eulerDegrees.x) < 5 { eulerDegrees.x *= 0.75; pitchOffset = 0; pitchTarget = 0 }
        case 7:
            if abs(eulerDegrees.x) > 20 { pitchOffset = 0; pitchTarget = 0 }
            if position.y < 2500 { counter = 1 }
            counter -= 1
            if counter < 1 {
                state = 6; steeringTarget = 0
                if eulerDegrees.x > 1 { pitchTarget = -1 }; if eulerDegrees.x < -1 { pitchTarget = 1 }
            }
        case 8:
            if abs(eulerDegrees.x) > 10 { pitchOffset = 0; pitchTarget = 0 }
            if eulerDegrees.x <= 0 && position.y <= target.y { pitchTarget = 1; state = 6 }
            if eulerDegrees.x > 0 && position.y >= target.y { pitchTarget = -1; state = 6 }
        case 9:
            counter -= 1
            if counter == 0 { state = 2; steeringTarget = 0 }
            else {
                let error = headingError(to: target)
                if abs(error) < 0.5 {
                    steeringTarget = 0; steering = 0; eulerDegrees.y = heading(to: target)
                    if random() < 8192 && bombCount != 0 { state = 10; counter = 8 } else { state = 12 }
                } else if abs(error) < 32 { steering = error * 0.0625 }
            }
        case 10: if hypot(target.x - position.x, target.z - position.z) < 12000 { state = 11 }
        case 11:
            if counter & 3 == 0 { pendingFires.append(2); bombCount -= 1 }
            counter -= 1; if counter == 0 { state = 2 }
        case 12:
            let d = target - position, distance = sqrt(dot(d, d))
            let angle = -abs(asin(clamp(d.y / max(distance, 0.0001), -1, 1)))
            pitchTarget = angle - 0.05
            if abs(eulerDegrees.x - angle * 180 / .pi) < 0.5 { pitchOffset = 0; pitchTarget = 0; state = 13 }
            if distance < 6000 || position.y < 1800 { pitchTarget = 1.5; state = 14 }
        case 13:
            if counter & 1 == 0 { pendingFires.append(1) }
            counter -= 1; if counter < 1 { pitchTarget = 1; state = 14 }
            if position.y < 1800 || (eulerDegrees.x < -25 && position.y < 5000) { pitchTarget = 1.5; state = 14 }
        case 14:
            if eulerDegrees.x > 15 { pitchTarget = 0 }
            if position.y > 2200 { pitchTarget = 0; state = 7 }
        case 15:
            steeringTarget = Double(random() >> 13) - 1.5
            pitchTarget = -Double((random() >> 14) + 1)
            rollSpeed = Double(random() >> 11) - 7.5
            state = 16
        case 16:
            emitWreckSmoke(scale: 0.6, random: random, events: &events)
            if eulerDegrees.x < -20 { pitchTarget = 0 }
            let ground = abs(position.x) < 15000 && abs(position.z) < 15000 ? height(position.x, position.z) : 0
            if position.y < ground + 100 {
                isActive = false
                events.append(.terminal(force: 10, shieldDamage: abs(position.x) < 300 && abs(position.z) < 300 ? 5 : 0))
                return
            }
        default: break
        }
        steering = steeringTarget * 0.08 + steering * 0.92
        pitchOffset = pitchTarget * 0.08 + pitchOffset * 0.92
        eulerDegrees.z = steering * 30; eulerDegrees.x += pitchOffset
        eulerDegrees.y = wrap(eulerDegrees.y + steering)
        position += forward(pitch: eulerDegrees.x, yaw: eulerDegrees.y) * speedPerTick
        if state == 2 && (abs(position.x) > 25000 || abs(position.z) > 25000) {
            state = 3; steeringTarget = random() < 16385 ? -2 : 2; pitchTarget = 0
            target.x = Double(random() >> 2) - 4096; target.z = Double(random() >> 2) - 4096
        }
        if position.y < 2240 && state < 12 {
            let ahead = position + flatForward * 4000
            let ground = abs(ahead.x) < 15000 && abs(ahead.z) < 15000 ? height(ahead.x, ahead.z) : 800
            if position.y < ground + 200 { state = 14; pitchTarget = 1; steeringTarget = 0 }
        }
    }

    private func updateCH53(random: () -> Int, height: (Double, Double) -> Double,
                            material: (Double, Double) -> UInt8,
                            earlierLandingTargets: [SIMD3<Double>], events: inout [Event]) {
        func ground() -> Double { helicopterGround?(position.x,position.z) ?? (abs(position.x) < 15000 && abs(position.z) < 15000 ? height(position.x, position.z) : 0) }
        func beginDescent() {
            if counter == 1 { acceleration = -2; pitchTarget = 25; verticalTarget = -2.3; counter = 0 }
        }
        switch state {
        case 0: isActive = false; return
        case 1:
            spawnAircraft(altitude: Double(random() >> 6) + 2500, speed: 140, random: random)
            cargoLoaded = true; rampPitchDegrees = 0
        case 2:
            for _ in 0..<512 {
                let x = (random() >> 6) * 40, z = (random() >> 6) * 40
                let point = SIMD3(Double(x - (x <= 10240 ? 12740 : 7740)), 0,
                                  Double(z - (z <= 10240 ? 12740 : 7740)))
                if material(point.x, point.z) < 32 && earlierLandingTargets.allSatisfy({ hypot($0.x - point.x, $0.z - point.z) >= 1000 }) {
                    target = point; state = 3; break
                }
            }
        case 3: if abs(position.x) < 20000 && abs(position.z) < 20000 { state = 4 }
        case 4:
            if abs(target.x - position.x) < 4800 || abs(target.z - position.z) < 4800 {
                steeringTarget = headingError(to: target) < 0 ? -2 : 2; counter = 1; state = 5
            }
        case 5:
            if hypot(target.x - position.x, target.z - position.z) < 4830 {
                beginDescent()
                if position.y - ground() < 700 { verticalTarget = -0.25; steeringTarget = 0; steering = 0; state = 6; break }
            }
            let error = headingError(to: target)
            if abs(error) < 0.5 { steeringTarget = 0; steering = 0; eulerDegrees.y = heading(to: target); state = 6 }
            else if abs(error) < 32 {
                let desired = error * 0.0625
                steering += clamp(desired - steering, -0.125, 0.125)
            }
        case 6:
            if hypot(target.x - position.x, target.z - position.z) < 4830 {
                beginDescent()
                let g = ground()
                if position.y - g < 338 || (helicopterGround != nil && position.y <= g + 338.001) {
                    position.y = g + 338; counter = 90; speedPerTick = 0
                    verticalTarget = 0; verticalSpeed = 0; state = 7
                } else if position.y - g < 700 { verticalTarget = -0.25 }
            }
        case 7:
            rampPitchDegrees += 2
            if rampPitchDegrees >= 35 {
                let heading = forward(pitch: eulerDegrees.x, yaw: eulerDegrees.y)
                let troops: [Trooper] = (0..<6).map { i in
                    let offset = Double(290 - i * 80)
                    let point = SIMD3<Double>(position.x - heading.x * offset, position.y - 270,
                                              position.z - heading.z * offset)
                    return Trooper(position: point, direction: SIMD3(-heading.x, 0, -heading.z),
                                   speedPerTick: 6, initialState: 5, initialDelay: 290 - i * 80 - 310)
                }
                cargoLoaded = false; events.append(.cargo(troops)); state = 8
            }
        case 8: counter -= 1; if counter == 0 { state = 9 }
        case 9:
            rampPitchDegrees -= 2; if rampPitchDegrees <= 0 { verticalTarget = 1; state = 10 }
        case 10:
            if position.y > 1500 { steeringTarget = eulerDegrees.y > 0 ? -1 : 1; acceleration = 2; pitchTarget = -25; state = 11 }
        case 11:
            if position.y > 4000 { steeringTarget = 0; verticalTarget = 0; state = 12 }
        case 12:
            if abs(position.x) > 60000 || abs(position.z) > 60000 {
                state = 0; isActive = false; events.append(.terminal(force: 0, shieldDamage: 0)); return
            }
        case 13:
            acceleration = -1; verticalTarget = -1
            steeringTarget = Double(random() >> 13); pitchTarget = Double((random() >> 10) - 16)
            fallingSpeed = 0; state = 14
        case 14:
            emitWreckSmoke(scale: 0.4, random: random, events: &events)
            fallingSpeed -= 1; position.y += fallingSpeed
            if position.y < ground() + 300 {
                isActive = false; events.append(.terminal(force: 0, shieldDamage: 0)); return
            }
        default: break
        }
        guard initialized else { return }
        steering = steeringTarget * 0.05 + steering * 0.95
        pitchOffset = pitchTarget * 0.05 + pitchOffset * 0.95
        if abs(pitchOffset) > 22 { pitchTarget = 0 }
        eulerDegrees.x = speedPerTick * -0.05 + pitchOffset
        let oldYaw = eulerDegrees.y
        eulerDegrees.y = wrap(eulerDegrees.y + steering); eulerDegrees.z = (eulerDegrees.y - oldYaw) * 30
        if speedPerTick < 30 && (state < 7 || state > 9) {
            let f = 1 / (speedPerTick + 1)
            let a = sin(hoverPhases.x * .pi / 180), b = sin(hoverPhases.y * .pi / 180)
            let c = sin(hoverPhases.z * .pi / 180), d = sin(hoverPhases.w * .pi / 180)
            eulerDegrees.z += (c + d) * f * 2; eulerDegrees.x += (a + c + b) * f
            position += SIMD3((a + c) * f * 2, (a + b) * f * 2, (b + c) * f * 2)
        }
        let heading = forward(pitch: eulerDegrees.x, yaw: eulerDegrees.y)
        speedPerTick += acceleration
        if speedPerTick > 140 { speedPerTick = 140; acceleration = 0 }
        if speedPerTick < 0 { speedPerTick = 0; acceleration = 0 }
        position.x += heading.x * speedPerTick; position.z += heading.z * speedPerTick
        verticalSpeed = verticalSpeed * 0.9 + verticalTarget; position.y += verticalSpeed
    }

    // FUN_004051c8:2280..2297 Jet,2974..2991 Cobra,4949..4966 CH53.
    // Called in the crash-state switch BEFORE movement and ground collision.
    private func emitWreckSmoke(scale: Double, random: () -> Int, events: inout [Event]) {
        guard currentGlobalParity == 0 else { return }
        let dx = Double((random() >> 8) - 64)
        let dy = Double((random() >> 9) - 32)
        let dz = Double((random() >> 8) - 64)
        events.append(.smoke(position: position + SIMD3(dx, dy, dz), scale: scale))
    }

    private func makeShot(flag: Int, random: () -> Int) -> Shot {
        if type == "JET" {
            let heading = forward(pitch: eulerDegrees.x, yaw: eulerDegrees.y)
            if flag == 2 {
                let origin = position + rotate(SIMD3(rocketSide * 40, 0, 0), pitch: eulerDegrees.x, yaw: eulerDegrees.y, roll: eulerDegrees.z)
                rocketSide = -rocketSide
                return Shot(kind: .bomb, origin: origin, velocity: SIMD3(heading.x * speedPerTick, 0, heading.z * speedPerTick),
                            gravityPerTick: 1.5, lifetimeTicks: nil, damage: 5, playerHitRadius: 500,
                            originalEmitterObject: originalObjectIndex, bombHorizontalSpeed: speedPerTick, bombForward: heading)
            }
            let origin = position + heading * 801 + rotate(SIMD3(0, -50, 0), pitch: eulerDegrees.x, yaw: eulerDegrees.y, roll: eulerDegrees.z)
            let spread = SIMD3(Double(random() >> 9) - 32, Double(random() >> 9) - 32, Double(random() >> 9) - 32)
            return Shot(kind: .bullet, origin: origin, velocity: unit(target + spread - origin) * 500,
                        gravityPerTick: 0.16, lifetimeTicks: nil, damage: 1, playerHitRadius: 300,
                        originalEmitterObject: originalObjectIndex)
        }
        let cobra = type == "COBRA"
        let kind: ShotKind = flag == 2 ? .rocket : type == "TANK" ? .shell : .bullet
        let barrel = cobra ? forward(pitch: eulerDegrees.x, yaw: eulerDegrees.y) : barrelForward
        var origin: SIMD3<Double>
        var aim = barrel
        if cobra {
            if kind == .bullet {
                origin = position + barrel * 601 + rotate(SIMD3(0, -190, 0), pitch: eulerDegrees.x, yaw: eulerDegrees.y, roll: eulerDegrees.z)
                let spread = SIMD3(Double(random() >> 8) - 64, Double(random() >> 8) - 64, Double(random() >> 8) - 64)
                aim = unit(target + spread - origin)
            } else {
                origin = position + rotate(SIMD3(rocketSide * 105, -165, 0), pitch: eulerDegrees.x, yaw: eulerDegrees.y, roll: eulerDegrees.z)
                rocketSide = -rocketSide
            }
        } else if kind == .rocket {
            // Original Launcher has local translation[0,192,0], missile offsets±48X,+65Z.
            let local = rotate(SIMD3(rocketSide * -48, 0, 65), pitch: barrelPitchDegrees, yaw: turretYawDegrees, roll: 0)
            origin = gunPivot + rotate(local, pitch: eulerDegrees.x, yaw: eulerDegrees.y, roll: eulerDegrees.z)
            rocketSide = -rocketSide
        } else { origin = gunPivot + barrel * (kind == .shell ? 241 : 201) }
        let emitter = originalObjectIndex + (cobra ? 0 : type == "TANK" ? 24 : 28)
        return Shot(kind: kind, origin: origin, velocity: aim * (kind == .rocket ? 280 : 500),
                    gravityPerTick: kind == .rocket ? 0 : 0.16,
                    lifetimeTicks: kind == .rocket ? (cobra ? 100 : 130) : nil,
                    damage: kind == .bullet ? 1 : 5,
                    playerHitRadius: kind == .shell ? 250 : 300, originalEmitterObject: emitter)
    }
    private var flatForward: SIMD3<Double> { forward(pitch: 0, yaw: eulerDegrees.y) }
    private func heading(to point: SIMD3<Double>) -> Double { atan2(position.x - point.x, position.z - point.z) * 180 / .pi }
    private func headingError(to point: SIMD3<Double>) -> Double { wrap(heading(to: point) - eulerDegrees.y) }
    private func headingDot(to point: SIMD3<Double>) -> Double {
        let d = point - position, length = hypot(d.x, d.z)
        return length == 0 ? 1 : (flatForward.x * d.x + flatForward.z * d.z) / length
    }
    private func wrap(_ value: Double) -> Double {
        var value = value.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }; if value < -180 { value += 360 }; return value
    }
    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, value)) }
    private func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private func unit(_ value: SIMD3<Double>) -> SIMD3<Double> {
        let length = sqrt(dot(value, value)); return length > 0 ? value / length : SIMD3(0, 0, -1)
    }
    private func forward(pitch: Double, yaw: Double) -> SIMD3<Double> {
        let p = pitch * .pi / 180, y = yaw * .pi / 180
        return SIMD3(-sin(y) * cos(p), sin(p), -cos(y) * cos(p))
    }
    private func rotate(_ v: SIMD3<Double>, pitch: Double, yaw: Double, roll: Double) -> SIMD3<Double> {
        let p = pitch * .pi / 180, y = yaw * .pi / 180, r = roll * .pi / 180
        let a = SIMD3(v.x * cos(r) - v.y * sin(r), v.x * sin(r) + v.y * cos(r), v.z)
        let b = SIMD3(a.x, a.y * cos(p) - a.z * sin(p), a.y * sin(p) + a.z * cos(p))
        return SIMD3(b.x * cos(y) + b.z * sin(y), b.y, b.z * cos(y) - b.x * sin(y))
    }
}

func originalEnemyAISelfTest() throws {
    struct Failure: Error { let reason: String }
    func require(_ value: Bool, _ reason: String) throws { if !value { throw Failure(reason: reason) } }
    for type in OriginalEnemyAI.supportedTypes {
        let ai = OriginalEnemyAI(type: type, slot: 0, direction: "South", aggression: [4, 4, 4, 4], seed: 42)!
        var fires: [String: Int] = [:], cargo: [OriginalEnemyAI.Trooper] = [], terminals = 0
        for _ in 0..<30000 {
            let result = ai.tick(terrainHeight: { _, _ in 0 })
            try require(result.position.x.isFinite && result.position.y.isFinite && result.position.z.isFinite, "\(type) finite movement")
            for event in result.events {
                switch event {
                case .fire(let shot): fires[shot.kind.rawValue, default: 0] += 1
                case .smoke: break
                case .cargo(let troops): cargo += troops
                case .terminal: terminals += 1
                }
            }
        }
        if type.hasPrefix("APC") || type == "CH53" { try require(cargo.count == 6, "\(type) six troops once") }
        if type == "APC1" { try require(ai.state == 0 && ai.isActive && fires.isEmpty, "parked APC1 remains a hull") }
        if type == "APC3" { try require(fires["rocket"] == 2, "APC3 has exactly two rockets") }
        if type == "CH53" {
            try require(terminals == 1 && !ai.isActive, "CH53 unload and departure terminal once")
            try require(cargo.map(\.initialDelay) == [-20, -100, -180, -260, -340, -420], "CH53 assembly unload timers")
        }
        if type == "JET" { try require(fires["bomb"] == nil && (fires["bullet"] ?? 0) > 0, "Jet default bomb count remains zero") }
        if type == "COBRA" || type == "JET" {
            ai.beginCrash(); var force = 0.0
            for _ in 0..<2000 {
                for event in ai.tick(terrainHeight: { _, _ in 0 }).events {
                    if case .terminal(let amount, _) = event { force += amount }
                }
            }
            try require(!ai.isActive && force == 10, "\(type) deferred force exactly once")
        }
    }
    let blocked = OriginalEnemyAI(type: "TANK", slot: 0, direction: "North", aggression: [])!
    try require(!blocked.tick(terrainHeight: { _, _ in 0 }, terrainMaterial: { _, _ in 255 }).isActive,
                "blocked material retries hidden instead of hanging")
    let apc = OriginalEnemyAI(type: "APC1", slot: 0, direction: "West", aggression: [])!
    _ = apc.tick(terrainHeight: { _, _ in 0 })
    apc.applyDamageState(0, active: true, cargoLoaded: false)
    let wreck = apc.tick(terrainHeight: { _, _ in 0 })
    try require(wreck.isActive && !wreck.cargoLoaded && wreck.state == 0, "damage preserves hull without restoring cargo")
    let tank=OriginalEnemyAI(type:"TANK",slot:0,direction:"North",aggression:[])!
    for _ in 0..<20 {_=tank.tick(terrainHeight:{_,_ in 0},random:{16384})}
    let tankSpeed=tank.speedPerTick
    try require(tankSpeed>1,"moving tank fixture")
    tank.applyDamageState(0,active:true)
    try require(tank.speedPerTick==tankSpeed && tank.barrelPitchDegrees == -20,"tank destruction preserves inertia and depresses barrel")
    _=tank.tick(terrainHeight:{_,_ in 0},random:{16384})
    try require(tank.speedPerTick==tankSpeed-1 && tank.isActive,"tank wreck decelerates by one per original tick")
    for _ in 0..<30 {_=tank.tick(terrainHeight:{_,_ in 0},random:{16384})}
    try require(tank.speedPerTick==0 && tank.isActive && tank.state==0,"tank hull settles without disappearing or sinking")
    for type in ["JET", "COBRA", "CH53"] {
        let ai = OriginalEnemyAI(type: type, slot: 0, direction: "North", aggression: [])!
        _ = ai.tick(terrainHeight: { _, _ in 0 }, random: { 16384 }, globalParity: 1)
        ai.beginCrash()
        _ = ai.tick(terrainHeight: { _, _ in 0 }, random: { 16384 }, globalParity: 1)
        let before = ai.position
        let update = ai.tick(terrainHeight: { _, _ in 0 }, random: { 16384 }, globalParity: 0)
        let puffs = update.events.compactMap { event -> (SIMD3<Double>, Double)? in
            if case .smoke(let position, let scale) = event { return (position, scale) }; return nil
        }
        try require(puffs.count == 1 && puffs[0].0 == before && puffs[0].1 == (type == "JET" ? 0.6 : 0.4), "\(type) wreck smoke pre-movement position and source scale")
        let off = ai.tick(terrainHeight: { _, _ in 0 }, random: { 16384 }, globalParity: 1)
        try require(!off.events.contains { if case .smoke = $0 { return true }; return false }, "shared odd parity emits no wreck smoke")
    }
}
