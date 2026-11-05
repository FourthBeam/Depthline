import Foundation
import SceneKit
import simd

/// Source ShapeData polygons, with their original part indices. The extraction
/// preserves Scale/Translate and does not use the visible model's bounding box
/// as a substitute. Segment/plane arithmetic is a Mac adapter; exact x87 edge
/// inclusion remains a floating-point adapter; source target-loop priority is
/// implemented separately in OriginalSharedBallistics/GameSharedProjectiles.
final class OriginalCollision {
    struct Polygon {
        let part: Int
        let points: [SIMD3<Double>]
        let normal: SIMD3<Double>
        let dropAxis: Int
        init?(part: Int, points: [SIMD3<Double>]) {
            guard points.count >= 3 else { return nil }
            var normal = SIMD3<Double>(repeating:0)
            for i in 1..<(points.count-1) {
                normal=simd_cross(points[i]-points[0],points[i+1]-points[0])
                if simd_length_squared(normal)>1e-16 {break}
            }
            guard simd_length_squared(normal)>1e-16 else {return nil}
            self.part=part;self.points=points;self.normal=normal
            let a=abs(normal.x),b=abs(normal.y),c=abs(normal.z)
            dropAxis=a>=b && a>=c ? 0 : b>=c ? 1 : 2
        }
        func fraction(start: SIMD3<Double>, end: SIMD3<Double>) -> Double? {
            let direction=end-start, denominator=simd_dot(normal,direction)
            guard abs(denominator)>1e-12 else {return nil}
            let t=simd_dot(normal,points[0]-start)/denominator
            guard t>=0 && t<=1 else {return nil}
            let p=start+direction*t
            let u=(dropAxis+1)%3,v=(dropAxis+2)%3
            var inside=false
            for i in points.indices {
                let a=points[i],b=points[(i+1)%points.count]
                let edge=(b[u]-a[u])*(p[v]-a[v])-(b[v]-a[v])*(p[u]-a[u])
                if abs(edge)<1e-9 && p[u]>=min(a[u],b[u])-1e-9 && p[u]<=max(a[u],b[u])+1e-9 &&
                    p[v]>=min(a[v],b[v])-1e-9 && p[v]<=max(a[v],b[v])+1e-9 {return t}
                if (a[v]>p[v]) != (b[v]>p[v]) && p[u]<(b[u]-a[u])*(p[v]-a[v])/(b[v]-a[v])+a[u] {inside.toggle()}
            }
            return inside ? t : nil
        }
    }
    struct Hit {let fraction:CGFloat;let part:Int}
    let gameID: String
    struct Shape {
        let polygons: [Polygon]
        let minimum: SCNVector3
        let maximum: SCNVector3

        init?(_ polygons: [Polygon]) {
            guard !polygons.isEmpty else { return nil }
            var lower = SIMD3<Double>(repeating: .infinity)
            var upper = SIMD3<Double>(repeating: -.infinity)
            for polygon in polygons {
                for point in polygon.points {
                    lower = simd_min(lower, point)
                    upper = simd_max(upper, point)
                }
            }
            self.polygons = polygons
            // Keep face-edge hits accepted by Polygon.fraction's tolerance.
            minimum = SCNVector3(lower - SIMD3(repeating: 1e-8))
            maximum = SCNVector3(upper + SIMD3(repeating: 1e-8))
        }

