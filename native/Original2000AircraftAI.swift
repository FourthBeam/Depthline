import Foundation

// BH2000 original JET/B52/COBRA state machines. Evidence:
// analysis/bh2000/full-decompile/functions/0x406805.c:990...2451;
// initialization0x404b24:166...213,244...265; respawn0x405d14:85...160;
// launches0x416a09:3529...3790; original main's AI -> collisions -> spawn order.
// All coordinates/velocities are original units/tick, Euler angles are degrees.
// No SceneKit, wall-clock routes or fabricated damage/score. Static restoration
// does not claim runtime/bit-identical floating-point or RNG replay.
//
// let ai=Original2000AircraftAI(declarations:[.init(kind:.jet,slot:0,sourceIndex:4,active:true)],aggression:level.aggression,random:rand)
// consume(ai.tick(terrainHeight:nearestHeight,random:rand))
// ... existing projectiles/player collisions, ai.applyDamage(...) ...
// for shot in ai.takeShots(random:rand,allocateBulletSlot:shared80Slot) {spawn(shot)}
// campaign scheduler then calls activate(kind:slot:sourceIndex:random:) on revive.
// Shot(.bomb) retains full forward AND horizontalSpeed for OriginalEnemyOrdnance.
// takeShots uses original Cobra -> B52 -> Jet ordering and shared12/16 rocket/
// bomb rings. Bullet slot allocation must share the original80 slots with player
// fire. Tick defaults hover phases to zero at construction; pass global phases
// and alternating smoke flags to retain them across levels.
final class Original2000AircraftAI {
    enum Kind:String {case jet,bomber,cobra}
    /// Synchronous source crash helper: consume debris RNG before a later
    /// aircraft or the same Cobra's smoke branch advances the shared RNG.
    typealias CrashVisualHandler = (String, Int, SIMD3<Double>, SIMD3<Double>) -> Void
    enum WeaponKind:String {case bullet,airRocket,bomb}
    struct Declaration {let kind:Kind,slot:Int,sourceIndex:Int;let active:Bool}
    struct Plane {
        let kind:Kind,slot:Int
        var sourceIndex = -1,visible=false,hp=1,state=1,counter=0,pendingFire=0,bombs=0
        var position=SIMD3<Double>.zero,eulerDegrees=SIMD3<Double>(0,180,0)
        var target=SIMD3<Double>.zero,forward=SIMD3<Double>(0,0,1)
        var speed:Double=0,acceleration:Double=0,turn:Double=0,turnTarget:Double=0
        var pitchSpring:Double=0,pitchTarget:Double=0,verticalSpeed:Double=0,verticalAcceleration:Double=0,fallSpeed:Double=0
        var rotorDegreesPerTick:Double=55,rollIncrementDegrees:Double=0
        var terrainLift = 0.0
        var isDying: Bool { visible && state >= (kind == .jet ? 14 : kind == .cobra ? 13 : 6) }
        var objectID:Int {(kind == .jet ? 76:kind == .bomber ? 73:88)+slot}
    }
    struct Shot:Equatable {
        let kind:WeaponKind,poolIndex:Int,sourceIndex:Int,originalEmitterObject:Int
        let origin:SIMD3<Double>,velocity:SIMD3<Double>
        let lifetimeTicks:Int?,bombHorizontalSpeed:Double?,bombForward:SIMD3<Double>?
        var originalProjectileObject:Int? {kind == .airRocket ? 163+poolIndex:kind == .bomb ? 175+poolIndex:nil}
    }
    enum Event:Equatable {
        case forceAndScore(sourceIndex:Int,force:Int,score:Int)
        case defenseChanged(Int)
        case removed(sourceIndex:Int,objectID:Int)
        case explosion(sourceIndex:Int,position:SIMD3<Double>,scale:Double)
        case smoke(sourceIndex:Int,position:SIMD3<Double>)
    }
    private(set) var jets=(0..<12).map{Plane(kind:.jet,slot:$0)}
    private(set) var bombers=(0..<3).map{Plane(kind:.bomber,slot:$0)}
    private(set) var cobras=(0..<6).map{Plane(kind:.cobra,slot:$0)}
    private let jetAggression:Int,cobraAggression:Int
    var helicopterAltitude: ((SIMD3<Double>, Double, Double, Bool, inout Double) -> Double)?
    var helicopterGround: ((Double, Double) -> Double)?
    private var ticks=0,nextRocket=0,nextBomb=0,nextBullet=0

