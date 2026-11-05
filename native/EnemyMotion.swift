import Foundation
import SceneKit

protocol EnemyPath {
    var flying: Bool { get }
    func position(age: Double, ground: (CGFloat, CGFloat) -> CGFloat) -> SCNVector3
    func orientation(age: Double) -> SCNVector3
    func canAttack(age: Double, position: SCNVector3) -> Bool
}

// Recoverable source facts: FUN_004051c8 updates position by forward * speed.
// Ground max 20, Cobra/CH53/C130 cruise 140, jets 160...191, bomber 200.
// The original main loop's default limiter has a 29 ms minimum step. Conversion
// to continuous time is a port choice; random steering/attack FSMs are reduced
// to deterministic approach, attack and return paths, not claimed equivalent.
struct EnemyMotion: EnemyPath {
    static let originalStep = 0.029
    let type: String
    let index: Int
    let direction: String
    let cruiseSpeed: Double
    var flying: Bool { ["COBRA", "CH53", "C130", "JET", "BOMBER"].contains(type) }
    var helicopter: Bool { type == "COBRA" || type == "CH53" }
    private var lane: Double { Double(index % 5 - 2) * 10 }
    private var rotation: Double {
        switch direction { case "North": return .pi; case "East": return .pi / 2
        case "West": return -.pi / 2; default: return 0 }
    }
    var viewingYaw: CGFloat { CGFloat(rotation + .pi) }

    init(type: String, index: Int, direction: String?) {
        self.type = type.uppercased(); self.index = index
        self.direction = direction ?? ["South", "North", "East", "West"][index % 4]
        let sourceSpeed: Double
        switch self.type {
        case "COBRA", "CH53", "C130": sourceSpeed = 140
        case "JET": sourceSpeed = Double(160 + (index * 7) % 32)
        case "BOMBER": sourceSpeed = 200
        default: sourceSpeed = 20
        }
        cruiseSpeed = sourceSpeed * 0.01 / Self.originalStep
    }

    // A continuous racetrack. The turns take place well beyond the turret;
    // wrapping arclength never teleports a plane between visible endpoints.
    private func flightPass(distance: Double) -> (Double, Double) {
        let near = -220.0, far = 320.0, radius = 65.0
        let straight = far - near, arc = Double.pi * radius
        let d = distance.truncatingRemainder(dividingBy: 2 * (straight + arc))
        if d < straight { return (lane, far - d) }
        if d < straight + arc {
            let angle = Double.pi + (d - straight) / radius
            return (lane + radius + radius * cos(angle), near + radius * sin(angle))
        }
        if d < 2 * straight + arc { return (lane + 2 * radius, near + d - straight - arc) }
        let angle = (d - 2 * straight - arc) / radius
        return (lane + radius + radius * cos(angle), far + radius * sin(angle))
    }

    private func localPosition(age: Double) -> (Double, Double, Double) {
        let t = max(0, age)
        if !flying {
            // Source ground acceleration is 0.5 per step; brake/attack and
            // route choices are simplified, retaining visible starts/stops.
            let acceleration = 0.5 * 0.01 / (Self.originalStep * Self.originalStep)
            let ramp = cruiseSpeed / acceleration
            let travel = t < ramp ? 0.5 * acceleration * t * t : cruiseSpeed * (t - ramp / 2)
            let start = 85.0 + Double(index % 3) * 4, attack = 28.0 + Double(index % 3) * 3
            let arrival = (start - attack) / cruiseSpeed + ramp / 2
            if t <= arrival { return (lane, 0, start - min(start - attack, travel)) }
            let patrolTime = max(0, t - arrival - 2.5)
            let a = patrolTime * cruiseSpeed / 24
            return (lane + 16 * sin(a), 0, attack + 8 * (1 - cos(a)))
        }
        if helicopter {
            let start = 320.0 + Double(index % 3) * 24, attack = 62.0
            let altitude = type == "CH53" ? 27.0 : 19.0 + Double(index % 3) * 2
            let brake = 2.0 * 0.01 / (Self.originalStep * Self.originalStep)
            let brakeTime = cruiseSpeed / brake, brakeDistance = cruiseSpeed * brakeTime / 2
            let cruiseTime = (start - attack - brakeDistance) / cruiseSpeed
            let arrival = cruiseTime + brakeTime
            if t <= cruiseTime { return (lane, altitude, start - t * cruiseSpeed) }
            if t <= arrival {
                let b = t - cruiseTime
                return (lane, altitude, attack + brakeDistance - cruiseSpeed * b + brake * b * b / 2)
            }
            let local = t - arrival
            if local < 2.5 { return (lane + 0.35 * sin(local * 2), altitude + 0.35 * sin(local * 3), attack) }
            let run = local - 2.5, radius = 62.0
            let ramp = 1.5
            let distance = run < ramp ? cruiseSpeed * run * run / (2 * ramp) : cruiseSpeed * (run - ramp / 2)
            let a = distance / radius
            return (lane + radius * sin(a), altitude + 2 * sin(a * 2), radius * cos(a))
        }
        let point = flightPass(distance: t * cruiseSpeed)
        let altitude = type == "C130" ? 44.0 : type == "BOMBER" ? 32.0 : 26.0 + Double(index % 3) * 5
        return (point.0, altitude + 1.5 * sin(t * 0.45), point.1)
    }

