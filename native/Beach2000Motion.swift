import Foundation
import SceneKit

// Beach Head 2000 has a northern sea and a short beach in front of the bunker.
// These deterministic paths follow that recovered terrain arrangement. Speeds,
// berths, maneuver shapes and phase lengths are prototype choices, not a
// reconstruction of the original game's complete AI state machine.
// TEMPORARY PARITY ITEMS (remove only after replacing with binary evidence):
// BH2000-MOTION-01: lane spacing 18, shoreline envelope width 120 / depth 16.4,
// berth offset -6, cargo offset +2.6, spawn z -150-12*variant, retreat 70.
// BH2000-MOTION-02: ship cruise 6 / return 7, acceleration 1.5, stop 6 seconds,
// turn in final 40% of stop, sea pivot 0.12 and bob amplitude 0.035 / rate 1.3.
// BH2000-MOTION-03: ground speeds 1.7 / 2.8 / 3.8, acceleration 1.2 / 1.8,
// target lateral ratios 0.12 / 0.25 and z -6.5 / -11 with 1.2 variant spacing,
// pauses 1.4 / 3, maneuver radius 2.2 / 5.5 and depth 0.7 / 1.4, 1s ramp,
// attack ranges 16 / 35. These are not recovered AI or combat timing values.
// BH2000-MOTION-04: air motion currently reuses the 2002 simplified North path,
// with minimum 12 clearance. Air unit movement requires separate 2000 recovery.
// C130/CH53/BARGE cannot fire through this path, but this DOES NOT make them
// invulnerable or define death penalties. The combat system owns those rules.
struct Beach2000Motion: EnemyPath {
    let type: String
    let index: Int
    let origin: SCNVector3?

    init(type: String, index: Int, origin: SCNVector3? = nil) {
        self.type = type.uppercased()
        self.index = index
        self.origin = origin
    }

    var flying: Bool { ["COBRA", "CH53", "JET", "BOMBER", "C130"].contains(type) }
    private var lane: Double { Double(((index % 5) + 5) % 5 - 2) * 18 }
    private var variant: Int { ((index % 3) + 3) % 3 }
    private var airMotion: EnemyMotion { EnemyMotion(type: type, index: max(0, index), direction: "North") }

    // Approximate shoreline envelope: central surf at -23.6 and outer beach
    // around -40. The actual ground elevation still comes from the heightmap.
    static func shorelineZ(at x: Double) -> Double {
        let edge = min(1, abs(x) / 120)
        return -23.6 - 16.4 * edge * edge
    }

    private var berthX: Double { origin.map { Double($0.x) } ?? lane }
    private var berthZ: Double { Self.shorelineZ(at: berthX) - 6 }
    private var seaStartZ: Double {
        min(origin.map { Double($0.z) } ?? (-150 - Double(variant) * 12), berthZ - 55)
    }
    private var seaExitZ: Double { seaStartZ - 70 }
    private var landingProfile: Travel {
        Travel(distance: berthZ - seaStartZ, speed: 6, acceleration: 1.5)
    }
    private var returnProfile: Travel {
        Travel(distance: berthZ - seaExitZ, speed: 7, acceleration: 1.5)
    }
    private var unloadingDuration: Double { 6 }

    /// Ship age at which it reaches the berth and cargo may be spawned once.
    /// Only meaningful for BARGE; non-vessel paths never unload or exit.
    var unloadTime: Double { type == "BARGE" ? landingProfile.duration : .infinity }
    var departureTime: Double { unloadTime + unloadingDuration }
    var exitTime: Double { type == "BARGE" ? departureTime + returnProfile.duration : .infinity }

    /// Spawn cargo here, ahead of the moored bow, rather than in the sea at the
    /// vessel's center. Pass this as the new vehicle/infantry path's origin.
    func unloadPosition(ground: (CGFloat, CGFloat) -> CGFloat) -> SCNVector3 {
        let x = CGFloat(berthX), z = CGFloat(Self.shorelineZ(at: berthX) + 2.6)
        return SCNVector3(x, ground(x, z), z)
    }

