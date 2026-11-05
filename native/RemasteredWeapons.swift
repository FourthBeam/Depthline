import AppKit
import SceneKit

/// Optional close-range surface treatment for the recovered first-person meshes.
/// This is an artistic remaster, not another inferred original game feature.
/// No vertices, indices, transforms, visibility, node links or firing bases change.
enum RemasteredWeapons {
    struct Report: Equatable {
        var treatedObjects = 0
        var treatedMeshes = 0
        var additionalDrawCalls: Int { 0 }
    }

    @discardableResult
    static func apply(to weapons: GameWeaponPresentation, enabled: Bool) -> Report {
        guard enabled else { return Report() }
        var report = Report()
        let old = weapons.version == .beach2000
        for (id, node) in weapons.nodes.sorted(by: { $0.key < $1.key }) {
            let kind: Float
            switch id {
            case old ? 8 : 20: kind = 1 // Twin receiver/mount.
            case old ? 9 : 21, old ? 10 : 22: kind = 2
            case old ? 143 : 24: kind = 3
            case 23 where !old: kind = 4 // M60, including its authored grip.
            case 25 where !old: kind = 5 // Source rotary weapon.
            case old ? 214 : 26, old ? 215 : 27: kind = 6
            default: continue
            }
            var changed = false
            // Assets.node creates one direct geometry child per source group.
            // Do not recurse: the pistol bolt and twin barrels are weapon nodes
            // in their own right and carry independent recoil transforms.
            for part in node.childNodes {
                guard !(part.name ?? "").hasPrefix("CompletedTwin"), !(part.name ?? "").hasPrefix("RemasteredArsenal"), let source = part.geometry,
                      !source.materials.contains(where: { $0.name == "HD:weapon-detail" }),
                      let geometry = source.copy() as? SCNGeometry else { continue }
                geometry.materials = source.materials.map { original in
                    let material = original.copy() as! SCNMaterial
                    material.name = "HD:weapon-detail"
                    material.lightingModel = .physicallyBased
                    material.diffuse.contents = NSColor(srgbRed: 0.25, green: 0.27, blue: 0.28, alpha: 1)
                    material.diffuse.contentsTransform = SCNMatrix4Identity
                    material.metalness.contents = 0.86
                    material.roughness.contents = 0.37
                    material.setValue(kind, forKey: "bhWeaponKind")
                    material.setValue(Float(id == (old ? 9 : 21) ? -0.3 : id == (old ? 10 : 22) ? 0.3 : 0), forKey: "bhBarrelX")
                    material.shaderModifiers = [.geometry: localCoordinates, .surface: steelDetail]
                    return material
                }
                part.geometry = geometry
                report.treatedMeshes += 1
                changed = true
            }
            if changed { report.treatedObjects += 1 }
        }
        return report
    }

    private static let localCoordinates = """
    #pragma varyings
    float3 bhWeaponPosition;
    float3 bhWeaponNormal;
    #pragma body
    out.bhWeaponPosition = _geometry.position.xyz;
    out.bhWeaponNormal = _geometry.normal;
    """

