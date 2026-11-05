import Foundation

/// Sound requests at the recovered combat branches. A particle or generic
/// explosion alone is not authority to play a sound. See original-sound-events.json.
enum OriginalCombatSounds {
    struct Request: Equatable {
        let name: String
        var bufferSlot: Int? = nil
        var attenuationHundredthsDB: Int? = nil
        var advanceWriter = false
    }

    private static func effect(_ name: String, gameID: String) -> Request {
        .init(name: name, bufferSlot: gameID == "2000" ? 0 : nil,
              advanceWriter: gameID == "2000")
    }

    /// Aircraft breakup helper2000: max(|X|,|Z|), inclusive8000 cutoff.
    /// Distinct from aircraft GROUND crash (ExBig) below.
    static func debris2000(at p: SIMD3<Double>) -> Request {
        effect(max(Int(abs(p.x)), Int(abs(p.z))) <= 8000 ? "ExClose" : "ExFar", gameID: "2000")
    }

    /// Both original AI functions read Z twice, then multiply by double-0.15.
    /// Confirmed instructions/constants; do not silently substitute XYZ distance.
    static func aircraftCrash(at p: SIMD3<Double>) -> Request {
        .init(name: "ExBig", bufferSlot: 0, attenuationHundredthsDB: Int(-abs(p.z) * 0.15))
    }

    static func playerBulletHit(gameID: String, bucket: Int) -> Request {
        precondition((0..<8).contains(bucket))
        let names = gameID == "2000"
            ? ["Metalbig", "Metallong", "Metalshort", "Ricocht1", "Ricocht2", "Ricocht3", "Ricocht4", "Ricocht5"]
            : ["Metalbig", "Metalbig", "Metalshort", "Metalshort", "Ricocht1", "Ricocht2", "Ricocht3", "Ricocht4"]
        return .init(name: names[bucket], bufferSlot: 0)
    }

    static func infantryBulletHit(gameID: String, random15: UInt32) -> Request? {
        if gameID == "2000" {
            let names = [0: "Soldead1", 2: "Soldead5", 4: "Soldead2", 6: "Soldead5",
                         8: "Soldead3", 10: "Soldead5", 12: "Soldead4", 15: "Soldead5"]
            return names[Int(random15 >> 11)].map { .init(name: $0, bufferSlot: 0) }
        }
        let names = [0: "Soldead1", 2: "Soldead2", 4: "Soldead3", 6: "Soldead4"]
        return names[Int(random15 >> 12)].map { .init(name: $0, bufferSlot: 0) }
    }

    /// Called after a confirmed eligible collision, with the PRE-HIT context.
    /// random is consumed only by an eligible infantry hit, only while enabled.
    static func directHit(_ context: OriginalDamageContext, weapon: OriginalDamageWeapon,
                          part: Int?, at p: SIMD3<Double>, random: () -> UInt32) -> [Request] {
        guard context.active else { return [] }
        let gameID = context.version.rawValue, type = context.canonicalType
        if weapon == .bullet {
            if type == "INFANTRY", let state = context.aiState,
               state > 1 && state < (gameID == "2000" ? 46 : 42) {
                return infantryBulletHit(gameID: gameID, random15: random()).map { [$0] } ?? []
            }
            if gameID == "2000", part == 0, type == "JET" || type == "CH53" {
                return [debris2000(at: p)]
            }
            if gameID == "2002", (part == 0 || type == "BOMBER"), ["JET", "BOMBER", "COBRA", "C130"].contains(type) {
                return [effect("ExFar", gameID: gameID)]
            }
            // Bullet armor/ordinary aircraft damage has no extra impact audio;
            // CH53 part0 is also silent in2002's inspected branch.
            return []
        }
        guard weapon == .cannon || weapon == .missile else { return [] }
        if gameID == "2002", ["TANK", "APC", "JET", "BOMBER", "COBRA", "CH53", "C130"].contains(type) {
            return [effect("ExFar", gameID: gameID)]
        }
        if gameID == "2000" {
            if ["JET", "BOMBER", "COBRA", "CH53", "C130"].contains(type) {
                var result = [debris2000(at: p)]
                // Cannon CH53 has an additional far-buffer Play after its helper.
                if type == "CH53" && weapon == .cannon { result.append(effect("ExFar", gameID: gameID)) }
                return result
            }
            if type == "TANK" {
                var result: [Request] = []
                if part == 0 && context.aiState != 20 { result.append(effect("ExClose", gameID: gameID)) }
                result.append(effect("ExFar", gameID: gameID))
                return result
            }
            if type == "APC" || (type == "BARGE" && weapon == .cannon) { return [effect("ExFar", gameID: gameID)] }
        }
        return []
    }

    static func playerGroundImpact(gameID: String, weapon: OriginalDamageWeapon, at p: SIMD3<Double>) -> [Request] {
        if weapon == .artillery && gameID == "2000" { return [.init(name: "ExMuffle")] }
        guard weapon == .cannon || weapon == .missile,
              gameID != "2000" || p.z > -5000 else { return [] }
        return [effect("ExMuffle", gameID: gameID)]
    }

    /// Source explosion distance selector uses ABS(Z) twice, not XZ distance.
    static func rocketGroundImpact(gameID: String, at p: SIMD3<Double>) -> Request {
        let distance = Int(abs(p.z))
        return effect(distance <= 1000 ? "ExClose" : distance >= 4000 ? "ExMuffle" : "ExFar", gameID: gameID)
    }

