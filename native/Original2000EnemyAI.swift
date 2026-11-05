import Foundation

// Original BH2000 landing craft + infantry simulation, in ORIGINAL world units
// and degrees, one tick per original update. Source:
// analysis/bh2000/full-decompile/functions/0x404b24.c:68...104,269...334;
// 0x406805.c:201...238,3293...4518; 0x416a09.c:2983...3046.
// No SceneKit and no invented periodic damage. Boats stop in state4; there is
// no departure branch in the original landing-craft switch.
//
// Init once per level, including delayed declarations. It randomizes all12
// original craft slots for the original separation calculation. Other original
// unit initializers also consume RNG; a complete game must preserve their call
// order if it requires a bit-identical replay, not merely the recovered rules.
// let ai = Original2000EnemyAI(bargeDeclarations:[.init(slot:0,sourceIndex:0,active:true)], random:{rng.next()})
// ai.activateBarge(slot:slot,sourceIndex:sourceIndex) // campaign delayed wave
// let events=ai.tick(terrainHeight:sourceHeight,viewPitchDegrees:pitch,
//                   vehicleNeighbors:[],random:{rng.next()},soundEnabled:true)
// Synchronize visible ai.boats and ai.soldiers into the scene, scaling XYZ .01.
// Barge ramp is objectID+12 and uses boat.rampPitchDegrees.
// Soldier sprite frames: native-assets-2000/frames/Soldiers128x22240/%03d.keyed.png
// Frames0...138 are exported. The geometry's Animated count75 is only its
// automatic-loop declaration; original AI explicitly selects death frames75+.
//
// destroyBarge(slot:) hides the hull. On the next tick, still attached soldiers
// state<4 disappear with force-1/score+1 each; shore troops survive. Hull score
// belongs to OriginalDamage. killSoldier changes animation only: the caller
// already applied the projectile's immediate score/force. Do not apply both.
// A standard corpse remains until original player pitch>20 degrees.
// Grenade events contain original launch position/velocity and pool index0...7;
// the projectile system owns subsequent gravity/collision/damage.
//
// This module ports craft, infantry, TANK, APC and CH53 FSMs. Optional declaration
// arrays preserve fixed slots; delayed activation is explicit. Projectile code
// feeds OriginalDamage HP/state/visibility back through applyVehicleDamage.
// CH53 does not fire. .tankShell supplies original400-unit/tick launch velocity.
// terrainHeight should sample nearest source height; terrainBilinearHeight is
// used for the four ground-vehicle contact corners. Global hover phases advance
// (4.1,6,9.5,12.2) degrees per original main-loop tick; smokeTick means tick%4==0.
// Pass those globals to preserve phase across levels. Defaults start at zero.
final class Original2000EnemyAI {
    typealias CrashVisualHandler = (String, Int, SIMD3<Double>, SIMD3<Double>) -> Void
    struct BargeDeclaration { let slot:Int, sourceIndex:Int; let active:Bool }
    enum VehicleKind {case tank,apc}
    struct VehicleDeclaration {let kind:VehicleKind,slot:Int,sourceIndex:Int;let active:Bool}
    struct HelicopterDeclaration {let slot:Int,sourceIndex:Int;let active:Bool}
    struct GroundVehicle {
        let kind:VehicleKind,slot:Int
        var sourceIndex = -1,visible=false,hp=1,state=0,counter=0
        var position=SIMD3<Double>(0,40,0),eulerDegrees=SIMD3<Double>(0,180,0)
        var speed:Double=0,acceleration:Double=0,turn:Double=0,turnTarget:Double=0
        var target=SIMD3<Double>.zero
        var turretYawDegrees:Double=0,barrelPitchDegrees:Double=0,rampPitchDegrees:Double=0
        var firePending=false
        var objectID:Int {(kind == .tank ? 37:61)+slot}
        var boatSlot:Int {(kind == .tank ? 6:9)+slot}
        var forward:SIMD2<Double> {SIMD2(-sin(eulerDegrees.y * .pi/180),-cos(eulerDegrees.y * .pi/180))}
    }
    struct Helicopter {
        let slot:Int
        var sourceIndex = -1,visible=false,hp=12,state=1,counter=0
        var position=SIMD3<Double>.zero,eulerDegrees=SIMD3<Double>(0,180,0)
        var target=SIMD3<Double>(99999,0,0)
        var speed:Double=140,acceleration:Double=0,turn:Double=0,turnTarget:Double=0
        var pitchSpring:Double=0,pitchTarget:Double=0,verticalSpeed:Double=0,verticalAcceleration:Double=0
        var fallSpeed:Double=0,rampPitchDegrees:Double=0,rotorDegreesPerTick:Double=25
        var terrainLift = 0.0
        var forward=SIMD3<Double>(0,0,1)
        var objectID:Int {106+slot}
    }
    struct VehicleShot:Equatable {
        let poolIndex:Int,sourceIndex:Int,objectID:Int
        let position:SIMD3<Double>,velocity:SIMD3<Double>
    }
    struct Boat {
        let slot:Int
        var sourceIndex = -1
        var objectID:Int {11+slot}
        var visible=false
        var position=SIMD3<Double>.zero
        var yawDegrees:Double=180
        var state=1
        var speed:Double=30
        var stopZ:Double=0
        var rampPitchDegrees:Double=0
        var rampStep:Double=2
        var hasInfantry:Bool {slot<6}
    }
    struct Soldier {
        struct BurningVisual {
            let position:SIMD3<Double>
            let horizontalScale:Double,verticalScale:Double
        }
        let slot:Int
        var sourceIndex = -1
        var visible=false
        var position=SIMD3<Double>.zero
        var direction=SIMD2<Double>.zero
        var state=1, nextState=6, counter=0, frame=0
        var apcExit: DepthlineAPCExit?
        var scale:Double=1
        var fireHeight:Double=0.5
        var fireYOffset:Double=0
        var isBurning=false
        //0x406805:4497...4515: fire shifts2 units toward zero and initially
        //stands80 above the foot; states46/47 lower it,48 shrinks only height.
        var burningVisual:BurningVisual? {
            guard visible && isBurning else {return nil}
            return .init(position:SIMD3(position.x+(position.x<0 ? 2:-2),position.y+80+fireYOffset,position.z+(position.z<0 ? 2:-2)),horizontalScale:0.25,verticalScale:fireHeight)
        }
        var texturePath:String {String(format:"frames/Soldiers128x22240/%03d.keyed.png",frame)}
        var onGround:Bool {state>3 && state<60}
    }
    struct Neighbor {
        let objectID:Int, position:SIMD3<Double>, speed:Double, forward:SIMD2<Double>
    }
    struct Shot:Equatable {
        let poolIndex:Int, sourceIndex:Int, soldierSlot:Int
        let position:SIMD3<Double>, velocity:SIMD3<Double>
    }
    enum Event:Equatable {
        case defenseChanged(Int)
        case forceAndScore(sourceIndex:Int, force:Int, score:Int)
        case rifleFlash(sourceIndex:Int, soldierSlot:Int, position:SIMD3<Double>)
        case grenade(Shot)
        case playerHurtVoice(Int)
        case soldierRemoved(sourceIndex:Int,slot:Int)
        case tankShell(VehicleShot)
        case vehicleRemoved(sourceIndex:Int,objectID:Int)
        case explosion(sourceIndex:Int,position:SIMD3<Double>,scale:Double)
        case smoke(sourceIndex:Int,position:SIMD3<Double>)
    }
    enum CarrierKind {case apc,ch53}
    private(set) var boats=(0..<12).map {Boat(slot:$0)}
    private(set) var soldiers=(0..<84).map {Soldier(slot:$0)}
    private(set) var tanks=(0..<6).map {GroundVehicle(kind:.tank,slot:$0)}
    private(set) var apcs=(0..<3).map {GroundVehicle(kind:.apc,slot:$0)}
    private(set) var helicopters=(0..<3).map {Helicopter(slot:$0)}
    var usesDepthlineAPCExit = false
    var helicopterAltitude: ((SIMD3<Double>, Double, Double, Bool, inout Double) -> Double)?
    var helicopterGround: ((Double, Double) -> Double)?
    private var nextGrenade=0
    private var nextTankShell=0
    private let tankAggression:Int
    private var ticks=0

