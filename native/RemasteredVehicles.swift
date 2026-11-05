import AppKit
import SceneKit
import simd

/// New visible ground units, fitted to the recovered model dimensions and hung
/// on its animated turret/barrel/ramp nodes. Hit testing uses separate source
/// volumes and is untouched. Each rigid part is one vertex-coloured draw.
enum RemasteredVehicles {
    static let olive=SIMD3<Float>(0.35,0.40,0.25),highlight=SIMD3<Float>(0.43,0.47,0.31)
    static let rubber=SIMD3<Float>(0.10,0.115,0.10),steel=SIMD3<Float>(0.24,0.27,0.26)
    static let glass=SIMD3<Float>(0.12,0.25,0.28),canvas=SIMD3<Float>(0.55,0.51,0.33)
    @discardableResult static func apply(to root:SCNNode,type:String,gameID:String)->Int {
        guard root.childNode(withName:"RemasteredVehicleHull",recursively:false)==nil else{return 0}
        let kind=type.uppercased(),old=gameID=="2000"
        guard kind=="TANK" || kind.hasPrefix("APC") || kind.hasPrefix("BARGE") else{return 0}
        var count=0
        func install(_ mesh:NativeDetailMesh,on node:SCNNode,_ name:String) {
            node.childNodes.filter{$0.geometry != nil}.forEach{$0.isHidden=true}
            let m=SCNMaterial();m.name="RemasteredVehiclePaint";m.lightingModel = .physicallyBased
            m.diffuse.contents=NSColor.white;m.metalness.contents=0.18;m.roughness.contents=0.68;m.isDoubleSided=true
            m.emission.contents=NSColor(calibratedWhite:0.012,alpha:1)
            NativeDetailMesh.configureSurface(m,style:.paint)
            let child=SCNNode(geometry:mesh.geometry(material:m));child.name=name;node.addChildNode(child)
            count+=mesh.indices.count/3
        }
        if kind=="TANK" {
            var hull=NativeDetailMesh();runningGear(&hull,width:2.34,length:4.25,centerZ:0.30,wheelCount:6)
            hull.beveledBox(center:.init(0,0.76,0.30),size:.init(2.12,0.69,4.25),bevel:0.19,color:olive)
            hull.beveledBox(center:.init(0,1.10,0.27),size:.init(2.18,0.13,3.80),bevel:0.05,color:highlight)
            for side:Float in [-1,1] {
                hull.beveledBox(center:.init(side*0.95,0.98,1.77),size:.init(0.40,0.32,0.70),bevel:0.035,color:olive)
                hull.cylinder(from:.init(side*0.88,1.13,-1.64),to:.init(side*0.88,1.13,-1.73),radius:0.075,sides:12,color:canvas)
                hull.cylinder(from:.init(side*0.88,1.13,-1.73),to:.init(side*0.88,1.13,-1.75),radius:0.058,sides:12,color:.init(0.72,0.75,0.55))
                hull.box(center:.init(side*0.55,1.18,1.40),size:.init(0.82,0.025,0.80),color:rubber)
                for z:Float in [1.06,1.19,1.32,1.45,1.58,1.71] {hull.box(center:.init(side*0.55,1.20,z),size:.init(0.82,0.035,0.045),color:highlight)}
            }
            hull.cylinder(from:.init(-0.38,1.14,-1.20),to:.init(-0.38,1.22,-1.20),radius:0.25,sides:18,color:olive)
            hull.box(center:.init(-0.38,1.25,-1.38),size:.init(0.20,0.06,0.045),color:glass)
            install(hull,on:root,"RemasteredVehicleHull")
            let turret=root.childNodes.first{($0.name=="Turret" || (old && $0.name=="Tank1")) && $0.geometry==nil}
            if let turret {
                let y:Float=old ? 0.12:1.30
                var mesh=NativeDetailMesh()
                mesh.ellipsoid(center:.init(0,y,old ? 0.25:0.12),radii:.init(0.85,0.40,old ? 1.10:1.35),segments:24,rings:12,color:olive)
                mesh.beveledBox(center:.init(0,y+0.01,1.01),size:.init(1.30,0.43,0.60),bevel:0.09,color:olive)
                mesh.cylinder(from:.init(0,y-0.30,0.15),to:.init(0,y-0.25,0.15),radius:0.74,sides:24,color:steel)
                for x:Float in [-0.36,0.36] {
                    mesh.cylinder(from:.init(x,y+0.29,0.25),to:.init(x,y+0.39,0.25),radius:0.24,sides:18,color:highlight)
                    mesh.box(center:.init(x,y+0.42,0.09),size:.init(0.18,0.06,0.06),color:glass)
                    mesh.cylinder(from:.init(x,y+0.25,1.13),to:.init(x,y+1.48,1.30),radius:0.008,sides:5,color:rubber)
                    mesh.beveledBox(center:.init(x,y+0.02,1.40),size:.init(0.52,0.25,0.25),bevel:0.04,color:canvas)
                }
                mesh.box(center:.init(0.36,y+0.50,0.20),size:.init(0.10,0.12,0.38),color:steel)
                mesh.cylinder(from:.init(0.36,y+0.52,0.03),to:.init(0.36,y+0.52,-0.49),radius:0.017,sides:10,color:steel)
                install(mesh,on:turret,"RemasteredVehicleUpper")
                if let gun=turret.childNodes.first(where:{($0.name=="TMount" || (old && $0.name=="Tank1")) && $0.geometry==nil}) {
                    var mantlet=NativeDetailMesh();mantlet.beveledBox(center:.init(0,0,-0.08),size:.init(0.68,0.45,0.40),bevel:0.075,color:olive)
                    let barrelNode=old ? gun.childNodes.first(where:{$0.name=="Tank1" && $0.geometry==nil}) ?? gun:gun
                    if barrelNode !== gun {install(mantlet,on:gun,"RemasteredVehicleCollar");mantlet=NativeDetailMesh()}
                    let end:Float=old ? -2.39:-2.17
                    mantlet.cylinder(from:.init(0,0,-0.20),to:.init(0,0,end),radius:0.084,endRadius:0.051,sides:20,color:highlight)
                    mantlet.cylinder(from:.init(0,0,-0.85),to:.init(0,0,-1.15),radius:0.11,sides:20,color:olive)
                    mantlet.cylinder(from:.init(0,0,end+0.10),to:.init(0,0,end),radius:0.075,sides:20,color:steel,caps:false)
                    mantlet.cylinder(from:.init(0,0,end+0.002),to:.init(0,0,end+0.001),radius:0.047,sides:20,color:rubber)
                    install(mantlet,on:barrelNode,"RemasteredVehicleTube")
                }
            }
        } else if kind.hasPrefix("APC") {
            let length:Float=old ? 3.20:4.40,width:Float=old ? 1.76:1.96,height:Float=old ? 1.35:1.63,z:Float=old ? 0:-0.45
            var hull=NativeDetailMesh();runningGear(&hull,width:width,length:length,centerZ:z,wheelCount:old ? 5:6)
            let footprint: DepthlineAPCHull = old ? .coast : .hills
            let rear=Float(footprint.rear)*0.01,front=Float(footprint.front)*0.01
            let cabinDepth:Float=1.10,bulkhead=rear-cabinDepth,doorWidth:Float=1.04
            let wallWidth=(width*0.95-doorWidth)*0.5
            hull.beveledBox(center:.init(0,height*0.62,(front+bulkhead)*0.5),size:.init(width*0.95,height*0.75,bulkhead-front),bevel:0.12,color:olive)
            for side:Float in [-1,1] {
                hull.beveledBox(center:.init(side*(doorWidth+wallWidth)*0.5,height*0.62,rear-cabinDepth*0.5),size:.init(wallWidth,height*0.75,cabinDepth),bevel:0.045,color:olive)
            }
            hull.box(center:.init(0,0.28,rear-cabinDepth*0.5),size:.init(doorWidth,0.08,cabinDepth),color:steel)
            hull.box(center:.init(0,height-0.06,rear-cabinDepth*0.5),size:.init(doorWidth,0.12,cabinDepth),color:olive)
            hull.box(center:.init(0,height*0.60,bulkhead),size:.init(doorWidth,height*0.66,0.05),color:rubber)
            hull.beveledBox(center:.init(0,height+0.015,z),size:.init(width*0.84,0.07,length*0.76),bevel:0.03,color:highlight)
            for side:Float in [-1,1] {
                hull.cylinder(from:.init(side*width*0.25,height+0.05,z-0.60),to:.init(side*width*0.25,height+0.11,z-0.60),radius:0.23,sides:16,color:olive)
                hull.box(center:.init(side*width*0.25,height+0.12,z-0.80),size:.init(0.22,0.08,0.06),color:glass)
                for zz in [-0.45,0.25,0.95] as [Float] {
                    hull.beveledBox(center:.init(side*width*0.49,height*0.65,z+zz),size:.init(0.055,0.26,0.38),bevel:0.015,color:highlight)
                    hull.cylinder(from:.init(side*width*0.49,height*0.75,z+zz),to:.init(side*width*0.53,height*0.75,z+zz),radius:0.034,sides:10,color:steel)
                }
                hull.cylinder(from:.init(side*width*0.38,height*0.65,z-length*0.48),to:.init(side*width*0.38,height*0.65,z-length*0.49),radius:0.065,sides:12,color:.init(0.74,0.76,0.61))
            }
            hull.box(center:.init(0,height+0.055,z+0.48),size:.init(width*0.50,0.025,0.70),color:rubber)
            for i in 0..<6 {hull.box(center:.init(0,height+0.075,z+0.20+Float(i)*0.11),size:.init(width*0.50,0.03,0.025),color:olive)}
            install(hull,on:root,"RemasteredVehicleHull")
            if let ramp=root.childNodes.first(where:{($0.name ?? "").lowercased().contains("ramp")}) {
                let doorHeight=height-0.36
                var mesh=NativeDetailMesh();mesh.beveledBox(center:.init(0,doorHeight*0.5,0),size:.init(doorWidth+0.035,doorHeight,0.08),bevel:0.025,color:olive)
                for x:Float in [-0.34,0.34] {mesh.box(center:.init(x,doorHeight*0.5,0.05),size:.init(0.035,doorHeight*0.90,0.025),color:highlight)}
                mesh.box(center:.init(0.31,doorHeight*0.65,0.065),size:.init(0.15,0.025,0.04),color:steel)
                install(mesh,on:ramp,"RemasteredVehicleGate")
            }
            if let turret=root.childNodes.first(where:{($0.name ?? "").contains("Turret")}) {
                var mesh=NativeDetailMesh();mesh.beveledBox(center:.init(0,1.82,0),size:.init(1.05,0.48,1.00),bevel:0.15,color:olive)
                mesh.cylinder(from:.init(0,1.56,0),to:.init(0,1.65,0),radius:0.52,sides:20,color:steel)
                install(mesh,on:turret,"RemasteredVehicleUpper")
                if let gun=turret.childNode(withName:"APCGun",recursively:false) {
                    var mesh=NativeDetailMesh();mesh.beveledBox(center:.init(0,0,-0.20),size:.init(0.34,0.30,0.40),bevel:0.04,color:olive)
                    mesh.cylinder(from:.init(0,0,-0.26),to:.init(0,0,-1.13),radius:0.048,endRadius:0.025,sides:16,color:steel)
                    install(mesh,on:gun,"RemasteredVehicleTube")
                }
                if let launcher=turret.childNode(withName:"Launcher",recursively:false) {
                    var mesh=NativeDetailMesh()
                    for x:Float in [-0.25,0.25] {for y:Float in [0,0.18] {
                        mesh.cylinder(from:.init(x,y,0.58),to:.init(x,y,-0.61),radius:0.085,sides:14,color:highlight)
                        mesh.cylinder(from:.init(x,y,-0.612),to:.init(x,y,-0.614),radius:0.06,sides:14,color:rubber)
                    }}
                    install(mesh,on:launcher,"RemasteredVehiclePods")
                }
                if let radar=turret.childNode(withName:"Radar",recursively:false) {
                    var mesh=NativeDetailMesh();mesh.box(center:.init(0,2.23,-0.1),size:.init(0.05,0.30,0.05),color:steel)
                    mesh.ellipsoid(center:.init(0,2.45,-0.1),radii:.init(0.37,0.20,0.06),segments:20,rings:10,color:canvas)
                    install(mesh,on:radar,"RemasteredVehicleAntenna")
                }
            }
        } else {
            let scale:Float=kind=="BARGE_VEHICLE" ? 1.4:1,width:Float=3.54*scale,length:Float=9.4*scale
            var hull=NativeDetailMesh()
            hull.beveledBox(center:.init(0,0.24*scale,-0.14*scale),size:.init(width,0.47*scale,length),bevel:0.14*scale,color:steel)
            hull.box(center:.init(0,0.49*scale,-0.25*scale),size:.init(width*0.86,0.05,length*0.91),color:olive)
            for side:Float in [-1,1] {
                hull.beveledBox(center:.init(side*width*0.465,0.97*scale,-0.1*scale),size:.init(0.25*scale,1.08*scale,length*0.97),bevel:0.06,color:olive)
                for i in 0..<8 {hull.box(center:.init(side*width*0.43,0.92*scale,(-3.7+Float(i)*1.05)*scale),size:.init(0.10*scale,0.90*scale,0.09*scale),color:highlight)}
                for z:Float in [-3.9,3.9] {
                    hull.cylinder(from:.init(side*width*0.46,1.5*scale,z*scale),to:.init(side*width*0.46,1.65*scale,z*scale),radius:0.055*scale,sides:10,color:steel)
                    hull.cylinder(from:.init(side*width*0.46-0.12*scale,1.65*scale,z*scale),to:.init(side*width*0.46+0.12*scale,1.65*scale,z*scale),radius:0.034*scale,sides:10,color:steel)
                }
            }
            hull.beveledBox(center:.init(0,1.05*scale,3.62*scale),size:.init(width*0.85,1.10*scale,1.0*scale),bevel:0.07,color:olive)
            hull.box(center:.init(0,1.42*scale,3.10*scale),size:.init(width*0.52,0.28*scale,0.02),color:glass)
            // A raised, offset wheelhouse and its swept canopy give the stern
            // an identifiable silhouette even when the bow ramp faces the gun.
            let helm=SIMD3<Float>(-0.78,1.83,3.48)*scale
            hull.beveledBox(center:helm,size:SIMD3<Float>(1.27,0.75,1.29)*scale,bevel:0.08*scale,color:highlight)
            for side: Float in [-1,1] {
                hull.box(center:helm+SIMD3(side*0.29,0.11,-0.65)*scale,size:SIMD3<Float>(0.44,0.27,0.035)*scale,color:glass)
            }
            hull.beveledBox(center:helm+SIMD3(0,0.43,0)*scale,size:SIMD3<Float>(1.52,0.11,1.58)*scale,bevel:0.025*scale,color:steel)
            for side:Float in [-1,1] {
                // Flat rubbing strake above a darker submerged chine.
                hull.beveledBox(center:.init(side*width*0.493,0.46*scale,-0.18*scale),size:.init(0.09*scale,0.16*scale,length*0.93),bevel:0.023*scale,color:rubber)
                hull.plate([.init(side*width*0.45,0.13*scale,-3.3*scale),.init(side*width*0.40,0.13*scale,-4.58*scale),.init(side*width*0.47,1.48*scale,-4.54*scale),.init(side*width*0.48,1.52*scale,-3.85*scale)],thickness:.init(0.055*scale,0,0),color:steel)
            }
            hull.cylinder(from:.init(width*0.31,1.59*scale,3.7*scale),to:.init(width*0.31,3.2*scale,3.7*scale),radius:0.024*scale,sides:8,color:steel)
            install(hull,on:root,"RemasteredVehicleHull")
            if let ramp=root.childNodes.first(where:{($0.name ?? "").contains("Ramp")}) {
                var mesh=NativeDetailMesh();mesh.beveledBox(center:.init(0,0.90*scale,-0.15*scale),size:.init(2.52*scale,1.80*scale,0.13*scale),bevel:0.03,color:olive)
                for i in 0..<9 {mesh.box(center:.init(0,Float(i)*0.20*scale,-0.23*scale),size:.init(2.40*scale,0.035,0.04),color:highlight)}
                install(mesh,on:ramp,"RemasteredVehicleGate")
            }
        }
        return count
    }

