import AppKit
import SceneKit

/// Readable new airframes fitted to the two source generations. Original root,
/// rotor, tail-prop and cargo-ramp nodes remain the animation/gameplay anchors.
enum RemasteredAircraft {
    static let paint=SIMD3<Float>(0.43,0.49,0.45),olive=SIMD3<Float>(0.31,0.38,0.23),light=SIMD3<Float>(0.62,0.66,0.63)
    static let dark=SIMD3<Float>(0.12,0.15,0.16),glass=SIMD3<Float>(0.14,0.29,0.36),steel=SIMD3<Float>(0.27,0.30,0.30)
    @discardableResult static func apply(to root:SCNNode,type:String,gameID:String)->Int {
        let type=type.uppercased(),old=gameID=="2000"
        guard ["JET","BOMBER","C130","COBRA","CH53"].contains(type),root.childNode(withName:"RemasteredAirframe",recursively:false)==nil else{return 0}
        var total=0
        func install(_ mesh:NativeDetailMesh,on node:SCNNode,name:String) {
            node.childNodes.filter{$0.geometry != nil}.forEach{$0.isHidden=true}
            let m=SCNMaterial();m.name="RemasteredAirPaint";m.lightingModel = .physicallyBased;m.diffuse.contents=NSColor.white
            m.metalness.contents=0.22;m.roughness.contents=0.57;m.isDoubleSided=true;m.emission.contents=NSColor(calibratedWhite:0.012,alpha:1)
            NativeDetailMesh.configureSurface(m,style:.paint)
            let model=SCNNode(geometry:mesh.geometry(material:m));model.name=name;node.addChildNode(model);total+=mesh.indices.count/3
        }
        var hull=NativeDetailMesh()
        if type=="COBRA" || type=="CH53" {
            let cargo=type=="CH53"
            if cargo {
                hull.ellipsoid(center:.init(0,-1.65,-0.2),radii:.init(1.24,1.32,3.55),segments:24,rings:16,color:olive)
                hull.ellipsoid(center:.init(0,-1.31,-2.80),radii:.init(1.10,0.78,1.32),segments:24,rings:12,color:glass)
                for side:Float in [-1,1] {
                    hull.ellipsoid(center:.init(side*1.15,-0.73,0.8),radii:.init(0.45,0.46,1.7),segments:16,rings:12,color:olive)
                    hull.cylinder(from:.init(side*1.15,-0.73,-0.65),to:.init(side*1.15,-0.73,-0.69),radius:0.30,sides:16,color:dark)
                    hull.cylinder(from:.init(side*1.15,-0.73,2.10),to:.init(side*1.15,-0.73,2.45),radius:0.25,sides:16,color:steel,caps:false)
                    for z:Float in [-1.45,-0.45,0.55,1.55] {
                        hull.beveledBox(center:.init(side*1.19,-1.44,z),size:.init(0.05,0.40,0.49),bevel:0.03,color:glass)
                    }
                    hull.beveledBox(center:.init(side*1.36,-2.50,1.20),size:.init(0.55,0.45,1.65),bevel:0.13,color:olive)
                    hull.cylinder(from:.init(side*1.24,-2.75,1.45),to:.init(side*1.24,-3.06,1.45),radius:0.065,sides:10,color:steel)
                    hull.cylinder(from:.init(side*1.11,-3.08,1.45),to:.init(side*1.42,-3.08,1.45),radius:0.27,sides:16,color:dark)
                    hull.cylinder(from:.init(side*1.43,-3.08,1.45),to:.init(side*1.45,-3.08,1.45),radius:0.12,sides:14,color:steel)
                }
                hull.cylinder(from:.init(0,-2.65,-2.65),to:.init(0,-3.1,-2.65),radius:0.055,sides:10,color:steel)
                hull.cylinder(from:.init(-0.16,-3.10,-2.65),to:.init(0.16,-3.10,-2.65),radius:0.25,sides:16,color:dark)
                hull.cylinder(from:.init(0,-1.25,2.20),to:.init(0,0.15,9.02),radius:0.57,endRadius:0.14,sides:20,color:olive)
                hull.plate([.init(0,-0.1,7.4),.init(0,1.05,8.9),.init(0,0.8,9.4),.init(0,-0.25,9.0)],thickness:.init(0.12,0,0),color:olive)
                hull.plate([.init(-1.65,-0.2,7.3),.init(1.65,-0.2,7.3),.init(1.45,-0.2,8.0),.init(-1.45,-0.2,8.0)],thickness:.init(0,0.07,0),color:olive)
                // Frame strips join glass to the painted nose instead of a
                // single undifferentiated dark blob.
                for side:Float in [-1,1] {hull.cylinder(from:.init(side*0.88,-1.45,-3.65),to:.init(side*0.55,-0.61,-2.55),radius:0.04,sides:8,color:olive)}
                hull.cylinder(from:.init(0,-1.40,-4.0),to:.init(0,-0.57,-2.75),radius:0.04,sides:8,color:olive)
                if let ramp=root.childNode(withName:"Ramp",recursively:false) {
                    var mesh=NativeDetailMesh();mesh.beveledBox(center:.init(0,0.1,0.70),size:.init(1.70,0.16,1.55),bevel:0.025,color:olive)
                    for i in 0..<8 {mesh.box(center:.init(0,0.20,Float(i)*0.19),size:.init(1.60,0.025,0.045),color:steel)}
                    install(mesh,on:ramp,name:"RemasteredAirGate")
                }
            } else {
                hull.ellipsoid(center:.init(0,-1.2,-0.35),radii:.init(0.50,0.71,2.70),segments:20,rings:14,color:olive)
                hull.ellipsoid(center:.init(0,-0.69,-1.38),radii:.init(0.43,0.58,1.57),segments:20,rings:14,color:glass)
                for z:Float in [-2.35,-1.55,-0.70] {
                    let f=sqrt(max(0,1-pow((z+1.38)/1.57,2)))*1.01
                    for i in 0..<12 {
                        func framePoint(_ n:Int)->SIMD3<Float>{let a=Float(n)*Float.pi/12;return .init(cos(a)*0.43*f,-0.69+sin(a)*0.58*f,z)}
                        hull.cylinder(from:framePoint(i),to:framePoint(i+1),radius:0.018,sides:6,color:olive)
                    }
                }
                hull.cylinder(from:.init(0,-0.84,1.15),to:.init(0,-0.52,5.40),radius:0.27,endRadius:0.10,sides:16,color:olive)
                hull.plate([.init(0,-0.55,4.2),.init(0,0.25,5.40),.init(0,0.10,5.89),.init(0,-0.80,5.40)],thickness:.init(0.08,0,0),color:olive)
                hull.plate([.init(-0.92,-0.66,4.0),.init(0.92,-0.66,4.0),.init(0.72,-0.66,4.65),.init(-0.72,-0.66,4.65)],thickness:.init(0,0.05,0),color:olive)
                for side:Float in [-1,1] {
                    hull.plate([.init(side*0.35,-1.16,-0.3),.init(side*1.19,-1.25,0),.init(side*1.19,-1.25,0.65),.init(side*0.35,-1.16,0.72)],thickness:.init(0,0.06,0),color:olive)
                    hull.cylinder(from:.init(side*0.94,-1.48,-0.55),to:.init(side*0.94,-1.48,0.83),radius:0.18,sides:14,color:olive)
                    hull.cylinder(from:.init(side*0.94,-1.48,-0.553),to:.init(side*0.94,-1.48,-0.558),radius:0.15,sides:14,color:dark)
                    for a in 0..<6 {let angle=Float(a)*Float.pi/3;hull.cylinder(from:.init(side*0.94+cos(angle)*0.09,-1.48+sin(angle)*0.09,-0.56),to:.init(side*0.94+cos(angle)*0.09,-1.48+sin(angle)*0.09,-0.565),radius:0.022,sides:6,color:steel)}
                    for z:Float in [-1.50,0.85] {hull.cylinder(from:.init(side*0.38,-1.5,z),to:.init(side*0.72,-2.23,z),radius:0.045,sides:10,color:steel)}
                    hull.cylinder(from:.init(side*0.72,-2.23,-1.85),to:.init(side*0.72,-2.23,1.35),radius:0.055,sides:12,color:steel)
                    hull.cylinder(from:.init(side*0.72,-2.23,-1.85),to:.init(side*0.72,-2.10,-2.17),radius:0.055,sides:12,color:steel)
                    hull.ellipsoid(center:.init(side*0.33,-0.59,0.8),radii:.init(0.22,0.24,0.75),segments:12,rings:10,color:olive)
                }
                hull.ellipsoid(center:.init(0,-1.85,-2.25),radii:.init(0.23,0.20,0.30),segments:14,rings:10,color:steel)
                hull.cylinder(from:.init(0,-1.85,-2.3),to:.init(0,-1.85,-3.05),radius:0.048,sides:12,color:dark)
            }
            hull.cylinder(from:.init(0,cargo ? -0.45:-0.30,0),to:.init(0,0.11,0),radius:cargo ? 0.16:0.095,sides:16,color:steel)
            for child in root.childNodes where child.geometry==nil {
                let name=child.name ?? ""
                if name.contains("Rotor") {
                    var mesh=NativeDetailMesh();let radius:Float=cargo ? 6.94:4.48,blades=cargo ? 6:2
                    mesh.cylinder(from:.init(0,-0.02,0),to:.init(0,0.15,0),radius:cargo ? 0.28:0.17,sides:16,color:steel)
                    for i in 0..<blades {
                        let a=Float(i)*2*Float.pi/Float(blades),d=SIMD3<Float>(cos(a),0,sin(a)),t=SIMD3<Float>(-sin(a),0,cos(a))
                        let cut=radius*0.90
                        mesh.plate([d*0.25-t*0.10,d*cut-t*0.19,d*cut+t*0.13,d*0.25+t*0.10],thickness:.init(0,0.055,0),color:dark)
                        mesh.plate([d*cut-t*0.19,d*radius-t*0.22,d*radius+t*0.05,d*cut+t*0.13],thickness:.init(0,0.055,0),color:.init(0.54,0.52,0.37))
                    }
                    install(mesh,on:child,name:"RemasteredAirBlades")
                } else if name.contains("Prop") {
                    var mesh=NativeDetailMesh();let radius:Float=cargo ? 1.44:0.90,x:Float=cargo ? 0:0.2
                    for i in 0..<4 {
                        let a=Float(i)*Float.pi/2,d=SIMD3<Float>(0,cos(a),sin(a)),t=SIMD3<Float>(0,-sin(a),cos(a)),p=SIMD3<Float>(x,0,0)
                        mesh.plate([p+d*0.10-t*0.07,p+d*radius-t*0.10,p+d*radius+t*0.10,p+d*0.10+t*0.07],thickness:.init(0.035,0,0),color:dark)
                    };install(mesh,on:child,name:"RemasteredAirTailBlades")
                }
            }
        } else {
            let jet=type=="JET",cargo=type=="C130"
            let front:Float=cargo ? -8.36:jet ? (old ? -6.39:-6.70):(old ? -14.87:-11.04)
            let rear:Float=cargo ? 11.01:jet ? (old ? 5.69:4.27):(old ? 16.33:8.94)
            let span:Float=cargo ? 12.67:jet ? (old ? 3.82:2.58):(old ? 18.44:5.66)
            let radius:Float=cargo ? 1.13:jet ? 0.45:0.87,length=rear-front
            hull.ellipsoid(center:.init(0,0,(front+rear)*0.5),radii:.init(radius,radius,length*0.5),segments:24,rings:26,color:cargo ? olive:paint)
            hull.ellipsoid(center:.init(0,radius*0.65,front+length*0.24),radii:.init(radius*0.85,radius*0.68,length*(jet ? 0.12:0.075)),segments:20,rings:12,color:glass)
            let rootFront:Float=front+length*(jet ? 0.42:0.35),rootBack:Float=front+length*(jet ? 0.66:0.61)
            for side:Float in [-1,1] {
                let tipFront:Float=cargo ? -0.35:front+length*(jet ? 0.63:0.59),tipBack=tipFront+length*(cargo ? 0.13:0.10)
                hull.plate([.init(side*radius*0.7,0.05,rootFront),.init(side*span,0.16,tipFront),.init(side*span,0.16,tipBack),.init(side*radius*0.7,0.05,rootBack)],thickness:.init(0,jet ? 0.09:0.16,0),color:cargo ? olive:paint)
                hull.plate([.init(side*radius*0.5,0.36,rear-length*0.20),.init(side*span*(cargo ? 0.36:0.43),0.50,rear-length*0.09),.init(side*span*(cargo ? 0.36:0.43),0.50,rear-length*0.035),.init(side*radius*0.5,0.36,rear-length*0.035)],thickness:.init(0,0.065,0),color:cargo ? olive:paint)
                if jet {
                    hull.beveledBox(center:.init(side*0.43,-0.03,front+length*0.42),size:.init(0.32,0.44,0.85),bevel:0.06,color:paint)
                    hull.box(center:.init(side*0.43,-0.03,front+length*0.42-0.43),size:.init(0.27,0.34,0.025),color:dark)
                    hull.cylinder(from:.init(side*0.23,0,rear-0.65),to:.init(side*0.23,0,rear-0.03),radius:0.22,endRadius:0.18,sides:16,color:steel,caps:false)
                    hull.cylinder(from:.init(side*0.23,0,rear-0.08),to:.init(side*0.23,0,rear-0.07),radius:0.14,sides:14,color:dark)
                } else if cargo {
                    for x:Float in [3.0,6.1] {
                        hull.ellipsoid(center:.init(side*x,0.93,-0.80),radii:.init(0.48,0.49,1.65),segments:16,rings:16,color:olive)
                        hull.cylinder(from:.init(side*x,0.93,-2.34),to:.init(side*x,0.93,-2.60),radius:0.23,endRadius:0.04,sides:16,color:steel)
                    }
                    for z:Float in [-4.0,-2.5,-1.0,0.5,2.0,3.5,5.0] {
                        hull.cylinder(from:.init(side*radius*0.97,0.26,z),to:.init(side*radius*1.005,0.26,z),radius:0.105,sides:12,color:glass)
                    }
                } else {
                    for fraction:Float in [0.34,0.64] {
                        let x=side*span*fraction,z=rootFront+(tipFront-rootFront)*fraction+0.65,pod=old ? Float(0.48):0.32
                        hull.box(center:.init(x,-0.45,z),size:.init(0.14,0.8,0.8),color:paint)
                        for pair:Float in [-1,1] {
                            let xx=x+pair*pod*0.85
                            hull.cylinder(from:.init(xx,-0.95,z-1.1),to:.init(xx,-0.95,z+0.95),radius:pod,endRadius:pod*0.80,sides:16,color:paint)
                            hull.cylinder(from:.init(xx,-0.95,z-1.105),to:.init(xx,-0.95,z-1.11),radius:pod*0.75,sides:16,color:dark)
                        }
                    }
                }
            }
            let tailHeight:Float=cargo ? 5.0:jet ? (old ? 2.25:1.87):(old ? 6.49:4.54)
            hull.plate([.init(0,0.35,rear-length*0.24),.init(0,tailHeight,rear-length*0.10),.init(0,tailHeight,rear-length*0.045),.init(0,0.35,rear-length*0.015)],thickness:.init(0.10,0,0),color:cargo ? olive:paint)
            hull.box(center:.init(0,radius*1.08,front+length*0.31),size:.init(0.05,0.23,0.11),color:steel)
            if cargo {
                for child in root.childNodes where (child.name ?? "").contains("Prop") {
                    var mesh=NativeDetailMesh()
                    for i in 0..<4 {
                        let a=Float(i)*Float.pi/2,d=SIMD3<Float>(cos(a),sin(a),0),t=SIMD3<Float>(-sin(a),cos(a),0)
                        mesh.plate([d*0.18-t*0.06,d*1.14-t*0.10,d*1.14+t*0.10,d*0.18+t*0.06],thickness:.init(0,0,0.035),color:dark)
                    };install(mesh,on:child,name:"RemasteredAirScrews")
                }
            }
        }
        install(hull,on:root,name:"RemasteredAirframe")
        return total
    }
    /// Completes tail/C130 prop animation where old host paths only updated the
    /// main helicopter rotor. Called with the logical tick; it owns no timer/RNG.
    static func updateScrews(on root:SCNNode,type:String,tick:Int) {
        guard root.childNode(withName:"RemasteredAirframe",recursively:false) != nil else{return}
        let angle=CGFloat(Double((tick*40)%360) * .pi/180)
        for child in root.childNodes where (child.name ?? "").contains("Prop") {
            if type=="C130" {child.eulerAngles.z = -angle}else{child.eulerAngles.x = -angle}
        }
    }
}