    init(bargeDeclarations:[BargeDeclaration],vehicleDeclarations:[VehicleDeclaration]=[],
         helicopterDeclarations:[HelicopterDeclaration]=[],aggression:[Int]=[0,0,0,0],
         beachZ:((Double)->Double)?=nil,random:()->UInt32) {
        tankAggression=(aggression.first ?? 0)+320
        precondition(Set(bargeDeclarations.map(\.slot)).count==bargeDeclarations.count)
        for i in boats.indices {
            boats[i].position.z=Double(draw(random)>>3)-13000
            boats[i].stopZ=Double(draw(random)>>5)-7500
            var candidate:Double
            repeat {candidate=Double(draw(random)>>1)-8192}
            while boats.indices.contains(where:{$0 != i && abs(boats[$0].position.x-candidate)<400})
            boats[i].position.x=candidate
            if let beachZ {
                // The ramp is 4.3 m (troops) or 6 m (vehicle) ahead of the pivot.
                // Allow for the final braking drift. Move the entire approach leg,
                // so launch-to-landing time and the shared random stream stay intact.
                let oldStop=boats[i].stopZ
                let rampOffset=boats[i].hasInfantry ? 510.0:680.0
                let variation=(oldStop+6990)*0.04
                boats[i].stopZ=beachZ(candidate)-rampOffset+variation
                boats[i].position.z+=boats[i].stopZ-oldStop
            }
        }
        for i in soldiers.indices {
            soldiers[i].frame=i%12
            if i<48 {
                let boat=boats[i/8]
                soldiers[i].position=SIMD3(boat.position.x+(i%8<4 ? -80:80),40,
                    boat.position.z+Double([-200,0,200,400][i%4]))
            } else {
                soldiers[i].state=i<66 ? 60:61
            }
        }
        for declaration in bargeDeclarations {
            precondition((0..<12).contains(declaration.slot))
            boats[declaration.slot].sourceIndex=declaration.sourceIndex
            if declaration.active {activateBarge(slot:declaration.slot,sourceIndex:declaration.sourceIndex)}
        }
        for d in vehicleDeclarations {activateVehicle(kind:d.kind,slot:d.slot,sourceIndex:d.sourceIndex,visible:d.active)}
        // These initial positions are randomized for all three original slots.
        for i in helicopters.indices {
            helicopters[i].position=SIMD3(Double(draw(random)-16384)*1.5,Double(draw(random)>>6)+2500,Double(draw(random)>>1)-40000)
        }
        for d in helicopterDeclarations {activateHelicopter(slot:d.slot,sourceIndex:d.sourceIndex,visible:d.active)}
    }

    func activateBarge(slot:Int,sourceIndex:Int) {
        precondition(boats.indices.contains(slot))
        boats[slot].visible=true;boats[slot].sourceIndex=sourceIndex
        if slot<6 {for i in slot*8..<slot*8+8 {soldiers[i].visible=true;soldiers[i].sourceIndex=sourceIndex}}
    }
    func destroyBarge(slot:Int) {if boats.indices.contains(slot) {boats[slot].visible=false}}
    func activateVehicle(kind:VehicleKind,slot:Int,sourceIndex:Int,visible:Bool=true) {
        if kind == .tank {precondition(tanks.indices.contains(slot));tanks[slot].sourceIndex=sourceIndex;tanks[slot].visible=visible;tanks[slot].hp=1}
        else {precondition(apcs.indices.contains(slot));apcs[slot].sourceIndex=sourceIndex;apcs[slot].visible=visible;apcs[slot].hp=1
            for n in slot*6+48..<slot*6+54 {soldiers[n].sourceIndex=sourceIndex}}
    }
    func activateHelicopter(slot:Int,sourceIndex:Int,visible:Bool=true) {
        precondition(helicopters.indices.contains(slot));helicopters[slot].sourceIndex=sourceIndex;helicopters[slot].visible=visible
        for n in slot*6+66..<slot*6+72 {soldiers[n].sourceIndex=sourceIndex}
    }
    /// Feed back OriginalDamage's state/HP/active result; it owns immediate score.
    func applyVehicleDamage(objectID:Int,hp:Int,state:Int,visible:Bool) {
        if (37..<43).contains(objectID) {
            let i=objectID-37;tanks[i].hp=hp;tanks[i].state=state;tanks[i].visible=visible
            if state==20 {tanks[i].acceleration = -1;tanks[i].barrelPitchDegrees = -20}
        }
        if (61..<64).contains(objectID) {
            let i=objectID-61;apcs[i].hp=hp;apcs[i].state=state;apcs[i].visible=visible
            if state==20 {apcs[i].acceleration = -1}
        }
        if (106..<109).contains(objectID) {let i=objectID-106;helicopters[i].hp=hp;helicopters[i].state=state;helicopters[i].visible=visible}
    }

    /// Projectile code owns score/force. Ordinary hits preserve the original
    /// previous state so standing/crouching/sideways death animation is selected.
    func killSoldier(slot:Int,animated:Bool=true) {
        guard soldiers.indices.contains(slot),soldiers[slot].visible else{return}
        if animated {soldiers[slot].nextState=soldiers[slot].state;soldiers[slot].state=21}
        else {soldiers[slot].visible=false}
        if soldiers[slot].apcExit != nil {
            soldiers[slot].apcExit = nil
            if !animated { soldiers[slot].state = 25 }
        }
        soldiers[slot].isBurning=false
    }

    /// Original vehicle explosion burn selection (0x416a09:2983...3046).
    /// Returns force/score once for each newly affected living infantry sprite.
    func burnInfantry(near position:SIMD3<Double>,random:()->UInt32)->[Event] {
        var events:[Event]=[]
        for i in soldiers.indices where soldiers[i].visible {
            let state=soldiers[i].state
            guard ((5..<21).contains(state)||(26..<32).contains(state)),
                  hypot(soldiers[i].position.x-position.x,soldiers[i].position.z-position.z)<600 else{continue}
            events.append(.forceAndScore(sourceIndex:soldiers[i].sourceIndex,force:-1,score:1))
            var burning=false
            if state<26 {
                if (9..<11).contains(state)||(13..<21).contains(state) {killSoldier(slot:i)}
                if state==11 {soldiers[i].state=40;burning=true}
                if state==12 {soldiers[i].state=41;burning=true}
                if state<9 {soldiers[i].state=43;burning=true}
            } else {
                if (29..<31).contains(state)||state==26 {killSoldier(slot:i)}
                if (27..<29).contains(state) {soldiers[i].state=38;burning=true}
                if state==31 {soldiers[i].state=45;burning=true}
            }
            if burning {soldiers[i].isBurning=true;soldiers[i].fireHeight=0.5;soldiers[i].counter=(draw(random)>>12)+4}
        }
        return events
    }

