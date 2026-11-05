import Foundation

// Enemy projectiles, in original world units per original update. These preserve
// endpoint tests from the executable; swept player tests would change gameplay.
// Host owns rendering, original shared pool slots, object collisions, and RNG.
// Evidence, including the reused-distance BH2002 behavior, is in
// analysis/original-enemy-ordnance.json. This is not a wall-clock damage timer.
enum OriginalEnemyOrdnanceKind: String, Codable {
    case bullet, shell, airRocket, groundRocket, bomb, grenade
}

enum OriginalEnemyImpactKind: String, Codable { case ground, water, player }
struct OriginalEnemyImpact {
    let kind: OriginalEnemyImpactKind
    let position: SIMD3<Double>
    // A ground explosion can affect infantry. Host applies OriginalDamage.splash
    // to the eligible victims using this radius, not the player's shell radius.
    let infantryRadius: Double?
    let horizontalOnly: Bool
    let infantryCenter: SIMD3<Double> // endpoint, which may be below effect/terrainY
    let includesEmbarkedInfantry: Bool
}
struct OriginalEnemyOrdnanceTick {
    let previous: SIMD3<Double>
    let position: SIMD3<Double>
    let active: Bool
    let shieldDamage: Int
    let impacts: [OriginalEnemyImpact]
}

struct OriginalEnemyOrdnanceState {
    let version: OriginalGameVersion
    let kind: OriginalEnemyOrdnanceKind
    private(set) var position: SIMD3<Double>
    private(set) var velocity: SIMD3<Double>
    private(set) var active = true
    private(set) var remainingTicks: Int?
    private(set) var bombHorizontalSpeed: Double?
    private(set) var bombForward: SIMD3<Double>?

    init(version: OriginalGameVersion, kind: OriginalEnemyOrdnanceKind,
         position: SIMD3<Double>, velocity: SIMD3<Double>, remainingTicks: Int? = nil,
         bombHorizontalSpeed: Double? = nil, bombForward: SIMD3<Double>? = nil) {
        self.version = version; self.kind = kind; self.position = position
        self.velocity = velocity; self.remainingTicks = remainingTicks
        self.bombHorizontalSpeed = bombHorizontalSpeed; self.bombForward = bombForward
        // Bomb callers must retain the aircraft's speed AND forward, because its
        // forward XZ projection need not be unit length during a dive.
        precondition(kind != .bomb || (bombHorizontalSpeed != nil && bombForward != nil))
    }
    init(_ shot: OriginalEnemyAI.Shot, version: OriginalGameVersion = .beach2002) {
        let kind: OriginalEnemyOrdnanceKind
        switch shot.kind.rawValue {
        case "shell": kind = .shell
        case "bomb": kind = .bomb
        case "rocket": kind = (142..<154).contains(shot.originalEmitterObject) ? .airRocket : .groundRocket
        default: kind = .bullet
        }
        self.init(version: version, kind: kind, position: shot.origin, velocity: shot.velocity,
                  remainingTicks: shot.lifetimeTicks, bombHorizontalSpeed: shot.bombHorizontalSpeed,
                  bombForward: shot.bombForward)
    }
    static func bomb(version: OriginalGameVersion, position: SIMD3<Double>,
                     forward: SIMD3<Double>, horizontalSpeed: Double) -> Self {
        .init(version: version, kind: .bomb, position: position,
              velocity: SIMD3(forward.x * horizontalSpeed, 0, forward.z * horizontalSpeed),
              bombHorizontalSpeed: horizontalSpeed, bombForward: forward)
    }
    mutating func retire() { active = false }

    /// Movement separated so the common bullet/shell bank can resolve terrain,
    /// units and player in source order regardless of who fired the slot.
    mutating func advanceFlight()->SIMD3<Double> {
        let previous=position
        guard active else {return previous}
        if kind == .grenade {velocity.y -= 1}
        position += velocity
        switch kind {
        case .bullet,.shell:velocity.y -= 0.16
        case .bomb:
            velocity.y -= 1.5
            let speed=max(0,bombHorizontalSpeed!-1);bombHorizontalSpeed=speed
            velocity.x=bombForward!.x*speed;velocity.z=bombForward!.z*speed
        case .airRocket,.groundRocket:
            if let life=remainingTicks {remainingTicks=life-1;if life-1==0 {active=false}}
        case .grenade:break
        }
        return previous
    }

