import Foundation

/// Scheduling and campaign bookkeeping recovered from the two original core binaries.
/// Run tick() once per active simulation update. 0.029s maps the original enabled >28ms limiter;
/// it is not a claim that the Windows executable always achieved that wall-clock cadence.
final class OriginalCampaign {
    static let tickDuration = 0.029

    struct SpawnEvent: Equatable {
        let type: String
        let slot: Int
        let sourceIndex: Int
        let cargoFamily: String?
        let direction: String?
        let force: Double
        let generation: Int
    }
    enum Transition: Equatable {
        case nextLevel(level: Int, bonus: Int)
        case defeat
    }
    struct OutcomeUpdate {
        let health: Int
        let inputLocked: Bool
        let transition: Transition?
    }
    private struct Source {
        let type: String
        let slot: Int
        let index: Int
        let cargoFamily: String?
        let direction: String?
        let force: Double
        let delay: Int
        let repeats: Bool
        var active: Bool
        var remainingActivations: Int
        var countdown: Int
        var generation = 0
        var remainingForce: Double

        var event: SpawnEvent {
            SpawnEvent(type: type, slot: slot, sourceIndex: index, cargoFamily: cargoFamily,
                       direction: direction, force: force, generation: generation)
        }
    }
    let gameID: String
    let level: Int
    let initialForce: Double
    let machineGunVariant: Int
    private var sources: [Source]
    private var initialSpawns: [SpawnEvent]
    private var endCountdown = 150
    private var secondAccumulator = 0.0
    private var terminal = false
    private(set) var activeTicks = 0
    private(set) var remainingSeconds: Int?
    var remainingForce: Double { max(0, sources.reduce(0) { $0 + $1.remainingForce }) }
    var endDelayTicks: Int { endCountdown }
    var pendingSpawnCount: Int { sources.reduce(0) { $0 + $1.remainingActivations } }

    init(gameID: String, level: Int, definition: [String: Any]) {
        self.gameID = gameID
        self.level = max(1, level)
        self.machineGunVariant = Self.machineGunVariant(definition: definition)
        self.remainingSeconds = gameID == "2000" ? max(0, Self.integer(definition["time"], default: 120)) : nil
        var prepared: [Source] = []
        var ordinals: [String: Int] = [:]
        for (index, object) in (definition["objects"] as? [[String: Any]] ?? []).enumerated() {
            let rawType = (object["type"] as? String ?? "").uppercased()
            let type = ["HELICOPTER1": "COBRA", "HELICOPTER2": "CH53", "APC": "APC1"][rawType] ?? rawType
            let ordinal = ordinals[type, default: 0]
            ordinals[type] = ordinal + 1
            let slot = Self.integer(object["slot"], default: ordinal)
            // ObjectInc can walk into child-model slots in the supplied scripts (Level32/79).
            // The original AI and force loops stop at the hull bounds; these are not extra units.
            if gameID == "2002", let count = Self.slotCount2002[type], !(0..<count).contains(slot) { continue }
            let delay = Self.integer(object["delay"])
            let force = Self.force(gameID: gameID, type: type, slot: slot, object: object)
            let active: Bool
            let activations: Int
            let repeats: Bool
            if gameID == "2000" {
                // 0x405d14: Delay only counts while the original slot is hidden and Revive>0.
                active = Self.integer(object["visible"], default: 1) == 1
                activations = max(0, Self.integer(object["revive"]))
                repeats = ["JET", "COBRA", "BOMBER"].contains(type)
            } else {
                // 0x429201: the presence of Delay hides a slot, including an explicit Delay0.
                // 0x4050f1 enables it only when decrementing the counter reaches exactly zero.
                active = object["delay"] == nil
                activations = object["delay"] != nil && delay > 0 ? 1 : 0
                repeats = false
            }
            let totalForce = force * Double((active ? 1 : 0) + activations)
            prepared.append(Source(type: type, slot: slot, index: index,
                                   cargoFamily: object["cargoFamily"] as? String,
                                   direction: object["direction"] as? String,
                                   force: force, delay: delay, repeats: repeats, active: active,
                                   remainingActivations: activations, countdown: delay,
                                   remainingForce: totalForce))
        }
        self.sources = prepared
        self.initialSpawns = prepared.filter(\.active).map(\.event)
        self.initialForce = prepared.reduce(0) { $0 + $1.remainingForce }
    }

