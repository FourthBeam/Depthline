import AppKit
import SceneKit
import simd

/// One cloth canopy surface, real suspension cords and solid detailed crates.
/// No copied back-face layer or coplanar transparent decal can flicker here.
enum RemasteredSupplies {
    @discardableResult static func apply(to root:SCNNode,type:String,gameID:String)->Int {
        let name=type.uppercased(),chute=name.hasPrefix("PARACHUTE")
        let boxes=["HEALTHBOXES","AMMOBOXES","PROJECTILEBOXES","MISSILEBOXES"]
        guard chute || boxes.contains(name),root.childNode(withName:"RemasteredSupply",recursively:false)==nil else{return 0}
        var total=0
        func install(_ mesh:NativeDetailMesh,_ suffix:String,style:NativeDetailMesh.Surface) {
            let m=SCNMaterial();m.name="RemasteredSupplyMaterial";m.lightingModel = .physicallyBased;m.diffuse.contents=NSColor.white;m.isDoubleSided=true
            m.roughness.contents=0.85;m.metalness.contents=0.03;NativeDetailMesh.configureSurface(m,style:style)
            let node=SCNNode(geometry:mesh.geometry(material:m));node.name="RemasteredSupply"+suffix;root.addChildNode(node);total+=mesh.indices.count/3
        }
        root.childNodes.filter{$0.geometry != nil}.forEach{$0.isHidden=true}
        if chute {
            var mesh=NativeDetailMesh();let radius=SIMD3<Float>(1.4,1.2,1.33),segments=48,rings=12
            for j in 0..<rings {for i in 0..<segments {
                func point(_ row:Int,_ column:Int)->SIMD3<Float> {
                    let t=Float(row)*Float.pi/2/Float(rings),a=Float(column)*Float.pi*2/Float(segments)
                    let fold=1-0.025*cos(a*12)*pow(sin(t),2)
                    return SIMD3(sin(t)*cos(a)*fold,cos(t),sin(t)*sin(a)*fold)*radius
                }
                let a=point(j,i),b=point(j+1,i),c=point(j+1,i+1),d=point(j,i+1),start=mesh.positions.count
                let color:SIMD3<Float>=(i/4)%2==0 ? .init(0.66,0.65,0.47):.init(0.40,0.47,0.29)
                mesh.quad(a,d,c,b,color:color)
                for k in start..<mesh.positions.count {mesh.normals[k]=simd_normalize(mesh.positions[k]/(radius*radius))}
            }}
            let bottom:Float=gameID=="2000" ? -4.04:-2.0
            for i in 0..<12 {
                let a=Float(i)*Float.pi/6,top=SIMD3<Float>(cos(a)*1.4,0,sin(a)*1.33),end=SIMD3<Float>(cos(a)*0.34,bottom,sin(a)*0.34)
                mesh.cylinder(from:top,to:end,radius:0.008,sides:6,color:.init(0.64,0.61,0.43))
            }
            install(mesh,"",style:.fabric)
            if gameID=="2000" {
                // Coast paints each pooled box when its actual reward is released.
                let payload=crate(kind:"GENERAL",center:.init(0,-4.50,0),size:.init(0.90,0.90,0.90))
                install(payload,"Payload",style:.paint)
            }
        } else {
            let size:SIMD3<Float>=name=="MISSILEBOXES" ? .init(0.60,1.20,0.60):name=="AMMOBOXES" ? .init(1,0.80,1):.init(1,1,1)
            install(crate(kind:name,center:.zero,size:size),"",style:.paint)
            let mark: DepthlineSupplyMark = ["HEALTHBOXES":.health,"AMMOBOXES":.cartridges,"PROJECTILEBOXES":.shell,"MISSILEBOXES":.missile][name]!
            mark.paint(root,center:.zero,size:size)
        }
        return total
    }
    private static func crate(kind:String,center:SIMD3<Float>,size:SIMD3<Float>)->NativeDetailMesh {
        var mesh=NativeDetailMesh()
        let medical=kind=="HEALTHBOXES",ammo=kind=="AMMOBOXES",missile=kind=="MISSILEBOXES"
        let body:SIMD3<Float>=medical ? .init(0.70,0.71,0.61):ammo ? .init(0.27,0.34,0.18):missile ? .init(0.31,0.36,0.35):.init(0.46,0.40,0.23)
        let trim=SIMD3<Float>(0.20,0.24,0.18)
        mesh.beveledBox(center:center,size:size,bevel:0.035,color:body)
        mesh.beveledBox(center:center + .init(0,size.y*0.48,0),size:.init(size.x+0.018,0.075,size.z+0.018),bevel:0.012,color:body*0.88)
        for side:Float in [-1,1] {
            let x=side*size.x*0.30
            mesh.box(center:center + .init(x,0,-size.z*0.505),size:.init(0.055,size.y,0.025),color:trim)
            mesh.box(center:center + .init(x,0,size.z*0.505),size:.init(0.055,size.y,0.025),color:trim)
            mesh.box(center:center + .init(x,size.y*0.525,0),size:.init(0.055,0.025,size.z),color:trim)
            let xx=side*(size.x*0.50+0.018)
            mesh.cylinder(from:center + .init(xx,0.11,-0.13),to:center + .init(xx,0.11,0.13),radius:0.021,sides:10,color:trim)
            for z:Float in [-0.13,0.13] {mesh.cylinder(from:center + .init(xx,0.11,z),to:center + .init(xx,0.02,z),radius:0.017,sides:8,color:trim)}
            mesh.beveledBox(center:center + .init(side*size.x*0.26,size.y*0.36,-size.z*0.52),size:.init(0.075,0.11,0.025),bevel:0.008,color:trim)
        }
        return mesh
    }
}

