import Foundation

// Recovered hit consequences, separate from hit detection and death animation.
// Sources: 2000 full-decompile/functions/0x416a09.c and 0x406805.c;
// 2002 decompiled/update-game.c and full-decompile/functions/0x4051c8.c.
// All line references below are to those files. No generic 100/150 kill reward.
// The 2002 score formula is not established: nil means unknown, not zero points.

enum OriginalDamageWeapon: String { case bullet, cannon, missile, artillery }
enum OriginalHitEligibility: Equatable {
    case ignored
    case collisionVolumes
    case endpointRadius(Float)
    case splashOnly
    var blocksProjectile: Bool { self != .ignored && self != .splashOnly }
}
enum OriginalDeathMode: String {
    case none
    case falling
    case explode
    case wreck
    case infantryDeath
    case infantryDebris
    case unknown
}
enum OriginalDeathTrigger: String { case nextAIUpdate, originalCrashCondition }

struct OriginalDeferredDeath: Equatable {
    let trigger: OriginalDeathTrigger
    let scoreDelta: Int?
    let forceDelta: Float?
    let nextAIState: Int?
    let deactivate: Bool
    let evidence: String
}

struct OriginalDamageContext {
    let version: OriginalGameVersion
    let type: String
    let hitPoints: Int
    var aiState: Int? = nil
    var active = true
    var originalObjectIndex: Int? = nil
    var c130RemainingTroops: Int? = nil
    var canonicalType: String {
        let name = type.uppercased()
        if name.hasPrefix("APC") { return "APC" }
        if name.hasPrefix("BARGE") { return "BARGE" }
        return name
    }
}

struct OriginalDamageResult {
    var hitPoints: Int
    var nextAIState: Int? = nil
    var active: Bool
    var deathMode: OriginalDeathMode = .none
    var scoreDelta: Int?
    var forceDelta: Float? = 0
    var deferred: OriginalDeferredDeath? = nil
    var confirmed = true
    var consumesProjectile = true
    var removeParachute = false
    var evidence: String
    // A falling target remains active and can be hit again, as in the source.
    var beginsDeath: Bool { deathMode != .none && deathMode != .unknown }
}

enum OriginalDamage {
    // Eligibility uses the MOVED projectile's y, in ORIGINAL units. The missile
    // airborne test in the executable is endpoint distance <300, not a swept sphere.
    // A host choosing swept spheres must label that as an adapter improvement.
    static func eligibility(version: OriginalGameVersion, weapon: OriginalDamageWeapon,
                            type: String, sourceY: Float) -> OriginalHitEligibility {
        let t = OriginalDamageContext(version:version,type:type,hitPoints:0).canonicalType
        let otherAir = ["JET","COBRA","BOMBER","C130"].contains(t)
        let ground = t == "TANK" || t == "APC"
        switch weapon {
        case .bullet:
            if t == "CH53" || t == "SUPPLY" || t == "PARACHUTE" { return .collisionVolumes }
            if otherAir { return sourceY >= 750 ? .collisionVolumes : .ignored }
            if ground || t == "INFANTRY" { return sourceY < 750 ? .collisionVolumes : .ignored }
        case .cannon:
            if t == "CH53" || t == "SUPPLY" || t == "PARACHUTE" { return .collisionVolumes }
            if otherAir { return sourceY >= 750 ? .collisionVolumes : .ignored }
            if ground || (t == "BARGE" && version == .beach2000) {
                return sourceY < 750 ? .collisionVolumes : .ignored
            }
            if t == "INFANTRY" { return .splashOnly }
        case .missile:
            let cutoff: Float = version == .beach2000 ? 750 : 800
            if sourceY >= cutoff && (otherAir || t == "CH53") { return .endpointRadius(300) }
            if sourceY < cutoff && (ground || (t == "CH53" && version == .beach2002)) { return .collisionVolumes }
            if t == "INFANTRY" { return .splashOnly }
        case .artillery:
            if version == .beach2000 && t == "INFANTRY" { return .splashOnly }
        }
        return .ignored
    }