    static func enemyImpact(gameID: String, tick: OriginalEnemyOrdnanceTick,
                            kind: OriginalEnemyOrdnanceKind, random: () -> UInt32) -> [Request] {
        var requests: [Request] = []
        for impact in tick.impacts {
            if impact.kind == .player {
                if kind == .bullet { requests.append(playerBulletHit(gameID: gameID, bucket: Int(random() >> 12))) }
                else {
                    // Both versions' impact blocks use the base ExHit buffer,
                    // while incrementing their otherwise shared2-slot writer.
                    requests.append(.init(name: "ExHit", bufferSlot: 0, advanceWriter: true))
                }
            } else if impact.kind == .ground {
                switch kind {
                case .shell: requests.append(effect("ExMuffle", gameID: gameID))
                case .airRocket, .groundRocket, .bomb: requests.append(rocketGroundImpact(gameID: gameID, at: impact.position))
                case .bullet, .grenade: break // Their original ground effect is silent.
                }
            }
        }
        return requests
    }

    static func runTests() throws {
        struct Failure: Error { let message: String }
        func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
        try check(debris2000(at: SIMD3(8000, 99999, 1)).name == "ExClose" && debris2000(at: SIMD3(8001, 0, 1)).name == "ExFar", "2000 debris uses inclusive8000 XZ maximum")
        try check(aircraftCrash(at: SIMD3(99999, 99999, -1000)).attenuationHundredthsDB == -150, "Original crash attenuation usesZ only")
        try check((0..<8).map { playerBulletHit(gameID: "2000", bucket: $0).name } == ["Metalbig", "Metallong", "Metalshort", "Ricocht1", "Ricocht2", "Ricocht3", "Ricocht4", "Ricocht5"], "2000 player metal/ricochet selection")
        try check(playerBulletHit(gameID: "2002", bucket: 1).name == "Metalbig" && playerBulletHit(gameID: "2002", bucket: 3).name == "Metalshort", "2002 weighted player metal sounds")
        try check(infantryBulletHit(gameID: "2000", random15: 32767)?.name == "Soldead5" && infantryBulletHit(gameID: "2000", random15: 2048) == nil, "2000 source silent buckets and fifth voice")
        try check(infantryBulletHit(gameID: "2002", random15: 8192)?.name == "Soldead2" && infantryBulletHit(gameID: "2002", random15: 4096) == nil, "2002 half-silent voice buckets")
        let c = OriginalDamageContext(version: .beach2000, type: "CH53", hitPoints: 8, aiState: 11)
        try check(directHit(c, weapon: .cannon, part: 0, at: .zero, random: { fatalError("Unexpected RNG") }).map(\.name) == ["ExClose", "ExFar"], "2000 CH53 cannon keeps helper plus explicit far sound")
        let c2 = OriginalDamageContext(version: .beach2002, type: "CH53", hitPoints: 8, aiState: 7)
        try check(directHit(c2, weapon: .bullet, part: 0, at: .zero, random: { fatalError("Unexpected RNG") }).isEmpty, "2002 CH53 bullet breakup has no invented sound")
        try check(playerGroundImpact(gameID: "2000", weapon: .cannon, at: SIMD3(0, 0, -5000)).isEmpty, "2000 water impact silent")
        try check([1000.0,1001,3999,4000].map {rocketGroundImpact(gameID:"2002",at:SIMD3(99999,0,$0)).name} == ["ExClose","ExFar","ExFar","ExMuffle"], "Source rocket sound thresholds andZ-only metric")
        print("PASS original combat sound branches, silent branches, weighted choices, fixed buffers and source distance rules")
    }
}

#if !ORIGINAL_COMBAT_SOUND_TESTS
extension Game {
    func playOriginalSoundRequests(_ requests: [OriginalCombatSounds.Request]) {
        sound.enabled = settings.soundEnabled && !paused && !finished
        for request in requests {
            sound.play(request.name, bufferSlot: request.bufferSlot,
                       attenuationHundredthsDB: request.attenuationHundredthsDB,
                       advanceWriter: request.advanceWriter)
        }
    }
    func playOriginalDirectHitSound(_ context: OriginalDamageContext, weapon: OriginalDamageWeapon,
                                    part: Int?, at position: SIMD3<Double>) {
        guard settings.soundEnabled, !paused, !finished else { return }
        playOriginalSoundRequests(OriginalCombatSounds.directHit(context, weapon: weapon, part: part, at: position, random: { self.random.next() }))
    }
    func playOriginalCrashSound(at position: SIMD3<Double>) {
        playOriginalSoundRequests([OriginalCombatSounds.aircraftCrash(at: position)])
    }
    func playOriginalGroundImpactSound(weapon: OriginalDamageWeapon, at position: SIMD3<Double>) {
        playOriginalSoundRequests(OriginalCombatSounds.playerGroundImpact(gameID: assets.gameID, weapon: weapon, at: position))
    }
    func playOriginalEnemyImpactSounds(_ tick: OriginalEnemyOrdnanceTick, kind: OriginalEnemyOrdnanceKind) {
        guard settings.soundEnabled, !paused, !finished else { return }
        playOriginalSoundRequests(OriginalCombatSounds.enemyImpact(gameID: assets.gameID, tick: tick, kind: kind, random: { self.random.next() }))
    }
    func playOriginalPlayerBulletHitSound(bucket: Int? = nil) {
        guard settings.soundEnabled, !paused, !finished else { return }
        playOriginalSoundRequests([OriginalCombatSounds.playerBulletHit(gameID: assets.gameID, bucket: bucket ?? Int(random.next() >> 12))])
    }
}
#else
@main private struct CombatSoundTests {
    static func main() throws { try OriginalCombatSounds.runTests() }
}
#endif
