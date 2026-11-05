import SceneKit
import simd

/// Distant folded ridges sit outside the playable height field. The nearer
/// spurs are in the generated terrain itself, so contact and silhouettes agree.
enum DepthlineHills {
    static func install(in scene: SCNScene, ground: (CGFloat, CGFloat) -> CGFloat) {
        let root = SCNNode()
        root.name = "DepthlineHills"
        scene.rootNode.childNode(withName:root.name!,recursively:false)?.removeFromParentNode()
        scene.rootNode.addChildNode(root)
        let rockMap=Bundle.main.url(forResource:"rock",withExtension:"png",subdirectory:"remastered-assets").flatMap { NSImage(contentsOf:$0) }
        func add(_ mesh: NativeDetailMesh, _ name: String, _ roughness: Double, shadows: Bool = false, geology: Bool = false) {
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased; mat.diffuse.contents = NSColor.white
            mat.roughness.contents = roughness
            if geology, let rockMap {
                let surface=SCNMaterialProperty(contents:rockMap)
                NativeGraphics.filter(surface,repeatTexture:true); mat.setValue(surface,forKey:"ridgeStone")
                mat.shaderModifiers=[.geometry:"""
                #pragma varyings
                float3 ridgeP;
                #pragma body
                out.ridgeP = _geometry.position.xyz;
                """,.surface:"""
                #pragma arguments
                texture2d<float> ridgeStone;
                #pragma varyings
                float3 ridgeP;
                #pragma body
                constexpr sampler smp(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
                float3 p=in.ridgeP;
                float2 uv=float2((p.x*0.75+p.z*0.32),p.y+0.08*p.z)/10.0;
                float stone=dot(ridgeStone.sample(smp,uv).rgb,float3(.25,.55,.2));
                float cuts=sin(p.x*.16+p.z*.087+sin(p.y*.114))*sin(p.y*.13+p.z*.067);
                _surface.diffuse.rgb*=0.69+stone*.71+cuts*.16;
                """]
            }
            let n = SCNNode(geometry: mesh.geometry(material:mat))
            n.name = name; n.castsShadow = shadows; root.addChildNode(n)
        }
        for layer in 0..<2 {
            var m = NativeDetailMesh()
            func point(_ i: Int, _ j: Int) -> SIMD3<Float> {
                let a = Float(i % 360) * 2 * .pi / 360, t = Float(j)/12
                let b = a + Float(layer)*2.16
                let crags = 3.4 * abs(sin(35*b+cos(9*b))) + 1.9*sin(51*b+0.72*cos(b*5))
                let crest = crags + (layer == 0 ? Float(30):Float(68)) + 12*sin(3*b+0.8)
                    + 10*cos(7*b-0.7) + 5*sin(13*b+1) + 2.7*cos(23*b) + 1.2*sin(41*b)
                let radius: Float = (layer == 0 ? 260:440) + t*(layer == 0 ? 174:202)
                    + 12*sin(5*b) + (9*cos(9*b)+4*sin(17*b))*sin(t * .pi)
                let fold = 1 - abs(t-0.69)/(t < 0.69 ? 0.69 : 0.31)
                let gullies = abs(sin(29*b-4*t+cos(b*7))) * (0.6+0.4*cos(11*b+t))
                let toe = 3 + 7*cos(8*b+0.3)*sin(t * .pi)
                let y = toe + max(0,fold)*(crest + 6*cos(18*b+t*3) - 12*gullies)
                return SIMD3(sin(a)*radius,y,cos(a)*radius)
            }
            let tint = layer == 0 ? SIMD3<Float>(0.33,0.385,0.34) : SIMD3<Float>(0.48,0.54,0.59)
            // Share normals and tints at the polar grid vertices. Faceted,
            // independent quad normals read as vertical strips on the horizon
            // when the low sun grazes the opposite side of the valley.
            for i in 0..<360 {
                for j in 0...12 {
                    let p=point(i,j)
                    let radial=point(i,min(12,j+1))-point(i,max(0,j-1))
                    let around=point((i+1)%360,j)-point((i+359)%360,j)
                    let normal=simd_normalize(simd_cross(radial,around))
                    let v = Float(i)*2 * .pi/360
                    let rock=max(0,cos(v*21+Float(j)*0.59))*0.12
                    let srgb=tint*(0.96+0.045*cos(v*9)+rock)
                    func linear(_ c:Float)->Float {pow((c+0.055)/1.055,2.4)}
                    m.positions.append(p); m.normals.append(normal)
                    m.colors.append(.init(linear(srgb.x),linear(srgb.y),linear(srgb.z),1))
                    m.surfaceDetail.append(.zero);m.restUV.append(.zero)
                }
            }
            for i in 0..<360 { for j in 0..<12 {
                let a=UInt32(i*13+j), b=UInt32(((i+1)%360)*13+j)
                m.indices.append(contentsOf:[a,a+1,b,b,a+1,b+1])
            }}
            add(m,layer == 0 ? "Broken foothills":"Back range",0.97,geology:true)
        }
        var detail = NativeDetailMesh()
        var seed: UInt32 = 0x28ae7019
        func next() -> Float {
            seed = seed &* 1664525 &+ 1013904223
            return Float(seed >> 8)/16777216
        }
        // Sparse groves mark the lee of the spurs. Draw the whole stand in one
        // opaque batch; at long range the crowns retain a mass without alpha shimmer.
        for (cx,cz,count) in [(-45,76,15),(59,112,22),(-85,185,33),(19,215,16),(117,52,14),(-129,-81,20),(40,-162,22)] {
            for _ in 0..<count {
                let x = Float(cx)+(next()-0.5)*32, z = Float(cz)+(next()-0.5)*18
                let y = Float(ground(CGFloat(x),CGFloat(z))), h = 2.2+next()*3.1
                let p = SIMD3(x,y-0.12,z)
                let tint = SIMD3<Float>(0.23,0.30,0.23)*(0.84+next()*0.32)
                // Wind-pruned juniper and low scrub. Forks carry layered, uneven
                // clumps; their silhouette stays substantial at 100+ metres.
                let lean=SIMD3<Float>(0.18+next()*0.18,0.81,0.035)*h
                detail.cylinder(from:p,to:p+lean,radius:h*0.034,endRadius:h*0.010,sides:6,color:.init(0.29,0.25,0.19))
                var az=next()*2 * .pi
                for k in 0..<9 {
                    let v=Float(k)/9, stem=p+lean*(0.19+v*0.73)
                    az+=2.39996+next()*0.33
                    let dir=SIMD3<Float>(cos(az),0,sin(az))
                    let spread=(0.31+0.19*next()-0.23*v)*h
                    let tip=stem+dir*spread+SIMD3(0.08*h,h*(0.13+next()*0.09),0)
                    detail.cylinder(from:stem,to:tip,radius:h*0.019,endRadius:0.016,sides:4,color:.init(0.25,0.24,0.18))
                    detail.ellipsoid(center:tip,radii:.init(h*(0.16+next()*0.10),h*(0.10+0.07*next()),h*(0.14+0.08*next())),segments:6,rings:4,color:tint*(0.82+0.28*v+next()*0.17))
                }
            }
        }
        // A low, weathered observation post on one spur provides a human scale.
        let x:Float = -23, z:Float=63, y=Float(ground(CGFloat(x),CGFloat(z)))
        let wall=SIMD3<Float>(0.47,0.47,0.40)
        detail.beveledBox(center:.init(x,y+0.47,z),size:.init(3.5,1.45,2.15),bevel:0.08,color:wall)
        for side:Float in [-1,1] {
            detail.box(center:.init(x+side*1.4,y+1.39,z),size:.init(0.54,0.52,1.96),color:wall*0.94)
        }
        detail.beveledBox(center:.init(x,y+1.70,z),size:.init(3.8,0.18,2.38),bevel:0.035,color:wall*0.85)
        add(detail,"Windbreaks and observation post",0.94,shadows:true)
    }
}
