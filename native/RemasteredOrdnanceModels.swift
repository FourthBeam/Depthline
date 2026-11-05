import AppKit
import SceneKit

/// Visible ordnance only. Flight, guidance, damage and pool ownership remain in
/// OriginalProjectiles/OriginalEnemyOrdnanceState. Models face the source -Z.
enum RemasteredOrdnanceModels {
    static let paint=SIMD3<Float>(0.32,0.36,0.27),steel=SIMD3<Float>(0.19,0.22,0.23)
    static let pale=SIMD3<Float>(0.67,0.68,0.61),band=SIMD3<Float>(0.57,0.44,0.14)
    @discardableResult static func apply(to root:SCNNode,type:String,gameID:String)->Int {
        let key=type.uppercased(),kind:String
        if key=="MISSILE" || key.range(of:"^MISSILE[0-9]+$",options:.regularExpression) != nil {kind="missile"}
        else if key=="ROCKETS" || key.range(of:"^ROCKET[0-9]+$",options:.regularExpression) != nil {kind="rocket"}
        else if key=="BOMBS" || key.range(of:"^BOMB[0-9]+$",options:.regularExpression) != nil {kind="bomb"}
        else if key=="GRENADES" {kind="grenade"}
        else{return 0}
        guard root.childNode(withName:"RemasteredOrdnance",recursively:false)==nil else{return 0}
        root.geometry=nil // Remove any legacy fallback shape when replacing a visual.
        var mesh=NativeDetailMesh()
        func fins(_ mesh:inout NativeDetailMesh,front:Float,rear:Float,radius:Float,span:Float) {
            for i in 0..<4 {
                let a=Float(i)*Float.pi/2+Float.pi/4,d=SIMD3<Float>(cos(a),sin(a),0),t=SIMD3<Float>(-sin(a),cos(a),0)
                mesh.plate([d*radius + .init(0,0,front),d*span + .init(0,0,rear-0.05),d*span + .init(0,0,rear),d*radius + .init(0,0,rear)],thickness:t*0.008,color:paint)
            }
        }
        if kind=="missile" {
            let old=gameID=="2000",length:Float=old ? 2.40:1.44,r:Float=old ? 0.095:0.055,span:Float=old ? 0.24:0.102
            mesh.cylinder(from:.init(0,0,-length*0.74),to:.init(0,0,-0.04),radius:r,sides:20,color:pale)
            mesh.cylinder(from:.init(0,0,-length),to:.init(0,0,-length*0.74),radius:0.006,endRadius:r,sides:20,color:steel)
            for z:Float in [-length*0.73,-length*0.28] {mesh.cylinder(from:.init(0,0,z),to:.init(0,0,z+0.025),radius:r*1.018,sides:20,color:band)}
            fins(&mesh,front:-length*0.25,rear:0,radius:r,span:span)
            mesh.cylinder(from:.init(0,0,-0.04),to:.init(0,0,0),radius:r*0.8,sides:16,color:steel,caps:false)
            mesh.cylinder(from:.init(0,0,-0.012),to:.init(0,0,-0.011),radius:r*0.60,sides:16,color:.init(0.035,0.035,0.03))
        }else if kind=="rocket" {
            mesh.cylinder(from:.init(0,0,-0.25),to:.init(0,0,0.39),radius:0.043,sides:16,color:paint)
            mesh.cylinder(from:.init(0,0,-0.40),to:.init(0,0,-0.25),radius:0.003,endRadius:0.043,sides:16,color:steel)
            mesh.cylinder(from:.init(0,0,-0.20),to:.init(0,0,-0.18),radius:0.044,sides:16,color:band)
            fins(&mesh,front:0.18,rear:0.40,radius:0.043,span:0.08)
            mesh.cylinder(from:.init(0,0,0.39),to:.init(0,0,0.40),radius:0.035,sides:16,color:steel,caps:false)
        }else if kind=="bomb" {
            mesh.ellipsoid(center:.init(0,0,-0.13),radii:.init(0.08,0.08,0.37),segments:20,rings:12,color:paint)
            mesh.cylinder(from:.init(0,0,-0.24),to:.init(0,0,-0.215),radius:0.076,sides:20,color:band)
            mesh.cylinder(from:.init(0,0,0.12),to:.init(0,0,0.48),radius:0.057,endRadius:0.025,sides:16,color:paint)
            fins(&mesh,front:0.19,rear:0.50,radius:0.028,span:0.08)
        }else{
            mesh.ellipsoid(center:.init(0,-0.02,0),radii:.init(0.063,0.083,0.063),segments:16,rings:10,color:paint)
            mesh.cylinder(from:.init(0,0.045,0),to:.init(0,0.085,0),radius:0.025,sides:12,color:steel)
            mesh.beveledBox(center:.init(0,0.086,0.012),size:.init(0.035,0.013,0.075),bevel:0.003,color:steel)
            mesh.cylinder(from:.init(0,0.08,0.046),to:.init(0,-0.055,0.071),radius:0.009,sides:8,color:steel)
            // A real open safety ring, not intersecting alpha cards.
            for i in 0..<12 {let a=Float(i)*Float.pi/6,b=Float(i+1)*Float.pi/6
                mesh.cylinder(from:.init(0.025+cos(a)*0.025,0.065+sin(a)*0.025,-0.005),to:.init(0.025+cos(b)*0.025,0.065+sin(b)*0.025,-0.005),radius:0.003,sides:6,color:steel)}
        }
        root.childNodes.filter{$0.geometry != nil}.forEach{$0.isHidden=true}
        let material=SCNMaterial();material.name="RemasteredOrdnancePaint";material.diffuse.contents=NSColor.white
        material.lightingModel = .physicallyBased;material.isDoubleSided=true
        NativeDetailMesh.configureSurface(material,style:.paint)
        let node=SCNNode(geometry:mesh.geometry(material:material));node.name="RemasteredOrdnance";root.addChildNode(node)
        return mesh.indices.count/3
    }
}

