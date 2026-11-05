import AppKit
import SceneKit

/// Original generic first-person weapons. Gameplay nodes supply aiming, recoil
/// and visibility; every visible part here is an independently authored primitive.
enum RemasteredArsenal {
    static let steel=SIMD3<Float>(0.25,0.28,0.31),edge=SIMD3<Float>(0.34,0.37,0.40)
    static let rubber=SIMD3<Float>(0.055,0.06,0.06),olive=SIMD3<Float>(0.20,0.24,0.14),brass=SIMD3<Float>(0.45,0.33,0.14)
    @discardableResult static func apply(to weapons:GameWeaponPresentation)->Int {
        let old=weapons.version == .beach2000
        var total=0
        func install(_ mesh:NativeDetailMesh,id:Int,suffix:String="",counterRoll:Bool=false) {
            guard let node=weapons.nodes[id],node.childNode(withName:"RemasteredArsenal"+suffix,recursively:false)==nil else{return}
            if !counterRoll {node.childNodes.filter{$0.geometry != nil && !($0.name ?? "").hasPrefix("RemasteredArsenal")}.forEach{$0.isHidden=true}}
            let m=SCNMaterial();m.name="RemasteredArsenalSteel";m.diffuse.contents=NSColor.white;m.lightingModel = .physicallyBased;m.isDoubleSided=false
            m.metalness.contents=0.7;m.roughness.contents=0.47;NativeDetailMesh.configureSurface(m,style:.weapon)
            let model=SCNNode(geometry:mesh.geometry(material:m));model.name="RemasteredArsenal"+suffix
            if counterRoll {
                model.constraints=[SCNTransformConstraint(inWorldSpace:false){node,_ in SCNMatrix4MakeRotation(-(node.parent?.eulerAngles.z ?? 0),0,0,1)}]
            }
            node.addChildNode(model);total+=mesh.indices.count/3
        }
        var cannon=NativeDetailMesh()
        cannon.machinedBox(center:.init(0,-0.035,-0.39),size:.init(0.28,0.26,0.44),bevel:0.026,color:steel)
        cannon.cylinder(from:.init(0,0,-0.55),to:.init(0,0,-2.65),radius:0.105,endRadius:0.058,sides:32,color:edge)
        cannon.cylinder(from:.init(0,0,-0.55),to:.init(0,0,-0.83),radius:0.126,sides:32,color:steel)
        cannon.cylinder(from:.init(0,0,-1.32),to:.init(0,0,-1.56),radius:0.093,sides:24,color:steel)
        cannon.cylinder(from:.init(0,0,-2.51),to:.init(0,0,-2.65),radius:0.087,sides:24,color:steel,caps:false)
        cannon.cylinder(from:.init(0,0,-2.646),to:.init(0,0,-2.645),radius:0.048,sides:24,color:rubber)
        cannon.cylinder(from:.init(-0.22,-0.10,-0.45),to:.init(0.22,-0.10,-0.45),radius:0.045,sides:18,color:steel)
        cannon.machinedBox(center:.init(0,-0.24,-0.46),size:.init(0.20,0.21,0.30),bevel:0.022,color:steel)
        for side:Float in [-1,1] {
            cannon.cylinder(from:.init(side*0.21,-0.10,-0.45),to:.init(side*0.26,-0.12,-0.25),radius:0.012,sides:10,color:edge)
            cannon.cylinder(from:.init(side*0.26,-0.12,-0.25),to:.init(side*0.26,-0.24,-0.25),radius:0.023,sides:12,color:rubber)
            for z:Float in [-0.27,-0.39,-0.51] {cannon.cylinder(from:.init(side*0.141,0.01,z),to:.init(side*0.147,0.01,z),radius:0.008,sides:8,color:edge)}
        }
        cannon.machinedBox(center:.init(0,0.11,-0.31),size:.init(0.07,0.025,0.08),bevel:0.006,color:edge)
        for x:Float in [-0.093,0.093] {
            cannon.machinedBox(center:.init(x,0.099,-0.40),size:.init(0.012,0.011,0.30),bevel:0.003,color:edge)
        }
        cannon.box(center:.init(0,0.13,-0.31),size:.init(0.010,0.018,0.025),color:steel)
        cannon.box(center:.init(0,0.09,-2.40),size:.init(0.012,0.07,0.035),color:steel)
        install(cannon,id:old ? 143:24)
        weapons.registerMuzzle(SCNVector3(0,0,-2.65),for:old ? 143:24)

        var pistol=NativeDetailMesh()
        pistol.machinedBox(center:.init(0,0.064,-0.07),size:.init(0.047,0.059,0.30),bevel:0.005,color:steel)
        pistol.machinedBox(center:.init(0,-0.018,0.018),size:.init(0.042,0.15,0.073),bevel:0.009,color:rubber)
        for i in 0..<5 {for side:Float in [-1,1] {
            pistol.machinedBox(center:.init(side*0.021,-0.070+Float(i)*0.022,0.018),size:.init(0.004,0.008,0.057),bevel:0.0015,color:rubber*1.38)
        }}
        pistol.box(center:.init(0,-0.096,0.018),size:.init(0.048,0.017,0.080),color:steel)
        pistol.cylinder(from:.init(0,0.14,-0.27),to:.init(0,0.14,-0.31),radius:0.015,sides:18,color:edge,caps:false)
        pistol.cylinder(from:.init(0,0.14,-0.307),to:.init(0,0.14,-0.306),radius:0.010,sides:16,color:rubber)
        // Closed trigger guard with visible air in its centre.
        pistol.cylinder(from:.init(0,0.045,-0.085),to:.init(0,-0.008,-0.10),radius:0.006,sides:8,color:steel)
        pistol.cylinder(from:.init(0,-0.008,-0.10),to:.init(0,-0.018,-0.026),radius:0.006,sides:8,color:steel)
        pistol.cylinder(from:.init(0,-0.018,-0.026),to:.init(0,0.035,-0.015),radius:0.006,sides:8,color:steel)
        pistol.cylinder(from:.init(0,0.033,-0.053),to:.init(0,0.003,-0.062),radius:0.004,sides:8,color:edge)
        for side:Float in [-1,1] {pistol.cylinder(from:.init(side*0.024,0.048,-0.07),to:.init(side*0.029,0.048,-0.07),radius:0.008,sides:10,color:edge)}
        addFiringHand(to:&pistol)
        install(pistol,id:old ? 214:26)
        weapons.registerMuzzle(SCNVector3(0,0.14,-0.31),for:old ? 214:26)
        var slide=NativeDetailMesh()
        slide.machinedBox(center:.init(0,0.118,-0.081),size:.init(0.049,0.068,0.415),bevel:0.007,color:steel)
        slide.box(center:.init(0.025,0.127,-0.095),size:.init(0.003,0.028,0.060),color:rubber)
        for i in 0..<8 {for side:Float in [-1,1] {slide.box(center:.init(side*0.025,0.118,0.045+Float(i)*0.008),size:.init(0.003,0.043,0.003),color:edge)}}
        slide.box(center:.init(0,0.162,-0.262),size:.init(0.008,0.020,0.015),color:edge)
        for x:Float in [-0.017,0.017] {slide.box(center:.init(x,0.163,0.09),size:.init(0.011,0.019,0.015),color:edge)}
        install(slide,id:old ? 215:27)
        if !old {
            var m60=NativeDetailMesh()
            m60.machinedBox(center:.init(0,0,-0.092),size:.init(0.100,0.110,0.30),bevel:0.009,color:steel)
            // The feed cover is dark blued steel, with a hinge and a rear latch
            // breaking the large near-camera flat surface into functional parts.
            let cover=SIMD3<Float>(0.105,0.125,0.14)
            m60.machinedBox(center:.init(0,0.062,-0.095),size:.init(0.104,0.022,0.25),bevel:0.005,color:cover)
            for x:Float in [-0.040,0.040] {
                m60.machinedBox(center:.init(x,0.075,-0.095),size:.init(0.009,0.006,0.206),bevel:0.002,color:steel)
            }
            m60.cylinder(from:.init(-0.050,0.067,-0.207),to:.init(0.050,0.067,-0.207),radius:0.010,sides:12,color:steel)
            m60.machinedBox(center:.init(0,0.076,0.014),size:.init(0.040,0.009,0.023),bevel:0.003,color:steel)
            m60.box(center:.init(0,0.081,0.014),size:.init(0.026,0.003,0.005),color:rubber)
            m60.machinedBox(center:.init(0,-0.013,0.13),size:.init(0.065,0.10,0.19),bevel:0.017,color:rubber)
            m60.machinedBox(center:.init(0,-0.103,0.025),size:.init(0.048,0.13,0.065),bevel:0.009,color:rubber)
            m60.cylinder(from:.init(0,0,-0.23),to:.init(0,0,-0.56),radius:0.020,endRadius:0.014,sides:20,color:edge)
            m60.cylinder(from:.init(0,-0.035,-0.245),to:.init(0,-0.035,-0.46),radius:0.018,sides:14,color:steel)
            m60.machinedBox(center:.init(0,-0.018,-0.315),size:.init(0.085,0.085,0.18),bevel:0.013,color:rubber)
            for i in 0..<7 {m60.box(center:.init(0,-0.055,-0.25-Float(i)*0.023),size:.init(0.083,0.006,0.007),color:edge)}
            // Fold the carrying handle beside the feed cover for firing.
            m60.cylinder(from:.init(-0.04,0.055,-0.18),to:.init(-0.10,0.055,-0.18),radius:0.009,sides:10,color:steel)
            m60.cylinder(from:.init(-0.10,0.055,-0.18),to:.init(-0.10,0.055,-0.05),radius:0.013,sides:12,color:rubber)
            m60.cylinder(from:.init(-0.10,0.055,-0.05),to:.init(-0.04,0.055,-0.05),radius:0.009,sides:10,color:steel)
            let boxPaint=SIMD3<Float>(0.33,0.36,0.23)
            m60.machinedBox(center:.init(-0.145,-0.088,-0.13),size:.init(0.12,0.15,0.20),bevel:0.009,color:boxPaint)
            m60.beveledBox(center:.init(-0.145,-0.008,-0.13),size:.init(0.129,0.014,0.211),bevel:0.004,color:boxPaint*1.15)
            m60.beveledBox(center:.init(-0.207,-0.036,-0.12),size:.init(0.007,0.045,0.028),bevel:0.003,color:edge)
            for i in 0..<8 {
                let t=Float(i)/7,x:Float = -0.047-t*0.113,y:Float=0.050+sin(t*Float.pi)*0.031-t*0.048
                m60.cylinder(from:.init(x,y,-0.167),to:.init(x,y,-0.105),radius:0.0065,sides:8,color:.init(0.69,0.50,0.24))
                m60.cylinder(from:.init(x,y,-0.188),to:.init(x,y,-0.167),radius:0.0008,endRadius:0.0065,sides:8,color:.init(0.48,0.32,0.18))
                m60.box(center:.init(x,y,-0.127),size:.init(0.016,0.011,0.014),color:steel)
            }
            for side:Float in [-1,1] {m60.cylinder(from:.init(side*0.045,-0.02,-0.43),to:.init(side*0.045,-0.05,-0.21),radius:0.006,sides:8,color:steel)}
            m60.box(center:.init(0,0.04,-0.51),size:.init(0.008,0.063,0.019),color:steel)
            // The inherited mount is only 25 cm in front of the camera. Keep
            // the receiver below the sightline and shorten the rear stock;
            // the original muzzle remains at local Z=-0.56.
            m60.scaleVisual(.init(0.65,0.55,1),rearScale:0.65)
            install(m60,id:23)
            weapons.registerMuzzle(SCNVector3(0,0,-0.56),for:23)
            var rotary=NativeDetailMesh()
            rotary.cylinder(from:.init(0,0,-0.15),to:.init(0,0,-0.22),radius:0.058,sides:24,color:steel)
            for i in 0..<6 {
                let a=Float(i)*Float.pi/3,x=cos(a)*0.031,y=sin(a)*0.031
                rotary.cylinder(from:.init(x,y,-0.21),to:.init(x,y,-0.56),radius:0.009,sides:12,color:edge)
                rotary.cylinder(from:.init(x,y,-0.56),to:.init(x,y,-0.559),radius:0.0055,sides:12,color:rubber)
            }
            for z:Float in [-0.30,-0.48] {rotary.cylinder(from:.init(0,0,z),to:.init(0,0,z-0.025),radius:0.049,sides:24,color:steel,caps:false)}
            install(rotary,id:25)
            weapons.registerMuzzle(SCNVector3(0,0,-0.56),for:25)
            var cradle=NativeDetailMesh();cradle.machinedBox(center:.init(0,-0.025,-0.035),size:.init(0.14,0.16,0.23),bevel:0.023,color:steel)
            cradle.machinedBox(center:.init(0,-0.08,0.12),size:.init(0.12,0.10,0.15),bevel:0.018,color:rubber)
            cradle.cylinder(from:.init(0.09,-0.025,-0.07),to:.init(0.09,-0.025,0.10),radius:0.046,sides:16,color:steel)
            cradle.machinedBox(center:.init(-0.12,-0.05,-0.045),size:.init(0.12,0.16,0.17),bevel:0.013,color:olive)
            cradle.scaleVisual(.init(0.85,0.85,1),rearScale:0.65)
            install(cradle,id:25,suffix:"Cradle",counterRoll:true)
            var flare=NativeDetailMesh();flare.machinedBox(center:.init(0,0.04,-0.03),size:.init(0.055,0.09,0.20),bevel:0.008,color:steel)
            flare.machinedBox(center:.init(0,-0.04,0.03),size:.init(0.05,0.14,0.07),bevel:0.011,color:.init(0.27,0.11,0.045))
            flare.cylinder(from:.init(0,0.09,-0.10),to:.init(0,0.09,-0.28),radius:0.032,sides:20,color:edge,caps:false)
            flare.cylinder(from:.init(0,0.09,-0.278),to:.init(0,0.09,-0.277),radius:0.024,sides:20,color:rubber)
            flare.box(center:.init(0,0.13,-0.24),size:.init(0.008,0.020,0.018),color:steel)
            addFiringHand(to:&flare)
            install(flare,id:28)
        }
        return total
    }
    /// Hand-held weapons keep a gripping hand and sleeve in the same batch as
    /// their frame; the slide remains a separate moving object.
    private static func addFiringHand(to mesh:inout NativeDetailMesh) {
        let leather=SIMD3<Float>(0.25,0.20,0.145),cloth=SIMD3<Float>(0.32,0.34,0.23)
        mesh.activeSurface=7
        mesh.ellipsoid(center:.init(0.026,-0.039,0.032),radii:.init(0.039,0.063,0.052),segments:12,rings:7,color:leather)
        for i in 0..<3 {
            let y:Float = -0.023-Float(i)*0.022,z:Float = -0.009+Float(i)*0.004
            mesh.cylinder(from:.init(0.041,y,0.008),to:.init(0.018,y,z-0.027),radius:0.012,sides:8,color:leather)
            mesh.cylinder(from:.init(0.018,y,z-0.027),to:.init(-0.023,y-0.002,z-0.017),radius:0.012,endRadius:0.009,sides:8,color:leather)
        }
        mesh.cylinder(from:.init(0.040,0.010,0.036),to:.init(-0.028,0.022,0.030),radius:0.014,sides:9,color:leather)
        mesh.cylinder(from:.init(-0.028,0.022,0.030),to:.init(-0.027,0.011,-0.036),radius:0.013,endRadius:0.010,sides:9,color:leather)
        mesh.cylinder(from:.init(0.041,0.011,0.003),to:.init(0.023,0.006,-0.057),radius:0.011,sides:8,color:leather)
        mesh.cylinder(from:.init(0.034,-0.065,0.065),to:.init(0.072,-0.089,0.12),radius:0.040,endRadius:0.046,sides:12,color:leather)
        mesh.cylinder(from:.init(0.061,-0.084,0.102),to:.init(0.245,-0.23,0.43),radius:0.052,endRadius:0.085,sides:14,color:cloth)
        mesh.cylinder(from:.init(0.061,-0.084,0.102),to:.init(0.075,-0.097,0.127),radius:0.055,endRadius:0.057,sides:14,color:cloth*0.82)
        mesh.activeSurface=0
    }

}