    // All dimensions below are in the renderer's metres (source units / 100).
    // Fine patterns are derivative-filtered so 4K detail falls back to an average
    // at lower resolution instead of shimmering. Bump shading never changes depth.
    private static let steelDetail = """
    #pragma arguments
    float bhWeaponKind;
    float bhBarrelX;
    #pragma varyings
    float3 bhWeaponPosition;
    float3 bhWeaponNormal;
    #pragma body
    float3 p = in.bhWeaponPosition;
    float3 n = normalize(in.bhWeaponNormal);
    float phase = p.z * 6400.0 + p.x * 31.0;
    float fine = sin(phase) * (1.0 - smoothstep(0.5, 3.0, fwidth(phase)));
    float broad = sin(p.z * 93.0 + sin(p.x * 81.0)) * sin(p.x * 157.0 + p.y * 61.0);
    float height = 0.0;
    float dark = 0.0;
    float polish = 0.0;
    float matte = 0.0;
    float ao = 1.0;

    if (bhWeaponKind < 1.5) {
        // Rivet heads on the EXISTING receiver top faces; no extra plates or
        // enlarged silhouette. Two rows, every 140 mm, 3 mm radius / .45 mm rise.
        float2 q = float2((abs(p.x) - 0.29) / 0.02, (p.z + 0.26) / 0.14);
        float2 cell = (fract(q + 0.5) - 0.5) * float2(0.02, 0.14);
        float radius = length(cell);
        float aa = max(fwidth(radius), 0.00005);
        float region = step(0.284, abs(p.x)) * step(abs(p.x), 0.316) * step(-0.84, p.z) * step(p.z, -0.24) * smoothstep(0.65, 0.85, n.y);
        float rivet = (1.0 - smoothstep(0.003-aa, 0.003+aa, radius)) * region;
        float rim = (1.0 - smoothstep(0.0038-aa, 0.0038+aa, radius)) * region;
        height += rivet * 0.00045;
        polish += rivet * 0.25;
        dark += max(0.0, rim - rivet) * 0.35;
    } else if (bhWeaponKind < 2.5) {
        // A short cooling-jacket surface on the recovered twin barrel, ending
        // well before its original muzzle. Holes are shallow shaded recesses,
        // not alpha cut-outs, so original depth/occlusion remains exact.
        float angle = atan2(p.y, p.x - bhBarrelX);
        float2 q = float2(angle * 0.95492966, (-p.z - 0.95) / 0.065);
        q.y += floor(q.x) * 0.5;
        float2 d = (fract(q) - 0.5) / float2(0.23, 0.24);
        float radius = length(d);
        float aa = max(fwidth(radius), 0.03);
        float region = smoothstep(-1.55, -1.53, p.z) * (1.0 - smoothstep(-0.95, -0.93, p.z)) * (1.0 - abs(n.z));
        float hole = (1.0 - smoothstep(0.8-aa, 0.8+aa, radius)) * region;
        float edge = (1.0 - smoothstep(1.0-aa, 1.0+aa, radius)) * region;
        dark += hole * 0.78;
        height -= hole * 0.00055;
        polish += max(0.0, edge - hole) * 0.2;
        ao *= 1.0 - hole * 0.3;
        // Fine turned bands at the barrel bearing and before the muzzle flare.
        float band = max(1.0 - smoothstep(0.002, 0.004, abs(p.z+0.965)), 1.0 - smoothstep(0.002, 0.004, abs(p.z+1.89)));
        polish += band * 0.35;
    } else if (bhWeaponKind < 3.5) {
        // Turned cannon steel: original bands and steps already have geometry.
        polish += (1.0 - smoothstep(0.003, 0.006, abs(p.z+0.75))) * 0.25;
        polish += (1.0 - smoothstep(0.003, 0.006, abs(p.z+1.30))) * 0.25;
    } else if (bhWeaponKind < 4.5) {
        matte = (1.0 - smoothstep(-0.018, -0.005, p.y)) * smoothstep(-0.08, 0.02, p.z);
    } else if (bhWeaponKind > 5.5) {
        matte = (1.0 - smoothstep(0.065, 0.085, p.y)) * smoothstep(-0.01, 0.035, p.z);
    }
    // Knurled grip shading is limited to source grip regions, never the slide.
    float gripPhase = (p.x + p.y + p.z) * 1900.0;
    float grip = sin(gripPhase) * sin((p.x-p.y+p.z)*1900.0) * (1.0-smoothstep(0.5, 3.0, fwidth(gripPhase)));
    _surface.diffuse.rgb *= (1.0 - dark) * (0.98 + fine * 0.02 + broad * 0.008);
    _surface.diffuse.rgb = mix(_surface.diffuse.rgb, float3(0.045, 0.048, 0.049) * (1.0+grip*0.07), matte);
    _surface.roughness = clamp(mix(0.39 + broad*0.015 + fine*0.02 - polish*0.22, 0.78, matte), 0.22, 0.84);
    _surface.metalness = mix(0.86, 0.12, matte);
    _surface.ambientOcclusion *= ao;
    float3 dx = dfdx(_surface.position);
    float3 dy = dfdy(_surface.position);
    float3 r1 = cross(dy, _surface.normal);
    float3 r2 = cross(_surface.normal, dx);
    float determinant = dot(dx, r1);
    float3 gradient = sign(determinant) * (dfdx(height)*r1 + dfdy(height)*r2);
    _surface.normal = normalize(max(abs(determinant), 1e-12) * _surface.normal - gradient);
    """
}

