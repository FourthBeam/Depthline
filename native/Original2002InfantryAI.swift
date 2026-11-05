import Foundation

/// Original object pool358..<454: FUN_004051c8 lines3225–4380.
/// Coordinates, sprite frame numbers, timers and movement remain in original units/ticks.
final class Original2002InfantryAI {
    enum Event {
        case rifleFlash(origin: SIMD3<Double>, shieldDamage: Int)
        case grenade(origin: SIMD3<Double>, velocity: SIMD3<Double>)
        case forceRemoved(Double)
        case parachuteReleased
    }
    struct BurningVisual {
        let position: SIMD3<Double>
        let horizontalScale: Double
        let verticalScale: Double
    }
    struct Update {
        let position: SIMD3<Double>
        let yawDegrees: Double
        let rollDegrees: Double
        let frameIndex: Int
        let state: Int
        let isActive: Bool
        let events: [Event]
        let burningVisual: BurningVisual?
        var texturePath: String { Original2002InfantryAI.texturePath(frameIndex: frameIndex) }
    }
    private(set) var position: SIMD3<Double>
    private(set) var direction: SIMD3<Double>
    private(set) var speedPerTick: Double
    private(set) var state: Int
    private(set) var frameIndex = 87
    private(set) var isActive = true
    private(set) var yawDegrees = 0.0
    private(set) var rollDegrees = 0.0
    private var rollSpeed = 0.0
    private var counter: Int
    private var previousState = 17
    private var thrownVelocity = SIMD3<Double>(repeating: 0)
    private var burnScale = 0.5
    private var burnHeight = 0.0
    private var deferredForceResolved = false
    var apcExit: DepthlineAPCExit?
    private var rng: OriginalEnemyAI.Random

    init(position: SIMD3<Double>, direction: SIMD3<Double> = SIMD3(0, 0, -1),
         speedPerTick: Double = 0, initialState: Int = 17, initialDelay: Int = 0, seed: UInt32 = 1) {
        self.position = position; self.direction = direction; self.speedPerTick = speedPerTick
        self.state = initialState; self.counter = initialDelay; self.rng = .init(seed: seed)
        if initialState == 1 || initialState == 2 { frameIndex = 230 }
    }
    /// The scene declares Film0=207 frames then Film1=99; frame IDs0...305 are contiguous.
    static func texturePath(frameIndex: Int) -> String {
        let frame = min(305, max(0, frameIndex))
        let sheet = frame < 207 ? "Soldiers128x29808" : "Soldiers128x14256"
        return "frames/\(sheet)/\(String(format: "%03d", frame < 207 ? frame : frame - 207)).keyed.png"
    }
    /// Called after the projectile/damage module has already deducted force1 and awarded score.
    func beginBulletDeath() {
        guard isActive && state > 1 && state < 42 else { return }
        previousState = state; state = 60
    }
    /// Burning infantry deducts force at animation completion, unlike a direct bullet hit.
    /// The prone firing states are removed immediately by the original blast branch.
    func beginBurning() -> [Event] {
        guard isActive && state > 0 && state < 42 else { return [] }
        if state == 30 || state == 38 { isActive = false; return [.forceRemoved(1)] }
        if [21, 23, 25].contains(state) { state = 50 }
        else if [22, 24, 26].contains(state) { state = 53 }
        else { state = 56 }
        burnScale = 0.5; burnHeight = position.y + 60; return []
    }
    /// The damage module selects one of the five original thrown death families70...74.
    /// Force/score belong to that hit; this animation does not deduct force again.
    func beginThrownDeath(state: Int, velocity: SIMD3<Double>, spin: Double = 0) {
        guard (70...74).contains(state) else { return }
        self.state = state; thrownVelocity = velocity
        rollDegrees = 0; rollSpeed = spin
        frameIndex = [70:138, 71:146, 72:154, 73:222, 74:270][state]!
    }
    func remove() { isActive = false }
    var burningVisual: BurningVisual? { snapshot([]).burningVisual }

