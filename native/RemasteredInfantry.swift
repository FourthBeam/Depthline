import AppKit
import SceneKit
import simd

/// An articulated, single-draw soldier replacing the old tiny billboard. Source
/// AI states/frames drive the pose; this adapter consumes no RNG and changes no
/// movement, damage, hit volumes, firing events or animation-completion timing.
final class RemasteredInfantryNode: SCNNode {
    let gameID: String
    let rig = SCNNode()
    private(set) var bones: [SCNNode] = []
    private(set) var action = RemasteredInfantry.Action.idle

    init(gameID: String) {
        self.gameID=gameID
        super.init()
        name="RemasteredInfantry"
        addChildNode(rig);rig.name="InfantryVisual"
        let template=RemasteredInfantry.template
        for i in template.pivots.indices {
            let bone=SCNNode();bone.name="InfantryBone\(i)"
            let parent=template.parents[i]
            let local=template.pivots[i]-(parent>=0 ? template.pivots[parent]:.zero)
            bone.simdPosition=local;bones.append(bone)
            if parent>=0 {bones[parent].addChildNode(bone)}else{rig.addChildNode(bone)}
        }
        let skin=SCNSkinner(baseGeometry:template.geometry,bones:bones,boneInverseBindTransforms:template.inverseBind,boneWeights:template.weights,boneIndices:template.indices)
        skin.skeleton=rig
        let surface=SCNNode(geometry:template.geometry);surface.name="InfantrySkin";surface.skinner=skin
        rig.addChildNode(surface)
        // Match the existing per-version source actor height. Enemy root scale
        // still belongs to source disembarkation/parachute animation.
        rig.simdScale=SIMD3(repeating:gameID=="2000" ? 1.6/1.70:1.27/1.70)
        apply(state:gameID=="2000" ? 6:19,frame:0,direction:.init(0,0,-1))
    }
    required init?(coder: NSCoder) { fatalError("Programmatic infantry") }