    /// The originals recycle resource files while retaining a monotonically increasing campaign level.
    /// BH2002's exact mapping can return100 (e.g. level109), but this supplied package lacks Level_100.
    /// The caller must report that missing resource, rather than silently select a different mission.
    static func sourceLevel(gameID: String, level: Int) -> Int {
        let level = max(1, level)
        if gameID == "2000" { return level <= 60 ? level : level % 10 + 51 }
        return level <= 99 ? level : level % 10 + 91
    }
    static let slotCount2002 = ["TANK": 12, "APC1": 4, "APC2": 4, "APC3": 4,
                               "JET": 16, "BOMBER": 9, "COBRA": 12, "CH53": 8, "C130": 8]

    static func machineGunVariant(definition: [String: Any]) -> Int {
        let commands = definition["commands"] as? [[String: Any]]
        let names = commands?.compactMap { $0["name"] as? String } ?? (definition["flags"] as? [String] ?? [])
        var variant = 0
        for name in names {
            if name == "AltGun" { variant = 1 }
            if name == "AltGun2" { variant = 2 }
        }
        return variant
    }

    func takeInitialSpawns() -> [SpawnEvent] {
        defer { initialSpawns.removeAll() }
        return initialSpawns
    }

    func tick() -> [SpawnEvent] {
        guard !terminal else { return [] }
        activeTicks += 1
        var events = takeInitialSpawns()
        for i in sources.indices where !sources[i].active && sources[i].remainingActivations > 0 {
            sources[i].countdown -= 1
            let due = gameID == "2000" ? sources[i].countdown < 1 : sources[i].countdown == 0
            guard due else { continue }
            sources[i].active = true
            sources[i].generation += 1
            if gameID == "2000" && sources[i].repeats {
                sources[i].remainingActivations -= 1
                sources[i].countdown = sources[i].delay
            } else {
                sources[i].remainingActivations = 0
            }
            events.append(sources[i].event)
        }
        return events
    }

    /// Signals removal of the source hull, enabling an original2000 Revive countdown.
    /// For unloading/exit, pass0; debit surviving cargo later via resolveForce. The source index
    /// stays stable across generations and is the original definition.objects array index.
    func enemyRemoved(sourceIndex: Int, forceRemoved: Double? = nil) {
        guard let i = sources.firstIndex(where: { $0.index == sourceIndex }), sources[i].active else { return }
        sources[i].active = false
        resolveForce(sourceIndex: sourceIndex, amount: forceRemoved ?? sources[i].force)
    }

    /// Debit original force points, not the number of render nodes. Do not add cargo force on unload:
    /// the original initial total already includes the soldiers carried by APC/CH53/C130/Barge.
    func resolveForce(sourceIndex: Int, amount: Double) {
        guard amount.isFinite, amount > 0,
              let i = sources.firstIndex(where: { $0.index == sourceIndex }) else { return }
        sources[i].remainingForce = max(0, sources[i].remainingForce - amount)
    }

    func forceRemaining(sourceIndex: Int) -> Double {
        sources.first(where: { $0.index == sourceIndex })?.remainingForce ?? 0
    }

    /// Original 2002 '=' writes the force meter to zero; it does not remove active enemies or
    /// cancel delayed activations. The caller records that this run used a native cheat control.
    func applyForceZeroCheat() {
        guard gameID == "2002" else { return }
        for index in sources.indices { sources[index].remainingForce = 0 }
    }

