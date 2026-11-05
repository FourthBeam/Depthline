import AppKit
import SceneKit

/// Original generic twin emplacement, built entirely from procedural primitives.
/// Aiming/recoil nodes remain gameplay pivots. No source-game mesh or texture is used.
enum OriginalWeaponCompletion {
    @discardableResult
    static func apply(to weapons: GameWeaponPresentation, remastered: Bool) -> Int {
        let old=weapons.version == .beach2000
        guard let mount=weapons.nodes[old ? 8:20],
              mount.childNode(withName:"CompletedTwinReceiver",recursively:false)==nil else {return 0}
        let steel=SIMD3<Float>(0.32,0.35,0.36), edge=SIMD3<Float>(0.50,0.52,0.51)
        let rubber=SIMD3<Float>(0.055,0.06,0.06), dark=SIMD3<Float>(0.18,0.20,0.21)
        let olive=SIMD3<Float>(0.32,0.34,0.22), brass=SIMD3<Float>(0.70,0.51,0.24)
        let material=SCNMaterial();material.name="CompletedReceiverMaterial"
        material.diffuse.contents=NSColor.white;material.isDoubleSided=false
        material.lightingModel = .physicallyBased
        material.metalness.contents=0.62;material.roughness.contents=0.43
        material.specular.contents=NSColor(calibratedWhite:0.3,alpha:1)
        NativeDetailMesh.configureSurface(material,style:.weapon)
        var fixed=NativeDetailMesh(), triangles=0
        for side:Float in [-1,1] {
            let x:Float=side*0.3
            func p(_ dx:Float,_ y:Float,_ z:Float)->SIMD3<Float>{.init(x+side*dx,y,z)}
            fixed.machinedBox(center:p(0,0,-0.49),size:.init(0.17,0.19,0.62),bevel:0.014,color:olive*1.06)
            fixed.machinedBox(center:p(0,0.111,-0.53),size:.init(0.18,0.036,0.40),bevel:0.006,color:dark)
            fixed.machinedBox(center:p(0,-0.004,-0.174),size:.init(0.177,0.197,0.040),bevel:0.014,color:steel)
            // Separate feed-cover rails, a rear inspection plate and inset screw
            // heads break the large blank near-camera slab into readable parts.
            for dx:Float in [-0.071,0.071] {
                fixed.machinedBox(center:p(dx,0.132,-0.53),size:.init(0.012,0.010,0.33),bevel:0.003,color:steel)
                for z:Float in [-0.39,-0.67] {
                    fixed.cylinder(from:p(dx,0.131,z),to:p(dx,0.137,z),radius:0.006,sides:12,color:edge)
                    fixed.box(center:p(dx,0.138,z),size:.init(0.007,0.001,0.0015),color:dark)
                }
            }
            if side<0 {
                // Spring buffer cap with locking lugs on the port gun.
                fixed.cylinder(from:p(0,0.002,-0.16),to:p(0,0.002,-0.115),radius:0.060,endRadius:0.053,sides:24,color:edge)
                fixed.cylinder(from:p(0,0.002,-0.116),to:p(0,0.002,-0.105),radius:0.039,sides:16,color:dark)
                fixed.beveledBox(center:p(0,0.002,-0.099),size:.init(0.066,0.015,0.012),bevel:0.004,color:steel)
            } else {
                // Removable breech plate and cam latch on the service side.
                let plate=[p(-0.058,-0.036,-0.15),p(0.062,-0.036,-0.15),p(0.062,0.034,-0.15),
                           p(0.018,0.067,-0.15),p(-0.058,0.035,-0.15)]
                fixed.plate(plate,thickness:.init(0,0,0.013),color:olive*1.18)
                fixed.cylinder(from:p(0.015,0.015,-0.14),to:p(0.015,0.015,-0.122),radius:0.023,sides:14,color:edge)
                fixed.cylinder(from:p(0.012,0.013,-0.118),to:p(-0.032,-0.015,-0.098),radius:0.008,sides:8,color:dark)
                for dx:Float in [-0.044,0.048] {
                    fixed.cylinder(from:p(dx,-0.021,-0.141),to:p(dx,-0.021,-0.134),radius:0.006,sides:6,color:edge)
                }
            }
            fixed.machinedBox(center:p(0,0.142,-0.69),size:.init(0.052,0.025,0.045),bevel:0.006,color:steel)
            // Open rear sight, rather than a solid silhouette block.
            for dx:Float in [-0.019,0.019] {
                fixed.machinedBox(center:p(dx,0.152,-0.29),size:.init(0.010,0.042,0.020),bevel:0.002,color:steel)
            }
            fixed.machinedBox(center:p(0,0.133,-0.29),size:.init(0.050,0.012,0.023),bevel:0.003,color:dark)
            fixed.box(center:p(0.090,0.035,-0.57),size:.init(0.012,0.058,0.17),color:rubber)
            fixed.machinedBox(center:p(0.087,-0.019,-0.57),size:.init(0.016,0.034,0.21),bevel:0.004,color:edge)
            for z:Float in [-0.47,-0.53,-0.59,-0.65] {
                fixed.machinedBox(center:p(0.097,-0.019,z),size:.init(0.004,0.019,0.025),bevel:0.002,color:dark)
            }
            fixed.machinedBox(center:p(0.096,-0.015,-0.38),size:.init(0.026,0.032,0.12),bevel:0.004,color:edge)
            fixed.cylinder(from:p(0.10,-0.01,-0.35),to:p(0.165,-0.01,-0.35),radius:0.009,sides:10,color:steel)
            fixed.cylinder(from:p(0.165,-0.01,-0.38),to:p(0.165,-0.01,-0.32),radius:0.014,sides:12,color:rubber)
            // Closed ammunition box and visible belt, extending into the former
            // empty outside area without moving either weapon's firing basis.
            fixed.machinedBox(center:p(0.31,-0.15,-0.53),size:.init(0.17,0.22,0.32),bevel:0.011,color:olive)
            fixed.machinedBox(center:p(0.31,-0.032,-0.53),size:.init(0.18,0.025,0.335),bevel:0.005,color:olive*1.16)
            fixed.box(center:p(0.40,-0.11,-0.53),size:.init(0.015,0.025,0.13),color:dark)
            for z:Float in [-0.40,-0.66] {
                fixed.machinedBox(center:p(0.31,-0.016,z),size:.init(0.14,0.008,0.016),bevel:0.002,color:steel)
            }
            fixed.beveledBox(center:p(0.20,-0.245,-0.53),size:.init(0.40,0.035,0.26),bevel:0.005,color:steel)
            for i in 0..<12 {
                let t=Float(i)/11, dx:Float=0.30-t*0.218
                let y:Float = -0.009+t*0.071+sin(t*Float.pi)*0.060
                fixed.cylinder(from:p(dx,y,-0.60),to:p(dx,y,-0.51),radius:0.0085,sides:8,color:brass)
                fixed.cylinder(from:p(dx,y,-0.63),to:p(dx,y,-0.60),radius:0.001,endRadius:0.0085,sides:8,color:.init(0.51,0.32,0.19))
                fixed.box(center:p(dx,y+0.001,-0.55),size:.init(0.020,0.014,0.016),color:dark)
            }
            fixed.cylinder(from:p(0.065,-0.07,-0.185),to:p(0.11,-0.10,-0.135),radius:0.010,sides:10,color:steel)
            fixed.cylinder(from:p(0.11,-0.10,-0.135),to:p(0.11,-0.22,-0.135),radius:0.018,sides:12,color:rubber)
            fixed.machinedBox(center:p(0,-0.13,-0.53),size:.init(0.21,0.06,0.43),bevel:0.006,color:dark)
            for z:Float in [-0.28,-0.47,-0.68] {for y:Float in [-0.05,0.06] {
                fixed.cylinder(from:p(0.085,y,z),to:p(0.090,y,z),radius:0.005,sides:8,color:edge)
            }}
            // Exposed trunnion journal and cheek plate join each gun to the yoke.
            fixed.plate([p(0,-0.055,-0.58),p(0,-0.067,-0.40),p(0,-0.28,-0.52),p(0,-0.28,-0.64)],thickness:.init(0.066,0,0),color:olive)
            fixed.cylinder(from:p(-0.10,-0.08,-0.51),to:p(0.113,-0.08,-0.51),radius:0.042,sides:20,color:edge)
            let id = old ? (side<0 ? 9:10):(side<0 ? 21:22)
            guard let barrel=weapons.nodes[id] else {continue}
            var moving=NativeDetailMesh()
            moving.cylinder(from:p(0,0,-0.77),to:p(0,0,-0.91),radius:0.046,endRadius:0.039,sides:20,color:steel)
            moving.cylinder(from:p(0,0,-0.90),to:p(0,0,-2.1325),radius:0.023,endRadius:0.018,sides:32,color:steel)
            // Real holes between rings/struts; all parts share one draw per gun.
            for i in 0..<10 {
                let z:Float = -0.92-Float(i)*0.065
                moving.cylinder(from:p(0,0,z),to:p(0,0,z-0.018),radius:0.037,sides:28,color:steel,caps:false)
            }
            for i in 0..<8 {
                let a=Float(i)*Float.pi/4,dx=cos(a)*0.034,y=sin(a)*0.034
                moving.cylinder(from:p(dx,y,-0.91),to:p(dx,y,-1.54),radius:0.0045,sides:6,color:steel)
            }
            moving.cylinder(from:p(0,0,-2.055),to:p(0,0,-2.1325),radius:0.027,endRadius:0.023,sides:20,color:dark,caps:false)
            moving.cylinder(from:p(0,0,-2.132),to:p(0,0,-2.131),radius:0.013,sides:20,color:rubber)
            moving.box(center:p(0,0.041,-2.015),size:.init(0.006,0.046,0.015),color:dark)
            barrel.childNodes.filter{$0.geometry != nil}.forEach{$0.isHidden=true}
            let model=SCNNode(geometry:moving.geometry(material:material));model.name="CompletedTwinBarrel"
            barrel.addChildNode(model);triangles+=moving.indices.count/3
            weapons.registerMuzzle(SCNVector3(x,0,-2.1325),for:id)
        }
        fixed.machinedBox(center:.init(0,-0.19,-0.57),size:.init(0.83,0.065,0.19),bevel:0.008,color:steel)
        fixed.cylinder(from:.init(0,-0.22,-0.57),to:.init(0,-0.70,-0.57),radius:0.068,endRadius:0.085,sides:16,color:steel)
        fixed.cylinder(from:.init(0,-0.21,-0.57),to:.init(0,-0.27,-0.57),radius:0.12,sides:20,color:dark)
        fixed.cylinder(from:.init(0,-0.34,-0.57),to:.init(0,-0.38,-0.57),radius:0.19,endRadius:0.22,sides:32,color:olive)
        fixed.cylinder(from:.init(0,-0.38,-0.57),to:.init(0,-0.405,-0.57),radius:0.23,sides:32,color:edge)
        mount.childNodes.filter{$0.geometry != nil}.forEach{$0.isHidden=true}
        let node=SCNNode(geometry:fixed.geometry(material:material));node.name="CompletedTwinReceiver"
        mount.addChildNode(node)
        return triangles+fixed.indices.count/3
    }
}