        func hit(node: SCNNode, start: SCNVector3, end: SCNVector3) -> Hit? {
            let a = node.convertPosition(start, from: nil), b = node.convertPosition(end, from: nil)
            guard OriginalProjectiles.segmentAABB(start: a, end: b, minimum: minimum, maximum: maximum) != nil else { return nil }
            let from = SIMD3<Double>(a.x, a.y, a.z), to = SIMD3<Double>(b.x, b.y, b.z)
            var nearest: Hit?
            for polygon in polygons {
                if let t = polygon.fraction(start: from, end: to), t < (nearest?.fraction ?? .infinity) {
                    nearest = Hit(fraction: CGFloat(t), part: polygon.part)
                }
            }
            return nearest
        }
    }
    private var shapes: [String:Shape]=[:]
    init(root:URL,gameID:String) throws {
        self.gameID=gameID
        let data=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("collision.json"))) as! [String:Any]
        for object in data["objects"] as? [[String:Any]] ?? [] {
            let name=(object["name"] as? String ?? "").uppercased()
            var polygons:[Polygon]=[]
            for part in object["parts"] as? [[String:Any]] ?? [] {
                for points in part["polygons"] as? [[[Double]]] ?? [] {
                    if let p=Polygon(part:part["index"] as? Int ?? 0,points:points.map {SIMD3<Double>($0[0]*0.01,$0[1]*0.01,$0[2]*0.01)}) {polygons.append(p)}
                }
            }
            shapes[name]=Shape(polygons)
        }
    }
    func shapeName(type:String,cargoFamily:String?=nil)->String {
        let type=type.uppercased()
        if gameID=="2000" {
            switch type {
            case "BARGE":return cargoFamily=="vehicle" ? "BARGE2":"BARGE1"
            case "APC","APC1","APC2","APC3":return "M113"
            case "TANK":return "M48"
            case "BOMBER":return "B52"
            case "JET":return "F4"
            case "COBRA":return "AH1"
            default:return type
            }
        }
        return type.hasPrefix("APC") ? "APC":type
    }
    func hit(type:String,cargoFamily:String?=nil,node:SCNNode,start:SCNVector3,end:SCNVector3)->Hit? {
        shapes[shapeName(type:type,cargoFamily:cargoFamily)]?.hit(node: node, start: start, end: end)
    }
    /// Recovered sprite hit test, independent of the rendered billboard size.
    /// 2000 0x4250a4; 2002 0x424897, assembly evidence ev_7f3d7cdebf5b2b6380e0932640cf0398efcc980f0a512a248a5dadd2df0df46c.
    /// Original tests the soldier's foot in the bullet-aligned coordinate frame:
    /// width +/-30, height 10...130, forward distance 400/500 source units.
    /// Strict inequalities and active-death-state differences are intentional.
    /// Swift trigonometry replaces the source x87 helpers; it is not bit exact.
    static func infantryHit(gameID:String,state:Int,foot:SCNVector3,start:SCNVector3,end:SCNVector3)->CGFloat? {
        guard gameID == "2000" ? !(21...25).contains(state) : state>1 else {return nil}
        let reach:Double=gameID == "2000" ? 400:500
        // This is the original velocity / nominal speed, not re-normalization
        // after gravity. In 2002 even the slower handgun uses the 500-unit helper.
        let dx=Double(end.x-start.x)*100/reach,dy=Double(end.y-start.y)*100/reach,dz=Double(end.z-start.z)*100/reach
        let horizontal=hypot(dx,dz)
        guard horizontal>0,abs(dy)<=1 else {return nil}
        let yaw=acos(max(-1,min(1,-dz/horizontal)))*(dx<0 ? -1:1),pitch=asin(-dy)
        let sy=sin(yaw),cy=cos(yaw),sp=sin(pitch),cp=cos(pitch)
        let x=Double(foot.x-start.x)*100,y=Double(foot.y-start.y)*100,z=Double(foot.z-start.z)*100
        let sideways=x*cy+z*sy
        let vertical=x*sp*sy+y*cp-z*cy*sp
        let depth = -x*cp*sy+y*sp+z*cp*cy
        guard abs(sideways)<30,depth<0,depth > -reach,vertical < -10,vertical > -130 else {return nil}
        // Original returns the soldier ID, not a geometric intersection point.
        // Fraction only locates the port's visual impact along this tick segment.
        return CGFloat(min(1,max(0,-depth/reach)))
    }
    static func selfTest() throws {
        let polygon=Polygon(part:2,points:[SIMD3<Double>(-1,-1,0),SIMD3<Double>(1,-1,0),SIMD3<Double>(1,1,0),SIMD3<Double>(-1,1,0)])!
        guard polygon.fraction(start:.init(0,0,2),end:.init(0,0,-2))==0.5,
              polygon.fraction(start:.init(2,0,2),end:.init(2,0,-2))==nil,
              polygon.fraction(start:.init(0,0,2),end:.init(0,0,1))==nil,
              polygon.fraction(start:.init(0,0,-2),end:.init(0,0,2))==0.5 else {throw NSError(domain:"OriginalCollision",code:1)}
        print("PASS: finite swept source polygon intersections, miss, no premature hit and both directions")
        let start=SCNVector3(0,1,0),end=SCNVector3(0,1,-5),foot=SCNVector3(0,0,-3)
        guard infantryHit(gameID:"2002",state:2,foot:foot,start:start,end:end) != nil,
              infantryHit(gameID:"2002",state:60,foot:foot,start:start,end:end) != nil,
              infantryHit(gameID:"2002",state:1,foot:foot,start:start,end:end) == nil,
              infantryHit(gameID:"2002",state:2,foot:SCNVector3(0.31,0,-3),start:start,end:end) == nil,
              infantryHit(gameID:"2000",state:21,foot:foot,start:start,end:SCNVector3(0,1,-4)) == nil,
              infantryHit(gameID:"2000",state:10,foot:foot,start:start,end:SCNVector3(0,1,-4)) != nil
        else {throw NSError(domain:"OriginalInfantryCollision",code:1)}
        print("PASS: original soldier width/height/depth and version-specific death-state collision gates")
    }
}