    // eligibleInfantryPositions must be active original objects 358...453 with
    // state2...41, in ascending original object order. BH2002 airRocket/bomb uses
    // the LAST such soldier's distance for its final shield check (local_24 was
    // overwritten by the splash loop). Empty means no such soldier exists.
    mutating func step(ground: (Double, Double) -> Double, waterAt: ((Double,Double)->Bool)? = nil,
                       eligibleInfantryPositions: [SIMD3<Double>] = [],
                       onUnits:((SIMD3<Double>,SIMD3<Double>)->Bool)? = nil,
                       onPhase:((OriginalEnemyOrdnanceTick)->Void)? = nil) -> OriginalEnemyOrdnanceTick {
        let previous = position
        guard active else { return .init(previous: previous, position: position, active: false, shieldDamage: 0, impacts: []) }
        var damage = 0
        var impacts: [OriginalEnemyImpact] = []
        _=advanceFlight()
        func nearPlayer(_ radius: Double) -> Bool {
            let delta = position - SIMD3<Double>(0, 800, 0)
            return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z < radius * radius
        }
        func impact(_ type: OriginalEnemyImpactKind, _ p: SIMD3<Double>, radius: Double? = nil) -> OriginalEnemyImpact {
            .init(kind: type, position: p, infantryRadius: radius, horizontalOnly: version == .beach2002,
                  infantryCenter: position, includesEmbarkedInfantry: version == .beach2000 &&
                    (kind == .airRocket || kind == .groundRocket || kind == .bomb))
        }
        // Grenades test the bunker before terrain and have no recovered TTL.
        if kind == .grenade {
            if nearPlayer(200) { active = false; damage = 5; impacts.append(impact(.player, position)) }
            else {
                let y = ground(position.x, position.z)
                if position.y < y { active = false; impacts.append(impact(.ground, SIMD3(position.x, y, position.z))) }
            }
            let tick=OriginalEnemyOrdnanceTick(previous:previous,position:position,active:active,shieldDamage:damage,impacts:impacts)
            if damage>0 || !impacts.isEmpty {onPhase?(tick)}
            return tick
        }
        let maxY: Double = version == .beach2000 ? (kind == .shell ? 8000 : (kind == .bullet ? 10000 : 15000)) : 10000
        let outsideWorld = abs(position.x) > 25000 || abs(position.z) > 25000 || position.y > maxY
        let inMap: Bool
        if version == .beach2002 { inMap = abs(position.x) < 15000 && abs(position.z) < 15000 }
        else if kind == .bullet { inMap = abs(position.x) < 15000 && abs(position.z) < 7500 }
        else { inMap = abs(position.x) < 15000 && position.z < 7500 && position.z >= -30000 }
        if outsideWorld { active = false }
        else if !inMap && waterAt == nil { if position.y < 0 { active = false } }
        else {
            let coastWater=waterAt?(position.x,position.z)
            let y = (coastWater ?? (version == .beach2000 && kind != .bullet && position.z <= -7500)) ? 0 : ground(position.x, position.z)
            if position.y < y {
                active = false
                let water = coastWater ?? (version == .beach2000 && kind != .bullet && position.z <= -5000)
                let isExplosive = kind != .bullet
                let radius: Double? = isExplosive && (!water || kind == .shell) ? (version == .beach2000 ? 300 : (kind == .shell ? 400 : 500)) : nil
                impacts.append(impact(water ? .water : .ground, SIMD3(position.x, y, position.z), radius: radius))
                if !water && (kind == .airRocket || kind == .groundRocket || kind == .bomb) {
                    var distance = hypot(position.x, position.z)
                    if version == .beach2002 && kind != .groundRocket, let soldier = eligibleInfantryPositions.last {
                        distance = hypot(soldier.x - position.x, soldier.z - position.z)
                    }
                    if (version == .beach2000 || kind != .groundRocket) && distance < 300 {
                        damage += 5; impacts.append(impact(.player, position))
                    }
                }
            }
        }
        // Flush terrain/AOE before source entity checks. Callbacks mutate live
        // infantry immediately, which later slots and the direct hit tests see.
        if damage>0 || !impacts.isEmpty {
            onPhase?(.init(previous:previous,position:position,active:active,shieldDamage:damage,impacts:impacts))
        }
        if version == .beach2000,(kind == .airRocket || kind == .bomb),!outsideWorld,inMap,position.y<750 {
            if onUnits?(previous,position) == true {active=false}
        }
        // These source blocks continue after setting active=0 on terrain contact.
        // Preserve that ordering: a high enough ground hit can also hit the bunker.
        let testDirect: Bool
        let radius: Double
        let directDamage: Int
        switch kind {
        case .bullet:
            testDirect = version == .beach2002 || position.y < 750
            radius = 300; directDamage = 1
        case .shell:
            testDirect = version == .beach2002 || (!outsideWorld && inMap)
            radius = 250; directDamage = 5
        case .airRocket, .groundRocket, .bomb:
            testDirect = !outsideWorld && inMap && (version == .beach2000 || kind == .groundRocket)
            radius = 300; directDamage = 5
        case .grenade: testDirect = false; radius = 0; directDamage = 0
        }
        if testDirect && nearPlayer(radius) {
            active = false; damage += directDamage
            let hit=impact(.player,position);impacts.append(hit)
            onPhase?(.init(previous:previous,position:position,active:active,shieldDamage:directDamage,impacts:[hit]))
        }
        return .init(previous: previous, position: position, active: active, shieldDamage: damage, impacts: impacts)
    }
}