    func tick(terrainHeight:(Double,Double)->Double,viewPitchDegrees:Double,
              vehicleNeighbors:[Neighbor]=[],random:()->UInt32,soundEnabled:Bool=true,
              hoverPhasesDegrees:SIMD4<Double>?=nil,smokeTick:Bool?=nil,
              terrainBilinearHeight:((Double,Double)->Double)?=nil,
              betweenGroundAndHelicopters:(()->Void)?=nil,
              betweenHelicoptersAndInfantry:(()->Void)?=nil,onCrashVisual:CrashVisualHandler?=nil)->[Event] {
        var events:[Event]=[]
        for i in boats.indices where boats[i].visible {
            switch boats[i].state {
            case 1:
                if boats[i].position.z<=boats[i].stopZ {boats[i].position.z += boats[i].speed}
                else {boats[i].state=2}
            case 2:
                boats[i].speed -= 5
                if boats[i].speed>0 {boats[i].position.z += boats[i].speed}
                else {boats[i].state=3;boats[i].rampStep=2}
            case 3:
                boats[i].rampPitchDegrees -= boats[i].rampStep;boats[i].rampStep += 1
                if boats[i].rampPitchDegrees < -80 {boats[i].rampPitchDegrees = -80;boats[i].state=4}
            default:break
            }
        }
        updateGroundVehicles(random:random,events:&events)
        // Original type order is boat,TANK,APC,JET,B52,COBRA,CH53,C130,infantry.
        // These hooks let the adapter interleave independent aircraft/supply
        // modules without changing the original shared-RNG update order.
        betweenGroundAndHelicopters?()
        updateHelicopters(terrainHeight:terrainHeight,random:random,events:&events,
            phases:hoverPhasesDegrees ?? SIMD4(4.1,6,9.5,12.2)*Double(ticks),smokeTick:smokeTick ?? (ticks%4==0),onCrashVisual:onCrashVisual)
        betweenHelicoptersAndInfantry?()
        let neighbors=vehicleNeighbors+(tanks+apcs).filter(\.visible).map {Neighbor(objectID:$0.objectID,position:$0.position,speed:$0.speed,forward:$0.forward)}
        for i in soldiers.indices where soldiers[i].visible && soldiers[i].state<60 {
            var s=soldiers[i]
            let carrier=i<48 ? boats[i/8]:nil
            switch s.state {
            case 0:break
            case 1:
                s.position.z += 30;if carrier?.state==2 {s.state=2}
            case 2:
                s.position.z += 4;if let b=carrier,s.position.z>=b.position.z+600 {s.state=3}
            case 3:
                s.position.z += 4;s.position.y -= 0.5;if s.position.y<=0 {s.state=5}
            case 5:
                aimAtCenter(&s,shift:3,offset:2048,random:random);s.state=s.nextState;advance(&s,step:1,max:10,wrap:0)
            case 6:
                if abs(s.position.x)<2500&&abs(s.position.z)<2500 {s.state=5;s.nextState=7}
                advance(&s,step:1,max:10,wrap:0)
            case 7,8:
                let old=s.state,bound=old==7 ? 1200.0:600.0
                if abs(s.position.x)>=bound||abs(s.position.z)>=bound {
                    let choice=draw(random)>>11
                    if s.frame==2&&choice==2 {s.frame=11;s.state=i%2==0 ? 9:10}
                    if s.frame==8&&choice==4 {s.direction = .zero;s.frame=47;s.state=18}
                    if old==8&&s.frame==1&&choice==6 {s.direction = .zero;s.frame=41;s.state=14}
                    if old==8&&s.frame==0&&choice==8 {s.direction = .zero;s.frame=53;s.state=17}
                    if s.state==old {advance(&s,step:1,max:10,wrap:0)}
                } else if old==7 {s.state=5;s.nextState=8}
                else {s.state=26;s.nextState=26;advance(&s,step:1,max:10,wrap:0)}
            case 9,10,34,35:
                s.frame += 1
                if s.frame==17 {s.state += 2}
            case 11,12,36,37:
                setSideDirection(&s,left:s.state==11||s.state==36)
                let stop:Bool
                if s.frame==25 {stop=s.state<13 ? draw(random)>28000:s.counter==1} else {stop=false}
                if stop {s.frame=33;s.state=13}else{advance(&s,step:1,max:32,wrap:18)}
            case 13:
                s.frame += 1;if s.frame>40 {s.frame=8;s.state=5}
            case 14,27:
                s.frame += 1;if s.frame==46 {s.counter=60;s.state += 1}
            case 15,19,28,30:
                let state=s.state;s.counter -= 1
                if s.counter==15 {
                    let distance=hypot(s.position.x,s.position.z)
                    let direction=distance>0 ? SIMD2(-s.position.x/distance,-s.position.z/distance):SIMD2<Double>.zero
                    let y=(state==15||state==28) ? 140.0:80.0
                    events.append(.rifleFlash(sourceIndex:s.sourceIndex,soldierSlot:i,
                        position:s.position+SIMD3(direction.x*20,y,direction.y*20)))
                    let roll=draw(random)
                    let hit=state==15 ? roll>28000:state==19 ? roll<4000:state==28 ? roll>24000:roll<8000
                    if hit {events.append(.defenseChanged(-1));if soundEnabled {events.append(.playerHurtVoice(draw(random)>>12))}}
                }
                if s.counter==0 {
                    if state==15 {s.state=16}else if state==19 {s.state=20}else{s.counter=(draw(random)>>10)+30}
                }
            case 16:
                s.frame -= 1;if s.frame<41 {s.frame=1;s.state=5}
            case 17,31:
                if s.state==31 {s.counter -= 1}
                if s.state==17||s.counter<1 {
                    s.frame += 1
                    if s.frame>74 {
                        if s.state==17 {s.frame=0;s.state=5}else{s.frame=53;s.counter=90}
                    }
                    if s.frame==64 {
                        let dx=Double((draw(random)>>6)-256)-s.position.x
                        let dy=Double((draw(random)>>5)+1024)-s.position.y
                        let dz=Double((draw(random)>>6)-256)-s.position.z
                        let speed=s.state==31 ? Double(draw(random)>>11)+20:40
                        let distance=sqrt(dx*dx+dy*dy+dz*dz)
                        events.append(.grenade(Shot(poolIndex:nextGrenade,sourceIndex:s.sourceIndex,soldierSlot:i,
                            position:s.position+SIMD3(0,100,0),velocity:SIMD3(dx,dy,dz)*(speed/distance))))
                        nextGrenade=(nextGrenade+1)%8
                    }
                }
            case 18,29:
                s.frame += 1;if s.frame==52 {s.counter=60;s.state += 1}
            case 20:
                s.frame -= 1;if s.frame<47 {s.frame=9;s.state=5}
            case 21:
                s.direction = .zero
                if (11...12).contains(s.nextState) {s.state=23;s.frame=94}
                else if (18...20).contains(s.nextState)||(29...30).contains(s.nextState) {s.state=24;s.frame=106}
                else {s.state=22;s.frame=75}
                // Source case21 falls through case22 even if it chose23/24.
                s.frame += 1;if s.frame==93 {s.state=25}
            case 22,23,24:
                let end=s.state==22 ? 93:s.state==23 ? 105:117
                s.frame += 1;if s.frame==end {s.state=25}
            case 25:
                if viewPitchDegrees>20 {s.visible=false;events.append(.soldierRemoved(sourceIndex:s.sourceIndex,slot:i))}
            case 26:
                let choice=draw(random)>>13
                if s.frame==1&&(choice==1||choice==2) {s.direction = .zero;s.frame=41;s.state=27}
                if s.frame==8&&choice==0 {s.direction = .zero;s.frame=47;s.state=29}
                if s.frame==0&&choice==3 {s.direction = .zero;s.frame=53;s.counter=90;s.state=31}
                if s.state==26 {advance(&s,step:1,max:10,wrap:0)}
            case 32,33:
                if s.frame==2 {s.frame=11;s.state=s.state==32 ? (i%2==0 ? 9:10):(i%2==0 ? 34:35)}
                else {advance(&s,step:1,max:10,wrap:0)}
            case 38:
                s.frame -= 1;if s.frame<41 {s.frame=11;s.state=39}
            case 39:
                s.frame += 2;if s.frame>16 {s.frame=18;s.state=i%2==0 ? 40:41}
            case 40,41:
                setSideDirection(&s,left:s.state==40)
                if s.frame==26&&draw(random)<16000 {
                    s.counter -= 1
                    if s.counter<1 {s.frame=94;s.state=47}else{s.frame=33;s.state=42}
                } else {advance(&s,step:2,max:32,wrap:18)}
            case 42:
                s.frame += 2;if s.frame>40 {s.frame=8;s.state=43}
            case 43:
                aimAtCenter(&s,shift:4,offset:1024,random:random);s.state=44;advance(&s,step:2,max:10,wrap:0)
            case 44:
                advance(&s,step:2,max:10,wrap:0)
                if s.frame==4 {
                    s.counter -= 1
                    if s.counter<1 {s.frame=75;s.state=46}
                    else if draw(random)>16000 {s.frame=11;s.state=39}
                }
            case 45:s.frame=0;s.state=43
            case 46,47:
                s.direction = .zero;s.frame += 1
                let end=s.state==46 ? 93:105
                s.fireYOffset -= s.state==46 ? 3.68:5.83
                if s.frame==end {s.state=48}
            case 48:
                s.fireHeight -= 0.01;if s.fireHeight<0.02 {s.isBurning=false;s.state=25}
            case 62,63:
                if s.counter<6 {s.counter += 6}
                else {
                    if s.state==62&&s.scale<1 {s.scale += 0.05}
                    s.position.y -= s.state==62 ? 2.4:2.6
                    let ground=terrainHeight(s.position.x,s.position.z)
                    if s.position.y<ground {s.position.y=ground;s.state=s.nextState;s.nextState=6}
                }
                if s.frame<12 {s.frame=min(10,s.frame+1)}else{advance(&s,step:1,max:32,wrap:18)}
                if s.state>59 {s.position.x += s.direction.x*6;s.position.z += s.direction.y*6}
            default:break
            }
            if s.state>3&&s.state<38 {
                s.position.x += s.direction.x*4;s.position.z += s.direction.y*4
                s.position.y=terrainHeight(s.position.x,s.position.z)
                avoidVehicles(&s,neighbors:neighbors)
            }
            if s.state<4,let b=carrier,!b.visible {
                s.visible=false
                events.append(.forceAndScore(sourceIndex:s.sourceIndex,force:-1,score:1))
                events.append(.soldierRemoved(sourceIndex:s.sourceIndex,slot:i))
            }
            if s.state>37&&s.state<60 {
                s.position.x += s.direction.x*8;s.position.z += s.direction.y*8
                s.position.y=terrainHeight(s.position.x,s.position.z)
            }
            soldiers[i]=s
        }
        updateCarriedInfantry(terrainHeight:terrainHeight,events:&events)
        if let bilinear=terrainBilinearHeight {fitGroundVehicles(terrainHeight:bilinear,events:&events)}
        else {fitGroundVehicles(terrainHeight:terrainHeight,events:&events)}
        ticks += 1
        return events
    }

