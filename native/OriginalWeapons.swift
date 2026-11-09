import Foundation

// Pure gameplay rules recovered from the two executables. Evidence and unresolved
// boundaries are in analysis/original-weapons.json. A tick means ONE original game
// loop, not one display frame or a verified number of seconds. Coordinates below
// are original world units. Convert only at the renderer boundary.
// This module deliberately does not infer hit volumes, death animations, scoring,
// enemy fire, or an unknown damage result from a convenient modern damage number.

enum OriginalGameVersion: String, Codable { case beach2000 = "2000", beach2002 = "2002" }
enum OriginalWeapon: Int, Codable { case machineGun = 0, cannon = 1, handgun = 2, flare = 3 }
enum OriginalBarrel: String, Codable { case left, right, center }

struct OriginalBallisticProfile: Equatable, Codable {
    let initialSpeedPerTick: Float
    let downwardVelocityChangePerTick: Float
    // MG and handgun share an 80-entry update pool. In 2000, the MG write pointer
    // wraps at 60 while the handgun wraps at 80; these are NOT separate pools.
    let writePointerWrap: Int
    let sharedBulletPool: Bool
}

struct OriginalWeaponProfile {
    let version: OriginalGameVersion
    var initialHandgunAmmo: Int { 15 }
    var bulletUpdatePoolCount: Int { 80 }
    var missileSlotCount: Int { 2 }
    var missileSpeedPerTick: Float { 280 }
    var missileLifeTicks: Int { 130 }
    var missileAcquisitionRemainingTicksExclusive: Int { 120 }
    var missileAcquisitionMinimumYExclusive: Float { 800 }
    var missileAcquisitionMinimumDot: Float { 0.8 }
    var missileMaximumTurnDegreesPerTick: Float { 5 }
    // 2002's optional limiter waits for integer milliseconds > 28. This is a
    // minimum interval, NOT proof of a fixed simulation frequency. 2000 unverified.
    var optionalFrameLimiterMinimumMilliseconds: Int? { version == .beach2002 ? 29 : nil }

    func ballistic(_ weapon: OriginalWeapon) -> OriginalBallisticProfile? {
        switch weapon {
        case .machineGun:
            return .init(initialSpeedPerTick: version == .beach2000 ? 400 : 500,
                         downwardVelocityChangePerTick: 0.16,
                         writePointerWrap: version == .beach2000 ? 60 : 80,
                         sharedBulletPool: true)
        case .handgun:
            return .init(initialSpeedPerTick: 400, downwardVelocityChangePerTick: 0.16,
                         writePointerWrap: 80, sharedBulletPool: true)
        case .cannon:
            return .init(initialSpeedPerTick: 400, downwardVelocityChangePerTick: 0.16,
                         writePointerWrap: version == .beach2000 ? 4 : 6,
                         sharedBulletPool: false)
        case .flare:
            return nil // Flare launch depends on aim elevation; not a bullet profile.
        }
    }
}

struct OriginalAmmo: Equatable, Codable {
    var machineGun: Int
    var cannon: Int
    var missile: Int
    var handgun: Int
    var flare: Int
}

struct OriginalFireAction: Equatable, Codable {
    let weapon: OriginalWeapon
    let barrel: OriginalBarrel
    // Raw original 2002 MG variant, 0/1/2. No unsupported weapon name is assigned.
    let variant: Int
    let recoilTicks: Int
    let ballistic: OriginalBallisticProfile?
}

struct OriginalMissileSlot: Equatable, Codable {
    var active = false
    var ready = false // 2002 HUD reserves these without consuming ammunition.
}

struct OriginalMissileLaunch: Equatable, Codable {
    let slot: Int // 0 = left; 1 = right
    let originalObjectIndex: Int
    let lifeTicks: Int
    let speedPerTick: Float
}

enum OriginalSupportAction: String, Codable {
    case beach2000GroundBarrage
    case beach2002NineBomberAirstrike
}

struct OriginalWeaponState: Equatable, Codable {
    let version: OriginalGameVersion
    // Ammo is writable so recovered supply/save code can apply its own rules.
    // Do not replenish handgun here: the original only initializes 15 on level load.
    var ammo: OriginalAmmo
    private(set) var selected: OriginalWeapon = .machineGun
    private(set) var phaseCounter = 0
    private(set) var singleShotLatched = false
    private(set) var missileSlots = [OriginalMissileSlot(), OriginalMissileSlot()]
    private(set) var supportAvailable: Bool
    var machineGunVariant: Int
    var cannonVariant: Int
    // The 2002 '1' cheat bypasses MG/cannon/missile/flare consumption, but NOT
    // handgun consumption. All weapons still require positive ammo to initiate.
    var unlimitedAmmo2002 = false