    /// A state1 trooper may follow its parachute node; supply code can instead instantiate at
    /// state2 after landing. Height is point-sampled HMap*8, not the vehicle bilinear sampler.
    func tick(terrainHeight: (Double, Double) -> Double, cameraYawDegrees: Double = 0,
              cameraPitchDegrees: Double = 0, parachutePosition: SIMD3<Double>? = nil,
              random: (() -> UInt32)? = nil) -> Update {
        guard isActive else { return snapshot([]) }
        if state == 9, apcExit != nil {
            if let step = apcExit?.step(ground: terrainHeight) {
                position = step.position
                direction = SIMD3(step.direction.x, 0, step.direction.y)
                runFrame()
                if apcExit?.isFinished == true {
                    state = 17
                    apcExit = nil
                }
            }
            return snapshot([])
        }
        let rand = { Int((random?() ?? self.rng.next()) & 0x7fff) }
        var events: [Event] = []
        switch state {
        case 0: if cameraPitchDegrees > 20 { isActive = false }
        case 1:
            if let parachutePosition { position = parachutePosition - SIMD3(0, 300, 0) }
            let h = terrainHeight(position.x, position.z)
            if position.y < h { position.y = h; state = 2; events.append(.parachuteReleased) }
            yawDegrees = cameraYawDegrees; frameIndex = 230
        case 2:
            frameIndex += 1
            if frameIndex > 239 { frameIndex = 87; state = 17 }
        case 5, 9:
            frameIndex = 87
            if counter < 6 { counter += 6 }
            else {
                position.y -= state == 5 ? 2.6 : 2.4
                if position.y < terrainHeight(position.x, position.z) { state = 17 }
            }
        case 17:
            let distance = hypot(position.x, position.z)
            let aim = distance >= 2500 ? SIMD3<Double>(Double(rand() >> 3) - 2048, 0, Double(rand() >> 3) - 2048) : .zero
            direction = flatUnit(aim - position); speedPerTick = 4; state = 19
            if abs(position.x) > 2500 || abs(position.z) > 2500 { state = 18 }
            if abs(position.x) < 1200 && abs(position.z) < 1200 { state = 20 }
            runFrame()
        case 18:
            if abs(position.x) < 2500 && abs(position.z) < 2500 { state = 17 }
            runFrame()
        case 19, 20:
            let near = state == 20
            runFrame()
            if near && hypot(position.x, position.z) < 700 { speedPerTick = 0; state = 36 }
            else if !near && abs(position.x) < 1200 && abs(position.z) < 1200 { state = 17 }
            else {
                let chance = rand() >> 11
                if frameIndex == 88 {
                    if chance == (near ? 1 : 2) { frameIndex = 14; state = 21 }
                    if chance == (near ? 3 : 4) { frameIndex = 1; state = 22 }
                    if chance == (near ? 5 : 6) { frameIndex = 125; speedPerTick = 0; state = 29 }
                    if near && chance == 9 { frameIndex = 118; speedPerTick = 0; state = 32 }
                    if near && chance == 13 { frameIndex = 93; speedPerTick = 0; state = 35 }
                }
            }
        case 21, 22:
            let left = state == 21; frameIndex += 1
            if frameIndex > (left ? 19 : 6) {
                if rand() < 10000 { frameIndex = left ? 51 : 65; state = left ? 23 : 24 }
                else { frameIndex = left ? 27 : 39; speedPerTick = 8; state = left ? 25 : 26 }
            }
        case 23...26:
            let left = state == 23 || state == 25, fast = state >= 25
            orbit(left: left)
            let trigger = fast ? (left ? 30 : 47) : (left ? 64 : 78)
            if frameIndex == trigger && rand() > 28000 {
                frameIndex = left ? 21 : 8; if fast { speedPerTick = 4 }; state = left ? 27 : 28
            } else {
                frameIndex += 1
                let end = fast ? (left ? 38 : 50) : (left ? 64 : 78)
                if frameIndex > end { frameIndex = fast ? (left ? 27 : 39) : (left ? 51 : 65) }
            }
        case 27, 28:
            let left = state == 27; frameIndex += 1
            if frameIndex > (left ? 26 : 13) { returnToRun() }
        case 29, 32, 37, 39:
            let prone = state == 29 || state == 37
            frameIndex += 1
            if frameIndex == (prone ? 137 : 124) { counter = 60; state += 1 }
        case 30, 33, 38, 40:
            let firingState = state; counter -= 1
            if counter == 15 {
                let origin = position + flatUnit(-position) * 20 + SIMD3(0, firingState == 30 || firingState == 38 ? 80 : 100, 0)
                let damage = rand() > 24000 ? 1 : 0
                events.append(.rifleFlash(origin: origin, shieldDamage: damage))
            }
            if counter == 0 {
                if firingState < 38 { state += 1 } else { counter = (rand() >> 10) + 30 }
            }
        case 31, 34:
            let prone = state == 31; frameIndex -= 1
            if frameIndex < (prone ? 125 : 118) { returnToRun() }
        case 35:
            frameIndex += 1
            if frameIndex > 117 { returnToRun() }
            if frameIndex == 107 { events.append(grenade(random: rand, repeatThrow: false)) }
        case 36:
            if frameIndex == 88 {
                let chance = rand() >> 13; speedPerTick = 0
                if chance == 0 { frameIndex = 125; state = 37 }
                else if chance < 3 { frameIndex = 118; state = 39 }
                else { frameIndex = 93; counter = 90; state = 41 }
            }
            if state == 36 { runFrame() }
        case 41:
            counter -= 1
            if counter < 1 {
                frameIndex += 1
                if frameIndex > 117 { frameIndex = 93; counter = 90 }
                if frameIndex == 107 { events.append(grenade(random: rand, repeatThrow: true)) }
            }
        case 50, 53:
            let left = state == 50
            frameIndex = left ? 27 : 39; speedPerTick = 8; state += 1
            counter = (rand() >> 12) + (left ? 4 : 6)
        case 51, 54:
            let left = state == 51; orbit(left: left); frameIndex += 1
            let end = left ? 38 : 50, deathStart = left ? 240 : 255
            if frameIndex == end {
                counter -= 1
                if counter == 0 { frameIndex = deathStart; speedPerTick = 0; state += 1 }
            }
            if frameIndex > end && frameIndex != deathStart { frameIndex = left ? 27 : 39 }
        case 52, 55, 58:
            burnHeight -= state == 58 ? 4.375 : 4.65
            let end = state == 52 ? 254 : state == 55 ? 269 : 305
            frameIndex += 1
            if frameIndex == end {
                if !deferredForceResolved { events.append(.forceRemoved(1)); deferredForceResolved = true }
                state = 59
            }
        case 56:
            frameIndex = (rand() >> 11) + 275; speedPerTick = 0; state = 57; counter = (rand() >> 12) + 4
        case 57:
            frameIndex += 1
            if frameIndex == 289 { counter -= 1; if counter == 0 { state = 58 } }
            if frameIndex > 289 { frameIndex = 279 }
        case 59:
            burnScale -= 0.01; if burnScale < 0.02 { state = 0 }
        case 60:
            speedPerTick = 0
            if previousState == 23 || previousState == 25 { state = 65; frameIndex = 240 }
            if previousState == 24 || previousState == 26 { state = 66; frameIndex = 255 }
            if previousState == 30 || previousState == 38 { state = 64; frameIndex = 207 }
            else if previousState < 23 || previousState > 26 {
                let choice = rand() >> 13
                state = choice < 2 ? 61 : choice == 2 ? 62 : 63
                frameIndex = choice < 2 ? 162 : choice == 2 ? 177 : 192
            }
        case 61...66:
            frameIndex += 1
            let end = [61:176, 62:191, 63:206, 64:221, 65:254, 66:269][state]!
            if frameIndex == end { state = 0 }
        case 70...74:
            frameIndex = min(frameIndex + 1, [70:145, 71:153, 72:161, 73:229, 74:274][state]!)
        default: break
        }
        if state > 1 && state < 70 {
            position.x += direction.x * speedPerTick; position.z += direction.z * speedPerTick
            yawDegrees = cameraYawDegrees
            if state > 16 { position.y = terrainHeight(position.x, position.z) }
        }
        if state > 69 {
            if position.y >= 0 {
                thrownVelocity.x *= 0.98; thrownVelocity.z *= 0.98; thrownVelocity.y -= 2
                position += thrownVelocity
            } else { isActive = false }
        }
        if (50...59).contains(state) && ![52, 55, 58, 59].contains(state) {
            burnHeight = position.y + 60
        }
        if isActive {
            // Original global object update FUN_0040347e runs after the AI/projectile pass.
            rollDegrees += rollSpeed
            if rollDegrees > 360 { rollDegrees -= 360 }; if rollDegrees < -360 { rollDegrees += 360 }
        }
        return snapshot(events)
    }
    private func runFrame() { frameIndex += 1; if frameIndex > 92 { frameIndex = 79 } }
    private func returnToRun() { frameIndex = 87; state = 17 }
    private func orbit(left: Bool) {
        let length = max(0.0001, hypot(position.x, position.z))
        direction = left ? SIMD3(-position.z / length, 0, position.x / length) : SIMD3(position.z / length, 0, -position.x / length)
    }
    private func flatUnit(_ vector: SIMD3<Double>) -> SIMD3<Double> {
        let length = hypot(vector.x, vector.z)
        return length > 0 ? SIMD3(vector.x / length, 0, vector.z / length) : SIMD3(0, 0, -1)
    }
    private func grenade(random: () -> Int, repeatThrow: Bool) -> Event {
        let target = SIMD3<Double>(Double(random() >> 6) - 256, Double(random() >> 5) + 1024, Double(random() >> 6) - 256)
        let speed = repeatThrow ? Double(random() >> 11) + 20 : 40
        let delta = target - position, length = sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
        return .grenade(origin: position + SIMD3(0, 120, 0), velocity: delta * (speed / max(length, 0.0001)))
    }
    private func snapshot(_ events: [Event]) -> Update {
        // FUN_004051c8:4327–4352 follows the trooper, five units toward the bunker on each
        // horizontal axis. Death animation lowers world Y; state59 shrinks only vertical scale.
        let flame = isActive && (50...59).contains(state)
            ? BurningVisual(position: SIMD3(position.x + (position.x < 0 ? 5 : -5), burnHeight,
                                             position.z + (position.z < 0 ? 5 : -5)),
                            horizontalScale: 0.25, verticalScale: burnScale) : nil
        return Update(position: position, yawDegrees: yawDegrees, rollDegrees: rollDegrees,
                      frameIndex: frameIndex, state: state, isActive: isActive, events: events,
                      burningVisual: flame)
    }
}