func testRemasteredSupplies() throws {
    func check(_ good:Bool,_ message:String) throws{if !good{throw NSError(domain:"RemasteredSupplies",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
    for game in ["2000","2002"] {
        let root=SCNNode();root.position=SCNVector3(0,25,-15);root.eulerAngles.x=0.2
        let child=SCNNode();child.name="GameplayPayload";child.position.y = -2.5;root.addChildNode(child)
        let source=SCNNode(geometry:SCNBox(width:1,height:1,length:1,chamferRadius:0));root.addChildNode(source)
        let transform=root.transform
        let triangles=RemasteredSupplies.apply(to:root,type:game=="2000" ? "Parachute1":"Parachute",gameID:game)
        try check(triangles>1000 && triangles<3000 && source.isHidden,"Canopy not replaced with bounded single cloth surface")
        try check(child.parent === root && child.position.y == -2.5 && SCNMatrix4EqualToMatrix4(root.transform,transform),"Canopy replacement changed gameplay payload relationship")
        try check(RemasteredSupplies.apply(to:root,type:"Parachute",gameID:game)==0,"Duplicate canopy layers")
        let canopy=root.childNode(withName:"RemasteredSupply",recursively:false)!.geometry!,vertices=canopy.sources(for:.vertex)[0]
        var points:[String]=[]
        vertices.data.withUnsafeBytes { raw in
            for i in 0..<vertices.vectorCount {
                let p=raw.baseAddress!.advanced(by:vertices.dataOffset+i*vertices.dataStride).assumingMemoryBound(to:Float.self)
                points.append((0..<3).map{String(Int((p[$0]*1_000_000).rounded()))}.joined(separator:","))
            }
        }
        var surfaces=Set<String>(),duplicate=false
        // The source canopy contained identical triangles across material
        // groups. Catch that actual depth-fighting cause in the replacement.
        for i in stride(from:0,to:points.count,by:3) {
            if !surfaces.insert(points[i..<i+3].sorted().joined(separator:"/")).inserted {duplicate=true}
        }
        try check(!duplicate,"Canopy has coplanar duplicate triangles")
    }
    for kind in ["HealthBoxes","AmmoBoxes","ProjectileBoxes","MissileBoxes"] {
        let root=SCNNode();let count=RemasteredSupplies.apply(to:root,type:kind,gameID:"2002")
        try check(count>100 && root.childNode(withName:"cargo-stencil",recursively:false)?.childNodes.count==4,"Each crate needs a visible stencil on every side")
    }
    print("PASS remastered supplies: one canopy layer, source payload linkage, independent crate silhouettes, idempotence")
}