    init(version: OriginalGameVersion, machineGunAmmo: Int, cannonAmmo: Int,
         missileAmmo: Int, flareAmmo: Int = 0, supportAvailable: Bool = false,
         machineGunVariant: Int = 0, cannonVariant: Int = 0,
         phaseCounter: Int = 0, singleShotLatched: Bool = false) {
        self.version = version
        self.supportAvailable = supportAvailable
        self.machineGunVariant = machineGunVariant
        self.cannonVariant = cannonVariant
        // Level loaders do not explicitly reset these globals. Carry them across
        // level changes or restore the Codable state; zero/false is a fresh-session
        // adapter default, not a recovered per-level reset rule.
        self.phaseCounter = phaseCounter
        self.singleShotLatched = singleShotLatched
        // These are 2002 LEVEL-PARSER upper limits, not a general supply clamp.
        ammo = OriginalAmmo(machineGun: min(max(0, machineGunAmmo), version == .beach2002 ? 500 : Int.max),
                            cannon: min(max(0, cannonAmmo), version == .beach2002 ? 20 : Int.max),
                            missile: min(max(0, missileAmmo), version == .beach2002 ? 20 : Int.max),
                            handgun: 15,
                            flare: version == .beach2002 ? min(max(0, flareAmmo), 20) : 0)
        if version == .beach2002 && ammo.machineGun == 0 { selected = .handgun }
    }

    mutating func loadMission(_ definition: [String: Any], machineGunVariant: Int) {
        let rounds = definition["ammo"] as? [Int] ?? []
        func amount(_ index: Int) -> Int { rounds.indices.contains(index) ? rounds[index] : 0 }
        let flags = definition["flags"] as? [String] ?? []
        let hasSupport = version == .beach2000
            ? (definition["artillery"] as? Int ?? 0) != 0 : flags.contains("Bombers")
        let unlimited = unlimitedAmmo2002
        self = .init(version: version, machineGunAmmo: amount(0), cannonAmmo: amount(1),
                     missileAmmo: amount(2), flareAmmo: amount(3), supportAvailable: hasSupport,
                     machineGunVariant: machineGunVariant, phaseCounter: phaseCounter,
                     singleShotLatched: singleShotLatched)
        unlimitedAmmo2002 = unlimited
        prepareMissileSlots()
    }

    var profile: OriginalWeaponProfile { .init(version: version) }
    var allCombatAmmoEmpty: Bool {
        ammo.machineGun == 0 && ammo.cannon == 0 && ammo.missile == 0 && ammo.handgun == 0
    }
    private var consumesMainAmmo: Bool { !(version == .beach2002 && unlimitedAmmo2002) }

    // Original Space behavior, including the fallback to handgun only after MG
    // depletion. Space resets the shared phase; G does not reset phase or latch.
    mutating func cycleWeapon() {
        phaseCounter = 0
        switch selected {
        case .machineGun: selected = .cannon
        case .cannon: selected = ammo.machineGun < 1 && ammo.handgun > 0 ? .handgun : .machineGun
        case .handgun: selected = .cannon
        case .flare: selected = ammo.machineGun < 1 ? .cannon : .machineGun
        }
    }

    mutating func pressHandgunKey() {
        selected = version == .beach2000 && selected == .handgun ? .machineGun : .handgun
    }

