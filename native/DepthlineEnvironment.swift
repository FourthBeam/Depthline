import AppKit
import SceneKit
import simd

/// Original, presentation-only field emplacement. No extracted geometry,
/// textures, insignia or collision data are used by these meshes/materials.
enum DepthlineEnvironment {
    private struct Random {
        var state: UInt64 = 0x61c0a57
        mutating func unit() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 40) & 0xffffff) / Float(0xffffff)
        }
        mutating func range(_ a: Float, _ b: Float) -> Float { a + (b-a) * unit() }
    }

    static func install(in scene: SCNScene, gameID: String, shoreline: ((Float) -> Float)? = nil, ground: (CGFloat, CGFloat) -> CGFloat) {
        scene.rootNode.childNode(withName: "DepthlineEnvironment", recursively: false)?.removeFromParentNode()
        let root = SCNNode(); root.name = "DepthlineEnvironment"
        let orientation: Float = gameID == "2000" ? 1 : -1
        if orientation < 0 { root.eulerAngles.y = .pi }
        let base = Float(ground(0, 0)) + 0.025
        func surface(_ x: Float, _ z: Float) -> Float {
            Float(ground(CGFloat(x * orientation), CGFloat(z * orientation)))
        }
        var concrete = NativeDetailMesh(), fabric = NativeDetailMesh(), crates = NativeDetailMesh()
        var metal = NativeDetailMesh(), stones = NativeDetailMesh(), grass = NativeDetailMesh()
        var random = Random()
        let cement = SIMD3<Float>(0.53, 0.51, 0.445)
        let sandCloth = SIMD3<Float>(0.53, 0.47, 0.325)
        let paint = SIMD3<Float>(0.24, 0.29, 0.19)
        let steel = SIMD3<Float>(0.20, 0.21, 0.19)

        // Segmented low retaining walls frame the view without crossing the
        // central firing lane. Their broad chamfers catch the angled daylight.
        concrete.beveledBox(center: .init(0,base-0.12,-1.00), size: .init(8.9,0.23,11.30), bevel: 0.09, color: cement * 0.91)
        // A continuous curved parapet reads even between the guns. The rebuilt
        // left pier stands one course higher; the middle remains a low firing sill.
        let corners:[SIMD2<Float>]=[.init(-4.28,-5.80),.init(-2.70,-6.54),.init(-1.00,-6.84),
                                    .init(0.62,-6.90),.init(1.84,-6.68),.init(2.77,-6.37),.init(4.28,-5.78)]
        let heights:[Float]=[0.58,0.46,0.31,0.30,0.39,0.47]
        let bagCounts=[3,3,0,2,2,3]
        for i in heights.indices {
            let a=corners[i],b=corners[i+1],d=simd_normalize(b-a),mid=(a+b)*0.5,h=heights[i]
            let length=simd_distance(a,b)
            let start=concrete.positions.count
            concrete.beveledBox(center:.init(0,base+h/2,0),size:.init(length+0.06,h,0.44),bevel:0.035,color:cement)
            concrete.beveledBox(center:.init(0,base+h+0.028,0),size:.init(length+0.05,0.095,0.50),bevel:0.024,color:cement*1.09)
            func orient(_ v:SIMD3<Float>)->SIMD3<Float> {
                .init(v.x*d.x-v.z*d.y,v.y,v.x*d.y+v.z*d.x)
            }
            for j in start..<concrete.positions.count {
                concrete.positions[j]=orient(concrete.positions[j])+SIMD3(mid.x,0,mid.y)
                concrete.normals[j]=orient(concrete.normals[j])
            }
            let count=bagCounts[i],yaw=atan2(-d.y,d.x)
            for j in 0..<count {
                let span=length/Float(count),at=a+d*span*(Float(j)+0.5)
                let ry=random.range(0.13,0.153)
                bag(into:&fabric,center:.init(at.x,base+h+0.060+ry*0.68,at.y+random.range(-0.045,0.045)),
                    radii:.init(min(0.40,span*0.56),ry,random.range(0.22,0.28)),
                    yaw:yaw+random.range(-0.15,0.15),seed:Float(i*7+j),color:sandCloth*random.range(0.88,1.11))
            }
            if i==0 {
                let at=mid+d*0.25
                bag(into:&fabric,center:.init(at.x,base+h+0.335,at.y+0.04),radii:.init(0.34,0.13,0.24),
                    yaw:yaw-0.20,seed:29,color:sandCloth*0.94)
            }
        }
        for side: Float in [-1, 1] {
            for segment in 0..<4 {
                let z = -5.25 + Float(segment) * 2.25
                let top: Float = segment == 0 ? 0.60 : segment == 1 ? 0.84 : 1.10
                concrete.beveledBox(center: .init(side*4.28,base+top/2,z), size: .init(0.42,top,2.20), bevel: 0.045,
                                    color: cement * (0.94 + Float(segment) * 0.025))
                // Thin recessed joints, not overlapping coplanar decal faces.
                concrete.beveledBox(center: .init(side*4.29,base+top+0.035,z), size: .init(0.49,0.10,2.15), bevel: 0.025,
                                    color: cement * 1.045)
            }
            // Recessed floor seams are narrow gaps between shallow slabs.
            for j in 0..<5 {
                concrete.beveledBox(center:.init(side*2.11,base+0.012,Float(j)*1.85-5.48),
                                    size:.init(4.16,0.035,1.81),bevel:0.006,color:cement*(0.96+Float(j)*0.008))
            }

            for index in 0..<4 {
                bag(into:&fabric,center:.init(side*4.28,base+(index==3 ? 1.02:0.78),-5.72+Float(index)*0.67),
                    radii:.init(0.32,0.16,0.23),yaw:.pi/2+random.range(-0.08,0.08),seed:Float(index+17),color:sandCloth*random.range(0.91,1.08))
            }

            // A couple of unmarked, generic steel ammunition containers.
            for index in 0..<2 {
                let center = SIMD3<Float>(side*(3.45+Float(index)*0.28),base+0.30,-1.40+Float(index)*1.06)
                crate(into:&crates,hardware:&metal,center:center,size:.init(0.72,0.58,0.44),color:paint*random.range(0.92,1.07),steel:steel)
            }
            // Sparse broken aggregate at the foot of the wall.
            for index in 0..<18 {
                let x = side * random.range(3.48,5.8), z = random.range(-7.4,3.8)
                let radius = random.range(0.045,0.16)
                rock(into:&stones,center:.init(x,surface(x,z)+radius*0.35,z),
                     radii:.init(radius, radius*random.range(0.4,0.8), radius*random.range(0.7,1.5)),seed:Float(index),color:cement*random.range(0.78,1.10))
            }
            // Vegetation stays outside the platform and main target approach.
            for clump in 0..<24 {
                let x=side*random.range(3.7,10.0),z=random.range(-11.0,3.5),y=surface(x,z)
                tuft(into:&grass,center:.init(x,y,z),seed:Float(clump),random:&random)
            }
            // Broken groups continue the foreground into the side dunes.
            // Open sand remains between them and across the central approach.
            for patch in 0..<6 {
                let anchorX=side*(5.4+Float(patch)*1.65+random.range(-0.5,1.1)) + random.range(-5.2,5.2)
                let anchorZ = -12.0-Float(patch)*5.4+random.range(-1.6,1.6) + random.range(-4,4)
                for index in 0..<2 {
                    let x=anchorX+random.range(-1.2,1.2),z=anchorZ+random.range(-1.6,1.6)
                    let radius=random.range(0.20,0.58)
                    rock(into:&stones,center:.init(x,surface(x,z)+radius*0.30,z),
                         radii:.init(radius*random.range(1.0,1.7),radius*random.range(0.55,0.88),radius),
                         seed:Float(41+patch*5+index),color:cement*random.range(0.72,0.98))
                }
                for clump in 0..<6 {
                    let x=anchorX+random.range(-1.5,1.5),z=anchorZ+random.range(-1.9,1.9)
                    let size=random.range(1.0,1.5)
                    tuft(into:&grass,center:.init(x,surface(x,z),z),seed:Float(patch*6+clump),random:&random,scale:size)
                }
            }
        }
        // A modest rear sill grounds the emplacement when the player turns.
        concrete.beveledBox(center:.init(0,base+0.30,4.41),size:.init(8.5,0.60,0.40),bevel:0.04,color:cement*0.96)
        // Exposed reinforcing rod appears only at a single damaged outside edge.
        for x: Float in [-3.36,-3.29] {
            metal.cylinder(from:.init(x,base+0.14,-6.2),to:.init(x+0.025,base+0.46,-6.10),radius:0.009,sides:6,color:.init(0.28,0.19,0.12))
        }
        if let shoreline {
            root.addChildNode(cutbanks(shore:shoreline,ground:surface,random:&random))
            addCoastDetails(shore:shoreline,ground:surface,stones:&stones,steel:&metal,grass:&grass,random:&random)
        }
        for (name,mesh,style) in [("Concrete",concrete,0),("Sandbags",fabric,1),("Crates",crates,2),
                                  ("Hardware",metal,3),("Aggregate",stones,4),("DuneGrass",grass,5)] {
            guard !mesh.indices.isEmpty else { continue }
            let node=SCNNode(geometry:mesh.geometry(material:material(style:style,floor:base)))
            node.name="DepthlineEnvironment"+name
            node.castsShadow=true
            root.addChildNode(node)
        }
        scene.rootNode.addChildNode(root)
    }

    /// Exposed ledges sit on the sea-facing toe of the heightfield scarp.
    /// Each slab has a dipped bedding plane, broken corners and a dark overhang.
    private static func cutbanks(shore:(Float)->Float,ground:(Float,Float)->Float,random:inout Random)->SCNNode {
        var mesh=NativeDetailMesh()
        for startX:Float in [-52,-65,-79,-89,-103,118,143] {
            let size:Float=startX < -74 ? 1.4:0.82
            for piece in 0..<3 {
                let x=startX+Float(piece)*1.62
                let slope=(shore(x+1)-shore(x-1))*0.5
                let tangent=simd_normalize(SIMD3<Float>(1,0,slope))
                let inward=SIMD3<Float>(-tangent.z,0,tangent.x)
                let along=random.range(1.9,3.5)*size
                let deep=random.range(1.1,1.9)*size
                let foot=SIMD3<Float>(x,0,shore(x))+inward*random.range(4.5,7.5)
                let y=ground(foot.x,foot.z)-0.7
                let h=random.range(1.3,2.2)*size
                let section:[SIMD2<Float>]=[.init(-0.99,-0.40),.init(-0.78,-0.90),.init(0.29,-1.0),
                    .init(0.96,-0.48),.init(0.85,0.57),.init(0.43,0.91),.init(-0.91,0.58)]
                let color=SIMD3<Float>(0.40,0.43,0.42)*random.range(0.88,1.09)
                var previous=[SIMD3<Float>]()
                for (row,radius,level):(Int,Float,Float) in [(0,1,0),(1,1.01,0.46),(2,0.91,0.50),(3,1.02,0.61),(4,0.83,1)] {
                    let ring=section.map { uv -> SIMD3<Float> in
                        let q=foot+tangent*(uv.x*along*radius)+inward*(uv.y*deep*radius+0.32*level)
                        let top=y+h*level+level*0.53*uv.x+level*0.28*uv.y
                        return SIMD3<Float>(q.x,row==0 ? min(top,ground(q.x,q.z)-0.6):top,q.z)
                    }
                    if !previous.isEmpty {
                        for j in ring.indices {
                            let k=(j+1)%ring.count
                            mesh.quad(previous[j],ring[j],ring[k],previous[k],color:color*(row==2 ? 0.63:1))
                        }
                    }
                    previous=ring
                }
                for i in 1..<(previous.count-1) {
                    mesh.triangle(previous[0],previous[i+1],previous[i],color:color*1.075)
                }
            }
        }
        let node=SCNNode(geometry:mesh.geometry(material:material(style:6,floor:0)))
        node.name="DepthlineEnvironmentCutbanks";node.castsShadow=false
        return node
    }

    private static func addCoastDetails(shore:(Float)->Float,ground:(Float,Float)->Float,
                                        stones:inout NativeDetailMesh,steel:inout NativeDetailMesh,
                                        grass:inout NativeDetailMesh,random:inout Random) {
        // Erosion leaves coarse blocks at the bluff foot and fewer, smaller
        // ones farther down-drift. Each irregular block has its own bedding.
        for (x,count,scale):(Float,Int,Float) in [(-109,12,2.0),(-92,14,1.5),(-79,11,1.0),
                                                   (-58,6,0.59),(-31,3,0.33),(91,8,1.10)] {
            for _ in 0..<count {
                let px=x+random.range(-4.5,4.5)
                let pz=shore(px)+random.range(-3.5,5.8)
                // The distant capes extend beyond the playable heightmap.
                // Their terrain supplies the silhouette; place loose blocks only
                // where the height sampler has an actual cell under the full foot.
                guard pz > -295 else {continue}
                let radius=random.range(0.4,1.35)*scale
                let center=SIMD3<Float>(px,ground(px,pz)-0.18*radius,pz)
                let tint=SIMD3<Float>(0.37,0.36,0.31)*random.range(0.79,1.16)
                let yaw=random.range(0,6.28)
                var base=[SIMD3<Float>](),rim=[SIMD3<Float>]()
                for j in 0..<7 {
                    let a=yaw+Float(j)*2*Float.pi/7
                    let ring=SIMD3<Float>(cos(a)*1.29,0,sin(a)*0.91)*radius*random.range(0.83,1.13)
                    base.append(center+ring-SIMD3(0,radius*0.3,0))
                    rim.append(center+ring*random.range(0.59,0.87)+SIMD3(0,radius*random.range(0.34,0.69),0))
                }
                let crown=center+SIMD3(-0.13,0.76,0.09)*radius
                for j in base.indices {
                    let k=(j+1)%base.count
                    stones.quad(base[j],rim[j],rim[k],base[k],color:tint)
                    stones.triangle(rim[j],crown,rim[k],color:tint*1.07)
                }
            }
        }
        // Five abandoned tank traps mark the high strand on the outer flanks.
        // Extruded angle-iron has an open silhouette even at landing distance.
        for (x,offset,yaw):(Float,Float,Float) in [(-48,8,0.78),(-41,12,1.23),(-30,14,0.37),(39,10,2.02),(54,7,1.52)] {
            let z=shore(x)+offset
            let center=SIMD3<Float>(x,ground(x,z)+0.61,z)
            let arm=SIMD3<Float>(cos(yaw),0,sin(yaw))
            let across=SIMD3<Float>(-arm.z,0,arm.x)
            for axis in [simd_normalize(arm+SIMD3<Float>(0,0.85,0)),
                         simd_normalize(-arm+SIMD3<Float>(0,0.85,0)),across] {
                let u=simd_normalize(simd_cross(axis,SIMD3<Float>(0,1,0)))*0.115
                let v=simd_normalize(simd_cross(u,axis))*0.115
                let a=center-axis*1.23,b=center+axis*1.23
                let c=SIMD3<Float>(0.28,0.24,0.19)
                steel.plate([a,b,b+u,a+u],thickness:v*0.13,color:c)
                steel.plate([a+v,b+v,b,a],thickness:u*0.13,color:c*0.83)
            }
        }
        for (px,pz):(Float,Float) in [(-14,-23),(-23,-39),(-35,-52),(19,-17),(43,-30)] {
            for j in 0..<19 {
                let x=px+random.range(-3.2,3.2),z=pz+random.range(-1.1,1.1)
                tuft(into:&grass,center:.init(x,ground(x,z),z),seed:Float(j),random:&random)
            }
        }
    }

    private static func bag(into mesh:inout NativeDetailMesh,center:SIMD3<Float>,radii:SIMD3<Float>,yaw:Float,seed:Float,color:SIMD3<Float>) {
        let sides=20,rings=10,c=cos(yaw),s=sin(yaw)
        func rotate(_ p:SIMD3<Float>)->SIMD3<Float> {.init(p.x*c+p.z*s,p.y,-p.x*s+p.z*c)}
        func spow(_ x:Float,_ exponent:Float)->Float {(x<0 ? -1:1)*pow(abs(x),exponent)}
        func point(_ ring:Int,_ side:Int)->(SIMD3<Float>,SIMD3<Float>) {
            let t=Float(ring)*Float.pi/Float(rings),a=Float(side)*2*Float.pi/Float(sides)
            let q=SIMD3<Float>(spow(sin(t)*cos(a),0.58),spow(cos(t),0.74),spow(sin(t)*sin(a),0.65))
            var p=q*radii
            p.y += 0.007*sin(q.x*9+seed)*sin(q.z*7+0.5)*sin(t)
            // Compressed underside, pinched tied ends and a pair of sagging
            // shoulders give the sacks broad contacts on both slab and cloth.
            p.y = max(-radii.y*0.76,p.y)
            p.y -= max(0,q.y)*radii.y*(0.09+0.16*sin(q.x*4+seed)*sin(q.z*3))
            let end=pow(abs(q.x),4)
            p.z *= 1-0.30*end
            p.y *= 1-0.27*end
            p.y -= radii.y*0.13*end
            let n=simd_normalize(SIMD3<Float>(spow(q.x,2/0.58-1)/radii.x,spow(q.y,2/0.74-1)/radii.y,spow(q.z,2/0.65-1)/radii.z))
            return (center+rotate(p),rotate(n))
        }
        for ring in 0..<rings {for side in 0..<sides {
            let v=[point(ring,side),point(ring,side+1),point(ring+1,side+1),point(ring+1,side)]
            for order in [[0,1,2],[0,2,3]] {
                let start=mesh.positions.count
                mesh.triangle(v[order[0]].0,v[order[1]].0,v[order[2]].0,color:color)
                if mesh.positions.count==start+3 {
                    mesh.normals.replaceSubrange(start..<(start+3),with:order.map{v[$0].1})
                }
            }
        }}
        let tie=center+rotate(.init(radii.x*0.91,-radii.y*0.15,0))
        mesh.cylinder(from:tie,to:tie+rotate(.init(0.048,-0.016,0.010)),radius:0.020,endRadius:0.011,sides:7,color:color*0.78)
        mesh.cylinder(from:tie+rotate(.init(0.035,-0.013,0.006)),to:tie+rotate(.init(0.071,-0.048,0.012)),radius:0.005,endRadius:0.003,sides:6,color:color*1.2)
        // The seam follows the bag's equator, with a restrained thickness.
        var previous=point(rings/2,0).0
        for side in 1...sides {
            let next=point(rings/2,side).0
            mesh.cylinder(from:previous,to:next,radius:0.0033,sides:5,color:color*0.77)
            previous=next
        }
    }

    private static func crate(into mesh:inout NativeDetailMesh,hardware:inout NativeDetailMesh,center:SIMD3<Float>,size:SIMD3<Float>,color:SIMD3<Float>,steel:SIMD3<Float>) {
        mesh.beveledBox(center:center,size:size,bevel:0.022,color:color)
        mesh.beveledBox(center:center + SIMD3<Float>(0,size.y/2+0.009,0),size:.init(size.x+0.028,0.045,size.z+0.025),bevel:0.010,color:color*1.10)
        for side:Float in [-1,1] {
            mesh.beveledBox(center:center + SIMD3<Float>(side*size.x*0.36,0,size.z/2+0.009),size:.init(0.044,size.y*0.86,0.023),bevel:0.004,color:color*1.10)
            hardware.beveledBox(center:center + SIMD3<Float>(side*size.x*0.24,size.y*0.29,size.z/2+0.02),size:.init(0.050,0.12,0.025),bevel:0.006,color:steel)
            hardware.cylinder(from:center + SIMD3<Float>(side*size.x*0.24-0.025,size.y*0.25,size.z/2+0.043),
                              to:center + SIMD3<Float>(side*size.x*0.24+0.025,size.y*0.25,size.z/2+0.043),radius:0.007,sides:8,color:steel*1.3)
        }
        let handleY=center.y+size.y/2+0.075
        hardware.cylinder(from:.init(center.x-0.12,handleY,center.z),to:.init(center.x+0.12,handleY,center.z),radius:0.014,sides:10,color:steel)
        for x:Float in [-0.12,0.12] {
            hardware.cylinder(from:.init(center.x+x,handleY,center.z),to:.init(center.x+x,handleY-0.045,center.z),radius:0.012,sides:8,color:steel)
        }
    }

    private static func rock(into mesh:inout NativeDetailMesh,center:SIMD3<Float>,radii:SIMD3<Float>,seed:Float,color:SIMD3<Float>) {
        let start=mesh.positions.count
        mesh.ellipsoid(center:center,radii:radii,segments:9,rings:5,color:color)
        for i in start..<mesh.positions.count {
            let d=mesh.positions[i]-center
            let variation:Float=0.92+0.12*sin(d.x*27+d.z*31+seed)*cos(d.y*39-seed)
            mesh.positions[i]=center+d*variation
        }
    }

    private static func tuft(into mesh:inout NativeDetailMesh,center:SIMD3<Float>,seed:Float,random:inout Random,scale:Float=1) {
        for blade in 0..<8 {
            let angle=random.range(0,2 * .pi),height=random.range(0.19,0.48)*scale,lean=random.range(0.06,0.24)*scale
            let direction=SIMD3<Float>(cos(angle),0,sin(angle)),width=SIMD3<Float>(-sin(angle),0,cos(angle))*random.range(0.008,0.016)
            let bottom=center+direction*random.range(0,0.10)
            let middle=bottom+SIMD3<Float>(0,height*0.60,0)+direction*lean*0.38
            let top=bottom+SIMD3<Float>(0,height,0)+direction*lean
            let color=SIMD3<Float>(0.37,0.39,0.22)*random.range(0.83,1.15)
            mesh.quad(bottom-width,middle-width*0.65,middle+width*0.65,bottom+width,color:color*0.76)
            mesh.triangle(middle-width*0.65,top,middle+width*0.65,color:color)
            if blade%3==0 {
                mesh.cylinder(from:middle,to:top+SIMD3<Float>(0,0.045,0),radius:0.0028,sides:4,color:.init(0.50,0.43,0.27))
            }
        }
    }

    private static let detailImages:[String:NSImage] = {
        let folder=(Bundle.main.resourceURL ?? URL(fileURLWithPath:"."))
            .appendingPathComponent("remastered-assets")
        var images:[String:NSImage]=[:]
        for name in ["grass","rock"] {
            images[name]=NSImage(contentsOf:folder.appendingPathComponent(name+".png"))
        }
        return images
    }()

    private static func material(style:Int,floor:Float)->SCNMaterial {
        let m=SCNMaterial();m.name="Depthline:environment:\(style)"
        m.lightingModel = .physicallyBased;m.diffuse.contents=NSColor.white
        m.metalness.contents=style==3 ? 0.82:0;m.roughness.contents=0.86
        m.isDoubleSided=style==5
        for (key,name) in [("dlEnvRock","rock"),("dlEnvGrass","grass")] {
            let property=SCNMaterialProperty(contents:detailImages[name] ?? NSColor(calibratedWhite:0.45,alpha:1))
            property.minificationFilter = .linear;property.magnificationFilter = .linear;property.mipFilter = .linear
            property.wrapS = .repeat;property.wrapT = .repeat;property.maxAnisotropy=16
            m.setValue(property,forKey:key)
        }
        m.setValue(Float(style),forKey:"dlEnvStyle");m.setValue(floor,forKey:"dlEnvFloor")
        m.shaderModifiers=[.geometry:geometry,.surface:surface]
        return m
    }

    private static let geometry="""
    #pragma varyings
    float3 dlEnvPosition;
    float3 dlEnvNormal;
    #pragma body
    out.dlEnvPosition=_geometry.position.xyz;
    out.dlEnvNormal=_geometry.normal;
    """

    private static let surface="""
    #pragma arguments
    texture2d<float> dlEnvRock;
    texture2d<float> dlEnvGrass;
    float dlEnvStyle;
    float dlEnvFloor;
    #pragma varyings
    float3 dlEnvPosition;
    float3 dlEnvNormal;
    #pragma body
    constexpr sampler detailSampler(coord::normalized,address::repeat,filter::linear,mip_filter::linear,max_anisotropy(16));
    float3 p=in.dlEnvPosition;
    float3 localN=normalize(in.dlEnvNormal);
    float3 blend=pow(abs(localN),float3(4.0));blend/=max(blend.x+blend.y+blend.z,0.0001);
    float3 q=p*8.0;
    float broad=sin(p.x*1.31+sin(p.z*0.83))*sin(p.y*1.71+p.z*1.17);
    float grain=sin(dot(q,float3(1.13,1.71,0.73)))*sin(dot(q,float3(-0.77,0.93,1.51)));
    float3 small=p*210.0;
    float detail=sin(dot(small,float3(0.71,1.93,1.07)))*sin(dot(small,float3(1.31,-0.57,0.79)));
    float fade=1.0-smoothstep(0.45,2.2,length(fwidth(small)));
    detail*=fade;
    float rough=0.88,metal=0.0,height=0.0;
    if(dlEnvStyle<0.5){
        float3 aggregate=dlEnvRock.sample(detailSampler,p.zy/0.85).rgb*blend.x
            +dlEnvRock.sample(detailSampler,p.xz/0.85).rgb*blend.y
            +dlEnvRock.sample(detailSampler,p.xy/0.85).rgb*blend.z;
        float aggregateValue=dot(aggregate,float3(0.22,0.65,0.13));
        float pores=smoothstep(0.28,0.76,detail);
        // Form-board lift joints and a few rusty tie holes on vertical faces.
        float face=1.0-smoothstep(0.2,0.7,abs(localN.y));
        float course=(p.y-dlEnvFloor)*4.8+grain*0.012;
        float joint=face*(1.0-smoothstep(0.008,0.026,abs(fract(course+0.5)-0.5)));
        float along=dot(p.xz,normalize(float2(abs(localN.z)+0.0001,abs(localN.x)+0.0001)));
        float2 bore=(fract(float2(along/0.86+floor(course*0.5)*0.5,course*0.5)+0.5)-0.5)*float2(0.86,0.42);
        float tie=face*(1.0-smoothstep(0.009,0.018,length(bore)));
        _surface.diffuse.rgb*=1.0-joint*0.21-tie*0.49;

        float damp=(1.0-smoothstep(dlEnvFloor+0.04,dlEnvFloor+0.58,p.y))*(0.34+0.22*broad);
        _surface.diffuse.rgb*=(0.72+aggregateValue*0.88)*(0.91+grain*0.09+broad*0.12-pores*0.11);
        _surface.diffuse.rgb=mix(_surface.diffuse.rgb,_surface.diffuse.rgb*float3(0.58,0.63,0.52),damp);
        rough=0.88+grain*0.035-damp*0.10;height=grain*0.0018+detail*0.0006+aggregateValue*0.009;
        _surface.ambientOcclusion*=1.0-pores*0.20;
    }else if(dlEnvStyle<1.5){
        // Millimetre micro-weave alone disappears at gameplay distance. A
        // broader coarse cloth weave and irregular folds remain legible.
        float3 weaveP=p*410.0;
        float weave=sin(weaveP.x+weaveP.z*0.31)*sin(weaveP.y+weaveP.z*0.71);
        float warp=sin(dot(p,float3(134.0,221.0,91.0))+sin(p.z*11.0)*0.8);
        float mottled=sin(p.x*8.4+p.z*5.3)*sin(p.z*11.1-p.y*7.0);
        _surface.diffuse.rgb*=1.0 + warp*0.095/(1.0+fwidth(warp)*3.0)+mottled*0.13;
        weave*=1.0-smoothstep(0.6,3.0,length(fwidth(weaveP)));
        float wrinkle=sin(p.x*54.0+p.z*31.0+sin(p.y*17.0)*1.8)*sin(p.y*61.0-p.z*13.0+sin(p.x*11.0));
        float creases=pow(max(0.0,wrinkle),3.0)*(0.45+0.55*(1.0-abs(localN.y)));
        _surface.diffuse.rgb*=0.91+grain*0.075+broad*0.08+weave*0.10-creases*0.17;
        rough=0.96;height=weave*0.00032+grain*0.0007+wrinkle*0.0018;
        _surface.ambientOcclusion*=1.0-creases*0.12;
    }else if(dlEnvStyle<2.5){
        float scratches=sin(p.x*340.0+p.y*14.0)*sin(p.z*17.0+p.y*240.0)*fade;
        _surface.diffuse.rgb*=0.95+broad*0.065+grain*0.025;
        rough=0.64+grain*0.055;metal=0.12;height=scratches*0.000035;
    }else if(dlEnvStyle<3.5){
        _surface.diffuse.rgb*=0.97+grain*0.045;
        rough=0.43+grain*0.07;metal=0.84;height=detail*0.000015;
    }else if(dlEnvStyle<4.5){
        float3 stone=dlEnvRock.sample(detailSampler,p.zy/0.95).rgb*blend.x
            +dlEnvRock.sample(detailSampler,p.xz/0.95).rgb*blend.y
            +dlEnvRock.sample(detailSampler,p.xy/0.95).rgb*blend.z;
        float stoneValue=dot(stone,float3(0.22,0.65,0.13));
        _surface.diffuse.rgb=mix(_surface.diffuse.rgb,stone*float3(0.60,0.61,0.55),0.43)*(0.88+grain*0.10+detail*0.06);
        rough=0.94;height=grain*0.003+detail*0.0006+stoneValue*0.024;
    }else if(dlEnvStyle<5.5){
        _surface.diffuse.rgb*=0.93+grain*0.07;
        rough=0.93;height=0.0;
    }else{
        float bed=p.y*2.2+p.x*0.091+0.82*sin(p.z*0.097);
        float seam=smoothstep(0.68,0.99,cos(bed));
        float3 grainMap=dlEnvRock.sample(detailSampler,float2(p.x*0.7+p.z*0.55,p.y)/2.9).rgb;
        float grainValue=dot(grainMap,float3(0.23,0.63,0.14));
        float split=smoothstep(0.89,0.99,cos(p.x*0.88-p.z*0.82+p.y*0.51));
        _surface.diffuse.rgb*=0.80+0.77*grainValue-0.35*seam-0.21*split;
        float moss=smoothstep(0.89,0.97,localN.y)*smoothstep(0.0,0.8,broad);
        _surface.diffuse.rgb=mix(_surface.diffuse.rgb,_surface.diffuse.rgb*float3(0.53,0.71,0.36),moss);
        rough=0.90+0.04*grainValue;height=grainValue*0.051-seam*0.027;
    }
    _surface.roughness=clamp(rough,0.3,0.98);_surface.metalness=metal;
    float3 dx=dfdx(_surface.position),dy=dfdy(_surface.position);
    float3 r1=cross(dy,_surface.normal),r2=cross(_surface.normal,dx);
    float determinant=dot(dx,r1);
    float3 gradient=sign(determinant)*(dfdx(height)*r1+dfdy(height)*r2);
    _surface.normal=normalize(max(abs(determinant),1e-12)*_surface.normal-gradient);
    """
}