    func apply(state: Int, frame: Int, direction: SIMD3<Double>, rollDegrees: Double = 0) {
        let old=gameID=="2000",type=RemasteredInfantry.action(gameID:gameID,state:state)
        action=type
        let sourceCycle=old ? Double(frame%11)/11:Double((frame-79+1400)%14)/14
        let phase=Float(sourceCycle*2 * .pi),swing=sin(phase)
        for i in bones.indices {
            let parent=RemasteredInfantry.template.parents[i]
            bones[i].simdPosition=RemasteredInfantry.template.pivots[i]-(parent>=0 ? RemasteredInfantry.template.pivots[parent]:.zero)
            bones[i].eulerAngles=SCNVector3Zero
        }
        rig.position=SCNVector3Zero;rig.eulerAngles=SCNVector3(0,0,rollDegrees * .pi/180)
        let moving = type == .run || type == .burning
        if moving {
            bones[6].eulerAngles.x=CGFloat(swing*0.59);bones[8].eulerAngles.x=CGFloat(-swing*0.59)
            bones[7].eulerAngles.x=CGFloat(-0.08-max(0,sin(phase+0.30))*0.94)
            bones[9].eulerAngles.x=CGFloat(-0.08-max(0,sin(phase+Float.pi+0.30))*0.94)
            // The supporting heel or toe stays on the ground instead of both
            // feet floating up whenever the hips swing. Translate all hip roots
            // together so the pelvis cannot detach from the moving legs.
            let solePoints:[SIMD3<Float>]=[.init(0,-0.465,-0.14),.init(0,-0.465,0.065)]
            var sole:Float=10
            for leg in [7,9] {for p in solePoints {sole=min(sole,bones[leg].simdConvertPosition(p,to:rig).y)}}
            for root in [0,6,8] {bones[root].position.y -= CGFloat(sole)}
            bones[0].eulerAngles.x = -0.09
            bones[0].eulerAngles.y=CGFloat(swing*0.045)
            bones[1].eulerAngles.y=CGFloat(-swing*0.035)
        }
        // Carry rifle across the chest; hands articulate at elbows.
        bones[2].eulerAngles=SCNVector3(0.70,0,-0.16)
        bones[3].eulerAngles.x=0.70
        bones[4].eulerAngles=SCNVector3(0.60,0,0.15)
        bones[5].eulerAngles.x=0.85
        bones[10].eulerAngles.z = -0.14
        if moving {bones[10].eulerAngles.x=CGFloat(cos(phase)*0.018)}
        if type == .standingFire || type == .kneelingFire {
            bones[2].eulerAngles=SCNVector3(1.1,0,-0.18);bones[3].eulerAngles.x=0.46
            bones[4].eulerAngles=SCNVector3(0.95,0,0.12);bones[5].eulerAngles.x=0.65
            bones[10].eulerAngles=SCNVector3Zero;bones[10].position.y += 0.24
            if type == .kneelingFire {
                rig.position.y = -0.25 * CGFloat(rig.scale.y)
                bones[6].eulerAngles.x=1.0;bones[7].eulerAngles.x = -1.75
                bones[8].eulerAngles.x = -0.4;bones[9].eulerAngles.x = -1.2
            }
        }
        if type == .prone {
            rig.eulerAngles.x = -.pi/2;rig.position.y=0.16;rig.position.z=0.62
            bones[2].eulerAngles.x=2.7;bones[3].eulerAngles.x=0.35
            bones[4].eulerAngles.x=2.7;bones[5].eulerAngles.x=0.35
            bones[10].eulerAngles.x = .pi/2;bones[10].position.y += 0.28
        }
        if type == .throwing {
            let start=old ? 53:93,length=old ? 21.0:24.0,t=Float(max(0,min(1,Double(frame-start)/length)))
            bones[4].eulerAngles.x=CGFloat(2.8-sin(t*Float.pi)*2.1)
            bones[5].eulerAngles.x=CGFloat(-0.55+sin(t*Float.pi)*0.9)
            bones[10].eulerAngles.z=0.65;bones[10].position.y -= 0.25
        }
        if type == .parachute {
            bones[2].eulerAngles=SCNVector3(0,0,-2.55);bones[4].eulerAngles=SCNVector3(0,0,2.55)
            bones[3].eulerAngles.x = -0.4;bones[5].eulerAngles.x = -0.4
            bones[6].eulerAngles.x=0.2;bones[8].eulerAngles.x = -0.2
            bones[10].eulerAngles.z=0.5
        }
        if type == .burning {
            bones[2].eulerAngles.x=CGFloat(2.4+swing*0.35);bones[4].eulerAngles.x=CGFloat(2.4-swing*0.35)
            bones[3].eulerAngles.x = -0.6;bones[5].eulerAngles.x = -0.6
        }
        if type == .falling {
            let progress=RemasteredInfantry.deathProgress(gameID:gameID,state:state,frame:frame)
            rig.eulerAngles.x=CGFloat(-progress * .pi/2)
            rig.position.y=CGFloat(progress*0.14)
            bones[2].eulerAngles=SCNVector3(0.25,0,-0.65);bones[4].eulerAngles=SCNVector3(0.1,0,0.7)
            bones[6].eulerAngles.x=0.13;bones[8].eulerAngles.x = -0.18
        }
        if type == .thrown {
            rig.eulerAngles.x=0.65;bones[2].eulerAngles.z = -1.8;bones[4].eulerAngles.z=1.8
            bones[6].eulerAngles.x=0.8;bones[8].eulerAngles.x = -0.5
        }
        if [.idle,.run,.standingFire,.kneelingFire,.prone,.parachute,.throwing].contains(type) {
            let firing=type == .standingFire || type == .kneelingFire
            let rifle=bones[10]
            if type != .parachute {
                poseArm(upper:2,lower:3,target:rifle.simdConvertPosition(.init(-0.01,0.02,-0.17),to:rig),side:-1)
                if type != .throwing {poseArm(upper:4,lower:5,target:rifle.simdConvertPosition(.init(0,-0.015,0.08),to:rig),side:1)}
                if firing {bones[1].eulerAngles=SCNVector3(-0.10,0,0.08)}
            }
        }
        var facing=direction
        // BH2000 boat/debark states advance directly along +Z; their direction
        // field stays zero until state 5 calls aimAtCenter. Face that actual
        // movement instead of retaining the mesh's default -Z orientation.
        if old && (1...3).contains(state) {facing=SIMD3(0,0,1)}
        if [.standingFire,.kneelingFire,.prone,.throwing].contains(type) {
            let p=worldPosition;facing=SIMD3(-Double(p.x),0,-Double(p.z))
        }
        if hypot(facing.x,facing.z)>0.00001 {eulerAngles.y=CGFloat(atan2(-facing.x,-facing.z))}
    }
    private func poseArm(upper:Int,lower:Int,target:SIMD3<Float>,side:Float) {
        let parent=bones[upper].parent!,p=bones[upper].simdPosition
        let desired=parent.simdConvertPosition(target,from:rig),delta=desired-p
        let distance=min(0.585,max(0.04,simd_length(delta))),axis=simd_normalize(delta)
        let outward=SIMD3<Float>(side,0,0),normal=simd_normalize(outward-axis*simd_dot(outward,axis))
        let upperLength:Float=0.28,lowerLength:Float=0.311
        let along=(upperLength*upperLength-lowerLength*lowerLength+distance*distance)/(2*distance)
        let elbow=p+axis*along+normal*sqrt(max(0,upperLength*upperLength-along*along))
        bones[upper].simdOrientation=simd_quatf(from:.init(0,-1,0),to:simd_normalize(elbow-p))
        let local=bones[upper].simdConvertPosition(target,from:rig)-bones[lower].simdPosition
        bones[lower].simdOrientation=simd_quatf(from:simd_normalize(SIMD3<Float>(0,-0.31,-0.025)),to:simd_normalize(local))
    }
}