    private var groundStart: (x: Double, z: Double) {
        if let origin = origin { return (Double(origin.x), Double(origin.z)) }
        return (lane, Self.shorelineZ(at: lane) + 2.6)
    }
    private var groundTarget: (x: Double, z: Double) {
        let start = groundStart
        return (start.x * (type == "INFANTRY" ? 0.12 : 0.25),
                (type == "INFANTRY" ? -6.5 : -11) - Double(variant) * 1.2)
    }
    private var groundSpeed: Double { type == "INFANTRY" ? 1.7 : type == "TANK" ? 2.8 : 3.8 }
    private var approachProfile: Travel {
        let a = groundStart, b = groundTarget
        return Travel(distance: hypot(b.x - a.x, b.z - a.z), speed: groundSpeed,
                      acceleration: type == "INFANTRY" ? 1.2 : 1.8)
    }
    private var attackPause: Double { type == "INFANTRY" ? 1.4 : 3 }

    // Trapezoidal speed profile (triangular on a short leg), with zero velocity
    // at both ends. Sampling by absolute age is independent of frame division.
    private struct Travel {
        let distance: Double
        let speed: Double
        let acceleration: Double
        let ramp: Double
        let cruise: Double
        var duration: Double { ramp * 2 + cruise }

        init(distance: Double, speed: Double, acceleration: Double) {
            self.distance = max(0, distance)
            self.acceleration = acceleration
            self.ramp = min(speed / acceleration, sqrt(max(0, distance) / acceleration))
            self.speed = self.ramp * acceleration
            self.cruise = self.speed > 0 ? max(0, (self.distance - self.speed * self.ramp) / self.speed) : 0
        }
        func traveled(_ age: Double) -> Double {
            let t = max(0, min(duration, age))
            if t < ramp { return 0.5 * acceleration * t * t }
            if t < ramp + cruise { return 0.5 * speed * ramp + speed * (t - ramp) }
            let remaining = duration - t
            return distance - 0.5 * acceleration * remaining * remaining
        }
    }

    private func horizontalPosition(age: Double) -> (x: Double, z: Double) {
        let t = max(0, age)
        if type == "BARGE" {
            if t <= unloadTime { return (berthX, seaStartZ + landingProfile.traveled(t)) }
            if t <= departureTime { return (berthX, berthZ) }
            return (berthX, berthZ - returnProfile.traveled(t - departureTime))
        }
        let start = groundStart, end = groundTarget, approach = approachProfile
        if t <= approach.duration {
            let fraction = approach.distance > 0 ? approach.traveled(t) / approach.distance : 1
            return (start.x + (end.x - start.x) * fraction, start.z + (end.z - start.z) * fraction)
        }
        let movingTime = max(0, t - approach.duration - attackPause)
        // Restart gradually after the attack pause, then keep maneuvering on
        // the landward side of the approach endpoint instead of looping to sea.
        let radius = type == "INFANTRY" ? 2.2 : 5.5
        let distance = movingTime < 1 ? groundSpeed * movingTime * movingTime / 2 : groundSpeed * (movingTime - 0.5)
        let angle = distance / radius
        return (end.x + radius * sin(angle), end.z + (type == "INFANTRY" ? 0.7 : 1.4) * (1 - cos(angle)))
    }

    func position(age: Double, ground: (CGFloat, CGFloat) -> CGFloat) -> SCNVector3 {
        if flying {
            var p = airMotion.position(age: max(0, age), ground: ground)
            p.y = max(p.y, ground(p.x, p.z) + 12)
            return p
        }
        let p = horizontalPosition(age: age), x = CGFloat(p.x), z = CGFloat(p.z)
        if type == "BARGE" {
            // The source sea is at y=0. Do not terrain-follow the vessel up a
            // beach slope; cargo uses unloadPosition's land height separately.
            let moored = age >= unloadTime && age <= departureTime
            let bob = moored ? 0 : 0.035 * sin(max(0, age) * 1.3)
            return SCNVector3(x, CGFloat(0.12 + bob), z)
        }
        return SCNVector3(x, ground(x, z), z)
    }

    func orientation(age: Double) -> SCNVector3 {
        if flying { return airMotion.orientation(age: max(0, age)) }
        let t = max(0, age)
        if type == "BARGE" {
            // Face the beach on approach; turn during the final part of the
            // unloading stop, then point seaward on departure (model -Z front).
            let turnStart = unloadTime + unloadingDuration * 0.6
            let f = max(0, min(1, (t - turnStart) / (unloadingDuration * 0.4)))
            let ease = f * f * (3 - 2 * f)
            return SCNVector3(0, CGFloat(Double.pi * (1 - ease)), 0)
        }
        let a = horizontalPosition(age: t), b = horizontalPosition(age: t + 0.02)
        let dx = b.x - a.x, dz = b.z - a.z
        let yaw = abs(dx) + abs(dz) > 0.00001 ? atan2(-dx, -dz) : atan2(a.x, a.z)
        return SCNVector3(0, CGFloat(yaw), 0)
    }