    /// Both originals reset the shared battle-end/ammo-starvation delay when a supply is collected.
    func noteSupplyCollected() { endCountdown = 150 }

    /// Call once after each active update. Returned health applies the original all-ammunition-empty
    /// fallback; flares and artillery availability are not part of that empty-ammunition condition.
    func tickOutcome(health: Int, ammunitionExhausted: Bool,
                     wallTimeDelta: Double = OriginalCampaign.tickDuration,
                     immediateVictory: Bool = false) -> OutcomeUpdate {
        guard !terminal else { return OutcomeUpdate(health: max(0, health), inputLocked: true, transition: nil) }
        if remainingSeconds != nil, wallTimeDelta.isFinite, wallTimeDelta > 0 {
            secondAccumulator += wallTimeDelta
            let elapsed = Int(secondAccumulator.rounded(.down))
            if elapsed > 0 {
                remainingSeconds = max(0, remainingSeconds! - elapsed)
                secondAccumulator -= Double(elapsed)
            }
        }
        var resultHealth = max(0, health)
        let won = gameID == "2000" ? remainingForce < 1 : remainingForce < 0.0001
        if won && (!immediateVictory || resultHealth > 0) {
            endCountdown -= 1
            if immediateVictory || endCountdown == 0 {
                terminal = true
                let bonus = gameID == "2000" ? (remainingSeconds ?? 0) / 10 : 0
                return OutcomeUpdate(health: resultHealth, inputLocked: true,
                                     transition: .nextLevel(level: level + 1, bonus: bonus))
            }
        }
        if resultHealth < 1 {
            endCountdown -= 1
            if endCountdown == 0 {
                terminal = true
                return OutcomeUpdate(health: 0, inputLocked: true, transition: .defeat)
            }
        }
        // Mirrors the original shared-counter ordering: after victory/defeat display processing.
        if ammunitionExhausted && endCountdown > 90 {
            endCountdown -= 1
            if endCountdown == 90 && remainingForce > 0 { resultHealth = 0 }
        }
        return OutcomeUpdate(health: resultHealth, inputLocked: won || resultHealth < 1, transition: nil)
    }

    private static func integer(_ value: Any?, default fallback: Int = 0) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String, let number = Int(text) { return number }
        return fallback
    }
    private static func force(gameID: String, type: String, slot: Int, object: [String: Any]) -> Double {
        if gameID == "2000" {
            switch type {
            case "BARGE": return slot < 6 ? 8 : 0 // Vehicle-carrying barges have no independent force.
            case "TANK": return 5
            case "APC1", "APC2", "APC3", "CH53": return 6
            case "JET", "COBRA": return 10
            default: return 0 // Bomber/C130 do not contribute to the original enemy meter.
            }
        }
        switch type {
        case "TANK", "JET", "COBRA": return 10
        case "APC1", "CH53": return 6
        case "APC2", "APC3": return 11
        case "C130": return Double(min(16, max(0, integer(object["troops1"]))) + min(16, max(0, integer(object["troops2"]))))
        default: return 0
        }
    }
}

