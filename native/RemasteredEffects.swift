import AppKit
import SceneKit
import simd

/// Presentation only: the existing effect state/pools remain the clock and owner.
/// Generated atlases plus deterministic spark layouts never consume gameplay RNG.
final class RemasteredEffects {
    struct Atlas {
        let image: NSImage
        let grid: Int
        let pixels: CGFloat
        func transform(frame: Int) -> SCNMatrix4 {
            let cell = CGFloat(1) / CGFloat(grid), inset = CGFloat(0.5) / pixels
            var value = SCNMatrix4Identity
            value.m11 = cell - 2 * inset; value.m22 = cell - 2 * inset
            value.m41 = CGFloat(frame % grid) * cell + inset
            value.m42 = CGFloat(frame / grid) * cell + inset
            return value
        }
    }
    private var atlases: [String: Atlas] = [:]
    init(resourceRoot: URL) {
        for (name, grid) in [("explosion-atlas", 4), ("smoke-atlas", 4), ("muzzle-atlas", 2)] {
            if let image = NSImage(contentsOf: resourceRoot.appendingPathComponent("\(name).png")) {
                let pixels = CGFloat(image.representations.map(\.pixelsWide).max() ?? Int(image.size.width))
                atlases[name] = Atlas(image: image, grid: grid, pixels: max(1, pixels))
            }
        }
    }
    var loadedAtlasCount: Int { atlases.count }
    private var templates: [OriginalEffectKind: SCNMaterial] = [:]
    func material(for profile: OriginalEffectProfile) -> (SCNMaterial, Atlas?) {
        let key: String
        switch profile.kind {
        case .explosion, .groundExplosion, .fire: key = "explosion-atlas"
        case .impactFlash, .muzzleFlash, .missileFlame: key = "muzzle-atlas"
        default: key = "smoke-atlas"
        }
        let atlas = atlases[key]
        if let template = templates[profile.kind] {
            return (template.copy() as! SCNMaterial, atlas)
        }
        let material = SCNMaterial()
        let kind = profile.kind
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        material.diffuse.minificationFilter = .linear
        material.diffuse.magnificationFilter = .linear
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.diffuse.contents = atlas?.image ?? NSColor.white
        material.blendMode = .alpha
        // Mip filtering suppresses distant smoke shimmer; the transparent cell
        // margin, half-texel inset and per-cell edge fade prevent bright seams.
        material.diffuse.mipFilter = .linear
        material.setValue(Float(atlas?.grid ?? 1), forKey: "fxGrid")
        material.setValue(Float(0), forKey: "fxAge")
        let tint: String
        switch kind {
        case .whiteSmoke: tint = "float3(0.85, 0.90, 0.94)"
        case .blackSmoke: tint = "float3(0.32, 0.35, 0.39)"
        case .smokeBurst: tint = "float3(0.52, 0.47, 0.40)"
        case .dirtHit: tint = "float3(0.74, 0.59, 0.40)"
        case .blood: tint = "float3(0.55, 0.045, 0.025)"
        case .waterSplash: tint = "float3(0.82, 0.94, 1.0)"
        default: tint = "float3(1.0)"
        }
        let flame = kind == .fire || kind == .missileFlame
        let groundFade = profile.isSmoke || [.groundExplosion,.dirtHit,.waterSplash].contains(kind)
        if groundFade { material.setValue(NSValue(scnVector3:SCNVector3(0,0,-10000)),forKey:"dlFXGround") }
        material.shaderModifiers = [.surface: """
        #pragma arguments
        float fxGrid;
        float fxAge;
        \(groundFade ? "float3 dlFXGround;" : "")
        #pragma transparent
        #pragma body
        float2 localUV = fract(_surface.diffuseTexcoord * fxGrid);
        float2 margin = min(localUV, float2(1.0) - localUV);
        float edge = smoothstep(0.012, 0.065, min(margin.x, margin.y));
        float rawAlpha = _surface.diffuse.a;
        _surface.diffuse.a = rawAlpha * smoothstep(0.025, 0.065, rawAlpha) * edge;
        _surface.diffuse.rgb *= \(tint);
        \(groundFade ? "float3 world=(scn_frame.inverseViewTransform*float4(_surface.position,1.0)).xyz; _surface.diffuse.a*=smoothstep(-0.08,0.65,world.y-dot(dlFXGround.xy,world.xz)-dlFXGround.z);" : "")
        \(atlas == nil ? "float r = length(localUV - float2(0.5)) * 2.0; _surface.diffuse.a *= exp(-r*r*5.0) * (1.0-smoothstep(0.6,1.0,r));" : "")
        \(flame ? "float heat = max(_surface.diffuse.r, max(_surface.diffuse.g, _surface.diffuse.b)); float tongue = 0.82 + 0.18*sin(localUV.x*25.0 + localUV.y*17.0 + fxAge*9.0); _surface.diffuse.a *= smoothstep(0.15,0.45,heat) * tongue; _surface.diffuse.rgb *= float3(1.4,1.13,0.75);" : "")
        """]
        // SceneKit shares the prepared image across these copies. Each effect
        // still owns its UV transform, age and local ground shader uniforms.
        templates[kind] = material
        return (material.copy() as! SCNMaterial, atlas)
    }

