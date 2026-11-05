import SceneKit

/// Scene adapter for the recovered weapon object tree. Object IDs, rather than
/// display names, distinguish the two BH2000 objects both named "Pistol".
/// The host owns the world mount's aim; this object owns authored local offsets,
/// independent hidden-weapon recovery and original immediate visibility changes.
final class GameWeaponPresentation {
    struct Basis {
        let forward: SCNVector3
        let right: SCNVector3
        let mountRight: SCNVector3
        let muzzle: SCNVector3?
    }
    let version: OriginalGameVersion
    let parent: SCNNode
    private(set) var nodes: [Int: SCNNode] = [:]
    private(set) var recoil: OriginalWeaponRecoil
    private let deployment: OriginalWeaponDeployment
    private var authoredOffsets: [Int: SCNVector3] = [:]
    private var muzzleTips: [Int: SCNVector3] = [:]
    private(set) var pose: OriginalWeaponDeployment.Pose

    init(version: OriginalGameVersion, objects: [[String: Any]], parent: SCNNode,
         makeNode: ([String: Any]) -> SCNNode) {
        self.version = version; self.parent = parent
        recoil = OriginalWeaponRecoil(version: version)
        deployment = OriginalWeaponDeployment(version: version)
        pose = deployment.step(selected: .machineGun)
        let ids: Set<Int> = version == .beach2000 ? [8, 9, 10, 142, 143, 214, 215] : Set(19...28)
        let mounts: Set<Int> = version == .beach2000 ? [8, 142] : [19]
        let selected = objects.filter { ($0["id"] as? Int).map(ids.contains) ?? false }
        for object in selected {
            guard let id = object["id"] as? Int else { continue }
            let node = makeNode(object)
            // The enclosing host mount already applies the world Y800 anchor.
            // Only these top-level source mounts discard their duplicate Y800.
            if mounts.contains(id) { node.position = SCNVector3Zero }
            authoredOffsets[id] = node.position
            nodes[id] = node
        }
        for object in selected {
            guard let id = object["id"] as? Int, let node = nodes[id] else { continue }
            if let link = object["link"] as? Int, let ancestor = nodes[link] { ancestor.addChildNode(node) }
            else { parent.addChildNode(node) }
        }
        sync(selected: .machineGun)
        applyRecoil()
    }

    @discardableResult
    func sync(selected: OriginalWeapon, machineGunVariant: Int = 0, cannonVariant: Int = 0,
              readyFields: [Int: Int] = [:]) -> OriginalWeaponDeployment.Pose {
        pose = deployment.step(selected: selected, machineGunVariant: machineGunVariant,
                               cannonVariant: cannonVariant, readyFields: readyFields)
        let visible = Set(pose.visibleObjectIDs)
        for (id, node) in nodes { node.isHidden = !visible.contains(id) }
        return pose
    }

    /// Call once per logical update after accepting fire and before spawning its
    /// projectile. Passing nil still advances recovering, currently hidden guns.
    func tick(acceptedFire: OriginalFireAction?) {
        if let action = acceptedFire { recoil.registerFire(action) }
        recoil.tick()
        applyRecoil()
    }

    /// Original level load reinstates the authored object translations.
    func reset() {
        recoil = OriginalWeaponRecoil(version: version)
        applyRecoil()
    }

    private func applyRecoil() {
        for value in recoil.poses {
            guard let node = nodes[value.objectID], let base = authoredOffsets[value.objectID] else { continue }
            node.position = SCNVector3(base.x + CGFloat(value.localOffset.x * 0.01),
                                      base.y + CGFloat(value.localOffset.y * 0.01),
                                      base.z + CGFloat(value.localOffset.z * 0.01))
            node.eulerAngles = SCNVector3(value.rotationDegrees.x * .pi / 180,
                                         value.rotationDegrees.y * .pi / 180,
                                         value.rotationDegrees.z * .pi / 180)
        }
    }

    /// The visual builder supplies the tip in the articulating barrel's space.
    /// It follows reload/recoil offsets and the current elevation automatically.
    func registerMuzzle(_ tip: SCNVector3, for objectID: Int) {
        muzzleTips[objectID] = tip
    }