    private static func runningGear(_ mesh:inout NativeDetailMesh,width:Float,length:Float,centerZ:Float,wheelCount:Int) {
        let x=width*0.43,r:Float=0.28,z0=centerZ-length*0.38,z1=centerZ+length*0.38
        for side:Float in [-1,1] {
            // A hollow capsule track, not a solid dark box covering the wheels.
            let xa=side*x-width*0.09,xb=side*x+width*0.09,straight=length*0.47-0.34
            for i in 0..<32 {
                func ring(_ n:Int,_ radius:Float,_ xx:Float)->SIMD3<Float> {
                    let a=Float(n)*2*Float.pi/32,c=cos(a)
                    return .init(xx,0.36+sin(a)*radius,centerZ+(c>=0 ? straight:-straight)+c*radius)
                }
                let a=ring(i,0.34,xa),b=ring(i+1,0.34,xa),c=ring(i+1,0.34,xb),d=ring(i,0.34,xb)
                let e=ring(i,0.28,xa),f=ring(i+1,0.28,xa),g=ring(i+1,0.28,xb),h=ring(i,0.28,xb)
                mesh.quad(a,b,c,d,color:steel);mesh.quad(h,g,f,e,color:rubber)
                mesh.quad(a,e,f,b,color:rubber);mesh.quad(d,c,g,h,color:rubber)
            }
            for i in 0..<wheelCount {
                let z=z0+(z1-z0)*Float(i)/Float(wheelCount-1),outer=side*(width*0.53)
                mesh.cylinder(from:.init(side*x,0.36,z),to:.init(outer,0.36,z),radius:r,sides:16,color:rubber)
                mesh.cylinder(from:.init(outer,0.36,z),to:.init(outer+side*0.015,0.36,z),radius:r*0.78,sides:16,color:olive)
                mesh.cylinder(from:.init(outer+side*0.016,0.36,z),to:.init(outer+side*0.05,0.36,z),radius:0.065,sides:12,color:steel)
            }
            for i in 0..<24 {
                let z=centerZ-length*0.44+Float(i)/23*length*0.88
                for y:Float in [0.04,0.69] {mesh.box(center:.init(side*x,y,z),size:.init(width*0.20,0.055,0.065),color:steel)}
            }
        }
    }