/// Exercises the real source hierarchy and deliberately shared geometry/material
/// references. This guards against remastering one gun mutating other instances
/// or the nostalgia renderer, while recoil and muzzle bases remain source-owned.
func testRemasteredWeapons(objects: [[String: Any]], version: OriginalGameVersion) throws {
    func check(_ good: Bool, _ message: String) throws {
        if !good { throw NSError(domain: "RemasteredWeapons", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let sharedMaterial = SCNMaterial(); sharedMaterial.name = "untouched-source"
    let sharedGeometry = SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0)
    sharedGeometry.materials = [sharedMaterial]
    let root = SCNNode(); root.position = SCNVector3(0, 8, 0)
    let presentation = GameWeaponPresentation(version: version, objects: objects, parent: root) { item in
        let node = SCNNode(); node.name = item["name"] as? String
        let xyz = (item["translation"] as? [NSNumber] ?? [0, 0, 0]).map { $0.doubleValue * 0.01 }
        node.position = SCNVector3(xyz[0], xyz[1], xyz[2])
        for _ in item["groups"] as? [[String: Any]] ?? [] { node.addChildNode(SCNNode(geometry: sharedGeometry)) }
        return node
    }
    let nodeState = presentation.nodes.mapValues { ($0.transform, $0.isHidden, $0.parent, $0.childNodes.count) }
    let unchanged = RemasteredWeapons.apply(to: presentation, enabled: false)
    try check(unchanged.treatedMeshes == 0, "Nostalgia must bypass remaster")
    for node in presentation.nodes.values {
        for child in node.childNodes where child.geometry != nil {
            try check(child.geometry === sharedGeometry, "Disabled remaster changed geometry")
        }
    }
    let action = OriginalFireAction(weapon: .machineGun, barrel: .left, variant: 0, recoilTicks: 6, ballistic: nil)
    let basisBefore = presentation.basis(for: action)
    let report = RemasteredWeapons.apply(to: presentation, enabled: true)
    try check(report.treatedMeshes == (version == .beach2000 ? 6 : 8) && report.additionalDrawCalls == 0, "Wrong weapon group count")
    try check(sharedMaterial.name == "untouched-source" && sharedMaterial.shaderModifiers == nil && sharedGeometry.materials.first === sharedMaterial, "Shared original material mutated")
    for (id, node) in presentation.nodes {
        let before = nodeState[id]!
        try check(SCNMatrix4EqualToMatrix4(node.transform, before.0) && node.isHidden == before.1 && node.parent === before.2 && node.childNodes.count == before.3, "Weapon pose, tree or visibility changed")
        for child in node.childNodes where child.geometry != nil {
            try check(child.geometry !== sharedGeometry && child.geometry!.materials.first !== sharedMaterial, "Remaster failed to isolate shared material")
        }
    }
    let basisAfter = presentation.basis(for: action)
    try check(basisBefore.forward.x == basisAfter.forward.x && basisBefore.forward.y == basisAfter.forward.y && basisBefore.forward.z == basisAfter.forward.z, "Original muzzle basis changed")
    try check(RemasteredWeapons.apply(to: presentation, enabled: true).treatedMeshes == 0, "Repeated application should be idempotent")
    presentation.tick(acceptedFire: action)
    try check(abs(presentation.nodes[version == .beach2000 ? 9 : 21]!.position.z - 0.3) < 0.00001, "Visual treatment broke recovered recoil")
    print("PASS remastered weapon \(version.rawValue): nostalgia bypass, shared material isolation, unchanged tree/pose/muzzle, source recoil and zero added draw calls")
}