    init(declarations:[Declaration],aggression:[Int],random:()->UInt32) {
        jetAggression=(aggression.count>1 ? aggression[1]:0)+500
        cobraAggression=(aggression.count>2 ? aggression[2]:0)+40
        for i in jets.indices {reset(&jets[i],random:random)}
        for i in cobras.indices {reset(&cobras[i],random:random)}
        for i in bombers.indices {reset(&bombers[i],random:random)}
        for d in declarations {setDeclaration(d)}
    }
    private func setDeclaration(_ d:Declaration) {
        switch d.kind {
        case .jet:precondition(jets.indices.contains(d.slot));jets[d.slot].sourceIndex=d.sourceIndex;jets[d.slot].visible=d.active
        case .bomber:precondition(bombers.indices.contains(d.slot));bombers[d.slot].sourceIndex=d.sourceIndex;bombers[d.slot].visible=d.active
        case .cobra:precondition(cobras.indices.contains(d.slot));cobras[d.slot].sourceIndex=d.sourceIndex;cobras[d.slot].visible=d.active
        }
    }
    func activate(kind:Kind,slot:Int,sourceIndex:Int,random:()->UInt32,resetForRevive:Bool=true) {
        // Initial visible declarations keep the already randomized level state.
        // Delayed activation and revival use the scheduler's original reset.
        if resetForRevive {switch kind {
        case .jet:reset(&jets[slot],random:random,fresh:false)
        case .bomber:reset(&bombers[slot],random:random,fresh:false)
        case .cobra:reset(&cobras[slot],random:random,fresh:false)
        }}
        setDeclaration(.init(kind:kind,slot:slot,sourceIndex:sourceIndex,active:true))
    }
    func applyDamage(objectID:Int,hp:Int,state:Int,visible:Bool) {
        // Original hit branches do not clear606a4. An aircraft destroyed by a
        // projectile can still emit its already requested final shot this tick.
        func apply(_ p:inout Plane) {p.hp=hp;p.state=state;p.visible=visible}
        if (76..<88).contains(objectID) {apply(&jets[objectID-76])}
        if (73..<76).contains(objectID) {apply(&bombers[objectID-73])}
        if (88..<94).contains(objectID) {apply(&cobras[objectID-88])}
    }
    private func reset(_ p:inout Plane,random:()->UInt32,fresh:Bool=true) {
        p.terrainLift = 0
        // Revive resets only the fields written by0x405d14. Springs, targets,
        // death roll increment and counters survive; new-level init clears them.
        if fresh {let old=p;p=Plane(kind:old.kind,slot:old.slot);p.sourceIndex=old.sourceIndex}
        p.eulerDegrees=SIMD3(0,180,0);p.state=1;p.pendingFire=0
        p.position.x=Double(draw(random)>>1)-8192
        if p.kind == .bomber {p.position.y=6000+Double(p.slot)*1500;p.position.z=Double(draw(random))-63000;p.speed=160;p.acceleration=0;p.hp=8}
        else {
            p.position.y=Double(draw(random)>>(p.kind == .jet ? 3:5))+(p.kind == .jet ? 2000:1500)
            p.position.z=Double(draw(random))-65000
            if p.kind == .jet {p.speed=Double(draw(random)>>10)+160;p.hp=4;p.bombs=2}
            else {p.speed=140;p.acceleration=0;p.hp=8;p.bombs=12;p.rotorDegreesPerTick=55}
        }
    }
    var hasPendingDeaths: Bool { jets.contains(where: \.isDying) || cobras.contains(where: \.isDying) || bombers.contains(where: \.isDying) }