func testRemasteredAircraft(objects:[[String:Any]],gameID:String) throws {
    func check(_ good:Bool,_ message:String) throws {if !good{throw NSError(domain:"RemasteredAircraft",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
    func tree(_ id:Int,root:Bool=false)->SCNNode {
        let object=objects.first{$0["id"] as? Int==id}!,node=SCNNode();node.name=object["name"] as? String
        let p=(object["translation"] as! [NSNumber]).map{$0.doubleValue/100};if !root{node.position=SCNVector3(p[0],p[1],p[2])}
        node.addChildNode(SCNNode(geometry:SCNSphere(radius:0.1)))
        for child in objects where child["link"] as? Int==id {node.addChildNode(tree(child["id"] as! Int))};return node
    }
    let variants:[(String,Int,Int)]=gameID=="2000" ? [("JET",76,1),("BOMBER",73,1),("C130",207,5),("COBRA",88,3),("CH53",106,4)]:[("JET",117,1),("BOMBER",133,1),("C130",210,5),("COBRA",142,3),("CH53",178,4)]
    for (type,id,draws) in variants {
        let root=tree(id,root:true);root.position=SCNVector3(0,12,-40)
        let rootMatrix=root.transform;var pivots:[(SCNNode,SCNMatrix4)]=[]
        root.enumerateChildNodes{node,_ in if node.geometry==nil{pivots.append((node,node.transform))}}
        let triangles=RemasteredAircraft.apply(to:root,type:type,gameID:gameID)
        try check(triangles>0 && triangles<12000 && RemasteredAircraft.apply(to:root,type:type,gameID:gameID)==0,"Incomplete or repeated airframe")
        var visible=0;root.enumerateChildNodes{node,_ in if node.geometry != nil && !node.isHidden {visible+=1}}
        try check(visible==draws,"Incorrect airframe/animated-part draw count for \(type)")
        for (node,matrix) in pivots{try check(SCNMatrix4EqualToMatrix4(node.transform,matrix),"Airframe replacement moved original pivot")}
        RemasteredAircraft.updateScrews(on:root,type:type,tick:3)
        try check(SCNMatrix4EqualToMatrix4(root.transform,rootMatrix),"Prop animation moved gameplay actor")
        for child in root.childNodes where (child.name ?? "").contains("Prop") {
            try check(abs((type=="C130" ? child.eulerAngles.z:child.eulerAngles.x)+2 * .pi/3)<0.0001,"Tail/transport prop failed to animate")
        }
    }
    print("PASS remastered aircraft \(gameID): five airframes, original pivots, bounded batches, supplemental prop animation")
}