    static func initialHitPoints(version: OriginalGameVersion, type: String) -> Int? {
        let t = OriginalDamageContext(version:version,type:type,hitPoints:0).canonicalType
        if version == .beach2000 {
            if t == "BARGE" { return 1 } // Generic object field; destruction is not HP-based.
            return OriginalDamageRules.initialHitPoints2000(targetType:t)
        }
        // 2002 load-level.c:187-200. Ground c4 fields are not general HP:
        // APC AI state1 writes cargoLoaded=1, state9 writes0 (0x4051c8:656,855).
        switch t {
        case "JET", "BOMBER": return 4
        case "COBRA", "CH53", "C130": return 8
        default: return nil
        }
    }

    // Call only after an eligible hit has been established. C130 and airborne
    // parachutes may instead be routed through OriginalSupply; use ONE owner.
    static func resolve(_ c: OriginalDamageContext, weapon: OriginalDamageWeapon,
                        part: Int?) -> OriginalDamageResult {
        var r = OriginalDamageResult(hitPoints:c.hitPoints,active:c.active,
                                     scoreDelta:c.version == .beach2000 ? 0 : nil,evidence:"")
        guard c.active else { r.consumesProjectile = false; r.evidence = "inactive object omitted from original hit loops"; return r }
        guard weapon != .artillery else { return unknown(c, "Artillery uses splash(), not direct hit") }
        if c.canonicalType == "INFANTRY" {
            guard weapon == .bullet else { return unknown(c, "Explosive infantry damage requires original radius/state checks via splash()") }
            guard let state = c.aiState else { return unknown(c, "Infantry original AI state required") }
            if c.version == .beach2000 {
                r.evidence = "2000_update:716-745"
                guard state > 1 && state < 46 else { r.consumesProjectile = false; return r }
                r.nextAIState = 21; r.deathMode = .infantryDeath
                r.scoreDelta = state < 38 ? 1 : 0; r.forceDelta = state < 38 ? -1 : 0
                r.removeParachute = state >= 38
            } else {
                r.evidence = "2002_update:798-818"
                guard state > 1 && state < 42 else { return r }
                r.nextAIState = 60; r.deathMode = .infantryDeath; r.forceDelta = -1
            }
            return r
        }
        if c.version == .beach2000 { return resolve2000(c, weapon:weapon, part:part) }
        return resolve2002(c, weapon:weapon, part:part)
    }

    private static func unknown(_ c: OriginalDamageContext, _ evidence: String) -> OriginalDamageResult {
        OriginalDamageResult(hitPoints:c.hitPoints,active:c.active,deathMode:.unknown,
                             scoreDelta:nil,forceDelta:nil,confirmed:false,evidence:evidence)
    }