    func canAttack(age: Double, position: SCNVector3) -> Bool {
        // C130 is reserved for friendly supply; CH53 and barges deliver troops.
        if ["BARGE", "C130", "CH53"].contains(type) { return false }
        if flying { return airMotion.canAttack(age: age, position: position) }
        return age >= approachProfile.duration && hypot(Double(position.x), Double(position.z)) < (type == "INFANTRY" ? 16 : 35)
    }
}

func testBeach2000Motion() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "Beach2000Motion", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func distance(_ a: SCNVector3, _ b: SCNVector3) -> Double {
        hypot(hypot(Double(a.x - b.x), Double(a.y - b.y)), Double(a.z - b.z))
    }
    let ground: (CGFloat, CGFloat) -> CGFloat = { x,z in max(0, (z + 30) * 0.12 + abs(x) * 0.002) }
    for index in 0..<5 {
        let ship = Beach2000Motion(type: "BARGE", index: index)
        let start = ship.position(age: 0, ground: ground)
        let berth = ship.position(age: ship.unloadTime, ground: ground)
        let cargo = ship.unloadPosition(ground: ground)
        try check(start.z < -100 && berth.z < -25 && berth.z > start.z, "ship must approach from northern sea")
        try check(ship.unloadTime > 0 && ship.exitTime > ship.departureTime, "ordered vessel phases")
        try check(distance(berth, ship.position(age: ship.unloadTime + 3, ground: ground)) < 0.0001, "stationary unloading interval")
        try check(cargo.z > berth.z && cargo.y == ground(cargo.x, cargo.z), "cargo exits bow onto terrain")
        try check(ship.position(age: ship.exitTime, ground: ground).z < start.z, "vessel leaves back out to sea")
        try check(!ship.canAttack(age: ship.unloadTime, position: berth), "transport does not directly damage bunker")
    }
    let landing = SCNVector3(-8, 0, -21)
    let infantry = Beach2000Motion(type: "INFANTRY", index: 2, origin: landing)
    let infantryStart = infantry.position(age: 0, ground: ground)
    try check(infantryStart.x == landing.x && infantryStart.z == landing.z, "infantry respects unloading origin")
    try check(infantry.position(age: 2, ground: ground).z > landing.z, "infantry walks toward bunker")
    for type in ["BARGE", "TANK", "APC", "APC1", "INFANTRY", "COBRA", "CH53", "JET", "BOMBER", "C130"] {
        let motion = Beach2000Motion(type: type, index: 2)
        var previous = motion.position(age: 0, ground: ground)
        for frame in 1...6000 {
            let age = Double(frame) / 60, p = motion.position(age: age, ground: ground)
            let o = motion.orientation(age: age)
            try check(p.x.isFinite && p.y.isFinite && p.z.isFinite && o.y.isFinite, "finite path and heading")
            try check(distance(previous, p) < 2.5, "no phase or route-wrap position jumps")
            if motion.flying { try check(p.y >= ground(p.x, p.z) + 12, "aircraft clears terrain and sea") }
            else if type != "BARGE" {
                try check(abs(p.y - ground(p.x, p.z)) < 0.00001, "ground entity terrain contact")
                try check(Double(p.z) > Beach2000Motion.shorelineZ(at: Double(p.x)), "ground patrol stays landward")
            }
            previous = p
        }
        let splitAge = (0..<120).reduce(0.0) { t,_ in t + 1.0 / 60 }
        try check(distance(motion.position(age: 2, ground: ground), motion.position(age: splitAge, ground: ground)) < 0.00001, "frame partition independent path")
        if type == "C130" || type == "CH53" {
            try check(!motion.canAttack(age: 60, position: SCNVector3(0,15,-10)), "air transport is not a direct attacker")
        }
    }
    print("PASS: 2000 sea-to-shore barges, unloading stop and retreat, cargo-origin infantry, landward ground maneuvers, aircraft clearance, continuity and transport roles")
}
