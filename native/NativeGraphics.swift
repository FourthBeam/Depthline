import AppKit
import SceneKit
import simd

/// Unified high-definition renderer. Original gameplay and collision data remain
/// independent from presentation meshes and modern material treatment.
final class NativeGraphics {
    let quality: CampaignStore.GraphicsQuality
    let resourceRoot: URL
    private(set) var antialiasing: SCNAntialiasingMode
    var isRemastered: Bool { true }
    private var images: [String: NSImage] = [:]
    private var animatedMaterials: [SCNMaterial] = []
    private var duskProbes: [Bool: [NSImage]] = [:]
    private var skyMaterials: [SCNMaterial] = []
    private var wakeStrength = [Float](repeating:0,count:12)
    static let requiredTextures = ["sand", "grass", "rock", "ocean", "sky-day", "sky-night", "sky-clouds-depthline"]

    init(quality: CampaignStore.GraphicsQuality = .remastered, resourceRoot: URL? = nil, antialiasingSamples: Int = 4) {
        self.quality = .remastered
        self.antialiasing = Self.antialiasingMode(samples: antialiasingSamples)
        self.resourceRoot = resourceRoot ?? (Bundle.main.resourceURL ?? URL(fileURLWithPath: "."))
            .appendingPathComponent("remastered-assets")
        if isRemastered {
            for name in Self.requiredTextures {
                images[name] = NSImage(contentsOf: self.resourceRoot.appendingPathComponent("\(name).png"))
            }
        }
    }
    private static func antialiasingMode(samples: Int) -> SCNAntialiasingMode {
        switch samples {
        case 0: return .none
        case 2: return .multisampling2X
        default: return .multisampling4X
        }
    }