    private static func resolve2000(_ c: OriginalDamageContext, weapon: OriginalDamageWeapon,
                                    part: Int?) -> OriginalDamageResult {
        var r = OriginalDamageResult(hitPoints:c.hitPoints,active:c.active,scoreDelta:0,evidence:"")
        let t = c.canonicalType
        if weapon == .bullet {
            if t == "TANK" || t == "APC" { r.evidence = "2000_update:785-840 (impact only; armor)"; return r }
            if t == "BARGE" { r.consumesProjectile = false; r.evidence = "2000_update:219-898: no barge test in bullet pass"; return r }
            guard let part, part >= 0 else { return unknown(c, "Original aircraft hit-part index required") }
            guard ["JET","COBRA","BOMBER","CH53","C130"].contains(t) else { return unknown(c,"2000 target not audited") }
            if part > 2 { r.evidence = "2000_update:319-713: only returned parts0/1/2 change aircraft HP/state"; return r }
            if part == 0 && (t == "JET" || t == "CH53") {
                r.active = false; r.deathMode = .explode
                if t == "JET" { r.scoreDelta = 10; r.forceDelta = -10; r.evidence = "2000_update:638-661" }
                else { r.hitPoints = 0; r.scoreDelta = 2; r.evidence = "2000_update:333-359" }
                return r
            }
            r.evidence = ["JET":"2000_update:622-635","COBRA":"2000_update:481-505",
                          "BOMBER":"2000_update:553-569","CH53":"2000_update:319-331",
                          "C130":"2000_update:702-713"][t]!
            guard c.hitPoints > 0 else { return r }
            r.hitPoints -= part == 2 ? 1 : 2
            guard r.hitPoints < 1 else { return r }
            r.deathMode = .falling
            switch t {
            case "JET":
                r.nextAIState = 14
                r.deferred = .init(trigger:.originalCrashCondition,scoreDelta:10,forceDelta:-10,
                                   nextAIState:nil,deactivate:true,evidence:"2000_AI:1469-1470")
            case "COBRA":
                r.nextAIState = 13
                r.deferred = .init(trigger:.originalCrashCondition,scoreDelta:10,forceDelta:-10,
                                   nextAIState:nil,deactivate:true,evidence:"2000_AI:2286-2287")
            case "BOMBER":
                r.nextAIState = 6
                r.deferred = .init(trigger:.originalCrashCondition,scoreDelta:5,forceDelta:0,
                                   nextAIState:nil,deactivate:true,evidence:"2000_AI:1735")
            case "CH53":
                r.nextAIState = 16; r.scoreDelta = 2
                // Both increments exist: lethal non-part0 hit gives2, crash gives2.
                r.deferred = .init(trigger:.originalCrashCondition,scoreDelta:2,forceDelta:0,
                                   nextAIState:nil,deactivate:true,evidence:"2000_AI:4833-4892")
            case "C130":
                r.nextAIState = 4
                r.deferred = .init(trigger:.nextAIUpdate,scoreDelta:-10,forceDelta:0,
                                   nextAIState:5,deactivate:false,evidence:"2000_AI:2548-2552")
            default: break
            }
            return r
        }
        if t == "TANK" {
            r.evidence = weapon == .cannon ? "2000_update:1614-1679" : "2000_update:2107-2185"
            guard let state = c.aiState else { return unknown(c,r.evidence + "; requires original state !=20 and <2 tests") }
            guard state != 20 else { return r }
            r.nextAIState = 20; r.deathMode = .wreck; r.active = state >= 2
            r.scoreDelta = 5; r.forceDelta = -5
            return r // Original Tank HP field is not changed.
        }
        if t == "APC" {
            r.evidence = weapon == .cannon ? "2000_update:1723-1756" : "2000_update:2227-2266"
            if let state = c.aiState { r.active = state >= 2 } else { r.confirmed = false }
            if c.hitPoints != 0 || weapon == .missile {
                r.nextAIState = 20; r.hitPoints = 0; r.deathMode = .wreck
                r.scoreDelta = c.hitPoints != 0 ? 2 : 0
            }
            return r // Cargo soldiers resolve separately; no bulk force subtraction here.
        }
        if t == "BARGE" {
            if weapon == .cannon {
                r.evidence = "2000_update:1504-1600"
                r.nextAIState = 0; r.active = false; r.deathMode = .explode; r.scoreDelta = 2
            } else { r.evidence = "2000_update:2107-2473: no barge missile test"; r.consumesProjectile = false }
            return r
        }
        guard ["JET","COBRA","BOMBER","CH53","C130"].contains(t) else { return unknown(c,"2000 direct explosive target not audited") }
        r.active = false; r.deathMode = .explode
        switch t {
        case "JET", "COBRA": r.scoreDelta = 10; r.forceDelta = -10
        case "BOMBER": r.scoreDelta = 5
        case "CH53": r.hitPoints = 0; r.scoreDelta = 2
        case "C130": r.hitPoints = 0; r.scoreDelta = -10
        default: break
        }
        r.evidence = weapon == .cannon ? "2000_update:1150-1211,1287-1499" : "2000_update:2313-2473"
        return r
    }