    func position(age: Double, ground: (CGFloat, CGFloat) -> CGFloat) -> SCNVector3 {
        let p = localPosition(age: age), c = cos(rotation), s = sin(rotation)
        let x = CGFloat(p.0 * c + p.2 * s), z = CGFloat(p.2 * c - p.0 * s)
        let y = flying ? max(CGFloat(p.1), ground(x, z) + 9) : ground(x, z)
        return SCNVector3(x, y, z)
    }

    func orientation(age: Double) -> SCNVector3 {
        let a = localPosition(age: age), b = localPosition(age: age + 0.02)
        let dx = b.0 - a.0, dz = b.2 - a.2
        // Source model forward is local -Z. When stopped, face the turret.
        let yaw = abs(dx) + abs(dz) > 0.0001 ? atan2(-dx, -dz) + rotation : atan2(a.0, a.2) + rotation
        let pitch = helicopter ? -min(0.12, hypot(dx, dz) / 0.02 * 0.0025) : 0
        return SCNVector3(pitch, yaw, 0)
    }

    func canAttack(age: Double, position: SCNVector3) -> Bool {
        let range = hypot(Double(position.x), Double(position.z))
        return age > 3 && range < (flying ? 105 : 70)
    }
}

func testEnemyMotion() throws {
    func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "EnemyMotion", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func distance(_ a: SCNVector3, _ b: SCNVector3) -> Double {
        sqrt(pow(Double(a.x-b.x),2) + pow(Double(a.y-b.y),2) + pow(Double(a.z-b.z),2))
    }
    let floor: (CGFloat, CGFloat) -> CGFloat = { x,z in 3 + x*0.001 + z*0.002 }
    for type in ["TANK", "APC1", "COBRA", "CH53", "JET", "BOMBER", "C130"] {
        let motion = EnemyMotion(type: type, index: 0, direction: "South")
        let a = motion.position(age: 0, ground: floor), b = motion.position(age: 2, ground: floor)
        try check(distance(a,b) > 8, "\(type) must visibly move in the first two seconds")
        try check(motion.position(age: 30, ground: floor).x.isFinite, "finite prolonged trajectory")
        if !motion.flying { try check(abs(b.y-floor(b.x,b.z)) < 0.00001, "ground contact") }
        // Absolute-time sampling gives the same endpoint under different dt divisions.
        let time = (0..<120).reduce(0.0) { value,_ in value + 1.0/60 }
        try check(distance(b,motion.position(age:time,ground:floor)) < 0.00001, "frame independent motion")
    }
    for (direction, axis, sign) in [("South",2,1.0),("North",2,-1.0),("East",0,1.0),("West",0,-1.0)] {
        let p = EnemyMotion(type:"APC1",index:2,direction:direction).position(age:0,ground:floor)
        try check(Double(axis == 0 ? p.x : p.z) * sign > 70, "source cardinal spawn axis")
    }
    let plane = EnemyMotion(type:"JET",index:0,direction:"South")
    var previous = plane.position(age:0,ground:floor)
    for frame in 1...12000 {
        let current = plane.position(age:Double(frame)/60,ground:floor)
        try check(distance(previous,current) < 2, "aircraft turn/wrap must not teleport")
        previous = current
    }
    print("PASS: seven enemy types move, terrain contact, source cardinal directions, dt-independent paths, continuous aircraft turns")
}
