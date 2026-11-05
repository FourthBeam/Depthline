import SceneKit

/// BH2000 swaps primary/Backup render-list pointers on specific vehicle hits.
/// This is an immediate mesh swap, not a delayed turret launch. DAT_0046eee4
/// in the adjacent part0 branch is the infantry ignition latch (OriginalBurning).
final class Original2000Wrecks {
    private let objects: [Int: [String: Any]]
    private let makeNode: ([String: Any]) -> SCNNode
    private var templates: [Int: SCNNode] = [:]

    init(resourceRoot: URL, makeNode: @escaping ([String: Any]) -> SCNNode) throws {
        self.makeNode = makeNode
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: resourceRoot.appendingPathComponent("wrecks.json"))) as! [String: Any]
        guard manifest["gameID"] as? String == "2000" else {
            throw NSError(domain: "Original2000Wrecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wrong wreck asset generation"])
        }
        objects = Dictionary(uniqueKeysWithValues: (manifest["objects"] as? [[String: Any]] ?? []).compactMap { item in
            (item["id"] as? Int).map { ($0, item) }
        })
        guard objects.count == 24 else { throw NSError(domain: "Original2000Wrecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Incomplete original wreck render lists"]) }
    }

    static func replacementIDs(context: OriginalDamageContext, weapon: OriginalDamageWeapon, part: Int?, result: OriginalDamageResult) -> [Int] {
        guard context.version == .beach2000, context.active, result.confirmed,
              result.deathMode == .wreck, (part ?? -1) >= 0,
              let id = context.originalObjectIndex else { return [] }
        if context.canonicalType == "TANK", (37..<43).contains(id),
           let state = context.aiState, state != 20, weapon == .cannon || weapon == .missile {
            return [id, id + 6]
        }
        if context.canonicalType == "APC", (61..<67).contains(id), context.hitPoints != 0, weapon == .cannon {
            return [id, id + 6]
        }
        // Original APC missile and enemy rocket/bomb branches kill the vehicle
        // without swapping the render pointers. Preserve that source difference.
        return []
    }

    @discardableResult
    func apply(context: OriginalDamageContext, weapon: OriginalDamageWeapon, part: Int?, result: OriginalDamageResult, body: SCNNode) -> Bool {
        let ids = Self.replacementIDs(context: context, weapon: weapon, part: part, result: result)
        // The HD remake keeps its detailed body/hinges and burns the paint;
        // swapping the recovered low-poly Backup list would undo the remake.
        if ids.count == 2, RemasteredVehicles.applyWreck(to: body) { return true }
        guard ids.count == 2, let second = objects[ids[1]], let name = second["name"] as? String,
              let child = body.childNode(withName: name, recursively: false) else { return false }
        let targets = [body, child]
        var replacements: [[SCNNode]] = []
        for id in ids {
            guard let object = objects[id] else { return false }
            let template: SCNNode
            if let cached = templates[id] { template = cached }
            else { template = makeNode(object); templates[id] = template }
            let groups = template.childNodes.filter { $0.geometry != nil }.map { $0.clone() }
            guard !groups.isEmpty else { return false }
            replacements.append(groups)
        }
        // Replace only direct mesh children. Source turret/barrel/ramp nodes,
        // their authored local pivots, and their animated transforms survive.
        for (target, groups) in zip(targets, replacements) {
            target.childNodes.filter { $0.geometry != nil }.forEach { $0.removeFromParentNode() }
            groups.forEach { target.addChildNode($0) }
        }
        return true
    }
}