func original2002InfantrySelfTest() throws {
    struct Failure: Error { let reason: String }
    func require(_ pass: Bool, _ reason: String) throws { if !pass { throw Failure(reason: reason) } }
    let soldier = Original2002InfantryAI(position: SIMD3(0, 0, 600), seed: 42)
    var rifles = 0, grenades = 0
    for _ in 0..<5000 {
        let update = soldier.tick(terrainHeight: { _, _ in 0 })
        try require((0...305).contains(update.frameIndex) && update.position.x.isFinite, "finite sprite and movement")
        for event in update.events { if case .rifleFlash = event { rifles += 1 }; if case .grenade = event { grenades += 1 } }
    }
    try require(rifles + grenades > 0, "close infantry attacks")
    soldier.beginBulletDeath()
    for _ in 0..<50 { _ = soldier.tick(terrainHeight: { _, _ in 0 }) }
    try require(soldier.state == 0 && soldier.isActive, "bullet corpse remains until looking down")
    _ = soldier.tick(terrainHeight: { _, _ in 0 }, cameraPitchDegrees: 21)
    try require(!soldier.isActive, "corpse camera-pitch cleanup")
    let burn = Original2002InfantryAI(position: SIMD3(0, 0, 2000), seed: 9)
    var force = burn.beginBurning().reduce(0.0) { amount, event in if case .forceRemoved(let n) = event { return amount + n }; return amount }
    for _ in 0..<500 {
        for event in burn.tick(terrainHeight: { _, _ in 0 }).events { if case .forceRemoved(let n) = event { force += n } }
    }
    try require(force == 1, "burning resolves force exactly once")
    for initialState in [21, 22, 17] {
        let burning = Original2002InfantryAI(position: SIMD3(-1000, 100, 2000), initialState: initialState)
        _ = burning.beginBurning()
        var burnedForce = 0.0
        var previous = burning.tick(terrainHeight: { _, _ in 100 }, random: { 0 })
        try require(previous.burningVisual?.verticalScale == 0.5
                    && previous.burningVisual?.horizontalScale == 0.25
                    && previous.burningVisual?.position.y == 160, "initial flame transforms")
        for _ in 0..<500 {
            let next = burning.tick(terrainHeight: { _, _ in 100 }, random: { 0 })
            for event in next.events { if case .forceRemoved(let value) = event { burnedForce += value } }
            if [52, 55, 58].contains(previous.state), let before = previous.burningVisual,
               let after = next.burningVisual {
                let decrement = previous.state == 58 ? 4.375 : 4.65
                try require(abs(before.position.y - after.position.y - decrement) < 0.00001,
                            "death animation must lower flame by original per-tick amount")
            }
            if previous.state == 59, let before = previous.burningVisual, let after = next.burningVisual {
                try require(abs(before.verticalScale - after.verticalScale - 0.01) < 0.00001,
                            "final flame fades only its vertical scale")
            }
            previous = next
        }
        try require(burnedForce == 1 && previous.state == 0 && previous.burningVisual == nil,
                    "all burning families resolve force once and finish without a flame")
    }
    try require(Original2002InfantryAI.texturePath(frameIndex: 207).contains("14256/000"), "second film boundary")
}