    static func glowMaterial(color: NSColor, ring: Bool = false) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant; material.diffuse.contents = color
        material.isDoubleSided = true; material.blendMode = .add
        material.readsFromDepthBuffer = true; material.writesToDepthBuffer = false
        material.shaderModifiers = [.surface: """
        #pragma transparent
        #pragma body
        float radius = length(_surface.diffuseTexcoord - float2(0.5)) * 2.0;
        float alpha = \(ring ? "exp(-pow((radius - 0.72) * 13.0, 2.0))" : "exp(-radius * radius * 6.0) * (1.0 - smoothstep(0.65, 1.0, radius))");
        _surface.diffuse.a *= alpha;
        _surface.diffuse.rgb *= alpha;
        """]
        return material
    }
    static func glowNode(size: CGFloat, color: NSColor, ring: Bool = false) -> SCNNode {
        let plane = SCNPlane(width: size, height: size); plane.materials = [glowMaterial(color: color, ring: ring)]
        return SCNNode(geometry: plane)
    }
    static func configureFlare(_ node: SCNNode) {
        node.geometry = SCNPlane(width: 0.44, height: 0.44)
        node.geometry?.materials = [glowMaterial(color: NSColor(srgbRed: 1, green: 0.93, blue: 0.71, alpha: 1))]
        let halo = glowNode(size: 1.8, color: NSColor(srgbRed: 1, green: 0.72, blue: 0.32, alpha: 0.18))
        halo.name = "remastered-flare-halo"; node.addChildNode(halo)
        let core = glowNode(size: 0.13, color: .white); core.name = "remastered-flare-core"; node.addChildNode(core)
    }
}

final class RemasteredEffectVisual {
    private let kind: OriginalEffectKind
    private let material: SCNMaterial
    private let plane: SCNNode
    private let atlas: RemasteredEffects.Atlas?
    private let base: CGFloat
    private let seed: Int
    private var glow: SCNNode?
    private var ring: SCNNode?
    private var sparks: SCNNode?
    private let loop: Bool