    // Once per original logical tick; weaponReady is the original deployment gate.
    // The action coalesces the original request flag and subsequent spawn/consume
    // pass. Apply its projectile AFTER updating the preexisting projectiles.
    mutating func step(triggerDown: Bool, weaponReady: Bool = true,
                       paused: Bool = false) -> OriginalFireAction? {
        guard !paused else { return nil }
        var action: OriginalFireAction?
        let firingWeapon = selected
        switch firingWeapon {
        case .machineGun:
            guard version == .beach2000 || (0...2).contains(machineGunVariant) else { return nil }
            let twin = version == .beach2000 || machineGunVariant == 0
            if triggerDown && weaponReady && ammo.machineGun > 0 &&
                (phaseCounter == 0 || (twin && phaseCounter == 3)) {
                action = .init(weapon: .machineGun,
                               barrel: twin ? (phaseCounter == 0 ? .left : .right) : .center,
                               variant: version == .beach2000 ? 0 : machineGunVariant,
                               recoilTicks: twin ? 6 : 2, ballistic: profile.ballistic(.machineGun))
                if consumesMainAmmo { ammo.machineGun = max(0, ammo.machineGun - 1) }
            }
            phaseCounter += 1
            if phaseCounter > (twin ? 6 : 2) { phaseCounter = 0 }
            if action != nil && version == .beach2000 && ammo.machineGun == 0 && ammo.handgun > 0 {
                selected = .handgun // Original spawn pass auto-fallback, without phase reset.
            }
        case .cannon:
            guard version == .beach2000 || cannonVariant == 0 else { return nil }
            if triggerDown && weaponReady && ammo.cannon > 0 && phaseCounter == 0 {
                action = .init(weapon: .cannon, barrel: .center, variant: cannonVariant,
                               recoilTicks: 8, ballistic: profile.ballistic(.cannon))
                if consumesMainAmmo { ammo.cannon = max(0, ammo.cannon - 1) }
                phaseCounter = 1
            }
            if phaseCounter > 0 { phaseCounter += 1 }
            if phaseCounter > 30 { phaseCounter = 0 }
        case .handgun, .flare:
            let available = firingWeapon == .handgun ? ammo.handgun : ammo.flare
            if triggerDown && !singleShotLatched && weaponReady && available > 0 && phaseCounter == 0 {
                action = .init(weapon: firingWeapon, barrel: .center, variant: 0,
                               recoilTicks: firingWeapon == .handgun ? 5 : 10,
                               ballistic: profile.ballistic(firingWeapon))
                singleShotLatched = true
                if firingWeapon == .handgun { ammo.handgun = max(0, ammo.handgun - 1) }
                else if consumesMainAmmo { ammo.flare = max(0, ammo.flare - 1) }
            }
            if !triggerDown { singleShotLatched = false }
            phaseCounter += 1
            if phaseCounter > 3 { phaseCounter = 0 }
        }
        return action
    }

    // 2002 F launches a flare independently of selected weapon, phase, and latch.
    // night is equivalent to original DAT_00462240 == 0.
    mutating func requestFlare(weaponReady: Bool, night: Bool) -> OriginalFireAction? {
        guard version == .beach2002 && weaponReady && night && ammo.flare > 0 else { return nil }
        if consumesMainAmmo { ammo.flare = max(0, ammo.flare - 1) }
        return .init(weapon: .flare, barrel: .center, variant: 0, recoilTicks: 0, ballistic: nil)
    }

    // Original 2002 HUD pass. Invoke at the corresponding end-of-tick presentation
    // stage, including before the first M input. 2000 uses inactive slots directly.
    mutating func prepareMissileSlots() {
        guard version == .beach2002 && ammo.missile > 0 else { return }
        var available = ammo.missile - missileSlots.filter(\.ready).count
        for index in missileSlots.indices where available > 0 {
            if !missileSlots[index].ready && !missileSlots[index].active {
                missileSlots[index].ready = true
                available -= 1
            }
        }
    }

    mutating func requestMissile(playAllowed: Bool = true) -> OriginalMissileLaunch? {
        guard playAllowed && ammo.missile > 0 else { return nil }
        let slot = missileSlots.indices.first {
            version == .beach2000 ? !missileSlots[$0].active : missileSlots[$0].ready
        }
        guard let slot else { return nil }
        missileSlots[slot].active = true
        missileSlots[slot].ready = false
        if consumesMainAmmo { ammo.missile = max(0, ammo.missile - 1) }
        return .init(slot: slot, originalObjectIndex: (version == .beach2000 ? 0xa1 : 0x1d6) + slot,
                     lifeTicks: profile.missileLifeTicks, speedPerTick: profile.missileSpeedPerTick)
    }

    mutating func missileFinished(slot: Int) {
        guard missileSlots.indices.contains(slot) else { return }
        missileSlots[slot].active = false
    }

    mutating func consumeSupport(playAllowed: Bool = true) -> OriginalSupportAction? {
        guard playAllowed && supportAvailable else { return nil }
        supportAvailable = false
        return version == .beach2000 ? .beach2000GroundBarrage : .beach2002NineBomberAirstrike
    }
}