    // 0x406805:242...984. The original barrel hierarchy is model37 ->43 at
    // (0,145,0) ->49 at (0,0,-60) ->55 at zero, with a241-unit muzzle offset.
    private func updateGroundVehicles(random:()->UInt32,events:inout [Event]) {
        for kind in [VehicleKind.tank,.apc] {
            let count=kind == .tank ? tanks.count:apcs.count
            for i in 0..<count {
                var v=kind == .tank ? tanks[i]:apcs[i]
                guard v.visible else{continue}
                let boat=boats[v.boatSlot]
                switch v.state {
                case 0:
                    v.position.x=boat.position.x;v.position.z=boat.position.z
                    if boat.state==3 {v.state=1;v.counter=0}
                case 1:
                    v.position.z += 20;v.counter += 20;if v.counter>599 {v.state=2}
                case 2:
                    if v.eulerDegrees.x > -10 {v.eulerDegrees.x -= 1}
                    v.position.z += 20;v.position.y -= 2;if v.position.y<=20 {v.state=3}
                case 3:
                    v.eulerDegrees.x=min(0,v.eulerDegrees.x+1);v.position.z += 20;v.position.y -= 2
                    if v.position.y<=0 {
                        v.speed=20
                        if kind == .tank {v.state=4}
                        else {
                            v.target.z=Double(draw(random)>>4)-512;v.state=6
                            if abs(v.position.x)<1000 {v.turnTarget=draw(random)<16384 ? -4:4;v.state=4}
                            if v.position.x < -5000 {v.target.x=Double(draw(random)>>4)-4096;v.turnTarget=2.25;v.state=7}
                            if v.position.x > 5000 {v.target.x=Double(draw(random)>>4)+2048;v.turnTarget = -2.25;v.state=7}
                        }
                    }
                default:
                    if kind == .tank {updateTankState(&v,random:random)}else{updateAPCState(&v,random:random)}
                }
                v.turn=v.turnTarget*0.1+v.turn*0.9
                v.eulerDegrees.y=wrapped(v.eulerDegrees.y+v.turn*v.speed*0.0035)
                v.speed += v.acceleration
                if v.speed>20 {v.speed=20;v.acceleration=0}
                if v.speed<0 {v.speed=0;v.acceleration=0}
                v.position.x += v.forward.x*v.speed;v.position.z += v.forward.y*v.speed
                if kind == .tank && v.state==4 {
                    if abs(v.position.x)>7500||v.position.z>2500||v.position.z < -4000 {
                        v.target.x=Double(draw(random)>>3)-2048;v.target.z=Double(draw(random)>>4)-1024
                        v.turnTarget=wrapped(bearing(v.target-v.position)-v.eulerDegrees.y)<0 ? -24:24;v.state=5
                    }
                    v.turretYawDegrees -= clamp(v.turretYawDegrees,-1.5,1.5)
                    var adjustment=v.barrelPitchDegrees
                    if adjustment>1 {adjustment=0.5};if adjustment < -1 {adjustment = -0.5}
                    v.barrelPitchDegrees -= adjustment
                }
                if v.state<2 && !boat.visible {
                    v.visible=false;v.state=20
                    if kind == .tank {events.append(.forceAndScore(sourceIndex:v.sourceIndex,force:-5,score:5))}
                    else {v.hp=0}
                    events.append(.vehicleRemoved(sourceIndex:v.sourceIndex,objectID:v.objectID))
                }
                if kind == .tank {tanks[i]=v}else{apcs[i]=v}
            }
        }
        // Steering avoidance runs AFTER all nine vehicle movement switches.
        for i in tanks.indices where tanks[i].visible && ((4...7).contains(tanks[i].state)||tanks[i].state==13) {
            var v=tanks[i],nearest=40000.0
            let neighbors=apcs.filter(\.visible)+tanks.filter{$0.visible&&$0.slot != i}
            let tests=neighbors.map{($0.position,0.95)}+[SIMD3<Double>(-120,0,-120),SIMD3(-120,0,120),SIMD3(120,0,120),SIMD3(120,0,-120)].map{($0,0.9)}
            for (p,threshold) in tests {
                let d=SIMD2(p.x-v.position.x,p.z-v.position.z),distance=hypot(d.x,d.y)
                if abs(d.x)<1500&&abs(d.y)<1500&&distance>0&&(v.forward.x*d.x+v.forward.y*d.y)/distance>threshold {
                    if v.state != 13 {v.turnTarget=draw(random)<16384 ? -12:12;v.state=13}
                    nearest=min(nearest,distance)
                }
            }
            if v.state==13&&nearest==40000 {v.turnTarget=0;v.state=4};tanks[i]=v
        }
        for i in apcs.indices where apcs[i].visible && ((4...7).contains(apcs[i].state)||apcs[i].state==13) {
            var v=apcs[i],nearest=40000.0
            for other in tanks.filter(\.visible)+apcs.filter({$0.visible&&$0.slot != i}) {
                let d=SIMD2(other.position.x-v.position.x,other.position.z-v.position.z),distance=hypot(d.x,d.y)
                if abs(d.x)<1500&&abs(d.y)<1500&&distance>0&&(v.forward.x*d.x+v.forward.y*d.y)/distance>0.9 {
                    v.acceleration = -0.5;v.turnTarget=0;v.state=8;nearest=min(nearest,distance)
                }
            }
            if v.state==13&&nearest==40000 {v.turnTarget=0;v.state=4};apcs[i]=v
        }
    }