// The same nine original objects133...141 serve scheduled BOMBER entries and B
// support. Keep one instance per slot and activate it; do not create nine extra
// copies when B is pressed. A killed state0 object stays dead if reactivated.
final class Original2002BomberAI {
    struct Update {
        let originalObjectIndex: Int
        let position: SIMD3<Double>
        let eulerDegrees: SIMD3<Double>
        let state: Int
        let active: Bool
        let dropBomb: Bool
        let forward: SIMD3<Double>
        let right: SIMD3<Double>
        let speedPerTick: Double
    }
    let originalObjectIndex: Int
    private(set) var state = 1
    private(set) var active = false
    private(set) var position = SIMD3<Double>(repeating: 0)
    private(set) var headingDegrees = 0.0
    private(set) var counter = 0
    private(set) var hitPoints = 4
    private var speed = 0.0
    init(slot: Int) { precondition((0..<9).contains(slot)); originalObjectIndex = 133 + slot }
    func activate() { active = true }
    func kill() { state = 0; active = false }
    static func supportHeading(random15: () -> Int) -> Double { Double(random15() >> 7) * 1.40625 }
    // Loader stores these literal floats in the shared heading, not cardinal angles.
    static func levelHeading(direction: String?) -> Double {
        switch direction?.uppercased() { case "NORTH": return 1; case "SOUTH": return 2; case "EAST": return 3; case "WEST": return 4; default: return 0 }
    }
    func step(groupHeadingDegrees: Double, random15: () -> Int) -> Update {
        var drop = false
        if active {
            switch state {
            case 0: active = false
            case 1:
                position.y = Double(random15() >> 4) + 2240
                headingDegrees = groupHeadingDegrees; speed = 200; hitPoints = 4
                let lateral = Double(random15() >> 2) - 4096
                let distance = Double(random15() << 2) + 65000
                let a = headingDegrees * .pi / 180
                position.x = cos(a) * lateral + sin(a) * distance
                position.z = cos(a) * distance - sin(a) * lateral
                state = 2
            case 2:
                if hypot(position.x, position.z) < 18000 { counter = random15() >> 10; state = 3 }
            case 3:
                counter -= 1
                // Intentional source behavior: initial0 becomes-1 and never drops.
                if counter == 0 { counter = 32; state = 4 }
            case 4:
                drop = counter & 7 == 0; counter -= 1
                if counter == 0 { state = 5 }
            case 5:
                if abs(position.x) > 60000 || abs(position.z) > 60000 { active = false }
            default: break
            }
            // Loader clears all steering targets and smoothers. No case in this
            // bomber FSM writes them, so the recovered zero-roll straight flight
            // is retained, including the update where the FSM turns active off.
            position += forward * speed
            if headingDegrees > 180 { headingDegrees -= 360 }
            if headingDegrees < -180 { headingDegrees += 360 }
        }
        return .init(originalObjectIndex: originalObjectIndex, position: position,
                     eulerDegrees: SIMD3(0, headingDegrees, 0), state: state, active: active,
                     dropBomb: drop, forward: forward, right: right, speedPerTick: speed)
    }
    private var forward: SIMD3<Double> { let a = headingDegrees * .pi / 180; return SIMD3(-sin(a), 0, -cos(a)) }
    private var right: SIMD3<Double> { let a = headingDegrees * .pi / 180; return SIMD3(cos(a), 0, -sin(a)) }
    // Shared24-entry bomb pool uses its write-pointer parity. First slot0 is+40X.
    static func bomb(from update: Update, sharedBombSlot: Int) -> OriginalEnemyOrdnanceState {
        .bomb(version: .beach2002, position: update.position + update.right * (sharedBombSlot & 1 == 0 ? 40 : -40),
              forward: update.forward, horizontalSpeed: update.speedPerTick)
    }
}