struct OriginalWeaponVector: Equatable, Codable {
    var x: Float
    var y: Float
    var z: Float
    static func + (a: Self, b: Self) -> Self { .init(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func - (a: Self, b: Self) -> Self { .init(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func * (a: Self, b: Float) -> Self { .init(x: a.x * b, y: a.y * b, z: a.z * b) }
    func dot(_ other: Self) -> Float { x * other.x + y * other.y + z * other.z }
    var normalized: Self? {
        let length = sqrt(dot(self))
        guard length > 0 && length.isFinite else { return nil }
        return self * (1 / length)
    }
    var outsideOriginalProjectileBounds: Bool {
        x < -25000 || x > 25000 || z < -25000 || z > 25000 || y > 10000
    }
}

struct OriginalProjectileSegment: Equatable {
    let start: OriginalWeaponVector
    let end: OriginalWeaponVector
}

struct OriginalBallisticState: Equatable, Codable {
    var position: OriginalWeaponVector
    var velocity: OriginalWeaponVector
    let downwardVelocityChangePerTick: Float

    init(position: OriginalWeaponVector, unitDirection: OriginalWeaponVector,
         profile: OriginalBallisticProfile) {
        self.position = position
        velocity = unitDirection * profile.initialSpeedPerTick
        downwardVelocityChangePerTick = profile.downwardVelocityChangePerTick
    }

    // Original explicit ordering: save old position, advance with current velocity,
    // then subtract gravity. Return the swept segment for recovered hit-volume tests.
    mutating func step() -> OriginalProjectileSegment {
        let previous = position
        position = position + velocity
        velocity.y -= downwardVelocityChangePerTick
        return .init(start: previous, end: position)
    }
}

struct OriginalMissileTarget {
    let originalObjectIndex: Int
    let position: OriginalWeaponVector
    let active: Bool
}

struct OriginalMissileTurn: Equatable {
    let pitchDegrees: Float
    let yawDegrees: Float
}

enum OriginalMissileGuidance {
    static func canAcquire(remainingTicks: Int, positionY: Float) -> Bool {
        remainingTicks < 120 && positionY > 800
    }

    static func eligibleObject(_ index: Int, version: OriginalGameVersion) -> Bool {
        if version == .beach2000 {
            return (0x49..<0x5e).contains(index) || (0x6a..<0x6d).contains(index) || index == 0xcf
        }
        return (0x75..<0x9a).contains(index) || (0xb2..<0xba).contains(index) || (0xd2..<0xda).contains(index)
    }

    // The original chooses the largest forward dot product, not nearest distance,
    // and reacquires every eligible tick. Sorting preserves original index tie-break.
    static func bestTarget(version: OriginalGameVersion, remainingTicks: Int,
                           position: OriginalWeaponVector, unitForward: OriginalWeaponVector,
                           candidates: [OriginalMissileTarget]) -> OriginalMissileTarget? {
        guard canAcquire(remainingTicks: remainingTicks, positionY: position.y) else { return nil }
        var best: OriginalMissileTarget?
        var bestDot: Float = 0
        for target in candidates.sorted(by: { $0.originalObjectIndex < $1.originalObjectIndex })
            where target.active && eligibleObject(target.originalObjectIndex, version: version) {
            guard let direction = (target.position - position).normalized else { continue }
            let dot = direction.dot(unitForward)
            if dot >= 0.8 && dot > bestDot { best = target; bestDot = dot }
        }
        return best
    }

    static func limitedYawDelta(_ difference: Float, version: OriginalGameVersion) -> Float {
        var difference = difference
        if version == .beach2002 {
            // Intentional original ±40 threshold. Do not 'fix' to a ±180 wrap.
            if difference <= 40 {
                if difference < -40 { difference += 360 }
            } else { difference -= 360 }
        }
        return max(-5, min(5, difference))
    }

    // Returned deltas modify the ORIGINAL Euler fields. The caller must rebuild
    // its matrix with the recovered coordinate convention; no SceneKit sign guess.
    static func turn(version: OriginalGameVersion, unitForward: OriginalWeaponVector,
                     unitTargetDirection: OriginalWeaponVector) -> OriginalMissileTurn {
        let degrees: Float = 57.2957795
        func bounded(_ value: Float) -> Float { max(-1, min(1, value)) }
        let pitch = asin(bounded(unitTargetDirection.y)) * degrees - asin(bounded(unitForward.y)) * degrees
        func yaw(_ vector: OriginalWeaponVector) -> Float {
            let angle = acos(bounded(-vector.z)) * degrees
            return vector.x > 0 ? -angle : angle
        }
        return .init(pitchDegrees: max(-5, min(5, pitch)),
                     yawDegrees: limitedYawDelta(yaw(unitTargetDirection) - yaw(unitForward), version: version))
    }
}

struct OriginalBarrageImpact: Equatable {
    let x: Float
    let z: Float
    // Original effect height is heightmap byte * 8 + 10. Ground decoding is external.
    var heightAboveGround: Float { 10 }
}

struct OriginalBarrageTick {
    let playApproachSound: Bool
    let impact: OriginalBarrageImpact?
}

struct Original2000BarrageState: Equatable, Codable {
    struct Area: Equatable, Codable {
        let originCM, sizeCM: SIMD2<Int>
        static let battlefield = Self(originCM: .init(-2048, -5000), sizeCM: .init(repeating: 4096))
    }

    private let impactArea: Area?
    private(set) var remainingTicks = 500
    private(set) var impactCount = 0

    init(impactArea: Area? = nil) { self.impactArea = impactArea }

    // Values must come from the original 15-bit RNG stream if replay parity is
    // required. Particle generation also consumes RNG outside this small module.
    mutating func step(random15: () -> Int) -> OriginalBarrageTick {
        guard remainingTicks > 0 else { return .init(playApproachSound: false, impact: nil) }
        let sound = remainingTicks == 240
        remainingTicks -= 1
        guard remainingTicks < 200 && random15() < 8000 else {
            return .init(playApproachSound: sound, impact: nil)
        }
        impactCount += 1
        if impactCount == 24 { remainingTicks = 0 }
        // The original 15-bit draws select one of 4096 cells per axis. The
        // normal battlefield has one-centimetre cells; a lesson can narrow it.
        let area = impactArea ?? .battlefield
        let x = Float(area.originCM.x + (random15() >> 3) * area.sizeCM.x / 4096)
        let z = Float(area.originCM.y + (random15() >> 3) * area.sizeCM.y / 4096)
        return .init(playApproachSound: sound, impact: .init(x: x, z: z))
    }
}

enum OriginalHitEffect: Equatable {
    case noDamage
    case subtractHitPoints(Int)
    case destroy // Caller must dispatch original death state, not immediately erase all units.
    case unknown
}

enum OriginalDamageRules {
    // The part index is the ORIGINAL collision helper's 0/1/2 result, not an
    // invented head/engine hit-zone. Model hit-volume mapping still needs recovery.
    static func hit(version: OriginalGameVersion, weapon: OriginalWeapon,
                    targetType: String, originalPart: Int) -> OriginalHitEffect {
        guard version == .beach2000 && originalPart >= 0 else { return .unknown }
        let target = targetType.uppercased()
        if weapon == .cannon && (target == "TANK" || target == "APC") { return .destroy }
        guard weapon == .machineGun || weapon == .handgun else { return .unknown }
        if target == "TANK" || target == "APC" { return .noDamage }
        guard (0...2).contains(originalPart) else { return .unknown }
        switch target {
        case "CH53", "JET":
            return originalPart == 0 ? .destroy : .subtractHitPoints(originalPart == 1 ? 2 : 1)
        case "COBRA", "BOMBER", "C130":
            return .subtractHitPoints(originalPart == 2 ? 1 : 2)
        default:
            return .unknown // Infantry is state-dependent; barge is not yet audited.
        }
    }

    static func initialHitPoints2000(targetType: String) -> Int? {
        switch targetType.uppercased() {
        case "TANK", "APC": return 1 // Ground kills use AI state; HP alone is insufficient.
        case "JET": return 4
        case "COBRA", "BOMBER", "C130": return 8
        case "CH53": return 12
        default: return nil
        }
    }
}

func testOriginalWeapons() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "OriginalWeapons", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    for version in [OriginalGameVersion.beach2000, .beach2002] {
        var gun = OriginalWeaponState(version: version, machineGunAmmo: 100, cannonAmmo: 10, missileAmmo: 3)
        var ticks: [Int] = [], barrels: [OriginalBarrel] = []
        for tick in 0..<15 {
            if let shot = gun.step(triggerDown: true) { ticks.append(tick); barrels.append(shot.barrel) }
        }
        try check(ticks == [0,3,7,10,14] && barrels == [.left,.right,.left,.right,.left], "original twin-barrel 7-tick phase")
        let snapshot = gun
        try check(gun.step(triggerDown: true, paused: true) == nil && gun == snapshot, "pause preserves firing state")
        gun.cycleWeapon()
        ticks = []
        for tick in 0..<91 { if gun.step(triggerDown: true) != nil { ticks.append(tick) } }
        try check(ticks == [0,30,60,90], "cannon cooldown begins on shot and lasts 30 ticks")

        var handgun = OriginalWeaponState(version: version, machineGunAmmo: 0, cannonAmmo: 0, missileAmmo: 0)
        try check(handgun.selected == (version == .beach2002 ? .handgun : .machineGun),
                  "2002 missions without machine gun rounds equip the loaded handgun")
        handgun.pressHandgunKey()
        handgun.unlimitedAmmo2002 = true
        var fired = 0
        for _ in 0..<16 {
            if handgun.step(triggerDown: true) != nil { fired += 1 }
            for _ in 0..<3 { _ = handgun.step(triggerDown: false) }
        }
        try check(fired == 15 && handgun.ammo.handgun == 0, "finite 15-round handgun, including 2002 unlimited-ammo cheat")
        var held = OriginalWeaponState(version: version, machineGunAmmo: 10, cannonAmmo: 1, missileAmmo: 1)
        held.pressHandgunKey()
        fired = 0
        for _ in 0..<80 { if held.step(triggerDown: true) != nil { fired += 1 } }
        try check(fired == 1, "held handgun trigger is latched")
        _ = held.step(triggerDown: false)
        for _ in 0..<4 { if held.step(triggerDown: true) != nil { fired += 1 } }
        try check(fired == 2, "release permits exactly one further handgun shot")

        var missiles = OriginalWeaponState(version: version, machineGunAmmo: 0, cannonAmmo: 0, missileAmmo: 3)
        if version == .beach2002 { try check(missiles.requestMissile() == nil, "2002 requires HUD slot preparation") }
        missiles.prepareMissileSlots()
        try check(missiles.requestMissile()?.slot == 0 && missiles.requestMissile()?.slot == 1,
                  "missile launch uses left then right slots")
        try check(missiles.requestMissile() == nil && missiles.ammo.missile == 1, "at most two active missiles")
        missiles.missileFinished(slot: 0)
        missiles.prepareMissileSlots()
        try check(missiles.requestMissile()?.slot == 0 && missiles.ammo.missile == 0, "expired missile releases slot")

        let profile = OriginalWeaponProfile(version: version).ballistic(.machineGun)!
        var bullet = OriginalBallisticState(position: .init(x: 0, y: 1000, z: 0),
                                            unitDirection: .init(x: 0, y: 0, z: -1), profile: profile)
        let first = bullet.step(), second = bullet.step()
        try check(first.end.y == 1000 && first.end.z == -profile.initialSpeedPerTick, "first step advances before gravity")
        try check(abs(second.end.y - 999.84) < 0.001 && abs(bullet.velocity.y + 0.32) < 0.00001,
                  "source gravity is velocity delta per tick")
        let encoded = try JSONEncoder().encode(missiles)
        let restored = try JSONDecoder().decode(OriginalWeaponState.self, from: encoded)
        try check(restored == missiles, "save state includes phases, ammo and missile slots")
    }
    var idlePhase = OriginalWeaponState(version: .beach2000, machineGunAmmo: 10, cannonAmmo: 1, missileAmmo: 0)
    _ = idlePhase.step(triggerDown: false)
    try check(idlePhase.step(triggerDown: true) == nil && idlePhase.step(triggerDown: true) == nil,
              "MG does not reset free-running phase on press")
    try check(idlePhase.step(triggerDown: true)?.barrel == .right, "off-phase press waits for original barrel phase")
    var fallback = OriginalWeaponState(version: .beach2000, machineGunAmmo: 1, cannonAmmo: 1, missileAmmo: 0)
    _ = fallback.step(triggerDown: true)
    try check(fallback.selected == .handgun && fallback.phaseCounter == 1, "2000 MG depletion falls back without phase reset")
    var noFallback = OriginalWeaponState(version: .beach2002, machineGunAmmo: 1, cannonAmmo: 1, missileAmmo: 0)
    _ = noFallback.step(triggerDown: true)
    try check(noFallback.selected == .machineGun, "2002 does not borrow 2000 auto-fallback")
    let capped = OriginalWeaponState(version: .beach2002, machineGunAmmo: 999, cannonAmmo: 999, missileAmmo: 999, flareAmmo: 999)
    try check(capped.ammo == .init(machineGun: 500, cannon: 20, missile: 20, handgun: 15, flare: 20), "2002 level ammo caps")
    for variant in [1,2] {
        var gun = OriginalWeaponState(version: .beach2002, machineGunAmmo: 50, cannonAmmo: 0, missileAmmo: 0, machineGunVariant: variant)
        var ticks: [Int] = []
        for tick in 0..<10 { if gun.step(triggerDown: true) != nil { ticks.append(tick) } }
        try check(ticks == [0,3,6,9], "2002 MG variant uses 3-tick phase")
    }
    let origin = OriginalWeaponVector(x: 0, y: 1000, z: 0), forward = OriginalWeaponVector(x: 0, y: 0, z: -1)
    let near = OriginalMissileTarget(originalObjectIndex: 0x49, position: .init(x: 10,y: 1000,z: -20), active: true)
    let aligned = OriginalMissileTarget(originalObjectIndex: 0x4a, position: .init(x: 0,y: 1000,z: -2000), active: true)
    try check(!OriginalMissileGuidance.canAcquire(remainingTicks: 120, positionY: 900) &&
              !OriginalMissileGuidance.canAcquire(remainingTicks: 119, positionY: 800) &&
              OriginalMissileGuidance.canAcquire(remainingTicks: 119, positionY: 801), "strict missile acquisition gates")
    try check(OriginalMissileGuidance.bestTarget(version: .beach2000, remainingTicks: 119,
              position: origin, unitForward: forward, candidates: [near,aligned])?.originalObjectIndex == 0x4a,
              "missile chooses highest alignment rather than nearest target")
    try check(OriginalMissileGuidance.eligibleObject(0xcf, version: .beach2000), "original 2000 C130 remains missile-targetable")
    try check(OriginalMissileGuidance.limitedYawDelta(50, version: .beach2000) == 5 &&
              OriginalMissileGuidance.limitedYawDelta(50, version: .beach2002) == -5 &&
              OriginalMissileGuidance.limitedYawDelta(-50, version: .beach2002) == 5,
              "preserve distinct original yaw wrap thresholds")
    var support = OriginalWeaponState(version: .beach2000, machineGunAmmo: 0, cannonAmmo: 0, missileAmmo: 0, supportAvailable: true)
    try check(support.consumeSupport() == .beach2000GroundBarrage && support.consumeSupport() == nil, "support available only once")
    var barrage = Original2000BarrageState(), impactTicks: [Int] = [], soundTicks: [Int] = []
    for tick in 0..<500 {
        let result = barrage.step(random15: { 0 })
        if result.playApproachSound { soundTicks.append(tick) }
        if let impact = result.impact {
            impactTicks.append(tick)
            try check(impact.x == -2048 && impact.z == -5000, "barrage original coordinate ranges")
        }
    }
    try check(soundTicks == [260] && impactTicks == Array(300...323) && barrage.impactCount == 24 && barrage.remainingTicks == 0,
              "barrage delay, cue and maximum of 24 impacts")
    try check(OriginalDamageRules.hit(version: .beach2000, weapon: .machineGun, targetType: "TANK", originalPart: 0) == .noDamage &&
              OriginalDamageRules.hit(version: .beach2000, weapon: .cannon, targetType: "TANK", originalPart: 0) == .destroy &&
              OriginalDamageRules.hit(version: .beach2000, weapon: .handgun, targetType: "CH53", originalPart: 0) == .destroy &&
              OriginalDamageRules.hit(version: .beach2002, weapon: .machineGun, targetType: "TANK", originalPart: 0) == .unknown,
              "known armor and hit-part rules do not leak across versions")
    print("PASS: original 2000/2002 firing phases, finite handgun, ammo caps, missile slots and guidance, source-unit ballistics, barrage timing, damage boundaries and state serialization")
}

// The original game has ONE bullet and ONE cannon ring shared by player and
// enemies. A generation lease prevents either renderer from continuing a slot
// overwritten by the other. No ownership/"friendly fire" split exists in the pool.
struct OriginalSharedBallisticSweep {
    let weapon: OriginalWeapon
    let start: SIMD3<Double>
    let end: SIMD3<Double>
    // Only authored cargo uses emitter identity; the shared combat bank
    // retains its existing friendly-fire and slot ordering.
    var enemyFired = false
}

final class OriginalProjectilePools {
    enum Bank: String, Hashable { case bullet, shell }
    struct Token: Equatable, Hashable {
        let bank: Bank
        let slot: Int
        let generation: UInt64
    }
    private struct Entry {
        let token: Token
        let onEvict: (Token) -> Void
        var advance: (() -> OriginalSharedBallisticSweep?)? = nil
    }
    let version: OriginalGameVersion
    private var entries: [Bank: [Int: Entry]] = [:]
    private var pointers: [Bank: Int] = [.bullet: 0, .shell: 0]
    private var generation: UInt64 = 0
    init(version: OriginalGameVersion) { self.version = version }
    func capacity(_ bank: Bank) -> Int { bank == .bullet ? 80 : (version == .beach2000 ? 4 : 6) }
    func nextSlot(_ bank: Bank) -> Int { pointers[bank, default: 0] }
    @discardableResult
    func claim(_ bank: Bank, writePointerWrap: Int? = nil,
               onEvict: @escaping (Token) -> Void = { _ in }) -> Token {
        let wrap = writePointerWrap ?? capacity(bank)
        precondition(wrap > 0 && wrap <= capacity(bank))
        let slot = pointers[bank, default: 0]
        // A previous 80-wrap writer can leave the cursor>=60; BH2000 MG writes
        // that current slot first, THEN increments and wraps. Do not modulo early.
        if let old = entries[bank]?[slot] { old.onEvict(old.token) }
        generation &+= 1
        let token = Token(bank: bank, slot: slot, generation: generation)
        entries[bank, default: [:]][slot] = .init(token: token, onEvict: onEvict)
        pointers[bank] = slot + 1 >= wrap ? 0 : slot + 1
        return token
    }
    func isCurrent(_ token: Token) -> Bool { entries[token.bank]?[token.slot]?.token == token }
    /// Each renderer registers movement for its live lease, but this ONE source
    /// bank owns iteration. A hit is applied synchronously before visiting the
    /// next slot, including a slot written by the opposite emitter faction.
    func registerAdvance(_ token:Token,_ advance:@escaping ()->OriginalSharedBallisticSweep?) {
        guard isCurrent(token) else {return}
        entries[token.bank]?[token.slot]?.advance=advance
    }
    func stepBallistics(resolve:(Token,OriginalSharedBallisticSweep)->Bool) {
        for bank in [Bank.bullet,.shell] {
            for slot in 0..<capacity(bank) {
                guard let entry=entries[bank]?[slot],let sweep=entry.advance?() else {continue}
                let retired=resolve(entry.token,sweep)
                // A callback can replace a slot. Never erase its new occupant.
                if retired,isCurrent(entry.token) {
                    entries[bank]?.removeValue(forKey:slot);entry.onEvict(entry.token)
                }
            }
        }
    }
    func release(_ token: Token) {
        if isCurrent(token) { entries[token.bank]?.removeValue(forKey: token.slot) }
    }
    // New process uses new instance. Level clear preserves global write cursors,
    // which neither recovered level loader resets.
    func clear() {
        let old = entries.values.flatMap { $0.values }
        entries.removeAll()
        for entry in old { entry.onEvict(entry.token) }
    }
}

func testOriginalProjectilePools() {
    let pools = OriginalProjectilePools(version: .beach2000)
    var evicted = 0
    let first = pools.claim(.bullet, onEvict: { _ in evicted += 1 })
    for _ in 0..<79 { _ = pools.claim(.bullet) }
    assert(pools.isCurrent(first) && pools.nextSlot(.bullet) == 0)
    let overwrite = pools.claim(.bullet)
    assert(evicted == 1 && !pools.isCurrent(first) && pools.isCurrent(overwrite))
    pools.release(first); assert(pools.isCurrent(overwrite))
    for _ in 0..<65 { _ = pools.claim(.bullet) }
    let mg = pools.claim(.bullet, writePointerWrap: 60)
    assert(mg.slot == 66 && pools.nextSlot(.bullet) == 0)
    let shell = pools.claim(.shell)
    for _ in 0..<4 { _ = pools.claim(.shell) }
    assert(!pools.isCurrent(shell))
    let cursor = pools.nextSlot(.shell)
    pools.clear(); assert(pools.nextSlot(.shell) == cursor)
    print("OriginalProjectilePools tests passed")
}