    private func updateTankState(_ v:inout GroundVehicle,random:()->UInt32) {
        switch v.state {
        case 4:
            let roll=draw(random)>>6
            if roll==310 {v.turnTarget=Double(draw(random)>>11)-7.5;v.counter=(draw(random)>>9)+30;v.state=7}
            if roll>319&&roll<=tankAggression {v.acceleration = -0.5;v.state=8}
        case 5:
            let d=SIMD2(v.target.x-v.position.x,v.target.z-v.position.z),length=hypot(d.x,d.y)
            if length>0&&(d.x*v.forward.x+d.y*v.forward.y)/length>0.99 {v.state=6;v.turnTarget=0}
        case 6:if abs(v.position.x)<7500&&v.position.z<2500&&v.position.z > -4000 {v.state=4}
        case 7:v.counter -= 1;if v.counter==0 {v.turnTarget=0;v.state=4}
        case 8:if v.speed==0 {v.state=9;v.target=SIMD3(0,860,0)}
        case 9:
            let error=wrapped(bearing(v.target-v.position)-v.eulerDegrees.y)-v.turretYawDegrees
            if abs(error)<=0.25 {v.counter=0;v.state=10}else{v.turretYawDegrees += clamp(error,-1.5,1.5)}
        case 10:
            let pose=tankGunPose(v),delta=v.target-pose.position,length=sqrt(delta.x*delta.x+delta.y*delta.y+delta.z*delta.z)
            let target=length>0 ? delta/length:.zero
            if target.x*pose.forward.x+target.y*pose.forward.y+target.z*pose.forward.z>=0.9996 {v.counter=75;v.state=11}
            else {
                let old=v.counter
                if target.y<=pose.forward.y {v.barrelPitchDegrees -= 0.5;v.counter -= 1}
                else {v.barrelPitchDegrees += 0.5;v.counter += 1}
                if (old>0&&v.counter<old)||(old<0&&v.counter>old) {v.counter=75;v.state=11}
            }
        case 11:v.counter -= 1;if v.counter==15 {v.firePending=true};if v.counter==0 {v.state=12}
        case 12:v.acceleration=0.5;v.state=4
        default:break
        }
    }
    private func updateAPCState(_ v:inout GroundVehicle,random:()->UInt32) {
        switch v.state {
        case 4:if abs(v.eulerDegrees.y)<135 {v.turnTarget=0;v.state=5}
        case 5:
            if abs(v.position.x)>2000 {v.turnTarget=v.eulerDegrees.y*0.025;v.target.z=Double(draw(random)>>4)-1024;v.state=6}
            if abs(v.eulerDegrees.y)<3 {v.turnTarget=0}
        case 6:if v.target.z<v.position.z {v.acceleration = -0.5;v.state=8}
        case 7:if abs(v.eulerDegrees.y)>88&&abs(v.eulerDegrees.y)<92 {v.acceleration = -0.5;v.turnTarget=0;v.state=8}
        case 8:if v.speed<2 {v.state=9}
        case 9:v.rampPitchDegrees += 2;if v.rampPitchDegrees==90 {v.state=20}
        default:break
        }
    }
    // 0x406805:4524...5037. CH53 landing/door/cargo/withdrawal/crash states.
    // Terrain lookup for aircraft and infantry is original nearest sample;
    // vehicle contact requires bilinear heights. The adapter can pass its exact
    // source height sampler; callers needing both can use tick's separate hook.
    private func updateHelicopters(terrainHeight:(Double,Double)->Double,random:()->UInt32,
                                   events:inout [Event],phases:SIMD4<Double>,smokeTick:Bool,onCrashVisual:CrashVisualHandler?) {
        for i in helicopters.indices where helicopters[i].visible {
            var h=helicopters[i]
            switch h.state {
            case 1:
                if h.position.z > -10000 {
                    repeat {h.target.x=Double(draw(random)>>1)-8192}
                    while helicopters.indices.contains(where:{$0 != i&&abs(helicopters[$0].target.x-h.target.x)<4000})
                    // Original compares x<4000 then fabs(bool), not fabs(x).
                    h.target.z=h.target.x<4000 ? Double(draw(random)>>5)+1024:Double(draw(random)>>4)
                    h.turnTarget=wrapped(bearing(h.target-h.position)-h.eulerDegrees.y)<0 ? -2:2
                    h.counter=1;h.state=8
                }
            case 2:
                let d=SIMD2(h.target.x-h.position.x,h.target.z-h.position.z),distance=hypot(d.x,d.y),n=hypot(h.forward.x,h.forward.z)
                if distance*n>0&&(d.x*h.forward.x+d.y*h.forward.z)/(distance*n)>0.99 {h.state=3;h.turnTarget=0}
            case 3:if abs(h.position.x)<25000&&abs(h.position.z)<25000 {h.state=1}
            case 4:h.counter -= 1;if h.counter==0 {h.state=1;h.turnTarget=0}
            case 5:h.verticalAcceleration=0;h.state=1 // original <= and >= cover all finite heights
            case 6:h.counter -= 1;if h.counter==0 {h.counter=60;h.acceleration=2;h.pitchTarget = -25;h.state=7}
            case 7:h.counter -= 1;if h.counter==0 {h.state=1}
            case 8:
                let d=h.target-h.position,distance=hypot(d.x,d.z)
                var enteredFinal=false
                if distance<4830 {
                    beginCH53Descent(&h)
                    let ground=helicopterGround?(h.position.x,h.position.z) ?? (h.position.z > -7500 ? terrainHeight(h.position.x,h.position.z):0)
                    if h.position.y-ground<700 {h.verticalAcceleration = -0.25;h.turnTarget=0;h.turn=0;h.state=9;enteredFinal=true}
                }
                if !enteredFinal {
                    let angle=wrapped(bearing(d)-h.eulerDegrees.y)
                    if abs(angle)>=0.5 {
                        if abs(angle)<32 {h.turn += clamp(angle*0.0625-h.turn,-0.125,0.125)}
                    } else {h.turnTarget=0;h.turn=0;h.state=9;h.eulerDegrees.y=wrapped(bearing(d))}
                }
            case 9:
                if hypot(h.target.x-h.position.x,h.target.z-h.position.z)<4830 {
                    beginCH53Descent(&h)
                    let ground=helicopterGround?(h.position.x,h.position.z) ?? (h.position.z > -7500 ? terrainHeight(h.position.x,h.position.z):0)
                    if h.position.y-ground<338 || (helicopterGround != nil && h.position.y <= ground+338.001) {
                        h.position.y=ground+338;h.counter=90;h.speed=0;h.verticalAcceleration=0;h.verticalSpeed=0;h.state=10
                    } else if h.position.y-ground<700 {h.verticalAcceleration = -0.25}
                }
            case 10:h.rampPitchDegrees += 2;if h.rampPitchDegrees>=35 {h.state=11}
            case 11:h.counter -= 1;if h.counter==0 {h.state=12}
            case 12:h.rampPitchDegrees -= 2;if h.rampPitchDegrees<=0 {h.verticalAcceleration=1;h.state=13}
            case 13:
                if h.position.y>1500 {h.turnTarget=h.eulerDegrees.y>0 ? -1:1;h.acceleration=2;h.pitchTarget = -25;h.state=14}
            case 14:
                if h.position.y>4000 {h.verticalAcceleration=0}
                if (h.turnTarget>0&&h.eulerDegrees.y > -20)||(h.turnTarget<0&&h.eulerDegrees.y<20) {
                    h.turnTarget=0;h.verticalAcceleration=0;h.state=15
                }
            case 15:
                if h.position.z < -30000 {h.visible=false;events.append(.vehicleRemoved(sourceIndex:h.sourceIndex,objectID:h.objectID))}
            case 16:
                h.acceleration = -1;h.verticalAcceleration = -1;h.turnTarget=Double(draw(random)>>13)
                h.pitchTarget=Double((draw(random)>>10)-16);h.state=17;h.fallSpeed=0
            case 17:
                h.rotorDegreesPerTick=max(20,h.rotorDegreesPerTick-0.25);h.fallSpeed -= 1;h.position.y += h.fallSpeed
                let ground=helicopterGround?(h.position.x,h.position.z) ?? (abs(h.position.x)<15000&&abs(h.position.z)<7500 ? terrainHeight(h.position.x,h.position.z):0)
                if h.position.y<ground+300 {
                    h.hp=0;h.visible=false
                    // Original0x406805:4889 emits debris before this same
                    // helicopter's smoke RNG and before the next CH53.
                    onCrashVisual?("CH53",h.objectID,h.position,h.eulerDegrees)
                    events.append(.forceAndScore(sourceIndex:h.sourceIndex,force:0,score:2))
                    events.append(.vehicleRemoved(sourceIndex:h.sourceIndex,objectID:h.objectID))
                    events.append(.explosion(sourceIndex:h.sourceIndex,position:h.position,scale:4))
                }
                if smokeTick {
                    let p=h.position+SIMD3(Double((draw(random)>>8)-64),Double((draw(random)>>9)-32),Double((draw(random)>>8)-64))
                    events.append(.smoke(sourceIndex:h.sourceIndex,position:p))
                }
            default:break
            }
            h.turn=h.turnTarget*0.05+h.turn*0.95
            h.pitchSpring=h.pitchTarget*0.05+h.pitchSpring*0.95
            if abs(h.pitchSpring)>22 {h.pitchTarget=0}
            h.eulerDegrees.x=h.speed * -0.05+h.pitchSpring
            let oldYaw=h.eulerDegrees.y;h.eulerDegrees.y=wrapped(h.eulerDegrees.y+h.turn)
            h.eulerDegrees.z=(h.eulerDegrees.y-oldYaw)*30
            if h.speed<30&&(h.state<10||h.state>12) {
                let p=phases * (.pi/180),a=sin(p.x),b=sin(p.y),c=sin(p.z),d=sin(p.w),weight=1/(h.speed+1)
                h.eulerDegrees.z += (c+d)*weight*2;h.eulerDegrees.x += (a+b+c)*weight
                h.position += SIMD3((a+c)*weight*2,(a+b)*weight*2,(b+c)*weight*2)
            }
            h.forward=rotate(SIMD3(0,0,-1),h.eulerDegrees)
            h.speed += h.acceleration
            if h.speed>140 {h.acceleration=0} // original does not clamp the140 overshoot
            if h.speed<0 {h.speed=0;h.acceleration=0}
            h.position.x += h.forward.x*h.speed;h.position.z += h.forward.z*h.speed
            h.verticalSpeed=h.verticalSpeed*0.9+h.verticalAcceleration;h.position.y += h.verticalSpeed
            if h.state < 16, let helicopterAltitude {
                let approach = (8...9).contains(h.state) && hypot(h.target.x-h.position.x,h.target.z-h.position.z)<4830
                let landing = approach || (10...13).contains(h.state)
                h.position.y = helicopterAltitude(h.position,h.eulerDegrees.y,h.speed,landing,&h.terrainLift)
            }
            helicopters[i]=h
        }
    }
    private func beginCH53Descent(_ h:inout Helicopter) {
        if h.counter==1 {h.acceleration = -2;h.pitchTarget=25;h.verticalAcceleration = -2.3;h.counter=0}
    }
    private func updateCarriedInfantry(terrainHeight:(Double,Double)->Double,events:inout [Event]) {
        // This is a second pass AFTER all on-foot infantry, even for hidden
        // cargo. On the release tick the original jumps ahead five slots: only
        // the sixth released sprite takes the final6-unit movement that tick.
        var i=48
        while i<84 {
            guard soldiers[i].state>59 else{i += 1;continue}
            let isAPC=i<66,slot=(i-(isAPC ? 48:66))/6
            let hp=isAPC ? apcs[slot].hp:helicopters[slot].hp
            let carrierState=isAPC ? apcs[slot].state:helicopters[slot].state
            if isAPC && usesDepthlineAPCExit {
                updateAPCPassenger(i, carrier: apcs[slot], terrainHeight: terrainHeight, events: &events)
                i += 1
                continue
            }
            if soldiers[i].state==60||soldiers[i].state==61 {
                if hp==0 {removeCarriedSoldier(i,events:&events)}
                else if carrierState==(isAPC ? 20:11) {
                    let position=isAPC ? apcs[slot].position:helicopters[slot].position
                    let yaw=isAPC ? apcs[slot].eulerDegrees.y:helicopters[slot].eulerDegrees.y
                    let direction=isAPC ? apcs[slot].forward:SIMD2(helicopters[slot].forward.x,helicopters[slot].forward.z)
                    releaseInfantry(first:i,isAPC:isAPC,position:position,yaw:yaw,forward:direction)
                    i += 5
                }
            } else {
                var s=soldiers[i]
                if s.counter<6 {s.counter += 6}
                else {
                    if isAPC&&s.scale<1 {s.scale += 0.05}
                    s.position.y -= isAPC ? 2.4:2.6
                    let ground=terrainHeight(s.position.x,s.position.z)
                    if s.position.y<ground {s.position.y=ground;s.state=s.nextState;s.nextState=6}
                }
                s.frame += 1
                if s.frame<12 {s.frame=min(10,s.frame)}else if s.frame>32 {s.frame=18}
                soldiers[i]=s
                if hp==0 {removeCarriedSoldier(i,events:&events)}
            }
            if soldiers[i].state>59 {soldiers[i].position.x += soldiers[i].direction.x*6;soldiers[i].position.z += soldiers[i].direction.y*6}
            i += 1
        }
    }
    private func updateAPCPassenger(_ i: Int, carrier: GroundVehicle, terrainHeight: (Double, Double) -> Double, events: inout [Event]) {
        var soldier = soldiers[i]
        if !soldier.visible && carrier.hp == 0 {
            removeCarriedSoldier(i, events: &events)
            return
        }
        if soldier.apcExit == nil {
            guard carrier.state == 20, carrier.visible else { return }
            soldier.apcExit = DepthlineAPCExit(hull: .coast, origin: carrier.position, angles: carrier.eulerDegrees, seat: (i - 48) % 6)
            soldier.state = 62
        }
        if let step = soldier.apcExit?.step(ground: terrainHeight) {
            soldier.visible = true
            soldier.position = step.position
            soldier.direction = step.direction
            soldier.frame = (soldier.frame + 1) % 11
            if soldier.apcExit?.isFinished == true {
                soldier.apcExit = nil
                soldier.state = 5
                soldier.nextState = 6
            }
        }
        soldiers[i] = soldier
    }
    private func removeCarriedSoldier(_ i:Int,events:inout [Event]) {
        soldiers[i].apcExit = nil
        soldiers[i].state=25;soldiers[i].visible=false
        events.append(.forceAndScore(sourceIndex:soldiers[i].sourceIndex,force:-1,score:1))
        events.append(.soldierRemoved(sourceIndex:soldiers[i].sourceIndex,slot:i))
    }
    private func releaseInfantry(first:Int,isAPC:Bool,position:SIMD3<Double>,yaw:Double,forward:SIMD2<Double>) {
        let angle=wrapped(bearing(-position)-yaw)
        for n in 0..<6 {
            let i=first+n,offset=Double((isAPC ? 110:290)-n*(isAPC ? 40:80))
            soldiers[i].visible=true;soldiers[i].position=SIMD3(position.x-forward.x*offset,position.y+(isAPC ? 40:-270),position.z-forward.y*offset)
            soldiers[i].direction = -forward;soldiers[i].counter=Int(offset)-(isAPC ? 130:310)
            soldiers[i].state=isAPC ? 62:63;soldiers[i].nextState=5
            if isAPC {soldiers[i].scale=0.65}
            // REA asm0x4139d9...0x4139f7 confirms impossible <=-135 && >=135;
            // do not 'fix' the original AND into OR. Outermost angles keep frame.
            if angle >= -25&&angle<=25 {soldiers[i].frame=18+n*2;soldiers[i].nextState=n%2==0 ? 11:12}
            if angle>25&&angle<135 {soldiers[i].frame=18+n*2;if (isAPC&&n%2==0)||(!isAPC&&n%2==1) {soldiers[i].nextState=isAPC ? 11:12}}
            if angle < -25&&angle > -135 {soldiers[i].frame=18+n*2;if (isAPC&&n%2==1)||(!isAPC&&n%2==0) {soldiers[i].nextState=isAPC ? 12:11}}
        }
    }
    private func fitGroundVehicles(terrainHeight:(Double,Double)->Double,events:inout [Event]) {
        for kind in [VehicleKind.tank,.apc] {for i in 0..<(kind == .tank ? tanks.count:apcs.count) {
            var v=kind == .tank ? tanks[i]:apcs[i];guard v.visible else{continue}
            if v.state>=4 {
                // Beachhead.3D BBox, already in source world units (scale1).
                let x:Double=kind == .tank ? 110:80,z:Double=kind == .tank ? 150:120
                let corners=[SIMD3(x,0,-z),SIMD3(-x,0,-z),SIMD3(-x,0,z),SIMD3(x,0,z)]
                let heights=corners.map {p ->Double in let q=rotate(p,SIMD3(0,v.eulerDegrees.y,0))+v.position;return terrainHeight(q.x,q.z)}
                let front=(heights[0]+heights[1])*0.5,back=(heights[2]+heights[3])*0.5
                let right=(heights[0]+heights[3])*0.5,left=(heights[1]+heights[2])*0.5
                v.eulerDegrees.x=atan2(front-back,z*2)*180 / .pi
                v.eulerDegrees.z=atan2(right-left,x*2)*180 / .pi
                v.position.y=(right+left)*0.5
            }
            if v.firePending {
                let pose=tankGunPose(v)
                events.append(.tankShell(VehicleShot(poolIndex:nextTankShell,sourceIndex:v.sourceIndex,objectID:v.objectID+18,
                    position:pose.position+pose.forward*241,velocity:pose.forward*400)))
                nextTankShell=(nextTankShell+1)%4;v.firePending=false
            }
            if kind == .tank {tanks[i]=v}else{apcs[i]=v}
        }}
    }
    private func tankGunPose(_ v:GroundVehicle)->(position:SIMD3<Double>,forward:SIMD3<Double>) {
        let turret=SIMD3<Double>(0,v.turretYawDegrees,0),barrel=SIMD3<Double>(v.barrelPitchDegrees,0,0)
        let origin=v.position+rotate(SIMD3(0,145,0)+rotate(SIMD3(0,0,-60),turret),v.eulerDegrees)
        let forward=rotate(rotate(rotate(SIMD3(0,0,-1),barrel),turret),v.eulerDegrees)
        return(origin,forward)
    }
    private func rotate(_ p:SIMD3<Double>,_ degrees:SIMD3<Double>)->SIMD3<Double> {
        let a=degrees * (.pi/180),cx=cos(a.x),sx=sin(a.x),cy=cos(a.y),sy=sin(a.y),cz=cos(a.z),sz=sin(a.z)
        let r=SIMD3(p.x*cz-p.y*sz,p.x*sz+p.y*cz,p.z)
        let q=SIMD3(r.x,r.y*cx-r.z*sx,r.y*sx+r.z*cx)
        return SIMD3(q.x*cy+q.z*sy,q.y,q.z*cy-q.x*sy)
    }
    private func wrapped(_ a:Double)->Double {var a=a;while a>180{a-=360};while a < -180{a+=360};return a}
    private func bearing(_ d:SIMD3<Double>)->Double {atan2(-d.x,-d.z)*180 / .pi}
    private func clamp(_ v:Double,_ lo:Double,_ hi:Double)->Double {min(hi,max(lo,v))}

