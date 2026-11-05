import AppKit
import SceneKit
import simd

/// New solid debris for the remake. Source opcode blocks still determine how
/// many pieces spawn and where on the vehicle each piece begins. Geometry uses
/// only a deterministic object/block hash, never the gameplay random stream.
enum RemasteredDebris {
    static func makeNode(objectID:Int,block:Int,sourceGroups:[[String:Any]])->SCNNode {
        let root=SCNNode();root.name="remastered-fragment-\(objectID)-\(block)"
        var points:[SIMD3<Float>]=[]
        for group in sourceGroups {
            let values=(group["vertices"] as? [NSNumber] ?? []).map{$0.floatValue*0.01}
            for i in stride(from:0,to:values.count-2,by:3) {points.append(.init(values[i],values[i+1],values[i+2]))}
        }
        guard let first=points.first else{return root}
        var lo=first,hi=first,sum=SIMD3<Float>.zero
        for p in points {lo=simd_min(lo,p);hi=simd_max(hi,p);sum+=p}
        let center=sum/Float(points.count),extent=hi-lo
        let major=max(extent.x,max(extent.y,extent.z)),size=min(1.2,max(0.16,major*0.17))
        let seed=UInt32(truncatingIfNeeded:objectID &* 1664525 &+ block &* 1013904223)
        let variant=Int(seed%4),paint=SIMD3<Float>(0.19,0.22,0.16),edge=SIMD3<Float>(0.28,0.29,0.27),char=SIMD3<Float>(0.08,0.085,0.08)
        var mesh=NativeDetailMesh()
        if variant==0 {
            // Torn skin: irregular edges, finite thickness and a folded half.
            mesh.plate([.init(-size*0.6,-size*0.32,0),.init(size*0.05,-size*0.42,0),.init(size*0.12,size*0.33,0),.init(-size*0.38,size*0.43,0)],thickness:.init(0,0,0.018),color:paint)
            mesh.plate([.init(size*0.05,-size*0.42,0),.init(size*0.58,-size*0.27,size*0.18),.init(size*0.47,size*0.21,size*0.16),.init(size*0.12,size*0.33,0)],thickness:.init(0,0,0.018),color:edge)
            mesh.cylinder(from:.init(-size*0.4,-size*0.15,-0.015),to:.init(size*0.2,-size*0.15,-0.015),radius:0.018,sides:6,color:char)
        }else if variant==1 {
            // A broken stiffener with a remaining plate and exposed edge.
            mesh.beveledBox(center:.zero,size:.init(size*1.25,size*0.11,size*0.14),bevel:0.012,color:edge)
            mesh.plate([.init(-size*0.42,0,-size*0.35),.init(size*0.50,0,-size*0.19),.init(size*0.32,0,size*0.24),.init(-size*0.50,0,size*0.18)],thickness:.init(0,0.022,0),color:paint)
        }else if variant==2 {
            // Open-ended exhaust/gun tube, with solid wall thickness at rims.
            let r=size*0.15
            mesh.cylinder(from:.init(0,0,-size*0.65),to:.init(0,0,size*0.40),radius:r,sides:12,color:edge,caps:false)
            let innerStart=mesh.positions.count,indexStart=mesh.indices.count
            mesh.cylinder(from:.init(0,0,-size*0.65),to:.init(0,0,size*0.40),radius:r*0.77,sides:12,color:char,caps:false)
            for i in innerStart..<mesh.normals.count {mesh.normals[i] = -mesh.normals[i]}
            for i in stride(from:indexStart,to:mesh.indices.count,by:3) {mesh.indices.swapAt(i+1,i+2)}
            for z in [-size*0.65,size*0.40] {for i in 0..<12 {
                let a=Float(i)*Float.pi/6,b=Float(i+1)*Float.pi/6
                mesh.quad(.init(cos(a)*r,sin(a)*r,z),.init(cos(b)*r,sin(b)*r,z),.init(cos(b)*r*0.77,sin(b)*r*0.77,z),.init(cos(a)*r*0.77,sin(a)*r*0.77,z),color:edge)
            }}
        }else{
            // Scorched mechanical housing, bolted through a broken flange.
            mesh.beveledBox(center:.zero,size:.init(size*0.62,size*0.36,size*0.78),bevel:size*0.07,color:char)
            mesh.plate([.init(-size*0.48,-size*0.15,-size*0.52),.init(size*0.38,-size*0.15,-size*0.48),.init(size*0.42,-size*0.15,size*0.32),.init(-size*0.38,-size*0.15,size*0.45)],thickness:.init(0,0.025,0),color:paint)
            for x:Float in [-0.18,0.18] {mesh.cylinder(from:.init(size*x,size*0.16,-size*0.15),to:.init(size*x,size*0.22,-size*0.15),radius:size*0.055,sides:6,color:edge)}
        }
        let yaw=Float(seed&255)*Float.pi/128,pitch=Float((seed>>8)&255)*Float.pi/256
        let rotation=simd_quatf(angle:yaw,axis:.init(0,1,0))*simd_quatf(angle:pitch,axis:.init(1,0,0))
        for i in mesh.positions.indices {mesh.positions[i]=rotation.act(mesh.positions[i])+center;mesh.normals[i]=rotation.act(mesh.normals[i])}
        let material=SCNMaterial();material.name="RemasteredDebrisPaint";material.diffuse.contents=NSColor.white
        material.lightingModel = .physicallyBased;material.isDoubleSided=true;NativeDetailMesh.configureSurface(material,style:.paint)
        root.geometry=mesh.geometry(material:material)
        return root
    }
}

func testRemasteredDebris() throws {
    func check(_ good:Bool,_ message:String)throws{if !good{throw NSError(domain:"RemasteredDebris",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
    let source:[[String:Any]]=[["vertices":[-100.0,0,0,100,0,0,0,100,0]]]
    for i in 0..<4 {
        let first=RemasteredDebris.makeNode(objectID:142,block:i,sourceGroups:source),second=RemasteredDebris.makeNode(objectID:142,block:i,sourceGroups:source)
        guard let geometry=first.geometry,let other=second.geometry else{throw NSError(domain:"RemasteredDebris",code:2)}
        try check(geometry.elements.count==1 && geometry.elements[0].primitiveCount>20 && geometry.elements[0].primitiveCount<200,"Debris must be solid and one bounded batch")
        try check(geometry.sources(for:.vertex)[0].data==other.sources(for:.vertex)[0].data,"Visual debris must be deterministic without consuming gameplay RNG")
        try check(SCNMatrix4EqualToMatrix4(first.transform,SCNMatrix4Identity),"Fragment visual must retain source motion pivot")
        let b=first.boundingBox
        try check(b.max.x>b.min.x && b.max.y>b.min.y && b.max.z>b.min.z,"Debris became a zero-thickness card")
    }
    try check(RemasteredDebris.makeNode(objectID:142,block:0,sourceGroups:[]).geometry==nil,"Non-polygon source block must remain invisible")
    print("PASS remastered debris: four solid forms, deterministic geometry, one draw/piece, source pivots and empty blocks retained")
}
