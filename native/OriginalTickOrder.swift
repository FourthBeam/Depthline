import Foundation

/// Explicit pass order from the exported original AI procedures. Rendering
/// adapters may combine a pass internally, but cannot move RNG-consuming work
/// across these boundaries. In particular, infantry is enumerated AFTER cargo
/// release so newly unloaded soldiers participate in the same logical tick.
enum OriginalTickOrder {
    enum Phase: String, CaseIterable {
        case barges, tanks, apcs, groundAvoidance
        case c130Aircraft, jets, bombers, cobras, ch53
        case supplyPayloads, infantry, embarkedInfantry, groundAlignment, terrainShadows
    }

    /// 2000 FUN_00406805:201/242/581/759/927/989/1587/1879;
    /// CH53 do-loop begins2453; chute212...213 precedes C130207, then the
    /// 84 infantry records, state>=60 carrier records, alignment and shadows.
    static let beach2000: [Phase] = [
        .barges, .tanks, .apcs, .groundAvoidance,
        .jets, .bombers, .cobras, .ch53,
        .supplyPayloads, .c130Aircraft, .infantry, .embarkedInfantry,
        .groundAlignment, .terrainShadows
    ]

    /// 2002 FUN_004051c8:226/607/1114/1289/1465/1868/2445/2560;
    /// CH53 do-loop starts3168 and its body is emitted after the return by
    /// Ghidra. Chutes294...357, boxes454...469 and infantry358...453 follow,
    /// then ground height alignment4368 and shadow vertices4489.
    static let beach2002: [Phase] = [
        .tanks, .apcs, .groundAvoidance,
        .c130Aircraft, .jets, .bombers, .cobras, .ch53,
        .supplyPayloads, .infantry, .groundAlignment, .terrainShadows
    ]

    static func phases(gameID: String) -> [Phase] { gameID == "2000" ? beach2000 : beach2002 }
    static func run(gameID: String, perform: (Phase) throws -> Void) rethrows {
        for phase in phases(gameID: gameID) { try perform(phase) }
    }
    static func phase(type: String) -> Phase? {
        switch type.uppercased() {
        case "BARGE", "BARGE_VEHICLE": return .barges
        case "TANK": return .tanks
        case "APC", "APC1", "APC2", "APC3": return .apcs
        case "C130": return .c130Aircraft
        case "JET": return .jets
        case "BOMBER", "B52": return .bombers
        case "COBRA": return .cobras
        case "CH53": return .ch53
        case "INFANTRY": return .infantry
        default: return nil
        }
    }

    /// Resolve the live collection for EACH phase. Capturing one array before
    /// run() would omit soldiers added by APC/CH53/C130 earlier that tick.
    /// Within a pass, original object order is deterministic, independent of
    /// activation/append order or a host dictionary's iteration order.
    static func visit<T>(_ phase: Phase, objects: () -> [T], type: (T) -> String,
                         objectID: (T) -> Int, update: (T) throws -> Void) rethrows {
        let ordered = objects().enumerated().filter { self.phase(type: type($0.element)) == phase }
            .sorted {
                let a = objectID($0.element), b = objectID($1.element)
                return a == b ? $0.offset < $1.offset : a < b
            }
        for row in ordered { try update(row.element) }
    }

    /// The projectile function emits new fire only AFTER old flights/hits and
    /// the generic object transform pass. These are emitter-object ranges,
    /// distinct from the hull order used by the AI above.
    static func emitterRank2002(type: String, slot: Int) -> Int {
        switch type.uppercased() {
        case "TANK": return 61 + slot
        case "APC2": return 105 + slot
        case "APC3": return 109 + slot
        case "JET": return 117 + slot
        case "BOMBER": return 133 + slot
        case "COBRA": return 142 + slot
        default: return 10000 + slot
        }
    }
}

/// Source globals are Float phases, incremented and wrapped after the active
/// update. Using an individual aircraft's age changes delayed-spawn hovering.
/// Keep this process clock across level loads; restarting a mission does not
/// reconstruct a new source process. Tests may explicitly replace it.
struct OriginalTickClock {
    private(set) var ticks = 0
    private(set) var phases = SIMD4<Float>.zero
    var parity: Int { ticks & 1 }
    var hoverPhasesDegrees: SIMD4<Double> { .init(Double(phases.x), Double(phases.y), Double(phases.z), Double(phases.w)) }
    mutating func advance() {
        ticks += 1
        phases += SIMD4<Float>(4.1, 6, 9.5, 12.2)
        for i in 0..<4 where phases[i] > 360 { phases[i] -= 360 }
    }
}

func originalTickOrderSelfTest() throws {
    struct Failure: Error { let reason: String }
    func check(_ good: Bool, _ why: String) throws { if !good { throw Failure(reason: why) } }
    // A deliberately scrambled live collection plus a real mutation between
    // passes catches both append-order traversal and eager whole-tick snapshots.
    struct Row { let type: String; let id: Int }
    var rows = [Row(type: "INFANTRY", id: 361), Row(type: "COBRA", id: 143),
                Row(type: "APC2", id: 77), Row(type: "TANK", id: 38), Row(type: "TANK", id: 37)]
    var visited: [Int] = [], infantryBornThisTick = false
    OriginalTickOrder.run(gameID: "2002") { phase in
        OriginalTickOrder.visit(phase, objects: { rows }, type: { $0.type }, objectID: { $0.id }) { row in
            visited.append(row.id)
            if row.id == 77 { rows.append(Row(type: "INFANTRY", id: 358)); infantryBornThisTick = true }
            if row.id == 358 { infantryBornThisTick = false }
        }
    }
    try check(visited == [37, 38, 77, 143, 358, 361] && !infantryBornThisTick,
              "source slot order and a newly unloaded soldier's same-tick update")
    for game in ["2000", "2002"] {
        let order = OriginalTickOrder.phases(gameID: game)
        func before(_ first: OriginalTickOrder.Phase, _ last: OriginalTickOrder.Phase) -> Bool {
            order.firstIndex(of: first)! < order.firstIndex(of: last)!
        }
        try check(before(.groundAvoidance, .jets) && before(.ch53, .infantry) && before(.infantry, .groundAlignment),
                  "independent ground second pass, post-carrier infantry, late ground alignment")
        try check(game == "2000" ? before(.supplyPayloads, .c130Aircraft) : before(.c130Aircraft, .supplyPayloads),
                  "version-specific supply aircraft/payload order")
    }
    var clock = OriginalTickClock()
    try check(clock.parity == 0 && clock.phases == .zero, "source globals begin at zero before first active update")
    for _ in 0..<60 { clock.advance() }
    try check(clock.phases.y == 360, "source wraps only strictly beyond360")
    clock.advance()
    try check(clock.phases.y == 6 && clock.parity == 1, "global phase advances once after update")
    try check(OriginalTickOrder.emitterRank2002(type: "JET", slot: 15) < OriginalTickOrder.emitterRank2002(type: "BOMBER", slot: 0),
              "Jet fire precedes shared-bomb-bank bomber fire")
    print("PASS original tick order: independent passes, numeric slots, same-tick cargo, version-specific supplies and global phases")
}