    init(profile: OriginalEffectProfile, plane: SCNNode, material: SCNMaterial, root: SCNNode,
         facing: SCNNode, atlas: RemasteredEffects.Atlas?, seed: Int, sourceScale: Double) {
        kind = profile.kind; self.material = material; self.plane = plane; self.atlas = atlas
        base = CGFloat(profile.templateSize.x * sourceScale); self.seed = seed; loop = profile.loops
        if [.explosion, .groundExplosion, .impactFlash, .muzzleFlash, .fire, .missileFlame].contains(kind) {
            let n = RemasteredEffects.glowNode(size: base * 1.4, color: NSColor(srgbRed: 1, green: 0.42, blue: 0.08, alpha: 0.35))
            n.position = plane.position; n.position.z = -0.015
            facing.addChildNode(n); glow = n
        }
        if [.groundExplosion, .waterSplash, .dirtHit].contains(kind) {
            let n = RemasteredEffects.glowNode(size: base, color: kind == .waterSplash ? NSColor(srgbRed: 0.65, green: 0.85, blue: 1, alpha: 0.45) : NSColor(srgbRed: 0.78, green: 0.63, blue: 0.38, alpha: 0.28), ring: true)
            n.eulerAngles.x = -.pi / 2; n.position.y = 0.025
            root.addChildNode(n); ring = n
        }
        let count: Int
        switch kind {
        case .explosion, .groundExplosion: count = 10
        case .impactFlash, .waterSplash: count = 7
        case .dirtHit, .blood: count = 5
        default: count = 0
        }
        var vertices: [SCNVector3] = [], velocities: [SCNVector3] = [], uv: [CGPoint] = [], indices: [UInt16] = []
        for i in 0..<count {
            let phase = Double(i) * 2.399963229728653 + Double(seed % 97) * 0.23
            let vertical = Float(0.28 + Double((i * 7 + seed) % 13) / 13 * 0.72)
            let direction = SCNVector3(Float(cos(phase)), vertical, Float(sin(phase)))
            let radius = max(0.0125, base * 0.0175)
            let offset = UInt16(vertices.count)
            vertices += [SCNVector3(-radius,-radius,0),SCNVector3(radius,-radius,0),SCNVector3(radius,radius,0),SCNVector3(-radius,radius,0)]
            velocities += Array(repeating:direction,count:4)
            uv += [CGPoint(x:0,y:1),CGPoint(x:1,y:1),CGPoint(x:1,y:0),CGPoint(x:0,y:0)]
            indices += [offset,offset+1,offset+2,offset,offset+2,offset+3]
        }
        if count > 0 {
            let color: NSColor = kind == .waterSplash ? NSColor(srgbRed: 0.7, green: 0.9, blue: 1, alpha: 0.9)
                : kind == .blood ? NSColor(srgbRed: 0.55, green: 0.025, blue: 0.01, alpha: 0.8)
                : kind == .dirtHit ? NSColor(srgbRed: 0.55, green: 0.42, blue: 0.26, alpha: 0.8)
                : NSColor(srgbRed: 1, green: 0.72, blue: 0.2, alpha: 1)
            let m = RemasteredEffects.glowMaterial(color: color)
            m.setValue(Float(0),forKey:"fxDistance");m.setValue(Float(0),forKey:"fxGravity")
            m.shaderModifiers?[.geometry] = """
            #pragma arguments
            float fxDistance;
            float fxGravity;
            #pragma body
            _geometry.position.xyz += _geometry.normal * fxDistance;
            _geometry.position.y -= fxGravity;
            """
            let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(normals:velocities),SCNGeometrySource(textureCoordinates:uv)],
                                       elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
            geometry.materials=[m]
            let n=SCNNode(geometry:geometry);n.name="remastered-batched-sparks"
            let constraint = SCNBillboardConstraint(); constraint.freeAxes = .all; n.constraints = [constraint]
            // Shader displacement is deliberately bounded; keep the renderer's
            // CPU frustum bounds large enough to include the moving sparks.
            n.boundingBox=(SCNVector3(-base*2,-base*2,-base*2),SCNVector3(base*2,base*2,base*2))
            root.addChildNode(n); sparks=n
        }
    }

    func update(_ state: OriginalEffectState) {
        let age = max(0, Double(state.counter)), limit = Double(max(1, state.profile.lastCounter))
        let t = min(1, age / limit)
        material.setValue(Float(age), forKey: "fxAge")
        if let atlas {
            let frame: Int
            if kind == .fire { frame = 2 + ((state.counter + seed % 3) / 2) % 5 }
            else if kind == .missileFlame { frame = state.counter % 4 }
            else { frame = min(atlas.grid * atlas.grid - 1, Int(t * Double(atlas.grid * atlas.grid))) }
            material.diffuse.contentsTransform = atlas.transform(frame: frame)
        }
        if state.profile.isSmoke {
            plane.opacity = CGFloat(0.72 * pow(max(0, 1 - t), 0.65))
            plane.eulerAngles.z = CGFloat(Double(seed % 19) * 0.32 + t * 0.3)
        } else if kind == .dirtHit || kind == .waterSplash || kind == .blood {
            plane.opacity = CGFloat(pow(max(0, 1 - t), 0.7))
        }
        if kind == .fire {
            plane.scale = SCNVector3(0.72 + 0.07 * sin(age * 1.7), 1.18 + 0.11 * sin(age * 1.1), 1)
        } else if kind == .missileFlame { plane.scale = SCNVector3(0.6, 1.1, 1) }
        glow?.opacity = CGFloat(loop ? 0.62 + 0.18 * sin(age * 1.9) : pow(max(0, 1 - t), 3))
        if let ring {
            let scale = CGFloat(0.4 + 2.5 * t)
            ring.scale = SCNVector3(scale, scale, scale); ring.opacity = CGFloat(pow(max(0, 1 - t), 2))
        }
        if let sparks {
            let time = min(1,t/0.82)
            sparks.geometry?.firstMaterial?.setValue(Float(base)*Float(time)*(kind == .dirtHit ? 0.7:1.2),forKey:"fxDistance")
            sparks.geometry?.firstMaterial?.setValue(Float(base)*Float(time*time)*0.6,forKey:"fxGravity")
            sparks.opacity=CGFloat(pow(max(0,1-time),1.5))
        }
    }
}