func testRemasteredOrdnanceModels() throws {
    func check(_ good:Bool,_ message:String)throws{if !good{throw NSError(domain:"RemasteredOrdnanceModels",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
    for game in ["2000","2002"] {for type in ["Missile1","MISSILE","Rocket1","ROCKETS","Bomb1","BOMBS","Grenades"] {
        let root=SCNNode();root.position=SCNVector3(3,6,-8);root.eulerAngles=SCNVector3(0.2,0.4,0.1);root.scale=SCNVector3(2,2,2)
        let original=SCNNode(geometry:SCNSphere(radius:0.1));root.addChildNode(original)
        let transform=root.transform,count=RemasteredOrdnanceModels.apply(to:root,type:type,gameID:game)
        try check(count>200 && count<1200,"Missing or excessive ordnance triangles")
        try check(SCNMatrix4EqualToMatrix4(transform,root.transform)&&original.isHidden,"Changed projectile flight basis or retained old mesh")
        try check(root.childNodes.filter{$0.geometry != nil && !$0.isHidden}.count==1,"Ordnance must use one visible batch")
        try check(RemasteredOrdnanceModels.apply(to:root,type:type,gameID:game)==0,"Duplicated ordnance")
        let node=root.childNode(withName:"RemasteredOrdnance",recursively:false)!,bounds=node.boundingBox
        if type.uppercased().hasPrefix("MISSILE") {
            try check(abs(bounds.min.z-(game=="2000" ? -2.4:-1.44))<0.0001 && bounds.max.z<=0.001,"Missile nose/nozzle moved from source extent")
        }
    }}
    try check(RemasteredOrdnanceModels.apply(to:SCNNode(),type:"MissileBoxes",gameID:"2002")==0,"Ordnance must not replace supply crate")
    print("PASS remastered ordnance: both generations, -Z nose/nozzle, one batch, preserved flight transforms, idempotent")
}