func testRemasteredArsenal(objects:[[String:Any]],version:OriginalGameVersion) throws {
    func check(_ good:Bool,_ message:String) throws{if !good{throw NSError(domain:"RemasteredArsenal",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
    var solid=NativeDetailMesh();solid.machinedBox(center:.init(2,-1,4),size:.init(0.8,1.2,2.0),bevel:0.06,color:.init(0.2,0.2,0.2))
    try check(solid.surfaceDetail.count==solid.positions.count && solid.surfaceDetail.contains(where:{$0.x>0.5}),"Machined casing lost its per-vertex edge attribute")
    for i in stride(from:0,to:solid.positions.count,by:3) {
        let outward=(solid.positions[i]+solid.positions[i+1]+solid.positions[i+2])/3-SIMD3<Float>(2,-1,4)
        let face=simd_cross(solid.positions[i+1]-solid.positions[i],solid.positions[i+2]-solid.positions[i])
        try check(simd_dot(outward,solid.normals[i])>0 && simd_dot(outward,face)>0,"Machined solid has an inward-facing corner/edge normal or winding")
    }
    let p=GameWeaponPresentation(version:version,objects:objects,parent:SCNNode()){item in
        let n=SCNNode();n.name=item["name"] as? String
        let v=(item["translation"] as? [NSNumber] ?? [0,0,0]).map{$0.doubleValue/100};n.position=SCNVector3(v[0],v[1],v[2])
        for _ in item["groups"] as? [[String:Any]] ?? [] {n.addChildNode(SCNNode(geometry:SCNBox(width:0.1,height:0.1,length:0.1,chamferRadius:0)))};return n
    }
    let old=version == .beach2000,ids=old ? [143,214,215]:[23,24,25,26,27,28]
    let before=Dictionary(uniqueKeysWithValues:ids.map{($0,p.nodes[$0]!.transform)})
    let count=RemasteredArsenal.apply(to:p)
    try check(count>1000 && count<24000 && RemasteredArsenal.apply(to:p)==0,"Arsenal absent, unbounded or duplicated")
    for id in ids {
        let node=p.nodes[id]!,draws=node.childNodes.filter{$0.geometry != nil && !$0.isHidden}.count
        try check(draws == (id==25 && !old ? 2:1),"Wrong visible weapon batches")
        try check(SCNMatrix4EqualToMatrix4(node.transform,before[id]!),"Replacement moved source weapon pivot")
    }
    p.sync(selected:.handgun);p.tick(acceptedFire:.init(weapon:.handgun,barrel:.center,variant:0,recoilTicks:5,ballistic:nil));p.tick(acceptedFire:nil)
    try check(abs(p.nodes[old ? 215:27]!.position.z-0.08)<0.0001,"New pistol slide lost source independent recoil")
    if !old {
        let cradle=p.nodes[25]!.childNode(withName:"RemasteredArsenalCradle",recursively:false)!
        try check(cradle.constraints?.count==1,"Rotary fixed cradle would spin with barrel")
        let m60=p.nodes[23]!,box=m60.childNode(withName:"RemasteredArsenal",recursively:false)!.boundingBox
        try check(box.max.z+m60.position.z < -0.10 && box.max.y+m60.position.y < 0.16,"M60 receiver intrudes on camera/sightline")
        try check(abs(box.min.z+m60.position.z+0.81)<0.0001,"M60 presentation adjustment moved original muzzle")
        p.sync(selected:.flare);try check(!p.nodes[28]!.isHidden,"New flare gun does not follow source weapon switch")
    }
    print("PASS remastered arsenal \(version.rawValue): \(count) triangles, all original pivots, slide recoil, source visibility, fixed rotary cradle")
}