    private static func resolve2002(_ c: OriginalDamageContext, weapon: OriginalDamageWeapon,
                                    part: Int?) -> OriginalDamageResult {
        var r = OriginalDamageResult(hitPoints:c.hitPoints,active:c.active,scoreDelta:nil,evidence:"")
        let t = c.canonicalType
        if weapon == .bullet {
            if t == "TANK" || t == "APC" { r.evidence = "2002_update:834-896 (impact only; armor)"; return r }
            guard ["JET","COBRA","BOMBER","CH53","C130"].contains(t) else { return unknown(c,"2002 ordinary-bullet target not audited") }
            guard let part, part >= 0 else { return unknown(c,"Original aircraft hit-part index required") }
            if t == "BOMBER" || part == 0 {
                r.active = false; r.deathMode = .explode
                switch t {
                case "JET": r.forceDelta = -10; r.evidence = "2002_update:559-567"
                case "COBRA": r.hitPoints = 0; r.forceDelta = -10; r.evidence = "2002_update:693-703"
                case "BOMBER": r.nextAIState = 0; r.evidence = "2002_update:615-630; explode helper0x4232fa:29"
                case "CH53":
                    r.hitPoints = 0; r.forceDelta = c.aiState.map { $0 < 8 ? -6 : 0 }
                    r.evidence = "2002_update:341-356"
                case "C130":
                    r.forceDelta = c.c130RemainingTroops.map { -Float($0) }
                    r.evidence = "2002_update:771-790; use OriginalSupply as exclusive C130 owner"
                default: break
                }
                return r
            }
            if part > 2 { r.evidence = "2002_update:321-790: non-bomber aircraft damage branches only parts0/1/2"; return r }
            r.evidence = ["JET":"2002_update:548-558","COBRA":"2002_update:681-692",
                          "CH53":"2002_update:321-340","C130":"2002_update:758-770"][t]!
            guard c.hitPoints > 0 else { return r }
            r.hitPoints -= part == 2 ? 1 : 2
            guard r.hitPoints < 1 else { return r }
            r.deathMode = .falling
            switch t {
            case "JET":
                r.nextAIState = 15
                r.deferred = .init(trigger:.originalCrashCondition,scoreDelta:nil,forceDelta:-10,
                                   nextAIState:nil,deactivate:true,evidence:"2002_AI:2339")
            case "COBRA":
                r.nextAIState = 14
                r.deferred = .init(trigger:.originalCrashCondition,scoreDelta:nil,forceDelta:-10,
                                   nextAIState:nil,deactivate:true,evidence:"2002_AI:3042")
            case "CH53":
                r.nextAIState = 13; r.forceDelta = c.aiState.map { $0 < 8 ? -6 : 0 }
                r.deferred = .init(trigger:.originalCrashCondition,scoreDelta:nil,forceDelta:0,
                                   nextAIState:nil,deactivate:true,evidence:"2002_AI:4937 onward; force already deducted in hit pass")
            case "C130":
                r.nextAIState = 5
                r.deferred = .init(trigger:.originalCrashCondition,scoreDelta:nil,
                                   forceDelta:c.c130RemainingTroops.map { -Float($0) },
                                   nextAIState:nil,deactivate:true,evidence:"2002_AI:1810; use OriginalSupply as exclusive C130 owner")
            default: break
            }
            return r
        }
        if t == "TANK" {
            r.evidence = weapon == .cannon ? "2002_update:1404-1467" : "2002_update:1789-1867"
            guard let state = c.aiState else { return unknown(c,r.evidence + "; requires original state !=0 test") }
            r.nextAIState = 0
            if state != 0 { r.forceDelta = -10; r.deathMode = .wreck }
            return r // Tank body remains active; turret breakup is a separate visual consequence.
        }
        if t == "APC" {
            r.evidence = weapon == .cannon ? "2002_update:1470-1512" : "2002_update:1870-1932"
            r.active = false; r.deathMode = .explode
            if let index = c.originalObjectIndex {
                r.forceDelta = -(c.hitPoints == 1 ? 6 : 0) - (index > 0x4c ? 5 : 0)
            } else { r.forceDelta = nil }
            return r // c4 is cargoLoaded, not a damage bar, and is not changed here.
        }
        guard ["JET","COBRA","BOMBER","CH53","C130"].contains(t) else { return unknown(c,"2002 direct explosive target not audited") }
        r.active = false; r.deathMode = .explode
        switch t {
        case "JET": r.forceDelta = -10; if weapon == .cannon { r.nextAIState = 0 }
        case "COBRA": r.forceDelta = -10
        case "BOMBER": if weapon == .cannon { r.nextAIState = 0 }
        case "CH53": r.forceDelta = c.aiState.map { $0 < 8 ? -6 : 0 }
        case "C130": r.forceDelta = c.c130RemainingTroops.map { -Float($0) }
        default: break
        }
        r.evidence = weapon == .cannon ? "2002_update:1045-1100,1200-1400" : "2002_update:1937-2075"
        return r
    }