    func basis(for action: OriginalFireAction) -> Basis {
        let id: Int
        if version == .beach2000 {
            switch action.weapon {
            case .machineGun: id = action.barrel == .left ? 9 : 10
            case .cannon: id = 143
            case .handgun: id = 214
            case .flare: id = 142
            }
        } else {
            switch action.weapon {
            case .machineGun: id = action.variant == 1 ? 23 : action.variant == 2 ? 25 : action.barrel == .left ? 21 : 22
            case .cannon: id = 24
            case .handgun: id = 26
            case .flare: id = 28
            }
        }
        let node = nodes[id] ?? parent
        return Basis(forward: node.convertVector(SCNVector3(0, 0, -1), to: nil),
                     right: node.convertVector(SCNVector3(1, 0, 0), to: nil),
                     mountRight: parent.convertVector(SCNVector3(1, 0, 0), to: nil),
                     muzzle: muzzleTips[id].map { node.convertPosition($0,to:nil) })
    }
}

/// Verifies the real source object declarations without loading textures or a
/// WindowServer. This catches duplicate-name aliasing and doubled Y800 anchors.
func testGameWeaponPresentation(objects: [[String: Any]], version: OriginalGameVersion) throws {
    func check(_ good: Bool, _ detail: String) throws {
        if !good { throw NSError(domain: "GameWeaponPresentation", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: detail]) }
    }
    func same(_ a: SCNVector3, _ b: SCNVector3) -> Bool {
        abs(a.x-b.x)<0.00001 && abs(a.y-b.y)<0.00001 && abs(a.z-b.z)<0.00001
    }
    let parent = SCNNode(); parent.position = SCNVector3(0, 8, 0)
    let presentation = GameWeaponPresentation(version: version, objects: objects, parent: parent) { item in
        let n = SCNNode(); n.name = item["name"] as? String
        let p = (item["translation"] as? [NSNumber] ?? []).map { $0.doubleValue }
        if p.count == 3 { n.position = SCNVector3(p[0]*0.01, p[1]*0.01, p[2]*0.01) }
        return n
    }
    let old = version == .beach2000, left = old ? 9 : 21, pistol = old ? 214 : 26, bolt = old ? 215 : 27
    try check(presentation.nodes.count == (old ? 7 : 10), "complete weapon tree")
    try check(presentation.nodes[bolt]?.parent === presentation.nodes[pistol], "bolt retains its pistol parent")
    try check(same(presentation.nodes[old ? 8 : 19]!.worldPosition, SCNVector3(0, 8, 0)), "world mount applies Y800 exactly once")
    presentation.tick(acceptedFire: .init(weapon: .machineGun, barrel: .left, variant: 0, recoilTicks: 6, ballistic: nil))
    try check(abs(presentation.nodes[left]!.position.z-0.3)<0.00001, "first tick moves only fired barrel")
    presentation.sync(selected: .handgun)
    try check(presentation.nodes[left]!.isHidden && !presentation.nodes[pistol]!.isHidden, "immediate source visibility")
    for _ in 0..<5 { presentation.tick(acceptedFire: nil) }
    try check(abs(presentation.nodes[left]!.position.z)<0.00001, "hidden gun completes independent recovery")
    presentation.tick(acceptedFire: .init(weapon: .handgun, barrel: .center, variant: 0, recoilTicks: 5, ballistic: nil))
    presentation.tick(acceptedFire: nil)
    try check(same(presentation.nodes[pistol]!.position, SCNVector3(0.05, -0.1, -0.7)), "pistol preserves authored position")
    try check(abs(presentation.nodes[bolt]!.position.z-0.08)<0.00001, "distinct bolt receives its own recoil")
    try check(abs(presentation.nodes[pistol]!.eulerAngles.x-2 * .pi/180)<0.00001, "pistol receives its own rotation")
    if !old {
        presentation.sync(selected: .machineGun, machineGunVariant: 2)
        presentation.tick(acceptedFire: .init(weapon: .machineGun, barrel: .center, variant: 2, recoilTicks: 2, ballistic: nil))
        try check(same(presentation.nodes[25]!.position, SCNVector3(0.08, 0.076, -0.25)), "rotary gun preserves authored offset")
        try check(abs(presentation.nodes[25]!.eulerAngles.z + .pi/6)<0.00001, "rotary gun spins on source axis")
        let basis = presentation.basis(for: .init(weapon: .machineGun, barrel: .center, variant: 2, recoilTicks: 2, ballistic: nil))
        try check(same(basis.forward, SCNVector3(0, 0, -1)) && same(basis.mountRight, SCNVector3(1, 0, 0)), "rotary roll leaves forward and mount right independent")
    }
    presentation.reset()
    try check(abs(presentation.nodes[bolt]!.position.z)<0.00001 && abs(presentation.nodes[pistol]!.eulerAngles.x)<0.00001, "level reset restores poses")
    print("PASS weapon scene \(version.rawValue): original hierarchy, authored offsets, visibility, independent recoil and reset")
}