    func tick(terrainHeight:(Double,Double)->Double,random:()->UInt32,
              hoverPhasesDegrees:SIMD4<Double>?=nil,smokeEveryTwoTicks:Bool?=nil,smokeEveryFourTicks:Bool?=nil,
              deathsOnly:Bool=false,onCrashVisual:CrashVisualHandler?=nil)->[Event] {
        var events:[Event]=[]
        let smoke2=smokeEveryTwoTicks ?? (ticks%2==0),smoke4=smokeEveryFourTicks ?? (ticks%4==0)
        let phases=hoverPhasesDegrees ?? SIMD4(4.1,6,9.5,12.2)*Double(ticks)
        for i in jets.indices where jets[i].visible && (!deathsOnly || jets[i].isDying) {
            var p=jets[i];updateJet(&p,ground:terrainHeight,random:random,smokeTick:smoke2,events:&events,onCrashVisual:onCrashVisual)
            fixedWingPhysics(&p,roll:30)
            if p.state==1&&(abs(p.position.x)>25000||abs(p.position.z)>25000) {
                p.state=2;p.turnTarget=draw(random)<16385 ? -2:2;p.pitchTarget=0
                p.target.x=Double(draw(random)>>2)-4096;p.target.z=Double(draw(random)>>2)-4096
            }
            if p.position.y<2240&&p.state<11 {
                let ahead=p.position+p.forward*4000
                let height=abs(ahead.x)<15000&&abs(ahead.z)<7500 ? terrainHeight(ahead.x,ahead.z):800
                if p.position.y<height+200 {p.state=13;p.pitchTarget=1;p.turnTarget=0}
            }
            jets[i]=p
        }
        for i in bombers.indices where bombers[i].visible && (!deathsOnly || bombers[i].isDying) {
            var p=bombers[i];updateBomber(&p,ground:terrainHeight,random:random,smokeTick:smoke2,events:&events,onCrashVisual:onCrashVisual)
            fixedWingPhysics(&p,roll:35)
            if p.state==1&&(abs(p.position.x)>30000||abs(p.position.z)>30000) {
                p.state=3;p.counter=360
                p.target=[SIMD3<Double>(0,800,0),SIMD3(1000,500,3200),SIMD3(4000,440,-400),SIMD3(-4000,300,-300)][draw(random)>>13]
                p.target.x += Double(draw(random)>>5)-512;p.target.z += Double(draw(random)>>5)-512
                p.turnTarget=draw(random)<16385 ? -1:1
            }
            bombers[i]=p
        }
        for i in cobras.indices where cobras[i].visible && (!deathsOnly || cobras[i].isDying) {
            var p=cobras[i];updateCobra(&p,ground:terrainHeight,random:random,smokeTick:smoke4,events:&events,onCrashVisual:onCrashVisual)
            cobraPhysics(&p,phases:phases)
            if p.state < 13, let helicopterAltitude {
                p.position.y = helicopterAltitude(p.position, p.eulerDegrees.y, p.speed, false, &p.terrainLift)
            }
            if p.state==1&&(abs(p.position.x)>20000||abs(p.position.z)>20000) {
                p.state=2;p.turnTarget=draw(random)<16385 ? -2:2
                p.target.x=Double(draw(random)>>4)-1024;p.target.z=Double(draw(random)>>4)-1024
            }
            cobras[i]=p
        }
        ticks += 1;return events
    }
    // Call AFTER hit processing. These launches are in the original projectile
    // function, not inside the AI pass; their RNG must likewise remain deferred.
    func takeShots(random:()->UInt32,allocateBulletSlot:(()->Int)?=nil)->[Shot] {
        var shots:[Shot]=[]
        for kind in [Kind.cobra,.bomber,.jet] {
            for i in 0..<(kind == .cobra ? cobras.count:kind == .bomber ? bombers.count:jets.count) {
                var p=kind == .cobra ? cobras[i]:kind == .bomber ? bombers[i]:jets[i]
                // Source generic object rotation precedes the aircraft launch loops.
                if p.visible {p.eulerDegrees.z += p.rollIncrementDegrees}
                if p.pendingFire>0 {
                    let f=rotate(SIMD3(0,0,-1),p.eulerDegrees),up=rotate(SIMD3(0,1,0),p.eulerDegrees),right=rotate(SIMD3(1,0,0),p.eulerDegrees)
                    if p.pendingFire==1 {
                        let origin=p.position+f*(kind == .cobra ? 601:801)+up*(kind == .cobra ? -190:-50)
                        let shift=kind == .cobra ? 8:9,offset=kind == .cobra ? 64:32
                        let delta=p.target+SIMD3(Double((draw(random)>>shift)-offset),Double((draw(random)>>shift)-offset),Double((draw(random)>>shift)-offset))-origin
                        let slot=allocateBulletSlot?() ?? nextBullet;nextBullet=(nextBullet+1)%80
                        shots.append(Shot(kind:.bullet,poolIndex:slot,sourceIndex:p.sourceIndex,originalEmitterObject:p.objectID,origin:origin,
                            velocity:normalized(delta)*400,lifetimeTicks:nil,bombHorizontalSpeed:nil,bombForward:nil))
                    } else if p.pendingFire==2&&kind == .cobra {
                        let origin=p.position+up * -165+right*(nextRocket%2==1 ? -105:105)
                        shots.append(Shot(kind:.airRocket,poolIndex:nextRocket,sourceIndex:p.sourceIndex,originalEmitterObject:p.objectID,
                            origin:origin,velocity:f*280,lifetimeTicks:100,bombHorizontalSpeed:nil,bombForward:nil));nextRocket=(nextRocket+1)%12
                    } else if p.pendingFire==2 {
                        let side:Double=(nextBomb%2==1 ? -1:1)*(kind == .jet ? 30:50),origin=p.position+right*side
                        shots.append(Shot(kind:.bomb,poolIndex:nextBomb,sourceIndex:p.sourceIndex,originalEmitterObject:p.objectID,
                            origin:origin,velocity:SIMD3(f.x*p.speed,0,f.z*p.speed),lifetimeTicks:nil,bombHorizontalSpeed:p.speed,bombForward:f));nextBomb=(nextBomb+1)%16
                    }
                }
                p.pendingFire=0
                if kind == .cobra {cobras[i]=p}else if kind == .bomber {bombers[i]=p}else{jets[i]=p}
            }
        }
        return shots
    }
    private func updateJet(_ p:inout Plane,ground:(Double,Double)->Double,random:()->UInt32,smokeTick:Bool,events:inout [Event],onCrashVisual:CrashVisualHandler?) {
        switch p.state {
        case 1:
            let roll=draw(random)>>6
            if roll==100&&abs(p.position.x)<20000&&abs(p.position.z)<20000 {
                p.turnTarget=(Double(draw(random)>>12)-3.5)*0.75;p.counter=(draw(random)>>9)+30;p.state=4
            }
            if roll==300&&abs(p.position.x)<20000&&abs(p.position.z)<20000 {
                p.turnTarget=Double(draw(random)>>13)-1.5;p.counter=(draw(random)>>9)+30;p.state=6
                if p.position.y>6000 {p.pitchTarget = -1};if p.position.y<4000 {p.pitchTarget=1}
            }
            if roll==400 {p.target.y=Double(draw(random)>>4)+2000;p.pitchTarget=p.target.y<=p.position.y ? -1:1;p.state=7}
            if roll>499&&roll<=jetAggression&&(abs(p.position.x)>16000||abs(p.position.z)>16000) {
                p.target=SIMD3(0,800,0);p.turnTarget=angleToTarget(p)<0 ? -2:2;p.counter=180;p.state=8
            }
        case 2:if aligned(p,threshold:0.99) {p.state=3;p.turnTarget=0}
        case 3:if abs(p.position.x)<25000&&abs(p.position.z)<25000 {p.state=1}
        case 4:p.counter -= 1;if p.counter==0 {p.state=5;p.turnTarget=0}
        case 5:
            if abs(p.eulerDegrees.x)<0.5 {p.eulerDegrees.x=0;p.state=1}
            if abs(p.eulerDegrees.x)<5 {p.eulerDegrees.x *= 0.75;p.pitchSpring=0;p.pitchTarget=0}
        case 6:
            if abs(p.eulerDegrees.x)>20 {p.pitchSpring=0;p.pitchTarget=0}
            if p.position.y<2500 {p.counter=1};p.counter -= 1
            if p.counter<1 {p.state=5;p.turnTarget=0;if p.eulerDegrees.x>1{p.pitchTarget = -1};if p.eulerDegrees.x < -1{p.pitchTarget=1}}
        case 7:
            if abs(p.eulerDegrees.x)>10 {p.pitchSpring=0;p.pitchTarget=0}
            if p.eulerDegrees.x<=0&&p.position.y<=p.target.y {p.pitchTarget=1;p.state=5}
            if p.eulerDegrees.x>0&&p.position.y>=p.target.y {p.pitchTarget = -1;p.state=5}
        case 8:
            p.counter -= 1
            if p.counter==0 {p.turnTarget=0;p.state=1}
            else if aimHeading(&p,threshold:0.5,factor:0.0625) {
                if draw(random)<8192&&p.bombs != 0 {p.state=9;p.counter=8}else{p.state=11}
            }
        case 9:if hypot(p.target.x-p.position.x,p.target.z-p.position.z)<12000 {p.state=10}
        case 10:
            if p.counter&3==0 {p.pendingFire=2;p.bombs -= 1};p.counter -= 1;if p.counter==0{p.state=1}
        case 11:
            let delta=p.target-p.position,distance=length(delta),angle = -abs(asin(clamp(delta.y/max(distance,0.00001),-1,1)))
            p.pitchTarget=angle-0.05
            if abs(p.eulerDegrees.x-angle*180 / .pi)<0.5 {p.pitchSpring=0;p.pitchTarget=0;p.state=12}
            if distance<6000||p.position.y<1800 {p.pitchTarget=1.5;p.state=13}
        case 12:
            if p.counter&1==0 {p.pendingFire=1};p.counter -= 1
            if p.counter<1 {p.pitchTarget=1;p.state=13}
            if p.position.y<1800||(p.eulerDegrees.x < -25&&p.position.y<5000) {p.pitchTarget=1.5;p.state=13}
        case 13:
            if p.eulerDegrees.x>15 {p.pitchTarget=0}
            if p.position.y>2200 {p.pitchTarget=0;p.state=6}
        case 14:
            p.turnTarget=Double(draw(random)>>13)-1.5;p.pitchTarget = -Double((draw(random)>>14)+1)
            p.rollIncrementDegrees=Double(draw(random)>>11)-7.5;p.state=15
        case 15:
            if p.eulerDegrees.x < -20 {p.pitchTarget=0}
            if smokeTick&&smokeAllowed(p) {emitSmoke(p,random:random,events:&events)}
            if p.position.y<mapGround(p.position,ground:ground)+100 {crash(&p,force:-10,score:10,playerDamage:true,events:&events,onCrashVisual:onCrashVisual)}
        default:break
        }
    }
    private func updateBomber(_ p:inout Plane,ground:(Double,Double)->Double,random:()->UInt32,smokeTick:Bool,events:inout [Event],onCrashVisual:CrashVisualHandler?) {
        switch p.state {
        case 2:p.counter -= 1;if p.counter==0 {p.turnTarget=0;p.state=1}
        case 3:
            p.counter -= 1
            if p.counter==0 {p.turnTarget=0;p.state=1}
            else if aimHeading(&p,threshold:0.1,factor:0.03125) {p.state=4;p.counter=32}
        case 4:if hypot(p.target.x-p.position.x,p.target.z-p.position.z)<12500 {p.state=5}
        case 5:if p.counter&7==0 {p.pendingFire=2};p.counter -= 1;if p.counter==0{p.state=1}
        case 6:
            p.turnTarget=Double(draw(random)>>14)-0.5;p.pitchTarget = -Double((draw(random)>>14)+1)
            p.rollIncrementDegrees=Double(draw(random)>>13)-1.5;p.state=7
        case 7:
            if p.eulerDegrees.x < -30 {p.pitchTarget=0}
            if p.position.y<mapGround(p.position,ground:ground)+100 {crash(&p,force:0,score:5,playerDamage:false,events:&events,onCrashVisual:onCrashVisual)}
            if smokeTick&&smokeAllowed(p) {emitSmoke(p,random:random,events:&events)}
        default:break
        }
    }
    private func updateCobra(_ p:inout Plane,ground:(Double,Double)->Double,random:()->UInt32,smokeTick:Bool,events:inout [Event],onCrashVisual:CrashVisualHandler?) {
        switch p.state {
        case 1:
            let roll=draw(random)>>7
            if roll==20&&abs(p.position.x)<15000&&abs(p.position.z)<15000 {p.turnTarget=Double(draw(random)>>13)-1.5;p.counter=(draw(random)>>7)+30;p.state=4}
            if roll==30 {p.target.y=Double(draw(random)>>5)+1000;p.verticalAcceleration=p.target.y<=p.position.y ? -1:1;p.state=5}
            if roll>39&&roll<=cobraAggression&&abs(p.position.x)<=12000&&p.position.z<=3000&&p.position.z >= -12000&&(abs(p.position.x)>4000||abs(p.position.z)>4000)&&p.speed>=130 {
                p.target.x=0;p.target.z=0;p.turnTarget=angleToTarget(p)<0 ? -2:2;p.pitchTarget=25;p.acceleration = -2;p.state=10
            }
            if roll>49&&roll<54&&(abs(p.position.x)>10000||abs(p.position.z)>10000)&&p.speed>=130 {
                p.target.x=0;p.target.z=0;p.turnTarget=angleToTarget(p)<0 ? -2:2;p.counter=150;p.state=8
            }
        case 2:if aligned(p,threshold:0.98) {p.state=3;p.turnTarget=0}
        case 3:if abs(p.position.x)<20000&&abs(p.position.z)<20000 {p.state=1}
        case 4:p.counter -= 1;if p.counter==0 {p.state=1;p.turnTarget=0}
        case 5:p.verticalAcceleration=0;p.state=1 // original <= and >= are exhaustive
        case 6:p.counter -= 1;if p.counter==0 {p.counter=60;p.acceleration=2;p.pitchTarget = -25;p.state=7}
        case 7:p.counter -= 1;if p.counter==0 {p.state=1}
        case 8:
            p.counter -= 1
            if p.counter==0 {p.turnTarget=0;p.state=1}
            else if aimHeading(&p,threshold:0.5,factor:0.0625) {p.state=9;p.counter=32}
        case 9:if p.counter&7==0 {p.pendingFire=2};p.counter -= 1;if p.counter==0 {p.state=1}
        case 10:if aimHeading(&p,threshold:0.5,factor:0.0625) {p.state=11;p.counter=(draw(random)>>9)+60}
        case 11:
            p.counter -= 1
            if p.counter==0 {
                p.target=SIMD3(Double(draw(random)>>7)-128,Double(draw(random)>>7)+672,Double(draw(random)>>7)-128)
                p.counter=(draw(random)>>10)+16;p.state=12
            }
        case 12:
            if p.counter&3==0 {p.pendingFire=1};p.counter -= 1
            if p.counter==0 {p.counter=60;p.acceleration=2;p.pitchTarget = -25;p.state=7}
        case 13:
            p.acceleration = -1;p.verticalAcceleration = -1;p.turnTarget=Double(draw(random)>>13)
            p.pitchTarget=Double((draw(random)>>10)-16);p.state=14;p.fallSpeed=0
        case 14:
            p.rotorDegreesPerTick=max(20,p.rotorDegreesPerTick-0.25);p.fallSpeed -= 1;p.position.y += p.fallSpeed
            let surface = helicopterGround?(p.position.x,p.position.z) ?? mapGround(p.position,ground:ground)
            if p.position.y<surface+200 {crash(&p,force:-10,score:10,playerDamage:true,events:&events,onCrashVisual:onCrashVisual)}
            if smokeTick&&smokeAllowed(p) {emitSmoke(p,random:random,events:&events)}
        default:break
        }
    }
    private func fixedWingPhysics(_ p:inout Plane,roll:Double) {
        p.turn=p.turnTarget*0.08+p.turn*0.92;p.pitchSpring=p.pitchTarget*0.08+p.pitchSpring*0.92
        p.eulerDegrees.z=p.turn*roll;p.eulerDegrees.x += p.pitchSpring;p.eulerDegrees.y=wrap(p.eulerDegrees.y+p.turn)
        p.forward=rotate(SIMD3(0,0,-1),p.eulerDegrees);p.position += p.forward*p.speed
    }
    private func cobraPhysics(_ p:inout Plane,phases:SIMD4<Double>) {
        p.turn=p.turnTarget*0.05+p.turn*0.95;p.pitchSpring=p.pitchTarget*0.05+p.pitchSpring*0.95
        if (p.state<8||p.state>9)&&abs(p.pitchSpring)>22 {p.pitchTarget=0}
        p.eulerDegrees.x=p.speed * -0.05+p.pitchSpring
        let previous=p.eulerDegrees.y;p.eulerDegrees.y=wrap(previous+p.turn);p.eulerDegrees.z=(p.eulerDegrees.y-previous)*p.speed*0.215
        if p.speed<30 {
            let phases=phases * (.pi/180),a=sin(phases.x),b=sin(phases.y),c=sin(phases.z),d=sin(phases.w),weight=1/(p.speed+1)
            p.eulerDegrees.z += (c+d)*weight*2;p.eulerDegrees.x += (a+b+c)*weight*1.5
            p.position += SIMD3((a+c)*weight*2,(a+b)*weight*2,(b+c)*weight*2)
        }
        p.forward=rotate(SIMD3(0,0,-1),p.eulerDegrees);p.speed += p.acceleration
        if p.speed>140 {p.speed=140;p.acceleration=0};if p.speed<0 {p.speed=0;p.acceleration=0}
        p.position.x += p.forward.x*p.speed;p.position.z += p.forward.z*p.speed
        p.verticalSpeed=p.verticalAcceleration*0.1+p.verticalSpeed*0.9
        p.position.y += p.forward.y*p.verticalSpeed // original unusual product, not forward.y*speed
    }
    private func aimHeading(_ p:inout Plane,threshold:Double,factor:Double)->Bool {
        let angle=angleToTarget(p)
        if abs(angle)>=threshold {if abs(angle)<32 {p.turn=angle*factor};return false}
        p.turnTarget=0;p.turn=0;p.eulerDegrees.y=bearing(p.target-p.position);return true
    }
    private func aligned(_ p:Plane,threshold:Double)->Bool {
        let d=p.target-p.position,n=hypot(d.x,d.z)*hypot(p.forward.x,p.forward.z)
        return n>0&&(d.x*p.forward.x+d.z*p.forward.z)/n>threshold
    }
    private func crash(_ p:inout Plane,force:Int,score:Int,playerDamage:Bool,events:inout [Event],onCrashVisual:CrashVisualHandler?) {
        p.visible=false;p.pendingFire=0;p.counter=5
        // Preserve the trigger pose: the source still performs physics after
        // this switch. Reading the final array in a deferred event is too late.
        onCrashVisual?(p.kind.rawValue.uppercased(),p.objectID,p.position,p.eulerDegrees)
        events.append(.removed(sourceIndex:p.sourceIndex,objectID:p.objectID));events.append(.forceAndScore(sourceIndex:p.sourceIndex,force:force,score:score))
        if abs(p.position.x)>400||abs(p.position.z)>400 {events.append(.explosion(sourceIndex:p.sourceIndex,position:p.position,scale:4))}
        if playerDamage&&abs(p.position.x)<300&&abs(p.position.z)<300 {events.append(.defenseChanged(-5))}
    }
    private func emitSmoke(_ p:Plane,random:()->UInt32,events:inout [Event]) {
        let position=p.position+SIMD3(Double((draw(random)>>8)-64),Double((draw(random)>>9)-32),Double((draw(random)>>8)-64))
        events.append(.smoke(sourceIndex:p.sourceIndex,position:position))
    }
    private func smokeAllowed(_ p:Plane)->Bool {abs(p.position.x)>400||abs(p.position.z)>400||p.position.y>1200}
    private func mapGround(_ p:SIMD3<Double>,ground:(Double,Double)->Double)->Double {abs(p.x)<15000&&abs(p.z)<7500 ? ground(p.x,p.z):0}
    private func angleToTarget(_ p:Plane)->Double {wrap(bearing(p.target-p.position)-p.eulerDegrees.y)}
    private func bearing(_ d:SIMD3<Double>)->Double {atan2(-d.x,-d.z)*180 / .pi}
    private func wrap(_ a:Double)->Double {var a=a;while a>180 {a-=360};while a < -180 {a+=360};return a}
    private func length(_ a:SIMD3<Double>)->Double {sqrt(a.x*a.x+a.y*a.y+a.z*a.z)}
    private func normalized(_ a:SIMD3<Double>)->SIMD3<Double> {let n=length(a);return n>0 ? a/n:.zero}
    private func clamp(_ a:Double,_ lo:Double,_ hi:Double)->Double {min(hi,max(lo,a))}
    private func draw(_ random:()->UInt32)->Int {let n=random();precondition(n<=32767);return Int(n)}
    private func rotate(_ p:SIMD3<Double>,_ degrees:SIMD3<Double>)->SIMD3<Double> {
        let a=degrees * (.pi/180),cx=cos(a.x),sx=sin(a.x),cy=cos(a.y),sy=sin(a.y),cz=cos(a.z),sz=sin(a.z)
        let r=SIMD3(p.x*cz-p.y*sz,p.x*sz+p.y*cz,p.z),q=SIMD3(r.x,r.y*cx-r.z*sx,r.y*sx+r.z*cx)
        return SIMD3(q.x*cy+q.z*sy,q.y,q.z*cy-q.x*sy)
    }
}

