import Foundation
import SceneKit
import simd

enum OriginalFragmentStyle { case airburst, groundBurst }

/// Source debris storage uses whole-object translation and rotation: chunks are
/// not recentered on their polygon centroids. Every new explosion overwrites the
/// same global fragment array. Sources are indexed in original-fragments.json.
struct OriginalFragmentState {
    let objectID: Int
    var position: SIMD3<Double>
    var rotationDegrees: SIMD3<Double>
    var velocity: SIMD3<Double>
    let angularVelocity: SIMD3<Double>
    var active = true

    init(objectID: Int, position: SIMD3<Double>, rotationDegrees: SIMD3<Double>,
         style: OriginalFragmentStyle, random15: () -> Int) {
        self.objectID = objectID; self.position = position; self.rotationDegrees = rotationDegrees
        let spinDivisor = style == .airburst ? 2000 : 1000
        // The source divides integers BEFORE converting to float. Avoid replacing
        // this with continuous noise; preserve the X,Y,Z then X,Z,Y RNG order.
        angularVelocity = .init(Double((random15()-16384)/spinDivisor),
                                Double((random15()-16384)/spinDivisor),
                                Double((random15()-16384)/spinDivisor))
        let divisor = style == .airburst ? 200 : 800
        let vx = Double((random15()-16384)/divisor)
        let vz = Double((random15()-16384)/divisor)
        let vy = style == .airburst ? Double((random15()-16384)/200) : Double(random15()/500+20)
        velocity = .init(vx, vy, vz)
    }

    /// BH2002 Tank hits unlink the authored turret, using FOUR floating-point
    /// random divisions (unlike the six integer divisions of polygon debris).
    init(tankTurretObjectID: Int, position: SIMD3<Double>, rotationDegrees: SIMD3<Double>,
         random15: () -> Int) {
        objectID=tankTurretObjectID; self.position=position; self.rotationDegrees=rotationDegrees
        let sx=(Double(random15())-16384)/8000
        let sz=(Double(random15())-16384)/8000
        angularVelocity = .init(sx,0,sz)
        let vx=(Double(random15())-16384)/1000
        let vz=(Double(random15())-16384)/1000
        velocity = .init(vx,40,vz)
    }

    mutating func advanceOrientation() {
        guard active else { return }
        rotationDegrees += angularVelocity
        for axis in 0..<3 {
            if rotationDegrees[axis] > 360 { rotationDegrees[axis] -= 360 }
            if rotationDegrees[axis] < -360 { rotationDegrees[axis] += 360 }
        }
    }

    mutating func advancePosition() {
        guard active else { return }
        // Original updater tests WORLD sea level, not local terrain height. The
        // source checks previous Y, so a below-zero result survives to next tick.
        guard position.y >= 0 else { active = false; return }
        velocity.x *= 0.98; velocity.z *= 0.98; velocity.y -= 3
        position += velocity
    }
}

final class OriginalFragments {
    struct Snapshot {
        let state: OriginalFragmentState
        let node: SCNNode
        let sourceCommandCount: Int
        let sourcePolygonCount: Int
    }
    private final class Piece {
        var state: OriginalFragmentState
        let node: SCNNode
        let commandCount: Int, polygonCount: Int
        init(state: OriginalFragmentState, node: SCNNode, commands: Int, polygons: Int) {
            self.state=state; self.node=node; commandCount=commands; polygonCount=polygons
        }
    }
    private struct Template {
        let node: SCNNode
        let commands: Int, polygons: Int
    }
    let version: OriginalGameVersion
    let parent: SCNNode
    private let objects: [Int: [String: Any]]
    let wrecks2000: Original2000Wrecks?
    private var templates: [String: [Template]] = [:]
    private var pieces: [Piece] = []
    // Turrets49..<61 have their own original physics loop and survive a later
    // explosion replacing the global polygon-fragment array.
    private var tankTurrets: [Int: Piece] = [:]
    private(set) var unsupportedRequests: [String] = []
    var snapshots: [Snapshot] {
        pieces.map { .init(state: $0.state, node: $0.node, sourceCommandCount: $0.commandCount, sourcePolygonCount: $0.polygonCount) }
    }
    var activeCount: Int { pieces.count }
    // One legacy fragment slot never advances position. Only moving pieces and
    // detached turrets can still land; a static wreck must not hold the result.
    var hasMovingDebris: Bool {
        !tankTurrets.isEmpty || pieces.contains { $0.state.objectID < firstObjectID + updatedSlotCount }
    }
    var tankTurretSnapshots: [Snapshot] {
        tankTurrets.keys.sorted().compactMap { id in
            tankTurrets[id].map { .init(state:$0.state,node:$0.node,sourceCommandCount:0,sourcePolygonCount:0) }
        }
    }
    var firstObjectID: Int { version == .beach2000 ? 228 : 536 }
    var initializedSlotCount: Int { version == .beach2000 ? 72 : 114 }
    var updatedSlotCount: Int { initializedSlotCount-1 }