func testRemasteredInfantry() throws {
    func check(_ good:Bool,_ message:String) throws {
        if !good {throw NSError(domain:"RemasteredInfantry",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
    }
    for game in ["2000","2002"] {
        let a=RemasteredInfantryNode(gameID:game),b=RemasteredInfantryNode(gameID:game)
        let rootPosition=SCNVector3(3,0,-8),rootScale=SCNVector3(0.8,0.8,0.8)
        a.position=rootPosition;a.scale=rootScale
        let running=game=="2000" ? 6:19
        func forward()->SIMD3<Float> {simd_normalize(a.simdConvertVector(.init(0,0,-1),to:nil))}
        if game=="2000" {
            for state in 1...3 {
                a.apply(state:state,frame:state*2,direction:.zero)
                try check(simd_dot(forward(),SIMD3(0,0,1))>0.999,"Debarking soldier faces against its source +Z displacement")
                try check(a.action == .run,"Debark facing fix changed the source run pose")
            }
            // State 3 becomes 5 after landing, one tick before aimAtCenter
            // initializes direction; keep the last valid facing that tick.
            a.apply(state:5,frame:6,direction:.zero)
            try check(simd_dot(forward(),SIMD3(0,0,1))>0.999,"Landing transition loses debark facing")
        }
        for heading:SIMD3<Double> in [.init(1,0,-1),.init(-1,0,1),.init(1,0,1),.init(-1,0,-1)] {
            a.apply(state:running,frame:3,direction:heading)
            try check(simd_dot(forward(),simd_normalize(SIMD3<Float>(heading)))>0.999,"Running soldier faces against actual source movement")
        }
        a.apply(state:running,frame:game=="2000" ? 3:82,direction:.init(1,0,-1))
        try check(a.bones.count==11 && a.childNode(withName:"InfantrySkin",recursively:true)?.skinner?.bones.count==11,"Missing articulated skeleton")
        try check(a.bones[0] !== b.bones[0],"Instances shared mutable bones")
        try check(a.simdPosition == SIMD3(3,0,-8) && a.simdScale == SIMD3(repeating:0.8),"Visual pose moved source gameplay actor")
        for (bone,target) in [(3,SIMD3<Float>(-0.01,0.02,-0.17)),(5,SIMD3<Float>(0,-0.015,0.08))] {
            let hand=a.bones[bone].simdConvertPosition(.init(0,-0.31,-0.025),to:a.rig)
            let grip=a.bones[10].simdConvertPosition(target,to:a.rig)
            try check(simd_distance(hand,grip)<0.015,"Carrying hand misses rifle grip")
        }
        let first=a.bones[6].simdOrientation.vector
        a.apply(state:running,frame:game=="2000" ? 8:88,direction:.init(1,0,-1))
        try check(simd_distance(first,a.bones[6].simdOrientation.vector)>0.1,"Source run frames do not articulate legs")
        a.apply(state:game=="2000" ? 18:29,frame:130,direction:.init(0,0,-1))
        try check(a.action == .prone && abs(a.rig.eulerAngles.x + .pi/2)<0.001,"Prone pose absent")
        a.apply(state:game=="2000" ? 25:0,frame:176,direction:.init(0,0,-1))
        try check(a.action == .falling && abs(a.rig.eulerAngles.x + .pi/2)<0.001,"Death pose did not finish on ground")
        a.apply(state:running,frame:87,direction:.init(0,0,-1))
        try check(abs(a.rig.eulerAngles.x)<0.001 && a.rig.position.y==0,"Old death pose leaked into reused active actor")
    }
    print("PASS remastered infantry: independent skeletons, source frame poses, grip IK, debark/run facing, unchanged actor position/scale")
}

enum RemasteredInfantry {
    enum Action {case idle,run,standingFire,kneelingFire,prone,throwing,parachute,burning,falling,thrown}
    static func action(gameID:String,state:Int)->Action {
        if gameID=="2000" {
            if [21,22,23,24,25,46,47,48].contains(state){return .falling}
            if (38...45).contains(state){return .burning}
            if [18,19,20,29,30].contains(state){return .prone}
            if [14,15,16,27,28].contains(state){return .standingFire}
            if [17,31].contains(state){return .throwing}
            if state==62{return .run}
            if state>59{return .parachute}
            return state==0 ? .idle:.run
        }
        if state>=70{return .thrown}
        if state==0 || (60..<70).contains(state) || [52,55,58,59].contains(state){return .falling}
        if (50...57).contains(state){return .burning}
        if [29,30,31,37,38].contains(state){return .prone}
        if [32,33,34,39,40].contains(state){return .kneelingFire}
        if [35,41].contains(state){return .throwing}
        if state==1 || state==2{return .parachute}
        return .run
    }
    static func deathProgress(gameID:String,state:Int,frame:Int)->Double {
        if state==0 || state==25 || state==48 || state==59 {return 1}
        let start:Int,end:Int
        if gameID=="2000" {start=frame>=106 ? 106:frame>=94 ? 94:75;end=start==75 ? 93:start==94 ? 105:117}
        else {let ranges=[(162,176),(177,191),(192,206),(207,221),(240,254),(255,269),(290,305)];let range=ranges.first{($0.0...$0.1).contains(frame)} ?? (162,176);start=range.0;end=range.1}
        return max(0,min(1,Double(frame-start)/Double(max(1,end-start))))
    }
    @discardableResult
    static func update(_ node:SCNNode,gameID:String,state:Int,frame:Int,direction:SIMD3<Double>,rollDegrees:Double=0)->Bool {
        guard let soldier=node as? RemasteredInfantryNode else{return false}
        soldier.apply(state:state,frame:frame,direction:direction,rollDegrees:rollDegrees);return true
    }
    struct Template {
        let pivots:[SIMD3<Float>],parents:[Int],geometry:SCNGeometry,weights:SCNGeometrySource,indices:SCNGeometrySource,inverseBind:[NSValue]
        let bodyParts: [DepthlineInfantryBodyPart]
    }
    static let template:Template = {
        let pivots:[SIMD3<Float>]=[.init(0,0.87,0),.init(0,1.41,0),.init(-0.22,1.36,0),.init(-0.22,1.08,0),.init(0.22,1.36,0),.init(0.22,1.08,0),.init(-0.10,0.87,0),.init(-0.10,0.47,0),.init(0.10,0.87,0),.init(0.10,0.47,0),.init(0.07,1.10,-0.28)]
        let parents=[-1,0,0,2,0,4,-1,6,-1,8,0]
        var mesh=NativeDetailMesh()
        let cloth=SIMD3<Float>(0.42,0.46,0.27),pants=SIMD3<Float>(0.33,0.38,0.23),web=SIMD3<Float>(0.47,0.43,0.29)
        let skin=SIMD3<Float>(0.67,0.46,0.32),helmet=SIMD3<Float>(0.31,0.36,0.20),boots=SIMD3<Float>(0.15,0.12,0.09),steel=SIMD3<Float>(0.24,0.27,0.28)
        // Human torso cross sections: narrower waist, broader upper chest and
        // sloping shoulders. This avoids the old round doll-like barrel body.
        func torso(_ sections:[SIMD4<Float>],color:SIMD3<Float>) {
            let sides=24
            func point(_ ring:Int,_ side:Int)->SIMD3<Float> {
                let q=sections[ring],a=Float(side)*2*Float.pi/Float(sides)
                return .init(cos(a)*q.y,q.x,sin(a)*q.z+q.w)
            }
            func normal(_ ring:Int,_ side:Int)->SIMD3<Float> {
                let q=sections[ring],lo=sections[max(0,ring-1)],hi=sections[min(sections.count-1,ring+1)]
                let a=Float(side)*2*Float.pi/Float(sides),dy=max(0.001,hi.x-lo.x)
                let sx=(hi.y-lo.y)/dy,sz=(hi.z-lo.z)/dy
                return simd_normalize(.init(cos(a)/q.y,-sx*cos(a)*cos(a)/q.y-sz*sin(a)*sin(a)/q.z,sin(a)/q.z))
            }
            for j in 0..<(sections.count-1) {for i in 0..<sides {
                let start=mesh.positions.count
                mesh.quad(point(j,i),point(j+1,i),point(j+1,i+1),point(j,i+1),color:color)
                mesh.normals.replaceSubrange(start..<(start+6),with:[normal(j,i),normal(j+1,i),normal(j+1,i+1),normal(j,i),normal(j+1,i+1),normal(j,i+1)])
            }}
        }
        mesh.activeBone=0;mesh.activeSurface=1
        mesh.beveledBox(center:.init(0,0.93,0),size:.init(0.31,0.20,0.21),bevel:0.04,color:pants)
        torso([.init(0.99,0.145,0.105,0),.init(1.06,0.162,0.114,0),.init(1.19,0.184,0.126,0),.init(1.31,0.203,0.134,0),.init(1.37,0.158,0.103,0),.init(1.40,0.090,0.067,0)],color:cloth)
        // Jacket pocket flaps and a modest collar; no badges or real unit marks.
        for x:Float in [-0.105,0.105] {
            mesh.beveledBox(center:.init(x,1.255,-0.124),size:.init(0.105,0.095,0.022),bevel:0.009,color:cloth)
            mesh.beveledBox(center:.init(x,1.292,-0.140),size:.init(0.108,0.022,0.012),bevel:0.003,color:pants)
            mesh.plate([.init(x*0.30,1.405,-0.065),.init(x*0.89,1.377,-0.088),.init(x*0.42,1.335,-0.132)],thickness:.init(0,0,0.009),color:cloth)
        }
        mesh.activeSurface=3
        mesh.beveledBox(center:.init(0,1.00,0),size:.init(0.34,0.045,0.245),bevel:0.009,color:web)
        for x:Float in [-0.125,0.125] {
            mesh.cylinder(from:.init(x,1.04,-0.129),to:.init(x,1.35,-0.108),radius:0.016,sides:8,color:web)
            mesh.beveledBox(center:.init(x,1.045,-0.165),size:.init(0.078,0.11,0.060),bevel:0.012,color:web)
            mesh.beveledBox(center:.init(x,1.098,-0.171),size:.init(0.082,0.024,0.065),bevel:0.006,color:web*0.90)
        }
        mesh.beveledBox(center:.init(0,1.21,0.177),size:.init(0.27,0.29,0.13),bevel:0.030,color:web)
        mesh.cylinder(from:.init(-0.13,1.37,0.18),to:.init(0.13,1.37,0.18),radius:0.038,sides:12,color:web)
        mesh.activeBone=1;mesh.activeSurface=4
        mesh.cylinder(from:.init(0,1.385,0),to:.init(0,1.46,0),radius:0.051,sides:14,color:skin)
        mesh.ellipsoid(center:.init(0,1.535,-0.006),radii:.init(0.081,0.094,0.083),segments:24,rings:14,color:skin)
        mesh.ellipsoid(center:.init(0,1.475,-0.026),radii:.init(0.061,0.052,0.066),segments:18,rings:10,color:skin)
        for x:Float in [-0.078,0.078] {mesh.ellipsoid(center:.init(x,1.515,0),radii:.init(0.014,0.024,0.016),segments:10,rings:8,color:skin)}
        mesh.ellipsoid(center:.init(0,1.520,-0.084),radii:.init(0.014,0.026,0.018),segments:14,rings:8,color:skin*0.96)
        mesh.ellipsoid(center:.init(0,1.505,-0.098),radii:.init(0.017,0.010,0.014),segments:14,rings:6,color:skin)
        for x:Float in [-0.033,0.033] {
            mesh.ellipsoid(center:.init(x,1.546,-0.079),radii:.init(0.016,0.007,0.006),segments:10,rings:6,color:.init(0.45,0.40,0.32))
            mesh.ellipsoid(center:.init(x,1.546,-0.085),radii:.init(0.0045,0.0045,0.002),segments:8,rings:6,color:.init(0.08,0.09,0.075))
            mesh.cylinder(from:.init(x-0.013,1.558,-0.080),to:.init(x+0.013,1.556,-0.080),radius:0.003,sides:6,color:boots)
        }
        mesh.cylinder(from:.init(-0.019,1.479,-0.086),to:.init(0.019,1.479,-0.086),radius:0.0025,sides:6,color:.init(0.31,0.18,0.13))
        mesh.activeSurface=2
        mesh.cylinder(from:.init(0,1.596,0),to:.init(0,1.613,0),radius:0.115,endRadius:0.110,sides:28,color:helmet)
        mesh.ellipsoid(center:.init(0,1.61,0),radii:.init(0.110,0.085,0.117),segments:28,rings:10,upperHalf:true,color:helmet)
        mesh.activeSurface=3
        for side:Float in [-1,1] {
            mesh.cylinder(from:.init(side*0.092,1.585,0.007),to:.init(side*0.070,1.475,-0.018),radius:0.006,sides:6,color:web)
            mesh.cylinder(from:.init(side*0.070,1.475,-0.018),to:.init(side*0.020,1.443,-0.035),radius:0.005,sides:6,color:web)
        }
        for (upper,lower,x) in [(2,3,Float(-0.22)),(4,5,Float(0.22))] {
            mesh.activeBone=UInt16(upper);mesh.activeSurface=1
            mesh.ellipsoid(center:.init(x,1.335,0),radii:.init(0.073,0.095,0.079),segments:16,rings:10,color:cloth)
            mesh.cylinder(from:.init(x,1.34,0),to:.init(x,1.08,0),radius:0.064,endRadius:0.047,sides:16,color:cloth)
            mesh.beveledBox(center:.init(x+(x<0 ? -0.060:0.060),1.24,0),size:.init(0.020,0.105,0.078),bevel:0.008,color:cloth)
            mesh.activeBone=UInt16(lower)
            mesh.ellipsoid(center:.init(x,1.08,0),radii:.init(0.053,0.058,0.055),segments:14,rings:8,color:cloth)
            mesh.cylinder(from:.init(x,1.08,0),to:.init(x,0.82,-0.025),radius:0.048,endRadius:0.032,sides:16,color:cloth)
            mesh.cylinder(from:.init(x,0.847,-0.022),to:.init(x,0.815,-0.025),radius:0.037,endRadius:0.034,sides:14,color:pants)
            mesh.activeSurface=4
            mesh.ellipsoid(center:.init(x,0.774,-0.025),radii:.init(0.031,0.055,0.027),segments:14,rings:10,color:skin)
            mesh.ellipsoid(center:.init(x+(x<0 ? 0.027:-0.027),0.789,-0.042),radii:.init(0.014,0.030,0.015),segments:10,rings:8,color:skin)
            for i in 0..<3 {mesh.cylinder(from:.init(x-0.025,0.745+Float(i)*0.013,-0.048),to:.init(x+0.023,0.745+Float(i)*0.013,-0.048),radius:0.002,sides:5,color:skin*0.84)}
        }
        for (upper,lower,x) in [(6,7,Float(-0.10)),(8,9,Float(0.10))] {
            mesh.activeBone=UInt16(upper);mesh.activeSurface=1
            mesh.ellipsoid(center:.init(x,0.85,0),radii:.init(0.083,0.10,0.091),segments:16,rings:10,color:pants)
            mesh.cylinder(from:.init(x,0.85,0),to:.init(x,0.47,0),radius:0.082,endRadius:0.058,sides:16,color:pants)
            mesh.beveledBox(center:.init(x+(x<0 ? -0.071:0.071),0.70,0),size:.init(0.022,0.15,0.10),bevel:0.01,color:pants)
            mesh.activeBone=UInt16(lower)
            mesh.ellipsoid(center:.init(x,0.47,0),radii:.init(0.063,0.067,0.067),segments:16,rings:10,color:pants)
            mesh.cylinder(from:.init(x,0.46,0),to:.init(x,0.17,0),radius:0.059,endRadius:0.043,sides:16,color:pants)
            for y:Float in [0.34,0.39] {mesh.cylinder(from:.init(x,y,0),to:.init(x,y+0.015,-0.002),radius:0.060,endRadius:0.057,sides:14,color:pants)}
            mesh.activeSurface=5
            mesh.cylinder(from:.init(x,0.23,0),to:.init(x,0.10,0),radius:0.052,sides:16,color:boots)
            mesh.beveledBox(center:.init(x,0.066,-0.040),size:.init(0.112,0.113,0.225),bevel:0.025,color:boots)
            mesh.beveledBox(center:.init(x,0.018,-0.042),size:.init(0.116,0.028,0.229),bevel:0.009,color:.init(0.065,0.062,0.054))
            for i in 0..<4 {mesh.cylinder(from:.init(x-0.029,0.123,-0.015-Float(i)*0.018),to:.init(x+0.029,0.123,-0.025-Float(i)*0.018),radius:0.0024,sides:5,color:web)}
        }
        mesh.activeBone=10;mesh.activeSurface=6
        mesh.beveledBox(center:.init(0.07,1.14,-0.33),size:.init(0.045,0.075,0.29),bevel:0.008,color:steel)
        mesh.activeSurface=5
        mesh.beveledBox(center:.init(0.07,1.12,-0.10),size:.init(0.045,0.09,0.24),bevel:0.008,color:boots)
        mesh.activeSurface=6
        mesh.cylinder(from:.init(0.07,1.145,-0.46),to:.init(0.07,1.145,-0.82),radius:0.016,endRadius:0.008,sides:14,color:steel)
        mesh.box(center:.init(0.07,1.05,-0.35),size:.init(0.035,0.15,0.065),color:steel)
        mesh.box(center:.init(0.07,1.17,-0.71),size:.init(0.009,0.05,0.015),color:steel)
        let m=SCNMaterial();m.name="RemasteredInfantryUniform";m.lightingModel = .physicallyBased;m.diffuse.contents=NSColor.white
        m.metalness.contents=0.0;m.roughness.contents=0.83;m.isDoubleSided=false
        m.emission.contents=NSColor.black
        NativeDetailMesh.configureSurface(m,style:.uniform)
        let geometry=mesh.geometry(material:m)
        precondition(mesh.indices.count/3 <= 12_000,"Infantry detail exceeds the single-draw crowd budget")
        let weights=Array(repeating:SIMD4<Float>(1,0,0,0),count:mesh.positions.count)
        let indices=mesh.boneIndices.map{SIMD4<UInt16>($0,0,0,0)}
        let ws=SCNGeometrySource(data:weights.withUnsafeBytes{Data($0)},semantic:.boneWeights,vectorCount:weights.count,usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)
        let ids=SCNGeometrySource(data:indices.withUnsafeBytes{Data($0)},semantic:.boneIndices,vectorCount:indices.count,usesFloatComponents:false,componentsPerVector:4,bytesPerComponent:2,dataOffset:0,dataStride:8)
        let inverse=pivots.map{NSValue(scnMatrix4:SCNMatrix4MakeTranslation(CGFloat(-$0.x),CGFloat(-$0.y),CGFloat(-$0.z)))}
        let bodyParts = DepthlineInfantryBodyPart.build(mesh: mesh, pivots: pivots)
        return Template(pivots:pivots,parents:parents,geometry:geometry,weights:ws,indices:ids,inverseBind:inverse,bodyParts:bodyParts)
    }()
}
