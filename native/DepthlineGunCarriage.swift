import AppKit
import SceneKit

/// The traverse bearing is bolted to the emplacement floor. The elevation arm
/// keeps each mounted gun connected to that fixed bearing at every heading.
final class DepthlineGunCarriage {
    private let pivot:SIMD3<Float>
    private let arm:SCNNode
    private let bearing:SCNNode

    init(scene:SCNScene, floor:CGFloat) {
        let metal=SIMD3<Float>(0.34,0.38,0.38), light=SIMD3<Float>(0.52,0.54,0.52)
        let paint=SIMD3<Float>(0.30,0.33,0.22)
        let finish=SCNMaterial()
        finish.name="Depthline traverse iron";finish.lightingModel = .physicallyBased
        finish.diffuse.contents=NSColor.white
        NativeDetailMesh.configureSurface(finish,style:.weapon)
        var base=NativeDetailMesh()
        base.cylinder(from:.init(0,0,0),to:.init(0,0.095,0),radius:0.48,sides:36,color:paint)
        base.cylinder(from:.init(0,0.095,0),to:.init(0,0.68,0),radius:0.24,endRadius:0.13,sides:24,color:paint)
        base.cylinder(from:.init(0,0.67,0),to:.init(0,0.72,0),radius:0.24,sides:32,color:light)
        base.cylinder(from:.init(0,0.72,0),to:.init(0,0.84,0),radius:0.24,endRadius:0.18,sides:32,color:metal)
        for i in 0..<8 {
            let a=Float(i)*Float.pi/4,x=cos(a)*0.38,z=sin(a)*0.38
            base.cylinder(from:.init(x,0.093,z),to:.init(x,0.12,z),radius:0.028,sides:6,color:light)
        }
        bearing=SCNNode(geometry:base.geometry(material:finish))
        bearing.name="Depthline turret pedestal"
        bearing.position=SCNVector3(0,floor+0.042,0)
        scene.rootNode.addChildNode(bearing)
        pivot=bearing.simdPosition+SIMD3(0,0.83,0)

        // Two open cheek plates expose the bearings and leave daylight between
        // them. The normalized long axis spans the exact pin-to-pin distance.
        var boom=NativeDetailMesh()
        for side:Float in [-1,1] {
            let x=side*0.087
            let profile:[SIMD3<Float>]=[.init(x,0,-0.09),.init(x,0.76,-0.04),
                .init(x,1,-0.032),.init(x,1,0.032),.init(x,0.22,0.079),.init(x,0,0.09)]
            boom.plate(profile,thickness:.init(0.028,0,0),color:paint)
        }
        for t:Float in [0.04,0.34,0.91,0.975] {
            boom.cylinder(from:.init(-0.108,t,0),to:.init(0.108,t,0),radius:0.021,sides:10,color:light)
        }
        arm=SCNNode(geometry:boom.geometry(material:finish))
        arm.name="Depthline elevation arm";scene.rootNode.addChildNode(arm)
    }

    func connect(to pin:SIMD3<Float>?, traverseRight:SIMD3<Float>, narrowFork:Bool) {
        arm.isHidden=pin==nil
        guard let pin else {return}
        let span=pin-pivot,length=simd_length(span)
        guard length>0.001 else {arm.isHidden=true;return}
        // A pin fixes both the arm's direction and its roll. Using just the
        // shortest rotation from world up made the fork twist around the
        // receiver as the player traversed the turret through a full turn.
        let up = span / length
        let back = simd_normalize(simd_cross(traverseRight, up))
        let right = simd_cross(up, back)
        arm.simdPosition=pivot
        arm.simdOrientation = simd_quatf(simd_float3x3(columns: (right, up, back)))
        arm.simdScale = .init(narrowFork ? 0.37 : 1, length, narrowFork ? 0.60 : 1)
    }
}