    init(resourceRoot: URL, version: OriginalGameVersion, parent: SCNNode,
         makeNode: @escaping ([String: Any]) -> SCNNode) throws {
        self.version=version; self.parent=parent
        wrecks2000 = version == .beach2000 ? try Original2000Wrecks(resourceRoot: resourceRoot, makeNode: makeNode) : nil
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: resourceRoot.appendingPathComponent("fragments.json"))) as! [String: Any]
        guard manifest["gameID"] as? String == version.rawValue else {
            throw NSError(domain: "OriginalFragments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fragment manifest game identity mismatch"])
        }
        objects = Dictionary(uniqueKeysWithValues: (manifest["objects"] as? [[String: Any]] ?? []).compactMap { value in
            (value["id"] as? Int).map { ($0, value) }
        })
    }

    private func commands(objectID: Int, seen: Set<Int> = []) -> [[String: Any]]? {
        guard !seen.contains(objectID), let object=objects[objectID], let commands=object["commands"] as? [[String: Any]] else { return nil }
        var result: [[String: Any]]=[]
        for command in commands {
            if command["kind"] as? String == "reference" {
                guard let id=command["objectID"] as? Int, let referenced=self.commands(objectID:id,seen:seen.union([objectID])) else { return nil }
                result.append(contentsOf:referenced)
            } else { result.append(command) }
        }
        return result
    }

    /// Keep source material boundaries and vertex order while folding adjacent
    /// equal groups. The HD debris uses their positions for the block's original
    /// location on the vehicle, replacing only its visible shape and material.
    private func mergedGroups(_ commands: ArraySlice<[String: Any]>) -> [[String: Any]] {
        var groups: [[String: Any]]=[]
        var lastKey: Data?
        for command in commands {
            guard let incoming=command["group"] as? [String: Any] else { continue }
            let properties=incoming.filter { !["vertices","normals","uvs","colors","indices"].contains($0.key) }
            let key=try? JSONSerialization.data(withJSONObject:properties,options:.sortedKeys)
            if key == lastKey, !groups.isEmpty {
                let index=groups.count-1, offset=(groups[index]["vertices"] as? [Double] ?? []).count/3
                for name in ["vertices","normals","uvs","colors"] {
                    groups[index][name]=(groups[index][name] as? [Double] ?? [])+(incoming[name] as? [Double] ?? [])
                }
                groups[index]["indices"]=(groups[index]["indices"] as? [Int] ?? [])+(incoming["indices"] as? [Int] ?? []).map {$0+offset}
            } else { groups.append(incoming); lastKey=key }
        }
        return groups
    }

    private func loadTemplates(objectID: Int, chunkSize: Int) -> [Template]? {
        let key="\(objectID):\(chunkSize)"
        if let cached=templates[key] { return cached }
        guard chunkSize>0, let stream=commands(objectID:objectID) else { return nil }
        let count=max(1,(stream.count+chunkSize-1)/chunkSize)
        // All audited destruction call sites fit this buffer. Preserve a bounded
        // rejection for an unsupported caller instead of reproducing memory corruption.
        guard count<=initializedSlotCount else { return nil }
        var result:[Template]=[]
        for i in 0..<count {
            let lower=min(i*chunkSize,stream.count),upper=min((i+1)*chunkSize,stream.count)
            let range=stream[lower..<upper]
            let node=RemasteredDebris.makeNode(objectID:objectID,block:i,sourceGroups:mergedGroups(range))
            node.position=SCNVector3Zero
            result.append(.init(node:node,commands:range.count,polygons:range.filter {$0["group"] != nil}.count))
        }
        templates[key]=result
        return result
    }

    /// This adapter emits only geometry. Caller still owns source sprite/sound,
    /// enemy visibility, score, force and flame ignition so those are not doubled.
    @discardableResult
    func emit(objectID: Int, chunkSize: Int, style: OriginalFragmentStyle,
              position: SIMD3<Double>, rotationDegrees: SIMD3<Double>, random15: () -> Int) -> Bool {
        guard let source=loadTemplates(objectID:objectID,chunkSize:chunkSize) else {
            unsupportedRequests.append("object \(objectID), opcode chunk \(chunkSize)"); return false
        }
        clearDebris() // Both recovered helpers reset the ONE global fragment buffer.
        for (index,template) in source.enumerated() {
            let state=OriginalFragmentState(objectID:firstObjectID+index,position:position,rotationDegrees:rotationDegrees,style:style,random15:random15)
            let node=template.node.clone(); parent.addChildNode(node)
            let piece=Piece(state:state,node:node,commands:template.commands,polygons:template.polygons)
            pieces.append(piece); render(piece)
        }
        return true
    }

    /// Transfer the real turret and its barrel out of the hull hierarchy. The
    /// executable copies BODY translation but retains TURRET local Euler angles
    /// when clearing its Link; adding hull yaw here would change source behavior.
    @discardableResult
    func detachTankTurret(bodyObjectID: Int, body: SCNNode, position: SIMD3<Double>,
                          random15: () -> Int) -> Bool {
        guard version == .beach2002, (37..<49).contains(bodyObjectID),
              let turret=body.childNode(withName:"Turret",recursively:true) else {return false}
        let id=bodyObjectID+12, r=turret.eulerAngles
        let rotation=SIMD3(Double(r.x),Double(r.y),Double(r.z)) * (180 / .pi)
        turret.childNode(withName:"TMount",recursively:true)?.eulerAngles.x = -20 * .pi/180
        let state=OriginalFragmentState(tankTurretObjectID:id,position:position,rotationDegrees:rotation,random15:random15)
        tankTurrets.removeValue(forKey:id)?.node.removeFromParentNode()
        turret.removeFromParentNode();parent.addChildNode(turret);turret.isHidden=false
        let piece=Piece(state:state,node:turret,commands:0,polygons:0)
        tankTurrets[id]=piece;render(piece)
        return true
    }

    func tick() {
        for piece in pieces {
            // The generic object pass updates angles and builds the visible mesh
            // BEFORE debris physics, which runs after the software render call.
            piece.state.advanceOrientation(); render(piece)
            if piece.state.objectID<firstObjectID+updatedSlotCount { piece.state.advancePosition() }
        }
        pieces.removeAll { piece in
            if !piece.state.active { piece.node.removeFromParentNode(); return true }
            return false
        }
        for id in tankTurrets.keys.sorted() {
            guard let piece=tankTurrets[id] else {continue}
            piece.state.advanceOrientation();render(piece);piece.state.advancePosition()
            if !piece.state.active {piece.node.removeFromParentNode();tankTurrets.removeValue(forKey:id)}
        }
    }
    private func render(_ piece: Piece) {
        let p=piece.state.position, r=piece.state.rotationDegrees * (.pi/180)
        piece.node.position=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
        // Recovered matrix pass applies local Z, then X, then Y rotation.
        let qz=simd_quatf(angle:Float(r.z),axis:SIMD3(0,0,1))
        let qx=simd_quatf(angle:Float(r.x),axis:SIMD3(1,0,0))
        let qy=simd_quatf(angle:Float(r.y),axis:SIMD3(0,1,0))
        piece.node.simdOrientation=qy*qx*qz
    }
    private func clearDebris() { pieces.forEach {$0.node.removeFromParentNode()}; pieces.removeAll() }
    func clear() {
        clearDebris();tankTurrets.values.forEach {$0.node.removeFromParentNode()};tankTurrets.removeAll()
    }
}