    static func splashProfile(version: OriginalGameVersion, weapon: OriginalDamageWeapon)
        -> (radius: Float, horizontalOnly: Bool)? {
        if version == .beach2000 {
            if weapon == .artillery { return (400,false) }
            if weapon == .cannon || weapon == .missile { return (300,false) }
        } else if weapon == .cannon || weapon == .missile { return (400,true) }
        return nil
    }

    // Caller must test the original explosion radius before calling this, and
    // supply the original shared RNG draw for 2002 debris variants if available.
    static func splash(_ c: OriginalDamageContext, weapon: OriginalDamageWeapon,
                       random15: Int? = nil, allowEmbarked2000: Bool = false) -> OriginalDamageResult {
        guard c.canonicalType == "INFANTRY", splashProfile(version:c.version,weapon:weapon) != nil,
              let state = c.aiState else { return unknown(c,"Infantry splash requires supported weapon and original AI state") }
        var r = OriginalDamageResult(hitPoints:c.hitPoints,active:c.active,scoreDelta:c.version == .beach2000 ? 0 : nil,
                                     evidence:c.version == .beach2000 ? "2000_update:954-984,1074-1100,2030-2058,3100-3122" : "2002_update:990-1041,1742-1786")
        r.consumesProjectile = false // Explosion already consumed its projectile.
        guard c.active else { return r }
        if c.version == .beach2000 {
            // Enemy rocket/bomb branch2674 only checks active; unlike shell it can hit embarked states1...3.
            if weapon != .artillery && !allowEmbarked2000 && state <= 3 { return r }
            r.active = false; r.deathMode = .infantryDebris; r.removeParachute = state > 37
            let counted = state < 21 || (state > 25 && state < 38) || state > 59
            r.scoreDelta = counted ? 1 : 0; r.forceDelta = counted ? -1 : 0
        } else {
            guard state > 1 && state < 42 else { return r }
            r.deathMode = .infantryDebris; r.forceDelta = -1
            if let random15 {
                let variant = random15 >> 12
                if (0...7).contains(variant) { r.nextAIState = [70,70,71,71,72,72,73,74][variant] }
                else { r.confirmed = false }
            } else { r.confirmed = false } // Missing RNG leaves animation state unresolved.
        }
        return r
    }
}