func testOriginalWeaponCompletion(objects:[[String:Any]],version:OriginalGameVersion) throws {
    func check(_ good:Bool,_ message:String) throws {if !good{throw NSError(domain:"OriginalWeaponCompletion",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
    let presentation=GameWeaponPresentation(version:version,objects:objects,parent:SCNNode()){item in
        let n=SCNNode();n.name=item["name"] as? String
        let p=(item["translation"] as? [NSNumber] ?? [0,0,0]).map{$0.doubleValue/100}
        n.position=SCNVector3(p[0],p[1],p[2]);n.addChildNode(SCNNode(geometry:SCNBox(width:0.1,height:0.1,length:0.1,chamferRadius:0)))
        return n
    }
    let old=version == .beach2000,mount=old ? 8:20,left=old ? 9:21,right=old ? 10:22
    let action=OriginalFireAction(weapon:.machineGun,barrel:.left,variant:0,recoilTicks:6,ballistic:nil)
    let basis=presentation.basis(for:action)
    let triangles=OriginalWeaponCompletion.apply(to:presentation,remastered:true)
    try check(triangles>3000 && triangles<18000,"Complete detailed model outside draw budget")
    try check(OriginalWeaponCompletion.apply(to:presentation,remastered:true)==0,"Completion duplicated geometry")
    for id in [mount,left,right] {
        let node=presentation.nodes[id]!
        try check(node.childNodes.filter{$0.geometry != nil && !$0.isHidden}.count==1,"Each articulated group needs one batched draw")
        try check(node.childNodes.filter{$0.geometry != nil && $0.isHidden}.count==1,"Original open mesh was not replaced")
    }
    let after=presentation.basis(for:action)
    try check(basis.forward.x==after.forward.x && basis.forward.y==after.forward.y && basis.forward.z==after.forward.z,"Visual replacement changed projectile basis")
    presentation.tick(acceptedFire:action)
    try check(abs(presentation.nodes[left]!.position.z-0.3)<0.00001 && abs(presentation.nodes[right]!.position.z)<0.00001,"Independent source recoil lost")
    presentation.sync(selected:.handgun)
    try check(presentation.nodes[mount]!.isHidden && presentation.nodes[left]!.isHidden,"Twin model failed to hide on weapon switch")
    print("PASS complete twin weapon \(version.rawValue): \(triangles) triangles, 3 batches, closed replacement, source basis/recoil/switch")
}