/// A bright finite head and one crossed-quad fading tail, never a full flight-path line.
enum RemasteredBallisticVisual {
    static func make(size: CGFloat, name: String) -> SCNNode {
        let root = SCNNode(); root.name = name
        let head = RemasteredEffects.glowNode(size: size * 0.65, color: NSColor(srgbRed: 1, green: 0.9, blue: 0.62, alpha: 1))
        head.name = "remastered-tracer-head"
        let facing = SCNBillboardConstraint(); facing.freeAxes = .all; head.constraints = [facing]
        root.addChildNode(head)
        let w=size*0.035, length:CGFloat=0.54
        let points=[SCNVector3(-w,0,0),SCNVector3(w,0,0),SCNVector3(w,0,length),SCNVector3(-w,0,length),
                    SCNVector3(0,-w,0),SCNVector3(0,w,0),SCNVector3(0,w,length),SCNVector3(0,-w,length)]
        let uv=[CGPoint(x:0,y:0),CGPoint(x:1,y:0),CGPoint(x:1,y:1),CGPoint(x:0,y:1)]
        let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:points),SCNGeometrySource(textureCoordinates:uv+uv)],
                                 elements:[SCNGeometryElement(indices:[UInt16(0),1,2,0,2,3,4,5,6,4,6,7],primitiveType:.triangles)])
        let m=SCNMaterial();m.lightingModel = .constant;m.blendMode = .add;m.writesToDepthBuffer=false;m.isDoubleSided=true
        m.diffuse.contents=NSColor(srgbRed:1,green:0.62,blue:0.21,alpha:0.55)
        m.shaderModifiers=[.surface:"""
        #pragma transparent
        #pragma body
        float across=1.0-abs(_surface.diffuseTexcoord.x*2.0-1.0);
        float fade=1.0-_surface.diffuseTexcoord.y;
        _surface.diffuse.a*=across*across*fade*fade;
        _surface.diffuse.rgb*=across*across*fade*fade;
        """]
        geometry.materials=[m]
        let tail=SCNNode(geometry:geometry);tail.name="remastered-tracer-tail";root.addChildNode(tail)
        return root
    }
    static func orient(_ node: SCNNode, direction: SIMD3<Float>) {
        guard simd_length_squared(direction) > 0.00001 else { return }
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: simd_normalize(direction))
    }
}