    private func aimAtCenter(_ s:inout Soldier,shift:Int,offset:Int,random:()->UInt32) {
        var target=SIMD2<Double>.zero
        if hypot(s.position.x,s.position.z)>=2500 {target=SIMD2(Double((draw(random)>>shift)-offset),Double((draw(random)>>shift)-offset))}
        let delta=target-SIMD2(s.position.x,s.position.z),distance=hypot(delta.x,delta.y)
        s.direction=distance>0 ? delta/distance:.zero
    }
    private func setSideDirection(_ s:inout Soldier,left:Bool) {
        let distance=hypot(s.position.x,s.position.z)
        guard distance>0 else{s.direction = .zero;return}
        let x=abs(s.position.x/distance),z=abs(s.position.z/distance)
        s.direction=left ? SIMD2(s.position.z>0 ? -z:z,s.position.x<0 ? -x:x)
                         : SIMD2(s.position.z<0 ? -z:z,s.position.x>0 ? -x:x)
    }
    private func advance(_ s:inout Soldier,step:Int,max:Int,wrap:Int) {s.frame += step;if s.frame>max{s.frame=wrap}}
    private func draw(_ random:()->UInt32)->Int {let n=random();precondition(n<=32767);return Int(n)}
    private func avoidVehicles(_ s:inout Soldier,neighbors:[Neighbor]) {
        let nearby=neighbors.filter {abs($0.position.x-s.position.x)<400&&abs($0.position.z-s.position.z)<400}
        guard let vehicle=nearby.min(by:{hypot($0.position.x-s.position.x,$0.position.z-s.position.z)<hypot($1.position.x-s.position.x,$1.position.z-s.position.z)}) else{return}
        if vehicle.speed<=1 {
            if (6...8).contains(s.state) {
                let current=hypot(vehicle.position.x-s.position.x,vehicle.position.z-s.position.z)
                // Preserve the unusual decompiled source multiplication, rather
                // than silently substituting a guessed obstacle-steering rule.
                let future=hypot(vehicle.position.x-(s.position.x*s.direction.x*100+s.position.x),
                                 vehicle.position.z-(s.position.z*s.direction.y*100+s.position.z))
                if future<current {s.counter=1;s.state=33}
            }
            if (36...37).contains(s.state)&&(abs(vehicle.position.x-s.position.x)>400||abs(vehicle.position.z-s.position.z)>400) {s.counter=0;s.state=5}
        } else if (6...8).contains(s.state) {
            let delta=SIMD2(s.position.x-vehicle.position.x,s.position.z-vehicle.position.z)
            let distance=hypot(delta.x,delta.y)
            if distance>0&&(vehicle.forward.x*delta.x+vehicle.forward.y*delta.y)/distance>0.71 {s.state=32}
        }
    }
}