func testOriginalEnemyOrdnance() {
    let flat: (Double, Double) -> Double = { _, _ in 0 }
    var bullet = OriginalEnemyOrdnanceState(version: .beach2002, kind: .bullet, position: SIMD3(0, 800, -1000), velocity: SIMD3(0, 0, 500))
    assert(bullet.step(ground: flat).shieldDamage == 0)
    assert(bullet.step(ground: flat).shieldDamage == 1)
    var oldBullet = OriginalEnemyOrdnanceState(version: .beach2000, kind: .bullet, position: SIMD3(0, 800, -400), velocity: SIMD3(0, 0, 400))
    assert(oldBullet.step(ground: flat).shieldDamage == 0) // source low-height branch
    var grenade = OriginalEnemyOrdnanceState(version: .beach2000, kind: .grenade, position: SIMD3(500, 1000, 0), velocity: SIMD3(0, 0, 0))
    assert(grenade.step(ground: flat).position.y == 999)
    assert(grenade.step(ground: flat).position.y == 997)
    var air = OriginalEnemyOrdnanceState(version: .beach2002, kind: .airRocket, position: SIMD3(0, 800, -280), velocity: SIMD3(0, 0, 280), remainingTicks: 100)
    assert(air.step(ground: flat).shieldDamage == 0)
    var groundRocket = OriginalEnemyOrdnanceState(version: .beach2002, kind: .groundRocket, position: SIMD3(0, 800, -280), velocity: SIMD3(0, 0, 280), remainingTicks: 130)
    assert(groundRocket.step(ground: flat).shieldDamage == 5)
    var bomb = OriginalEnemyOrdnanceState.bomb(version: .beach2002, position: SIMD3(1000, 1000, 0), forward: SIMD3(0, 0.6, -0.8), horizontalSpeed: 200)
    assert(bomb.step(ground: flat).position == SIMD3(1000, 1000, -160))
    assert(bomb.velocity.y == -1.5 && abs(bomb.velocity.z + 159.2) < 1e-10)
    var blast = OriginalEnemyOrdnanceState.bomb(version: .beach2002, position: SIMD3(0, -1, 0), forward: SIMD3(0, 0, -1), horizontalSpeed: 0)
    assert(blast.step(ground: flat).shieldDamage == 5)
    var overwritten = OriginalEnemyOrdnanceState.bomb(version: .beach2002, position: SIMD3(0, -1, 0), forward: SIMD3(0, 0, -1), horizontalSpeed: 0)
    assert(overwritten.step(ground: flat, eligibleInfantryPositions: [SIMD3(1000, 0, 0)]).shieldDamage == 0)
    var remote = OriginalEnemyOrdnanceState.bomb(version: .beach2002, position: SIMD3(1000, -1, 0), forward: SIMD3(0, 0, -1), horizontalSpeed: 0)
    let rt = remote.step(ground: flat, eligibleInfantryPositions: [SIMD3(1100, 0, 0)])
    assert(rt.shieldDamage == 5 && rt.impacts.first?.infantryRadius == 500)
    var doubleHit = OriginalEnemyOrdnanceState(version: .beach2000, kind: .airRocket, position: SIMD3(0, 700, -280), velocity: SIMD3(0, 0, 280), remainingTicks: 100)
    assert(doubleHit.step(ground: { _, _ in 800 }).shieldDamage == 10)
    var water = OriginalEnemyOrdnanceState.bomb(version: .beach2000, position: SIMD3(0, -1, -8000), forward: SIMD3(0, 0, -1), horizontalSpeed: 0)
    assert(water.step(ground: { _, _ in 999 }).impacts.first?.kind == .water)
    var seaShell = OriginalEnemyOrdnanceState(version: .beach2000, kind: .shell,
        position: SIMD3(0,-20,-6000), velocity: SIMD3(0,0,0))
    let seaImpact = seaShell.step(ground: flat).impacts[0]
    assert(seaImpact.kind == .water && seaImpact.infantryRadius == 300 && seaImpact.infantryCenter.y == -20)
    assert(!seaImpact.includesEmbarkedInfantry)
    var landBomb = OriginalEnemyOrdnanceState.bomb(version: .beach2000, position: SIMD3(1000,-20,0), forward: SIMD3(0,0,-1), horizontalSpeed: 0)
    assert(landBomb.step(ground: flat).impacts[0].includesEmbarkedInfantry)
    let plane = Original2002BomberAI(slot: 0); plane.activate()
    var calls = 0
    let random: () -> Int = { calls += 1; return calls == 2 ? 16384 : 1024 }
    var drops = 0
    for _ in 0..<1100 { if plane.step(groupHeadingDegrees: 0, random15: random).dropBomb { drops += 1 } }
    assert(drops == 4 && !plane.active)
    let zero = Original2002BomberAI(slot: 1); zero.activate()
    var zeros = 0
    let zeroRandom: () -> Int = { zeros += 1; return zeros == 2 ? 16384 : 0 }
    for _ in 0..<1000 { assert(!zero.step(groupHeadingDegrees: 0, random15: zeroRandom).dropBomb) }
    assert(zero.state == 3 && zero.counter < 0)
    plane.kill(); plane.activate()
    assert(!plane.step(groupHeadingDegrees: 20, random15: { 1 }).active)
    assert(Original2002BomberAI.supportHeading(random15: { 32767 }) == 358.59375)
    print("OriginalEnemyOrdnance tests passed")
}