    @discardableResult static func applyWreck(to root:SCNNode)->Bool {
        var found=false
        root.enumerateChildNodes {node,_ in
            guard (node.name ?? "").hasPrefix("RemasteredVehicle"),let geometry=node.geometry else{return}
            found=true
            if geometry.materials.first?.name=="RemasteredVehicleWreck" {return}
            let copy=geometry.copy() as! SCNGeometry
            copy.materials=geometry.materials.map{source in
                let m=source.copy() as! SCNMaterial;m.name="RemasteredVehicleWreck"
                m.multiply.contents=NSColor(srgbRed:0.24,green:0.21,blue:0.18,alpha:1);m.roughness.contents=0.95;m.metalness.contents=0.04
                m.setValue(Float(1),forKey:"bhDetailWreck")
                return m
            };node.geometry=copy
        }
        return found
    }
}

func testRemasteredVehicles(objects:[[String:Any]],gameID:String) throws {
    func check(_ good:Bool,_ message:String) throws {if !good{throw NSError(domain:"RemasteredVehicles",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
    func tree(_ id:Int,root:Bool=false)->SCNNode {
        let object=objects.first{$0["id"] as? Int==id}!,node=SCNNode();node.name=object["name"] as? String
        let p=(object["translation"] as! [NSNumber]).map{$0.doubleValue/100};if !root{node.position=SCNVector3(p[0],p[1],p[2])}
        node.addChildNode(SCNNode(geometry:SCNBox(width:0.1,height:0.1,length:0.1,chamferRadius:0)))
        for child in objects where child["link"] as? Int==id {node.addChildNode(tree(child["id"] as! Int))}
        return node
    }
    let old=gameID=="2000"
    let variants:[(String,Int,Int)]=old ? [("TANK",37,4),("APC1",61,2),("BARGE",11,2),("BARGE_VEHICLE",17,2)]:[("TANK",37,3),("APC1",73,2),("APC2",77,4),("APC3",81,5)]
    for (type,id,draws) in variants {
        let root=tree(id,root:true);root.position=SCNVector3(3,0,-8);root.eulerAngles.y=0.3
        var source:[(SCNNode,SCNMatrix4)]=[(root,root.transform)]
        root.enumerateChildNodes{node,_ in if node.geometry==nil {source.append((node,node.transform))}}
        let triangles=RemasteredVehicles.apply(to:root,type:type,gameID:gameID)
        try check(triangles>0 && triangles<8000 && RemasteredVehicles.apply(to:root,type:type,gameID:gameID)==0,"Geometry duplicated or exceeded per-unit budget")
        var visible:[SCNNode]=[];root.enumerateChildNodes{node,_ in if node.geometry != nil && !node.isHidden {visible.append(node)}}
        try check(visible.count==draws,"Missing articulated visual groups for \(type)")
        for (node,transform) in source {try check(SCNMatrix4EqualToMatrix4(node.transform,transform),"Replacement moved source animated pivot")}
        for node in visible {try check(!(node.name ?? "").lowercased().contains("turret") && !(node.name ?? "").lowercased().contains("barrel") && !(node.name ?? "").lowercased().contains("ramp"),"Visual group would receive source animation twice")}
        let copy=root.clone(),originalMaterial=visible[0].geometry!.materials[0]
        try check(RemasteredVehicles.applyWreck(to:copy),"New wreck appearance absent")
        try check(originalMaterial.name=="RemasteredVehiclePaint","Burning cloned unit mutated shared live materials")
        if type=="TANK" {
            let turret=source.first{($0.0.name=="Turret" || (old && $0.0.name=="Tank1" && $0.0.parent === root))}!.0
            let visual=turret.childNode(withName:"RemasteredVehicleUpper",recursively:false)!
            turret.eulerAngles.y=0.8
            let forward=visual.convertVector(SCNVector3(0,0,-1),to:root)
            try check(abs(forward.x + sin(0.8))<0.0001,"Detailed turret failed to follow original yaw once")
        }
    }
    print("PASS remastered vehicles \(gameID): articulated parts, source pivots, one draw/part, bounded mesh size, isolated wreck materials")
}