func testOriginalDamage() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain:"OriginalDamage",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    let oldTank = OriginalDamageContext(version:.beach2000,type:"TANK",hitPoints:1,aiState:3)
    let armored = OriginalDamage.resolve(oldTank,weapon:.bullet,part:0)
    try check(armored.hitPoints == 1 && armored.deathMode == .none && armored.consumesProjectile, "armor consumes bullet without damage")
    let wreck = OriginalDamage.resolve(oldTank,weapon:.cannon,part:1)
    try check(wreck.nextAIState == 20 && wreck.active && wreck.scoreDelta == 5 && wreck.forceDelta == -5, "2000 tank becomes wreck with exact reward")
    let repeatHit = OriginalDamage.resolve(.init(version:.beach2000,type:"TANK",hitPoints:1,aiState:20),weapon:.cannon,part:0)
    try check(repeatHit.scoreDelta == 0 && repeatHit.forceDelta == 0, "wreck never awards another tank kill")
    let oldCobra = OriginalDamage.resolve(.init(version:.beach2000,type:"COBRA",hitPoints:8,aiState:1),weapon:.bullet,part:0)
    let newCobra = OriginalDamage.resolve(.init(version:.beach2002,type:"COBRA",hitPoints:8,aiState:1),weapon:.bullet,part:0)
    try check(oldCobra.hitPoints == 6 && oldCobra.active && !newCobra.active && newCobra.forceDelta == -10 && newCobra.scoreDelta == nil,
              "Cobra part0 differs between versions and no invented 2002 score")
    let ch53 = OriginalDamage.resolve(.init(version:.beach2000,type:"CH53",hitPoints:1,aiState:1),weapon:.bullet,part:1)
    try check(ch53.hitPoints == -1 && ch53.nextAIState == 16 && ch53.scoreDelta == 2 && ch53.deferred?.scoreDelta == 2,
              "CH53 original negative HP, hit score and distinct later crash score")
    let beforeUnload = OriginalDamage.resolve(.init(version:.beach2002,type:"APC2",hitPoints:1,aiState:4,originalObjectIndex:77),weapon:.missile,part:0)
    let afterUnload = OriginalDamage.resolve(.init(version:.beach2002,type:"APC2",hitPoints:0,aiState:10,originalObjectIndex:77),weapon:.missile,part:0)
    try check(beforeUnload.forceDelta == -11 && afterUnload.forceDelta == -5, "2002 armed APC cargo flag changes exact force decrement")
    let transport = OriginalDamage.resolve(.init(version:.beach2002,type:"CH53",hitPoints:1,aiState:8),weapon:.bullet,part:1)
    try check(transport.forceDelta == 0 && transport.nextAIState == 13, "unloaded CH53 does not remove six troops again")
    let friendly = OriginalDamage.resolve(.init(version:.beach2000,type:"C130",hitPoints:1,aiState:2),weapon:.bullet,part:2)
    try check(friendly.scoreDelta == 0 && friendly.deferred?.scoreDelta == -10 && friendly.deferred?.trigger == .nextAIUpdate,
              "2000 supply-plane penalty waits for state4 AI and affects score")
    let airCargo = OriginalDamage.resolve(.init(version:.beach2002,type:"C130",hitPoints:8,aiState:1,c130RemainingTroops:3),weapon:.cannon,part:1)
    try check(airCargo.forceDelta == -3 && airCargo.scoreDelta == nil, "2002 C130 force comes from remaining cargo, no fixed penalty")
    try check(OriginalDamage.eligibility(version:.beach2000,weapon:.bullet,type:"BARGE",sourceY:0) == .ignored &&
              OriginalDamage.eligibility(version:.beach2000,weapon:.cannon,type:"BARGE",sourceY:0) == .collisionVolumes &&
              OriginalDamage.eligibility(version:.beach2000,weapon:.missile,type:"CH53",sourceY:749) == .ignored &&
              OriginalDamage.eligibility(version:.beach2002,weapon:.missile,type:"CH53",sourceY:749) == .collisionVolumes &&
              OriginalDamage.eligibility(version:.beach2002,weapon:.missile,type:"JET",sourceY:800) == .endpointRadius(300),
              "version-specific altitude gates and nonblocking classes")
    let soldier = OriginalDamage.resolve(.init(version:.beach2000,type:"INFANTRY",hitPoints:1,aiState:10),weapon:.bullet,part:nil)
    try check(soldier.nextAIState == 21 && soldier.scoreDelta == 1 && soldier.forceDelta == -1, "2000 infantry hit enters death state")
    let debris = OriginalDamage.splash(.init(version:.beach2002,type:"INFANTRY",hitPoints:1,aiState:10),weapon:.cannon,random15:30000)
    try check(debris.nextAIState == 74 && debris.forceDelta == -1, "2002 splash debris preserves original RNG variant mapping")
    try check(!OriginalDamage.resolve(.init(version:.beach2000,type:"JET",hitPoints:4),weapon:.bullet,part:nil).confirmed,
              "missing hit volume never silently defaults to lethal part0")
    print("PASS: original version-specific armor/aircraft damage, exact 2000 score, deferred deaths, cargo force, eligibility gates, infantry states and explicit unknowns")
}