func originalCampaignSelfTest() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "OriginalCampaignTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let a = OriginalCampaign(gameID: "2000", level: 1, definition: ["time": 90, "objects": [
        ["type": "BARGE", "slot": 0, "visible": 1, "delay": 200],
        ["type": "JET", "slot": 0, "visible": 0, "delay": 3, "revive": 2],
        ["type": "BOMBER", "slot": 0, "visible": 0, "delay": 1, "revive": 1]
    ]])
    try require(a.initialForce == 28 && a.takeInitialSpawns().map(\.type) == ["BARGE"], "Visible2000 units must start immediately and future revives count toward force")
    try require(a.tick().map(\.type) == ["BOMBER"] && a.tick().isEmpty && a.tick().map(\.type) == ["JET"], "Hidden units must wait exactly Delay active ticks")
    for _ in 0..<10 { try require(a.tick().isEmpty, "A live aircraft must not duplicate itself") }
    a.enemyRemoved(sourceIndex: 1)
    try require(a.remainingForce == 18 && a.tick().isEmpty && a.tick().isEmpty && a.tick().map(\.generation) == [2], "Revive starts only after removal and resets its delay")
    a.enemyRemoved(sourceIndex: 0, forceRemoved: 0)
    for _ in 0..<8 { a.resolveForce(sourceIndex: 0, amount: 1) }
    try require(a.remainingForce == 10, "Unloading must preserve and then debit cargo force exactly once")
    a.enemyRemoved(sourceIndex: 1)
    try require(a.remainingForce == 0, "Supply/bomber hulls must not block victory")
    for _ in 0..<149 { try require(a.tickOutcome(health: 100, ammunitionExhausted: false).transition == nil, "Victory delay must be150 active ticks") }
    try require(a.tickOutcome(health: 100, ammunitionExhausted: false).transition == .nextLevel(level: 2, bonus: 8), "2000 victory adds the remaining-seconds bonus")
    let b = OriginalCampaign(gameID: "2002", level: 100, definition: ["flags": ["AltGun", "AltGun2"], "objects": [
        ["type": "APC2", "delay": 2], ["type": "C130", "adrop": 2],
        ["type": "C130", "delay": 1, "troops1": 8, "troops2": 3], ["type": "TANK", "delay": 0]
    ]])
    try require(b.initialForce == 22 && b.takeInitialSpawns().count == 1 && b.machineGunVariant == 2, "2002 force excludes pure supplies and Delay0 never activates")
    try require(b.tick().map(\.sourceIndex) == [2] && b.tick().map(\.sourceIndex) == [0], "2002 order follows original tick delays")
    var health = 100
    for _ in 0..<59 { health = b.tickOutcome(health: health, ammunitionExhausted: true).health }
    try require(health == 100 && b.endDelayTicks == 91, "Ammo starvation grace period must not end early")
    health = b.tickOutcome(health: health, ammunitionExhausted: true).health
    try require(health == 0 && b.endDelayTicks == 90, "All ammo empty sets health0 on tick60")
    for _ in 0..<89 { try require(b.tickOutcome(health: 0, ammunitionExhausted: true).transition == nil, "Defeat waits the remaining shared delay") }
    try require(b.tickOutcome(health: 0, ammunitionExhausted: true).transition == .defeat, "Defeat must emit once after90 more ticks")
    try require(b.tickOutcome(health: 0, ammunitionExhausted: true).transition == nil, "End transitions must be idempotent")
    try require(OriginalCampaign.sourceLevel(gameID: "2000", level: 61) == 52 && OriginalCampaign.sourceLevel(gameID: "2000", level: 70) == 51, "Preserve2000 original modulo mapping")
    try require(OriginalCampaign.sourceLevel(gameID: "2002", level: 100) == 91 && OriginalCampaign.sourceLevel(gameID: "2002", level: 109) == 100, "Preserve2002 original missing-Level100 edge instead of fabricating a mission")
    let cheat = OriginalCampaign(gameID: "2002", level: 1, definition: ["objects": [["type": "TANK", "delay": 2]]])
    cheat.applyForceZeroCheat()
    try require(cheat.remainingForce == 0 && cheat.pendingSpawnCount == 1 && cheat.tick().isEmpty
                && cheat.tick().count == 1, "2002 force-zero cheat must preserve pending enemies")
    let notCheat = OriginalCampaign(gameID: "2000", level: 1, definition: ["objects": [["type": "TANK", "visible": 1]]])
    notCheat.applyForceZeroCheat()
    try require(notCheat.remainingForce == 5, "Force-zero cheat must not alter2000")
    print("PASS: original campaign ticks, initial visibility, inactive-only revive, cargo force, supply exclusion, delayed victory, time bonus, ammo starvation, defeat and resource-loop mapping")
}
