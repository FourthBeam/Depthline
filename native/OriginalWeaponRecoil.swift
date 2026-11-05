import Foundation

// Source: BH2000 0x416a09:177...224 and 0x401165:522...557;
// BH2002 0x4154b7 (analysis/decompiled/update-game.c:163...218),
// 0x40101d:300...373. One tick is an original game update, not wall-clock time.
// Register newly accepted fire BEFORE tick, then use poses for mesh matrices and
// weapon direction BEFORE spawning that tick's projectile/flash. Hidden weapons
// keep recovering because the original update also visits them unconditionally.
struct OriginalWeaponRecoil {
    struct Pose: Equatable {
        let objectID: Int
        let assetName: String
        // Delta from the ORIGINAL object's authored local translation. Scene
        // adapters multiply offset by .01, angles by pi/180. Keep the authored
        // Pistol (5,-10,-70), M60 (8,10,-25), Mortor (8,7.6,-25) offsets.
        let localOffset: SIMD3<Double>
        let rotationDegrees: SIMD3<Double>
    }
    let version: OriginalGameVersion
    private(set) var leftTicks = 0
    private(set) var rightTicks = 0
    private(set) var cannonTicks = 0
    private(set) var handgunTicks = 0
    private(set) var rotaryTicks = 0
    private var leftZ: Double = 0
    private var rightZ: Double = 0
    private var cannonZ: Double = 0
    private var handgunPitch: Double = 0
    private var boltZ: Double = 0
    private var rotaryRoll: Double = 0

    init(version: OriginalGameVersion) { self.version = version }

    mutating func registerFire(_ action: OriginalFireAction) {
        switch action.weapon {
        case .machineGun:
            if version == .beach2002 && action.variant == 2 { rotaryTicks = 2 }
            else if version == .beach2000 || action.variant == 0 {
                if action.barrel == .left { leftTicks = 6 }
                else if action.barrel == .right { rightTicks = 6 }
            }
            // 2002 variant1 (M60) writes a counter2 with no recovered reader.
        case .cannon: cannonTicks = 8
        case .handgun: handgunTicks = 5
        case .flare: break // counter10 exists, but no recovered pose update.
        }
    }

    @discardableResult
    mutating func tick() -> [Pose] {
        func barrel(_ ticks: inout Int, _ z: inout Double) {
            if ticks > 4 && ticks < 7 { z += 30 }
            if ticks > 0 && ticks < 5 { z -= 15 }
            ticks = max(0, ticks - 1)
        }
        barrel(&leftTicks, &leftZ); barrel(&rightTicks, &rightZ)
        if cannonTicks > 6 { cannonZ += 36 }
        if cannonTicks > 0 && cannonTicks < 7 { cannonZ -= 12 }
        cannonTicks = max(0, cannonTicks - 1)
        switch handgunTicks {
        case 4, 2: handgunPitch = 2; boltZ = 8
        case 3: handgunPitch = 3; boltZ = 12
        case 1: handgunPitch = 0; boltZ = 0
        default: break
        }
        handgunTicks = max(0, handgunTicks - 1)
        if version == .beach2002 && rotaryTicks > 0 { rotaryRoll -= 30 }
        rotaryTicks = max(0, rotaryTicks - 1)
        // Generic object matrix pass wraps only outside [-360,+360].
        if rotaryRoll < -360 { rotaryRoll += 360 }
        if rotaryRoll > 360 { rotaryRoll -= 360 }
        return poses
    }

    var poses: [Pose] {
        func pose(_ id: Int, _ name: String, z: Double = 0, pitch: Double = 0, roll: Double = 0) -> Pose {
            .init(objectID: id, assetName: name, localOffset: .init(0, 0, z), rotationDegrees: .init(pitch, 0, roll))
        }
        if version == .beach2000 {
            return [pose(9, "LeftGun", z: leftZ), pose(10, "RightGun", z: rightZ),
                    pose(143, "Cannon", z: cannonZ), pose(214, "Pistol", pitch: handgunPitch),
                    pose(215, "Pistol", z: boltZ)]
        }
        return [pose(21, "LeftGun", z: leftZ), pose(22, "RightGun", z: rightZ),
                pose(23, "M60"), pose(24, "Cannon", z: cannonZ),
                pose(25, "Mortor", roll: rotaryRoll), pose(26, "Pistol", pitch: handgunPitch),
                pose(27, "Bolt", z: boltZ), pose(28, "Flaregun")]
    }

    func pose(objectID: Int) -> Pose? { poses.first { $0.objectID == objectID } }
}

func testOriginalWeaponRecoil() throws {
    func check(_ good: Bool, line: Int = #line) throws {
        if !good { throw NSError(domain: "OriginalWeaponRecoil", code: line,
                                 userInfo: [NSLocalizedDescriptionKey: "Recovered weapon invariant failed at line \(line)"]) }
    }
    func action(_ weapon: OriginalWeapon, _ barrel: OriginalBarrel = .center, _ variant: Int = 0) -> OriginalFireAction {
        .init(weapon: weapon, barrel: barrel, variant: variant, recoilTicks: 0, ballistic: nil)
    }
    for version in [OriginalGameVersion.beach2000, .beach2002] {
        var recoil = OriginalWeaponRecoil(version: version)
        let leftID = version == .beach2000 ? 9 : 21
        recoil.registerFire(action(.machineGun, .left))
        for expected in [30.0, 60, 45, 30, 15, 0] {
            recoil.tick(); try check(recoil.pose(objectID: leftID)!.localOffset.z == expected)
        }
        let cannonID = version == .beach2000 ? 143 : 24
        recoil.registerFire(action(.cannon))
        for expected in [36.0, 72, 60, 48, 36, 24, 12, 0] {
            recoil.tick(); try check(recoil.pose(objectID: cannonID)!.localOffset.z == expected)
        }
        let pistolID = version == .beach2000 ? 214 : 26
        let boltID = version == .beach2000 ? 215 : 27
        recoil.registerFire(action(.handgun))
        for (pitch, bolt) in [(0.0, 0.0), (2, 8), (3, 12), (2, 8), (0, 0)] {
            recoil.tick()
            try check(recoil.pose(objectID: pistolID)!.rotationDegrees.x == pitch)
            try check(recoil.pose(objectID: boltID)!.localOffset.z == bolt)
        }
        try check(recoil.leftTicks == 0 && recoil.cannonTicks == 0 && recoil.handgunTicks == 0)
    }
    var rotary = OriginalWeaponRecoil(version: .beach2002)
    rotary.registerFire(action(.machineGun, .center, 2))
    rotary.tick(); try check(rotary.pose(objectID: 25)!.rotationDegrees.z == -30)
    rotary.tick(); try check(rotary.pose(objectID: 25)!.rotationDegrees.z == -60)
    rotary.tick(); try check(rotary.pose(objectID: 25)!.rotationDegrees.z == -60)
    rotary.registerFire(action(.machineGun, .center, 1)); rotary.tick()
    try check(rotary.pose(objectID: 23)!.localOffset == .zero)
    print("PASS original weapon recoil: both versions, independent barrels, cannon, pistol, rotary")
}