func testOriginalFragments(resource2000: URL, resource2002: URL) throws {
    func check(_ good:Bool,_ message:String) throws {
        if !good { throw NSError(domain:"OriginalFragments",code:2,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    let draws=[0,16384,32767,0,32767,0]; var pointer=0
    var air=OriginalFragmentState(objectID:228,position:SIMD3(100,100,100),rotationDegrees:SIMD3(360,0,-360),style:.airburst,random15:{defer{pointer+=1};return draws[pointer]})
    try check(pointer==6 && air.angularVelocity==SIMD3(-8,0,8) && air.velocity==SIMD3(-81,-81,81),"source six-draw integer division and axis ordering")
    air.advanceOrientation(); air.advancePosition()
    try check(air.rotationDegrees==SIMD3(352,0,-352) && abs(air.position.x-20.62)<1e-9 && air.position.y==16 && abs(air.position.z-179.38)<1e-9,"rotation then damp/gravity/translation order")
    air.advancePosition(); try check(air.active && air.position.y == -71,"newly negative Y remains active for current tick")
    air.advancePosition(); try check(!air.active,"next old-negative-Y tick retires without terrain query")
    pointer=0
    let ground=OriginalFragmentState(objectID:536,position:.zero,rotationDegrees:.zero,style:.groundBurst,random15:{defer{pointer+=1};return draws[pointer]})
    try check(ground.angularVelocity==SIMD3(-16,0,16) && ground.velocity==SIMD3(-20,20,20),"ground burst has separate source divisors and upward velocity")
    pointer=0
    let turret=OriginalFragmentState(tankTurretObjectID:49,position:.zero,rotationDegrees:.zero,random15:{defer{pointer+=1};return draws[pointer]})
    try check(pointer==4 && turret.angularVelocity==SIMD3(-2.048,0,0) && turret.velocity==SIMD3(16.383,40,-16.384),"tank turret preserves FOUR float divisions and X/Z order")
    for version in [OriginalGameVersion.beach2000,.beach2002] {
        let root=version == .beach2000 ? resource2000:resource2002, parent=SCNNode()
        let fragments=try OriginalFragments(resourceRoot:root,version:version,parent:parent,makeNode:{_ in SCNNode()})
        let cobra=version == .beach2000 ? 88:142
        var randomCalls=0
        try check(fragments.emit(objectID:cobra,chunkSize:40,style:.airburst,position:SIMD3(0,1000,-4000),rotationDegrees:.zero,random15:{randomCalls+=1;return 16384}),"load actual ordered Cobra stream")
        let count=version == .beach2000 ? 11:12
        try check(fragments.activeCount==count && randomCalls==count*6 && fragments.snapshots.reduce(0,{$0+$1.sourcePolygonCount})==438,"source opcode grouping and every Cobra visible polygon preserved (one additional BoundingVol opcode)")
        try check(fragments.snapshots.dropLast().allSatisfy {$0.sourceCommandCount==40},"each full block has exactly40 source opcodes")
        fragments.tick()
        try check(fragments.snapshots[0].state.position.y==997 && abs(fragments.snapshots[0].node.position.y-10)<0.000001,"draw snapshot precedes source after-render physics")
        try check(fragments.emit(objectID:cobra+1,chunkSize:20,style:.groundBurst,position:SIMD3(0,0,0),rotationDegrees:.zero,random15:{16384}),"original Instance resolves its complete stream")
        try check(parent.childNodes.count==fragments.activeCount && fragments.activeCount==(version == .beach2000 ? 22:23),"later explosion replaces rather than accumulates global batch")
        for _ in 0..<50 {fragments.tick()}
        try check(fragments.activeCount==0 && parent.childNodes.isEmpty,"all ground-burst fragments retire through real source physics")
        if version == .beach2002 {
            let hull=SCNNode(), turret=SCNNode(),barrel=SCNNode()
            hull.eulerAngles.y=1.5;turret.name="Turret";turret.eulerAngles.y=0.3;barrel.name="TMount"
            hull.addChildNode(turret);turret.addChildNode(barrel)
            randomCalls=0
            try check(fragments.detachTankTurret(bodyObjectID:37,body:hull,position:SIMD3(100,0,200),random15:{randomCalls+=1;return 16384}),"detach original turret hierarchy")
            try check(randomCalls==4 && hull.childNodes.isEmpty && turret.parent===parent && barrel.parent===turret && abs(barrel.eulerAngles.x + .pi/9)<1e-7,"turret unlinks with barrel pitch=-20 and consumes exactly4 random draws")
            try check(abs(fragments.tankTurretSnapshots[0].state.rotationDegrees.y-0.3*180 / .pi)<1e-6,"unlinked turret retains local yaw, does not inherit hull yaw")
            _=fragments.emit(objectID:142,chunkSize:40,style:.airburst,position:.zero,rotationDegrees:.zero,random15:{16384})
            try check(fragments.tankTurretSnapshots.count==1 && turret.parent===parent,"a new polygon explosion does not erase detached tank turret")
            fragments.tick()
            try check(fragments.tankTurretSnapshots[0].state.position.y==37 && turret.position.y==0,"turret shares source after-render gravity phase")
            for _ in 0..<30 {fragments.tick()}
            try check(fragments.tankTurretSnapshots.isEmpty && turret.parent==nil,"turret and child barrel retire together at sea level")
        }
        fragments.clear()
        try check(fragments.unsupportedRequests.isEmpty,"all tested source requests fit original fixed buffer")
    }
    try testOriginalFragmentRecipes()
    try testOriginal2000Wrecks(resourceRoot: resource2000)
    try testRemasteredDebris()
    print("PASS original fragments: ordered opcode chunks, source integer RNG, shared replacement, rotations, damping, gravity and retirement; modern solid geometry")
}