    func setAntialiasing(samples: Int, view: SCNView) {
        let mode = Self.antialiasingMode(samples: samples)
        if mode != antialiasing {
            antialiasing = mode
            view.antialiasingMode = mode
        }
    }
    func validateResources() throws {
        guard isRemastered else { return }
        let missing = Self.requiredTextures.filter { images[$0] == nil }
        guard missing.isEmpty else {
            throw NSError(domain: "NativeGraphics", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: DLoc.text("高清材质缺失：\(missing.joined(separator: ", "))。请重新构建游戏。",
                              "Missing textures: \(missing.joined(separator: ", ")). Rebuild the game.")])
        }
    }
    static func filter(_ property: SCNMaterialProperty, repeatTexture: Bool = false) {
        property.minificationFilter = .linear
        property.magnificationFilter = .linear
        property.mipFilter = .linear
        property.maxAnisotropy = 16
        if repeatTexture { property.wrapS = .repeat; property.wrapT = .repeat }
    }
    func configure(view: SCNView, hud: OriginalHUD) {
        // NSView/SCNView uses point coordinates; its Metal layer receives the
        // current display's native backing scale, including after display moves.
        view.wantsLayer = true
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        view.layer?.contentsScale = scale
        hud.wantsLayer = true; hud.layer?.contentsScale = scale
        hud.remastered = isRemastered
        view.antialiasingMode = antialiasing
        hud.needsDisplay = true
    }
    func configure(material: SCNMaterial, sourceURL: URL?, reflected: Bool) {
        guard isRemastered else { return }
        Self.filter(material.diffuse)
        if reflected {
            // A reflection lookup is not an albedo texture. Use PBR steel in
            // this mode, leaving the recovered view-normal mapping in nostalgia.
            material.name = "HD:steel"
            material.shaderModifiers = nil
            material.lightingModel = .physicallyBased
            material.diffuse.contents = NSColor(srgbRed: 0.25, green: 0.27, blue: 0.28, alpha: 1)
            material.diffuse.contentsTransform = SCNMatrix4Identity
            material.metalness.contents = 0.88
            material.roughness.contents = 0.32
            material.specular.contents = NSColor.white
            return
        }
        let name = sourceURL?.lastPathComponent.lowercased() ?? ""
        if name.hasPrefix("terrain") {
            configureGround(material, waterOnly: false)
        } else if name.hasPrefix("ocean") {
            configureGround(material, waterOnly: true)
        } else if !name.hasPrefix("sky") {
            material.lightingModel = .physicallyBased
            material.metalness.contents = 0.08
            material.roughness.contents = 0.72
        }
    }
    private func configureGround(_ material: SCNMaterial, waterOnly: Bool) {
        material.name = waterOnly ? "HD:water" : "HD:terrain"
        material.lightingModel = .physicallyBased
        material.metalness.contents = 0
        material.roughness.contents = 0.82
        for (key, name) in [("bhSand", "sand"), ("bhGrass", "grass"), ("bhRock", "rock"), ("bhOcean", "ocean")] {
            let property = SCNMaterialProperty(contents: images[name] ?? NSColor.gray)
            Self.filter(property, repeatTexture: true)
            material.setValue(property, forKey: key)
        }
        material.setValue(Float(0), forKey: "bhTime")
        material.setValue(Float(waterOnly ? 1 : 0), forKey: "bhWaterOnly")
        material.shaderModifiers = [.geometry: Self.worldGeometry, .surface: waterOnly ? Self.waterSurface : Self.groundSurface]
        if waterOnly {
            material.setValue(NSValue(scnVector3:SCNVector3(0.55,0.45,-0.70)),forKey:"bhSunDirection")
            material.setValue(Float(0),forKey:"bhDusk")
            material.setValue(Float(0),forKey:"bhNight")
            for key in ["bhWakes0","bhWakes1","bhWakes2"] {
                material.setValue(NSValue(scnMatrix4:SCNMatrix4(simd_float4x4())),forKey:key)
            }
        }
        animatedMaterials.append(material)
    }
    func configureSky(_ node: SCNNode) {
        node.castsShadow = false
        node.enumerateChildNodes { part, _ in part.castsShadow = false }
        guard isRemastered,
              (node.name == "SkyDay" && images["sky-day"] != nil || node.name == "SkyNight" && images["sky-night"] != nil) else {
            OriginalScenePresentation.configureSky(node); return
        }
        // 2000's SkyDay object also contains the ocean mesh: retain that mesh.
        node.enumerateChildNodes { part, _ in
            if part.geometry?.materials.first?.name == "HD:water" {
                part.castsShadow = false
                part.renderingOrder = -500
                // The source ocean and terrain share Y0. A separate visual
                // depth layer keeps the ocean stable and hides submerged parts.
                for m in part.geometry?.materials ?? [] {
                    m.readsFromDepthBuffer = true; m.writesToDepthBuffer = true
                }
            } else { part.isHidden = true }
        }
    }
    func configureScene(_ scene: SCNScene, camera: SCNCamera, sun: SCNNode) {
        guard isRemastered else { return }
        for imageName in ["sky-day", "sky-night"] {
            guard let sky = images[imageName] else { continue }
            let node = RemasteredSky.makeNode(image:imageName == "sky-day" ? (images["sky-clouds-depthline"] ?? sky):sky,night:imageName == "sky-night")
            scene.rootNode.addChildNode(node)
            if let material=node.geometry?.firstMaterial {skyMaterials.append(material)}
            if imageName == "sky-day" { scene.lightingEnvironment.contents = sky }
        }
        // Fixed in the world: turning the turret changes normals relative to
        // sun/sky. No camera-mounted daytime lamp that flattens every heading.
        let fill = SCNNode(); fill.name = "DepthlineSkyBounce"
        fill.light = SCNLight(); fill.light?.type = .directional; fill.light?.intensity = 180
        fill.light?.color = NSColor(srgbRed: 0.60, green: 0.74, blue: 1, alpha: 1)
        fill.eulerAngles = SCNVector3(-0.80,-0.80,0)
        scene.rootNode.addChildNode(fill)
        sun.eulerAngles = SCNVector3(-0.46,2.42,0)
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.10
        camera.averageGray = 0.18
        camera.whitePoint = 3.6
        camera.bloomIntensity = 0.12
        camera.bloomThreshold = 2.0
        camera.bloomBlurRadius = 5
        camera.screenSpaceAmbientOcclusionIntensity = 0.65
        camera.screenSpaceAmbientOcclusionRadius = 0.35
        camera.screenSpaceAmbientOcclusionBias = 0.025
        camera.screenSpaceAmbientOcclusionDepthThreshold = 0.35
        camera.screenSpaceAmbientOcclusionNormalThreshold = 0.7
        if let light = sun.light {
            light.castsShadow = true
            light.shadowMode = .forward
            light.shadowMapSize = CGSize(width: 4096, height: 4096)
            light.shadowRadius = 2
            light.shadowSampleCount = 16
            light.shadowBias = 0.035
            light.maximumShadowDistance = 220
            light.shadowCascadeCount = 3
            light.shadowCascadeSplittingFactor = 0.75
            light.automaticallyAdjustsShadowProjection = true
            light.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.78)
        }
    }
    func updateLighting(scene: SCNScene, ambient: SCNNode, sun: SCNNode,
                        preset: DepthlineLight, inland: Bool, camera: SCNCamera) {
        let night = preset == .night, dusk = preset == .dusk
        scene.rootNode.childNode(withName: "RemasteredSkyDay", recursively: false)?.isHidden = night
        scene.rootNode.childNode(withName: "RemasteredSkyNight", recursively: false)?.isHidden = !night
        let fill = scene.rootNode.childNode(withName: "DepthlineSkyBounce", recursively: false)?.light
        fill?.intensity = night ? 90 : (dusk ? 135 : 180)
        fill?.color = NSColor(srgbRed: 0.60, green: 0.74, blue: 1.0, alpha: 1)
        let direction = preset.sunDirection(inland: inland)
        sun.simdOrientation = simd_quatf(from: SIMD3<Float>(0,0,1), to: direction)
        let vector = NSValue(scnVector3: SCNVector3(direction.x,direction.y,direction.z))
        for material in skyMaterials {
            material.setValue(vector, forKey: "skySun")
            material.setValue(Float(dusk ? 1 : 0), forKey: "skyDusk")
        }
        for material in animatedMaterials where material.name == "HD:water" {
            material.setValue(vector, forKey: "bhSunDirection")
            material.setValue(Float(dusk ? 1 : 0), forKey: "bhDusk")
            material.setValue(Float(night ? 1 : 0), forKey: "bhNight")
        }
        if dusk {
            if duskProbes[inland] == nil { duskProbes[inland] = DepthlineLight.duskEnvironment(sun: direction) }
            scene.lightingEnvironment.contents = duskProbes[inland]
        } else {
            scene.lightingEnvironment.contents = images[night ? "sky-night" : "sky-day"]
        }
        switch preset {
        case .day:
            scene.lightingEnvironment.intensity = 0.42
            ambient.light?.intensity = 48
            sun.light?.intensity = 1750
            sun.light?.color = NSColor(srgbRed:1,green:0.86,blue:0.68,alpha:1)
            scene.fogColor = NSColor(srgbRed:0.58,green:0.66,blue:0.70,alpha:1)
            scene.fogStartDistance = 160
            scene.fogEndDistance = 720
            camera.exposureOffset = -0.10
        case .dusk:
            scene.lightingEnvironment.intensity = 0.72
            ambient.light?.intensity = 75
            sun.light?.intensity = 650
            sun.light?.color = NSColor(srgbRed:1.0,green:0.66,blue:0.43,alpha:1)
            scene.fogColor = NSColor(srgbRed:0.29,green:0.36,blue:0.46,alpha:1)
            scene.fogStartDistance = 48
            scene.fogEndDistance = 505
            camera.exposureOffset = -0.22
        case .night:
            scene.lightingEnvironment.intensity = 0.58
            ambient.light?.intensity = 72
            sun.light?.intensity = 245
            sun.light?.color = NSColor(srgbRed:0.58,green:0.72,blue:1,alpha:1)
            scene.fogColor = NSColor(srgbRed:0.105,green:0.15,blue:0.205,alpha:1)
            scene.fogStartDistance = 65
            scene.fogEndDistance = 480
            camera.exposureOffset = -0.12
        }
        scene.fogDensityExponent = 1.35
    }
    func update(time: Double) {
        guard isRemastered else { return }
        // Driven by simulation time: water stops when the game is paused.
        for material in animatedMaterials { material.setValue(Float(time), forKey: "bhTime") }
        for material in skyMaterials {material.setValue(Float(time),forKey:"skyTime")}
    }

    /// Each column describes a hull in metres, its heading and remaining prop wash.
    /// Grouping four slots per uniform covers every campaign vessel in one water draw.
    func updateWakes(_ boats:[Original2000EnemyAI.Boat]) {
        var groups=Array(repeating:simd_float4x4(),count:3)
        if boats.isEmpty {wakeStrength=Array(repeating:0,count:12)}
        for boat in boats {
            let i=boat.slot
            guard boat.visible else {wakeStrength[i]=0;continue}
            wakeStrength[i]=max(Float(max(0,boat.speed)/30),wakeStrength[i]*0.976)
            groups[i/4][i%4]=SIMD4(Float(boat.position.x)*0.01,Float(boat.position.z)*0.01,
                                   Float(boat.yawDegrees * .pi/180),wakeStrength[i])
        }
        for m in animatedMaterials where m.name=="HD:water" {
            for (i,matrix) in groups.enumerated() {
                m.setValue(NSValue(scnMatrix4:SCNMatrix4(matrix)),forKey:"bhWakes"+String(i))
            }
        }
    }

    /// Only averages normals across small angular discontinuities. Vertex/index
    /// arrays and collision meshes are never moved, welded or subdivided.
    static func smoothMetalNormals(vertices: [Float], normals: [Float]) -> [Float] {
        guard vertices.count == normals.count, vertices.count % 3 == 0 else { return normals }
        struct Position: Hashable { let x: Int; let y: Int; let z: Int }
        var buckets: [Position: [SIMD3<Float>]] = [:]
        func key(_ i: Int) -> Position {
            Position(x: Int((vertices[i] * 10000).rounded()), y: Int((vertices[i + 1] * 10000).rounded()), z: Int((vertices[i + 2] * 10000).rounded()))
        }
        for i in stride(from: 0, to: normals.count, by: 3) {
            let n = SIMD3(normals[i], normals[i + 1], normals[i + 2])
            if simd_length_squared(n) > 0.0001 { buckets[key(i), default: []].append(simd_normalize(n)) }
        }
        var result = normals
        for i in stride(from: 0, to: normals.count, by: 3) {
            let n = SIMD3(normals[i], normals[i + 1], normals[i + 2])
            guard simd_length_squared(n) > 0.0001 else { continue }
            let unit = simd_normalize(n)
            let sum = (buckets[key(i)] ?? []).filter { simd_dot(unit, $0) > 0.78 }.reduce(SIMD3<Float>.zero, +)
            if simd_length_squared(sum) > 0.0001 {
                let smoothed = simd_normalize(sum)
                result[i] = smoothed.x; result[i + 1] = smoothed.y; result[i + 2] = smoothed.z
            }
        }
        return result
    }

    // These phases are shared by surface shading and mesh displacement. The first
    // two are wind swells. The last turns along the signed-distance shore contours.
    private static let swell = """
    float t = bhTime;
    float offshore = smoothstep(2.0, 35.0, -d);
    float longPhase = dot(p,float2(0.094,0.185))-t*0.86+1.35*sin(dot(p,float2(-0.033,0.021)));
    float crossPhase = dot(p,float2(-0.195,0.098))-t*0.78+1.17*sin(dot(p,float2(0.018,0.029)));
    float surfPhase = d*0.53 - t*1.10 + 0.42*sin(p.x*0.12) + 0.32*sin(p.x*0.051+t*0.19);
    float swellY = offshore*(0.17*sin(longPhase)+0.09*sin(crossPhase))
                 + (1.0-offshore)*(0.04+0.13*sin(surfPhase));
    """

    private static let worldGeometry = """
    #pragma arguments
    float bhWaterOnly;
    float bhTime;
    #pragma varyings
    float3 bhWorld;
    float2 bhShore;
    #pragma body
    out.bhWorld = (scn_node.modelTransform * _geometry.position).xyz;
    out.bhShore = _geometry.texcoords[1];
    float2 p=out.bhWorld.xz;
    float d=out.bhShore.x;
    \(swell)
    _geometry.position.y += bhWaterOnly*swellY;
    """

    private static let groundSurface = """
    #pragma arguments
    texture2d<float> bhSand;
    texture2d<float> bhGrass;
    texture2d<float> bhRock;
    float bhTime;
    #pragma varyings
    float3 bhWorld;
    float2 bhShore;
    #pragma body
    constexpr sampler repeatMap(coord::normalized,address::repeat,filter::linear,mip_filter::linear,max_anisotropy(8));
    float2 p=in.bhWorld.xz;
    float d=in.bhShore.x;
    float3 normal=_surface.normal;
    float3 worldN=normalize((scn_frame.inverseViewTransform*float4(normal,0.0)).xyz);
    float3 macro=_surface.diffuse.rgb;
    float patch=sin(dot(p,float2(0.089,0.12))+sin(p.y*0.072))*cos(dot(p,float2(-0.06,0.079)));
    float sandVegetation=smoothstep(0.85,1.26,macro.g/max(macro.r,0.008));
    float grassMix=smoothstep(0.10,0.86,sandVegetation+0.115*patch);
    float rockMix=smoothstep(0.062,0.34,1.0-abs(worldN.y));
    if (d>1000.0) {
        float saturation=(max(max(macro.r,macro.g),macro.b)-min(min(macro.r,macro.g),macro.b))/max(max(macro.r,macro.g),0.01);
        rockMix=max(rockMix,1.0-smoothstep(0.055,0.235,saturation));
    }
    float2 drift=p*float2(0.50,0.37)+patch*0.12;
    float3 sand=bhSand.sample(repeatMap,drift).rgb;
    float3 sandMacro=bhSand.sample(repeatMap,float2(-p.y,p.x)/15.7+0.23).rgb;
    float3 turf=bhGrass.sample(repeatMap,p/4.1+0.31).rgb*float3(0.85,0.92,0.70);
    float3 rock=bhRock.sample(repeatMap,float2(p.x*0.72+p.y*0.36,in.bhWorld.y+p.y*0.15)/3.8).rgb;
    float strata=sin(in.bhWorld.y*1.52+p.x*0.058+1.6*sin(p.y*0.063));
    float3 color=mix(sand*(0.78+0.42*sandMacro),turf,grassMix);
    color=mix(color,rock*(0.83+0.14*strata),rockMix);
    float swash=0.65*sin(p.x*0.12-bhTime*1.10)+0.42*sin(p.x*0.29+bhTime*0.17);
    float bluff=(smoothstep(46.0,80.0,-p.x)+0.56*smoothstep(99.0,152.0,p.x))*step(d,1000.0);
    float cut=d-1.8*sin(p.x*0.16+p.y*0.044)-abs(sin(p.x*0.235+p.y*0.123))-0.72*abs(sin(p.x*0.41-p.y*0.086));
    float shelf=bluff*smoothstep(1.6,3.5,cut);
    float exposed=max(1.0-smoothstep(11.0,16.0,cut),smoothstep(0.12,0.33,1.0-abs(worldN.y)));
    float u=p.x*0.71+p.y*0.91;
    float y=in.bhWorld.y;
    float wear=sin(u*0.47+y*0.53+1.2*sin(y*0.81-u*0.25))*cos(y*0.62-u*0.31);
    float bed=y*2.1+p.x*0.095+sin(p.y*0.11)*0.78+0.39*sin(u*0.61)+0.81*wear;
    float seam=smoothstep(0.76,0.98,cos(bed))*smoothstep(-0.75,0.35,wear);
    float faults=smoothstep(0.90,0.99,cos(u*1.11+y*0.69+wear))*smoothstep(-0.4,0.6,sin(bed*0.45));
    float stoneLuma=dot(rock,float3(0.24,0.63,0.13));
    float3 shale=float3(0.105,0.145,0.158)*(0.73+stoneLuma*0.93+0.19*wear)*(1.0-0.19*seam-0.21*faults);
    shale+=float3(0.021,0.021,0.017)*smoothstep(0.95,0.995,sin(bed-0.28))*smoothstep(0.0,0.8,wear);
    float3 cap=float3(0.073,0.112,0.052)*(0.86+0.19*patch+dot(turf,float3(0.22,0.63,0.15)));
    color=mix(color,mix(cap,shale,exposed),shelf);
    float wet=(1.0-smoothstep(1.4,12.6,d-0.75*swash-1.4*patch))*(1.0-grassMix);
    float3 damp=color*float3(0.32,0.405,0.465)+float3(0.006,0.009,0.012);
    color=mix(color,damp,wet)*(0.91+0.075*patch);
    // An independent normal / roughness field keeps glints away from albedo motifs.
    float grain=sin(dot(p,float2(18.7,-8.6))+sin(p.y*2.1)*1.4)*sin(dot(p,float2(8.0,15.7)));
    grain*=1.0-smoothstep(0.65,2.6,16.0*length(fwidth(p)));
    float ripple=sin(p.y*3.2+p.x*1.1+1.8*sin(p.x*0.42+p.y*0.08));
    float height=0.0024*grain+0.006*ripple*(1.0-grassMix)*(0.35+0.65*wet)+rockMix*strata*0.032;
    float3 dx=dfdx(_surface.position),dy=dfdy(_surface.position);
    float3 r1=cross(dy,normal),r2=cross(normal,dx);
    float determinant=dot(dx,r1);
    _surface.normal=normalize(max(abs(determinant),1e-12)*normal-sign(determinant)*(dfdx(height)*r1+dfdy(height)*r2));
    _surface.diffuse.rgb=color;
    _surface.roughness=mix(0.89+0.046*patch,0.37+0.06*ripple,wet);
    _surface.metalness=0.0;
    """

    private static let waterSurface = """
    #pragma arguments
    texture2d<float> bhOcean;
    float bhTime;
    float bhDusk;
    float bhNight;
    float3 bhSunDirection;
    float4x4 bhWakes0;
    float4x4 bhWakes1;
    float4x4 bhWakes2;
    #pragma varyings
    float3 bhWorld;
    float2 bhShore;
    #pragma body
    constexpr sampler repeatMap(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
    float2 p=in.bhWorld.xz;
    float d=in.bhShore.x;
    \(swell)
    float2 shoreN=normalize(float2(-in.bhShore.y,1.0));
    float2 tilt=offshore*(0.17*cos(longPhase)*float2(0.094,0.185)+0.09*cos(crossPhase)*float2(-0.195,0.098))
               +(1.0-offshore)*shoreN*(0.069*cos(surfPhase));
    float2 windUV=float2(p.x+p.y*0.27,p.y-p.x*0.37);
    float breakup=sin(p.x*0.27+p.y*0.18+1.4*sin(p.y*0.085))+0.54*sin(p.y*0.46-p.x*0.13-t*0.53);
    float chop=dot(windUV,float2(0.89,1.04))-t*1.35+2.8*sin(dot(p,float2(0.11,-0.15)))+breakup;
    float counter=dot(windUV,float2(-1.15,0.74))-t*0.91+2.1*cos(p.x*0.17+p.y*0.27);
    float fine=1.0-smoothstep(0.17,1.8,length(fwidth(p)));
    tilt+=fine*(0.045*cos(chop)*float2(0.89,1.04)+0.035*cos(counter)*float2(-1.15,0.74));
    float3 n=normalize(float3(-tilt.x,1.0,-tilt.y));
    float viewDistance=length(_surface.position);
    float depth=smoothstep(1.5,29.0,-d);
    float3 tex=bhOcean.sample(repeatMap,windUV/18.7+float2(t*0.005,-t*0.007)).rgb;
    float3 color=mix(float3(0.075,0.167,0.153),float3(0.035,0.071,0.082),depth);
    color*=0.91+0.18*tex+0.036*breakup;
    float3 viewDir=normalize(scn_frame.inverseViewTransform[3].xyz-in.bhWorld);
    float3 reflected=reflect(-viewDir,n);
    float facing=1.0-saturate(dot(n,viewDir));
    float3 skyColor=mix(float3(0.118,0.172,0.205),float3(0.082,0.102,0.132),bhDusk);
    skyColor=mix(skyColor,float3(0.028,0.039,0.063),bhNight);
    color=mix(color,skyColor,0.39*pow(facing,3.0));
    float sun=max(0.0,dot(reflected,normalize(bhSunDirection)));
    color+=float3(1.0,0.76,0.45)*pow(sun,64.0)*(0.095-0.073*bhNight);

    float flecks=smoothstep(-0.86,0.72,breakup*0.64+sin(chop)*0.27+tex.g);
    float surfZone=(1.0-smoothstep(1.3,20.0,-d));
    float breaker=smoothstep(0.70,0.98,sin(surfPhase))*surfZone*flecks;
    float runup=swellY*9.0;
    float lip=(1.0-smoothstep(0.18,1.28,abs(d-runup)))*(0.29+0.61*flecks);
    float foam=max(lip,breaker*0.86);
    // Only pixels near an active hull evaluate its bow wave and tapered wake.
    if (viewDistance<255.0) {
        for (int group=0;group<3;group++) {
            float4x4 hulls=(group==0 ? bhWakes0:(group==1 ? bhWakes1:bhWakes2));
            for (int j=0;j<4;j++) {
                float4 hull=hulls[j];
                float2 rel=p-hull.xy;
                if (hull.w<0.016 || dot(rel,rel)>1400.0) continue;
                float2 heading=-float2(sin(hull.z),cos(hull.z));
                float along=dot(rel,heading);
                float side=abs(dot(rel,float2(heading.y,-heading.x)));
                float halfLength=(group*4+j<6 ? 4.3:6.0);
                float halfBeam=(group*4+j<6 ? 1.27:1.76);
                float trail=max(0.0,-along-halfLength+0.9);
                float decay=(1.0-smoothstep(3.0,29.0*hull.w+3.2,trail));
                float wash=(1.0-smoothstep(0.2,1.0,side/(halfBeam+trail*0.19)))*step(0.1,trail);
                float bowLine=halfBeam+max(0.0,halfLength-along)*0.21;
                float bow=(1.0-smoothstep(0.18,0.92+trail*0.032,abs(side-bowLine)))*step(along,halfLength);
                foam=max(foam,hull.w*decay*max(wash*0.81,bow)*(0.54+0.46*flecks));
            }
        }
    }
    _surface.normal=normalize((scn_frame.viewTransform*float4(n,0.0)).xyz);
    _surface.diffuse.rgb=mix(color,float3(0.63,0.71,0.71),foam);
    _surface.roughness=mix(0.245+0.024*breakup,0.76,foam);
    _surface.metalness=0.0;
    """
}