extension Original2000AircraftAI {
    struct TestFailure:Error,CustomStringConvertible {let description:String}
    static func runTests() throws {
        func check(_ value:@autoclosure()->Bool,_ message:String)throws {if !value(){throw TestFailure(description:message)}}
        var seed:UInt32=11
        func random()->UInt32 {seed=seed &* 214013 &+ 2531011;return(seed>>16)&32767}
        let flat:(Double,Double)->Double={_,_ in 0}
        let all=(0..<12).map{Declaration(kind:.jet,slot:$0,sourceIndex:$0,active:true)} +
            (0..<6).map{Declaration(kind:.cobra,slot:$0,sourceIndex:20+$0,active:true)} +
            (0..<3).map{Declaration(kind:.bomber,slot:$0,sourceIndex:30+$0,active:true)}
        let ai=Original2000AircraftAI(declarations:all,aggression:[100,11,15,0],random:random)
        try check(ai.jets.allSatisfy{(160...191).contains($0.speed)&&$0.hp==4&&$0.bombs==2},"Original12 jet speed/HP/bomb initialization")
        try check(ai.bombers.map{$0.position.y}==[6000,7500,9000],"Original three bomber flight levels")
        let initial=Original2000AircraftAI(declarations:[],aggression:[],random:random)
        let originalPosition=initial.jets[0].position,originalSeed=seed
        initial.activate(kind:.jet,slot:0,sourceIndex:50,random:random,resetForRevive:false)
        try check(initial.jets[0].visible && initial.jets[0].position==originalPosition && seed==originalSeed,"Initial visible declaration does not randomize level position twice")
        var shotsByEmitter:[Kind:Int]=[:],kinds:Set<WeaponKind>=[]
        for _ in 0..<10000 {
            _=ai.tick(terrainHeight:flat,random:random)
            for s in ai.takeShots(random:random) {
                let kind:Kind=s.originalEmitterObject<76 ? .bomber:s.originalEmitterObject<88 ? .jet:.cobra
                shotsByEmitter[kind,default:0] += 1;kinds.insert(s.kind)
                try check(s.origin.x.isFinite&&s.origin.y.isFinite&&s.origin.z.isFinite,"Aircraft launch coordinates stay finite")
                if s.kind == .bullet {try check(abs(ai.length(s.velocity)-400)<0.00001,"Aircraft machine gun speed400")}
                if s.kind == .airRocket {try check(abs(ai.length(s.velocity)-280)<0.00001&&s.lifetimeTicks==100,"Cobra rocket speed280/lifetime100")}
                if s.kind == .bomb {try check(s.bombForward != nil&&s.bombHorizontalSpeed != nil&&s.velocity.y==0,"Aircraft bomb retains forward and scalar speed")}
            }
        }
        try check(Kind.allTestKinds.allSatisfy{shotsByEmitter[$0,default:0]>0}&&kinds.count==3,"All original aircraft types reach their gun/bomb/rocket attack FSMs")
        let last=Original2000AircraftAI(declarations:[],aggression:[],random:random)
        last.jets[0].visible=true;last.jets[0].sourceIndex=700;last.jets[0].pendingFire=1
        last.jets[0].position = .zero;last.jets[0].eulerDegrees=SIMD3(0,180,0);last.jets[0].target=SIMD3(0,800,3000)
        last.applyDamage(objectID:76,hp:0,state:14,visible:false)
        let finalShot=last.takeShots(random:{16384},allocateBulletSlot:{79})
        try check(finalShot.count==1&&finalShot[0].poolIndex==79&&finalShot[0].origin.y == -50&&abs(finalShot[0].origin.z-801)<0.00001,"Destroyed aircraft preserves same-tick pending shot and shared bullet allocator")
        try check(last.takeShots(random:random).isEmpty,"Pending shot consumed once")
        let rings=Original2000AircraftAI(declarations:[],aggression:[],random:random)
        var rocketSlots:[Int]=[],bombSlots:[Int]=[]
        for _ in 0..<20 {
            rings.cobras[0].pendingFire=2;rings.bombers[0].pendingFire=2;rings.jets[0].pendingFire=2
            let shots=rings.takeShots(random:random)
            try check(shots.map(\.originalEmitterObject)==[88,73,76],"Original projectile loop order Cobra,B52,Jet")
            rocketSlots += shots.filter{$0.kind == .airRocket}.map(\.poolIndex)
            bombSlots += shots.filter{$0.kind == .bomb}.map(\.poolIndex)
        }
        try check(rocketSlots==Array(0..<12)+Array(0..<8)&&bombSlots==Array(0..<16)+Array(0..<16)+Array(0..<8),"One shared12 rocket and16 bomb ring across all aircraft")
        let crashOrder=Original2000AircraftAI(declarations:[.init(kind:.jet,slot:0,sourceIndex:900,active:true),
            .init(kind:.jet,slot:1,sourceIndex:901,active:true)],aggression:[],random:{16384})
        crashOrder.jets[0].state=15;crashOrder.jets[0].position=SIMD3(1000,50,0)
        crashOrder.jets[0].eulerDegrees = .zero;crashOrder.jets[0].speed=100
        crashOrder.jets[1].state=14
        var crashDraws=0,visualCalls=0,drawsAtVisual = -1
        var crashPose=SIMD3<Double>.zero
        func crashRandom()->UInt32 {defer{crashDraws+=1};return UInt32(crashDraws*2048)}
        let crashEvents=crashOrder.tick(terrainHeight:flat,random:crashRandom,
            smokeEveryTwoTicks:false,smokeEveryFourTicks:false,onCrashVisual:{type,id,p,r in
                visualCalls+=1;drawsAtVisual=crashDraws;crashPose=p
                // A fragment renderer draws here, before Jet1's crash setup.
                for _ in 0..<6 {_=crashRandom()}
            })
        try check(visualCalls==1 && drawsAtVisual==0 && crashDraws==9,
                  "crash fragment RNG precedes next aircraft's three setup draws")
        try check(crashPose==SIMD3(1000,50,0) && crashOrder.jets[0].position != crashPose,
                  "crash callback carries trigger pose before the source's trailing physics")
        try check(crashEvents.filter {if case .removed(_,76)=$0{return true};return false}.count==1,
                  "synchronous crash visual retains exactly one normal removal event")
        _=crashOrder.tick(terrainHeight:flat,random:{16384},smokeEveryTwoTicks:false,smokeEveryFourTicks:false,
                         onCrashVisual:{_,id,_,_ in if id==76 {visualCalls+=1}})
        try check(visualCalls==1,"hidden crashed aircraft never emits a second crash visual")
        for kind in Kind.allTestKinds {
            let one=Original2000AircraftAI(declarations:[Declaration(kind:kind,slot:0,sourceIndex:99,active:true)],aggression:[],random:random)
            let id=kind == .jet ? 76:kind == .bomber ? 73:88,state=kind == .jet ? 14:kind == .bomber ? 6:13
            one.applyDamage(objectID:id,hp:0,state:state,visible:true)
            var force=0,score=0
            for _ in 0..<2000 {
                for event in one.tick(terrainHeight:flat,random:random) {if case .forceAndScore(_,let f,let s)=event {force += f;score += s}}
                _=one.takeShots(random:random)
            }
            try check(force==(kind == .bomber ? 0:-10)&&score==(kind == .bomber ? 5:10),"Original delayed aircraft crash force/score occurs exactly once")
            one.activate(kind:kind,slot:0,sourceIndex:100,random:random)
            let plane=kind == .jet ? one.jets[0]:kind == .bomber ? one.bombers[0]:one.cobras[0]
            try check(plane.visible&&plane.state==1&&plane.hp==(kind == .jet ? 4:8)&&plane.sourceIndex==100,"Scheduler revive reuses exact original slot and source attribution")
        }
    }
}
private extension Original2000AircraftAI.Kind {static var allTestKinds:[Self] {[.jet,.bomber,.cobra]}}
#if ORIGINAL2000_AIRCRAFT_AI_TESTS
@main private struct Original2000AircraftTests {
    static func main() throws {try Original2000AircraftAI.runTests();print("PASS: BH2000 aircraft FSMs, fire cadence, shared pools, launch geometry, crash score/force and revive")}
}
#endif