extension Original2000EnemyAI {
    struct TestFailure:Error,CustomStringConvertible {let description:String}
    static func runTests() throws {
        func check(_ condition:@autoclosure()->Bool,_ message:String)throws{if !condition(){throw TestFailure(description:message)}}
        var rng:UInt32=1
        func random()->UInt32 {rng=rng &* 214013 &+ 2531011;return(rng>>16)&32767}
        let ai=Original2000EnemyAI(bargeDeclarations:(0..<3).map{BargeDeclaration(slot:$0,sourceIndex:100+$0,active:true)},random:random)
        try check(ai.soldiers.filter(\.visible).count==24,"First level has three boats with8 visible deck soldiers")
        for i in ai.boats.indices {for j in ai.boats.indices where i != j {try check(abs(ai.boats[i].position.x-ai.boats[j].position.x)>=400,"All12 craft initialized with original minimum separation")}}
        let flat:(Double,Double)->Double={_,_ in 0}
        var grenades=0,flashes=0
        for _ in 0..<12000 {
            let events=ai.tick(terrainHeight:flat,viewPitchDegrees:0,random:random)
            for e in events {if case .grenade=e{grenades += 1};if case .rifleFlash=e{flashes += 1}}
            try check(ai.soldiers.allSatisfy{(0..<139).contains($0.frame)},"Every original animation frame exists in expanded atlas")
        }
        try check(ai.boats.prefix(3).allSatisfy{$0.visible&&$0.state==4&&$0.rampPitchDegrees == -80},"Original boats remain moored after ramp opening")
        try check(ai.soldiers.prefix(24).allSatisfy{$0.state>=5},"All living first-level infantry disembark")
        try check(grenades>0&&flashes>0,"Original random infantry FSM produces both rifle shots and grenades")
        ai.activateBarge(slot:3,sourceIndex:200)
        try check(ai.soldiers[24..<32].allSatisfy{$0.visible&&$0.sourceIndex==200},"Delayed boat carries its exact sourceIndex")
        ai.destroyBarge(slot:3)
        let killed=ai.tick(terrainHeight:flat,viewPitchDegrees:0,random:random)
        let force=killed.reduce(0){sum,e in if case .forceAndScore(_,let f,_)=e{return sum+f};return sum}
        try check(force == -8 && !ai.soldiers[24..<32].contains(where:{$0.visible}),"Destroyed carrier removes8 still-attached troops once")
        let old=ai.soldiers[0].state
        ai.killSoldier(slot:0)
        try check(ai.soldiers[0].state==21&&ai.soldiers[0].nextState==old,"Shot preserves pose for original death animation")
        for _ in 0..<30 {_=ai.tick(terrainHeight:flat,viewPitchDegrees:0,random:random)}
        try check(ai.soldiers[0].state==25&&ai.soldiers[0].visible,"Corpse persists while looking down")
        _=ai.tick(terrainHeight:flat,viewPitchDegrees:21,random:random)
        try check(!ai.soldiers[0].visible,"Corpse hides only after original viewPitch>20 threshold")
        // Force a known firing state to distinguish its one-tick probability
        // from the discarded prototype's fixed7-second10-damage attack timer.
        ai.soldiers[1].state=15;ai.soldiers[1].counter=16;ai.soldiers[1].direction = .zero
        let firing=ai.tick(terrainHeight:flat,viewPitchDegrees:0,random:{32767},soundEnabled:false)
        try check(firing.contains(.defenseChanged(-1)),"State15 atcounter15 rolls>28000 for exactly1 damage")
        let carriers=Original2000EnemyAI(
            bargeDeclarations:(6..<12).map{BargeDeclaration(slot:$0,sourceIndex:300+$0,active:true)},
            vehicleDeclarations:(0..<3).map{VehicleDeclaration(kind:.tank,slot:$0,sourceIndex:400+$0,active:true)} +
                (0..<3).map{VehicleDeclaration(kind:.apc,slot:$0,sourceIndex:500+$0,active:true)},
            helicopterDeclarations:(0..<3).map{HelicopterDeclaration(slot:$0,sourceIndex:600+$0,active:true)},
            aggression:[191,0,0,0],random:random)
        var tankShots=0,apcUnloaded=false,ch53Unloaded=false,ch53Departed=false
        for _ in 0..<10000 {
            let e=carriers.tick(terrainHeight:flat,viewPitchDegrees:0,random:random)
            for event in e {if case .tankShell(let shot)=event {
                tankShots += 1
                let speed=sqrt(shot.velocity.x*shot.velocity.x+shot.velocity.y*shot.velocity.y+shot.velocity.z*shot.velocity.z)
                try check(abs(speed-400)<0.0001,"Original tank shell has400 units/tick speed")
            }}
            apcUnloaded = apcUnloaded || carriers.soldiers[48..<66].allSatisfy{$0.visible&&$0.state<60}
            ch53Unloaded = ch53Unloaded || carriers.soldiers[66..<84].allSatisfy{$0.visible&&$0.state<60}
            ch53Departed = ch53Departed || carriers.helicopters.allSatisfy{!$0.visible&&$0.state==15}
        }
        try check(tankShots>0,"Tank exits boat, maneuvers, aims turret/barrel and fires original shell")
        try check(apcUnloaded&&carriers.apcs.allSatisfy{$0.state==20&&$0.rampPitchDegrees==90},"Three APCs land, stop, open ramps and release all18 soldiers")
        try check(ch53Unloaded&&ch53Departed,"Three CH53s land, release18 troops and leave through original north boundary")
        let exact=Original2000EnemyAI(bargeDeclarations:[],random:random)
        exact.apcs[0].sourceIndex=700;exact.apcs[0].state=20;exact.apcs[0].position=SIMD3(0,100,-1000)
        exact.apcs[0].eulerDegrees.y=180
        for n in 48..<54 {exact.soldiers[n].sourceIndex=700}
        _=exact.tick(terrainHeight:flat,viewPitchDegrees:0,random:random)
        try check(exact.soldiers[48..<54].map(\.counter)==[-20,-60,-100,-140,-180,-220],"REA x87 release counters use Int(local14)-130")
        try check(exact.soldiers[48].position.z == -1110&&exact.soldiers[53].position.z == -916,"On release tick only sixth carried sprite makes6-unit movement")
        exact.applyVehicleDamage(objectID:61,hp:0,state:0,visible:false)
        let cargoDeath=exact.tick(terrainHeight:flat,viewPitchDegrees:0,random:random)
        try check(cargoDeath.reduce(0){sum,e in if case .forceAndScore(_,let f,_)=e{return sum+f};return sum} == -6,"APC destroyed before unloading completes removes its6 carried troops exactly once")
        let crashOrder=Original2000EnemyAI(bargeDeclarations:[],helicopterDeclarations:[
            .init(slot:0,sourceIndex:900,active:true),.init(slot:1,sourceIndex:901,active:true)],random:random)
        crashOrder.helicopters[0].state=17;crashOrder.helicopters[0].position=SIMD3(1000,100,0)
        crashOrder.helicopters[0].speed=10;crashOrder.helicopters[0].fallSpeed=0
        crashOrder.helicopters[1].state=16
        var crashDraws=0,visualCalls=0,drawsAtVisual = -1
        var crashPose=SIMD3<Double>.zero
        func crashRandom()->UInt32 {defer{crashDraws+=1};return UInt32(crashDraws*2048)}
        let crashEvents=crashOrder.tick(terrainHeight:flat,viewPitchDegrees:0,random:crashRandom,
            smokeTick:true,onCrashVisual:{type,id,p,r in
                visualCalls+=1;drawsAtVisual=crashDraws;crashPose=p
                for _ in 0..<6 {_=crashRandom()}
            })
        try check(visualCalls==1 && drawsAtVisual==0 && crashDraws==11,
                  "CH53 debris RNG precedes its three smoke draws and next helicopter's two crash-setup draws")
        try check(crashPose==SIMD3(1000,99,0) && crashOrder.helicopters[0].position != crashPose,
                  "CH53 callback freezes fall-updated pose before trailing movement")
        let smoke=crashEvents.compactMap {event->SIMD3<Double>? in
            if case .smoke(let index,let p)=event,index==900 {return p};return nil
        }
        try check(smoke==[SIMD3(984,95,0)],"same-tick CH53 smoke consumes random values after debris")
        let h=Original2000EnemyAI(bargeDeclarations:[],helicopterDeclarations:[HelicopterDeclaration(slot:0,sourceIndex:800,active:true)],random:random)
        h.applyVehicleDamage(objectID:106,hp:0,state:16,visible:true)
        var crashScore=0,crashForce=0
        for _ in 0..<200 {for e in h.tick(terrainHeight:flat,viewPitchDegrees:0,random:random) {if case .forceAndScore(_,let force,let score)=e {crashForce += force;crashScore += score}}}
        try check(!h.helicopters[0].visible&&crashForce == -6&&crashScore==8,"CH53 crash adds original deferred2 score plus6 attached infantry, without duplicate direct-hit score")
    }
}

#if ORIGINAL2000_ENEMY_AI_TESTS
@main private struct Original2000EnemyAITestRunner {
    static func main() throws {try Original2000EnemyAI.runTests();print("PASS: BH2000 original craft, infantry FSM, sprite frames, firing, cargo and deaths")}
}
#endif