func testOriginal2000Wrecks(resourceRoot: URL) throws {
    func check(_ good: Bool, _ detail: String) throws {
        if !good { throw NSError(domain: "Original2000WrecksTest", code: 1, userInfo: [NSLocalizedDescriptionKey: detail]) }
    }
    let scene = try JSONSerialization.jsonObject(with: Data(contentsOf: resourceRoot.appendingPathComponent("scene.json"))) as! [String: Any]
    let objects = scene["objects"] as! [[String: Any]]
    func node(_ object: [String: Any]) -> SCNNode {
        let n = SCNNode(); n.name = object["name"] as? String
        let p = (object["translation"] as? [NSNumber] ?? [0, 0, 0]).map { $0.doubleValue / 100 }
        n.position = SCNVector3(p[0], p[1], p[2])
        for group in object["groups"] as? [[String: Any]] ?? [] {
            // Keep actual vertex/index payloads and texture identity in this
            // WindowServer-free test; only material image loading is omitted.
            let values = (group["vertices"] as! [NSNumber]).map { $0.floatValue / 100 }
            let vertices = SCNGeometrySource(data: values.withUnsafeBytes { Data($0) }, semantic: .vertex, vectorCount: values.count/3, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
            let indices = (group["indices"] as! [Int]).map { UInt32($0) }
            let element = SCNGeometryElement(data: indices.withUnsafeBytes { Data($0) }, primitiveType: .triangles, primitiveCount: indices.count/3, bytesPerIndex: 4)
            let g = SCNGeometry(sources: [vertices], elements: [element])
            let m = SCNMaterial(); m.name = String(group["texture"] as? Int ?? -1); g.materials = [m]
            n.addChildNode(SCNNode(geometry: g))
        }
        return n
    }
    func tree(_ id: Int) -> SCNNode {
        let object = objects.first { $0["id"] as? Int == id }!, n = node(object)
        for child in objects where child["link"] as? Int == id { n.addChildNode(tree(child["id"] as! Int)) }
        return n
    }
    let wrecks = try Original2000Wrecks(resourceRoot: resourceRoot, makeNode: node)
    for id in 37..<43 {
        let hull = tree(id), turret = hull.childNode(withName: "Tank1", recursively: false)!
        let barrel = turret.childNode(withName: "Tank1", recursively: false)!
        hull.position = SCNVector3(10, 2, -30); hull.eulerAngles.y = 1.2; turret.eulerAngles.y = 0.4; barrel.eulerAngles.x = -0.2
        let hullMatrix = hull.transform, turretMatrix = turret.transform, barrelMatrix = barrel.transform
        let context = OriginalDamageContext(version: .beach2000, type: "TANK", hitPoints: 1, aiState: 4, originalObjectIndex: id)
        // All original polygon parts trigger the swap; only part0 ignites infantry.
        let part = (id-37)%3, weapon: OriginalDamageWeapon = id%2 == 0 ? .cannon : .missile
        let result = OriginalDamage.resolve(context, weapon: weapon, part: part)
        try check(wrecks.apply(context: context, weapon: weapon, part: part, result: result, body: hull), "All six tank slots and all original parts must swap")
        try check(turret.parent === hull && barrel.parent === turret && SCNMatrix4EqualToMatrix4(hull.transform, hullMatrix) && SCNMatrix4EqualToMatrix4(turret.transform, turretMatrix) && SCNMatrix4EqualToMatrix4(barrel.transform, barrelMatrix), "Wreck swap must retain turret, barrel and source transforms")
        try check(hull.childNodes.compactMap { $0.geometry }.contains { $0.materials.first?.name == "474" } && turret.childNodes.compactMap { $0.geometry }.contains { $0.materials.first?.name == "474" }, "Both source burnt tank render lists must use recovered texture474")
        var dead = context; dead.aiState = 20
        let repeated = OriginalDamage.resolve(dead, weapon: weapon, part: 0)
        try check(!wrecks.apply(context: dead, weapon: weapon, part: 0, result: repeated, body: hull), "Repeated hits must not toggle wreck back to intact")
    }
    for weapon in [OriginalDamageWeapon.cannon, .missile] {
        let hull = tree(61), ramp = hull.childNode(withName: "Ramp", recursively: false)!
        let rampMatrix = ramp.transform
        let context = OriginalDamageContext(version: .beach2000, type: "APC", hitPoints: 1, aiState: 4, originalObjectIndex: 61)
        let result = OriginalDamage.resolve(context, weapon: weapon, part: 1)
        let changed = wrecks.apply(context: context, weapon: weapon, part: 1, result: result, body: hull)
        try check(changed == (weapon == .cannon), "APC cannon swaps; source missile branch deliberately does not")
        try check(ramp.parent === hull && SCNMatrix4EqualToMatrix4(ramp.transform, rampMatrix), "APC ramp must retain its hinge")
        if changed { try check(ramp.childNodes.compactMap { $0.geometry }.first?.materials.first?.name == "475", "APC ramp uses its recovered burnt texture475") }
    }
    print("PASS original2000 wrecks: six tank slots, all parts, cannon/missile distinctions, actual burnt meshes, retained barrel/ramp hierarchy and no repeated toggle")
}
