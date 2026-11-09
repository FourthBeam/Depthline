import Foundation

// BH2002 original supply/airborne-cargo logic, from analysis/decompiled/:
// load-level.c:117...133,201...273,484...492;
// update-enemy-ai.c:1465...1868,3171...3250;
// update-game.c:363...450,716...787,1102...1167,1349...1390,2683...2694.
// Corresponding full functions: 0x429201,0x4051c8,0x4154b7; scheduler0x4050f1.
// This file performs no rendering, sound or approximate collision detection.
// Coordinates are ORIGINAL world units; angles degrees. Divide XYZ by100 only
// in SceneKit. Use an original simulation tick, not the render-frame delta.
//
// Construct from actual C130 declarations only. Level_01 has none: an empty
// declarations array remains empty forever. Unlike BH2000 there is no invented
// periodic friendly plane. C130 can deliver enemy paratroopers as well as boxes.
//
// var supply = Beach2002Supply(declarations: c130Records.map {
//   .init(sourceIndex:$0.sourceIndex, slot:$0.slot, delay:$0.declaredDelay,
//         passes:$0.passes, far:$0.far, troops1:$0.troops1, troops2:$0.troops2,
//         hdrop:$0.hdrop, adrop:$0.adrop, pdrop:$0.pdrop, mdrop:$0.mdrop)
// }, direction:.north)
// // nil Delay means initially active. Explicit Delay0 stays hidden, exactly
// // as the original hidden counter becomes-1 and never equals0 again.
// // One active tick: AI -> projectile hits -> resource caps/HUD -> scheduler.
// consume(supply.updateAI(random:{rng.next()}, terrainHeight:sourceHeight,
//   smokeTick:tick%2==0, allocateTrooperID:{
//     defer { nextTrooperOrdinal += 1 }; return Self.safeTrooperID(ordinal:nextTrooperOrdinal) }))
// // Share this allocator with APC/CH53. Native compatibility deliberately fixes
// // original DAT_00447d20 overflow: IDs358...453, then1000...; no living soldier
// // is overwritten and original supply-box IDs454...469 remain disjoint.
// if let hit = supply.collect(parachuteID:hitID, resources:resources) {
//   resources=hit.resources; remainingForce += hit.remainingForceDelta
//   if let counter=hit.transitionCounter { transitionCounter=counter }
// }
// resources.applyOriginalCaps() // original caps happen AFTER all projectile hits
// consume(supply.updateScheduler())
//
// Initial required force already includes troops1+troops2. Releasing/landing a
// troop does NOT add force. On .trooperLanded transfer it to ground AI; retain
// sourceIndex/objectID. .remainingForceChanged reports only not-yet-dropped
// troops killed with a plane. Midair chute hits return remainingForceDelta=-1.
// Render boxes/troopers as children of the returned parentParachuteID using the
// retained local offset(-250Y/-300Y). Ring slots intentionally preserve original
// reuse/stale-child behavior; sourceIndex is attribution metadata, not a counter.
//
// Original parsing sets `alternate` but the complete exported native functions
// contain no read of that byte. It is retained without invented behavioral use.
// Original reward ranges exclude missile box469. Assembly confirms this in
// analysis/bh2002/projectile-assembly.json, evidence ev_8c80fe78fbc03719e151246d96ba881fea7f1297759c7b6e9c2b00f38b729390:
// 0x4161a3...0x4161ac and0x418803...0x418813 compare >=0x1d2 and<0x1d5.
//
// Standalone tests:
// swiftc -parse-as-library -module-cache-path /tmp/bh2002-supply-module-cache \
//   -D BEACH2002_SUPPLY_TESTS native/{SupplyDescent,Beach2002Supply}.swift -o /tmp/bh2002-supply-tests
// /tmp/bh2002-supply-tests
struct Beach2002Supply {
    struct Vector: Equatable {
        var x: Float, y: Float, z: Float
        static let zero = Vector(x: 0, y: 0, z: 0)
    }
    struct Random {
        private(set) var state: UInt32
        init(seed: UInt32) { state = seed }
        mutating func next() -> UInt32 {
            state = state &* 214013 &+ 2531011
            return (state >> 16) & 0x7fff
        }
    }
    enum Direction: Int { case random = 0, north = 1, south = 2, east = 3, west = 4 }
    enum PayloadKind: Int, Equatable { case defense = 0, machineGun = 1, cannon = 2, missile = 3, trooper = 4 }
    enum FlightState: Int { case inactive = 0, initialize = 1, inbound = 2, dropping = 3, outbound = 4, beginCrash = 5, crashing = 6 }
    enum PlaneWeapon: Equatable { case commonBullet(part: Int), cannon, missile }

    struct Declaration {
        let sourceIndex: Int, slot: Int
        let delay: Int?
        let passes: Int
        let far: Bool, alternate: Bool
        let troops1: Int, troops2: Int
        let drops: [Int]
        init(sourceIndex: Int, slot: Int, delay: Int? = nil, passes: Int = 127,
             far: Bool = false, troops1: Int = 0, troops2: Int = 0,
             hdrop: Int = 0, adrop: Int = 0, pdrop: Int = 0, mdrop: Int = 0,
             alternate: Bool = false) {
            precondition((0..<8).contains(slot), "C130 has eight original slots")
            precondition([passes,troops1,troops2,hdrop,adrop,pdrop,mdrop].allSatisfy { $0 >= 0 },
                         "Expected nonnegative authored C130 fields")
            self.sourceIndex=sourceIndex; self.slot=slot; self.delay=delay
            self.passes=min(127,max(1,passes)); self.far=far; self.alternate=alternate
            self.troops1=min(16,troops1); self.troops2=min(16,troops2)
            self.drops=[hdrop,adrop,pdrop,mdrop].map { min(4,$0) }
        }
    }

    static func declarations(from objects: [[String: Any]]) -> [Declaration] {
        var result: [Declaration] = []
        var ordinal = 0
        for (index, object) in objects.enumerated() where object["type"] as? String == "C130" {
            let slot = object["slot"] as? Int ?? ordinal
            ordinal += 1
            guard (0..<8).contains(slot) else { continue }
            func amount(_ key: String, default fallback: Int = 0) -> Int {
                (object[key] as? NSNumber)?.intValue ?? fallback
            }
            result.append(Declaration(sourceIndex: index, slot: slot, delay: object["delay"] as? Int,
                                      passes: amount("passes", default: 127), far: amount("far") != 0,
                                      troops1: amount("troops1"), troops2: amount("troops2"),
                                      hdrop: amount("hdrop"), adrop: amount("adrop"),
                                      pdrop: amount("pdrop"), mdrop: amount("mdrop"),
                                      alternate: amount("alternate") != 0))
        }
        return result
    }
    struct Plane {
        let declaration: Declaration
        var isCrashing: Bool { visible && (state == .beginCrash || state == .crashing) }
        var sourceIndex: Int { declaration.sourceIndex }
        var objectID: Int { 210 + declaration.slot }
        /// Root and its four propeller groups are objectID+[0,8,16,24,32].
        var linkedObjectIDs: [Int] { [0,8,16,24,32].map { objectID+$0 } }
        var propellerDegreesPerTick: [Float] { [-34,-36,35,33] }
        var visible: Bool
        var delayCountdown: Int
        var state = FlightState.initialize
        var position = Vector.zero
        var pitch: Float = 0, yaw: Float = 0, roll: Float = 0
        var speed: Float = 0
        var hp = 8
        var passesRemaining: Int
        var troops1: Int, troops2: Int
        var dropsRemaining = [0,0,0,0]
        var dropCountdown = 0, alternateFlag = 0
        var yawRate: Float = 0, targetYawRate: Float = 0
        var pitchRate: Float = 0, targetPitchRate: Float = 0
        init(_ declaration: Declaration) {
            self.declaration=declaration; visible=declaration.delay == nil
            delayCountdown=declaration.delay ?? 0; passesRemaining=declaration.passes
            troops1=declaration.troops1; troops2=declaration.troops2
        }
    }
    struct Parachute {
        let objectID: Int
        var sourceIndex = -1
        var visible = false
        var position = Vector.zero
        var pitch: Float = 0, yaw: Float = 0, angularVelocity: Float = 0
        var payloadID = -1
        var payloadKind:PayloadKind?
    }
    struct Payload {
        let objectID: Int
        let kind: PayloadKind
        var sourceIndex = -1
        var parentParachuteID = -1
        var visible = false
        var position = Vector.zero // Local until parentParachuteID becomes-1.
    }
    struct Resources: Equatable {
        var defense: Int, machineGun: Int, cannon: Int, missile: Int
        mutating func applyOriginalCaps() {
            defense=min(100,defense); machineGun=min(500,machineGun)
            cannon=min(20,cannon); missile=min(20,missile)
        }
    }
    struct Collection {
        let sourceIndex: Int, parachuteID: Int, payloadID: Int
        let reward: PayloadKind?
        let resources: Resources
        let remainingForceDelta: Int
        let transitionCounter: Int?
    }
    enum Event: Equatable {
        case planeActivated(sourceIndex: Int, objectID: Int)
        case planeDeparted(sourceIndex: Int, objectID: Int)
        case planeReversed(sourceIndex: Int, objectID: Int)
        case parachuteReleased(sourceIndex: Int, parachuteID: Int, payloadID: Int, kind: PayloadKind, position: Vector)
        case boxLanded(sourceIndex: Int, parachuteID: Int, payloadID: Int, position: Vector)
        case trooperLanded(sourceIndex: Int, parachuteID: Int, objectID: Int, position: Vector)
        case remainingForceChanged(sourceIndex: Int, amount: Int)
        case planeDestroyed(sourceIndex: Int, objectID: Int, position: Vector)
        case planeCrashed(sourceIndex: Int, objectID: Int, position: Vector)
        case smoke(sourceIndex: Int, position: Vector)
    }

    let direction: Direction
    let cargoDescent: SupplyDescent
    private(set) var planes: [Plane]
    private(set) var parachutes = (294..<358).map { Parachute(objectID:$0) }
    private(set) var boxes = (454..<470).map { Payload(objectID:$0,kind:PayloadKind(rawValue:($0-454)/4)!) }
    private(set) var airborneTroopers: [Payload] = []
    /// Compatibility fix: the original monotonically incremented a96-slot
    /// infantry table beyond its allocated range in authored later levels.
    /// Preserve its first96 IDs, then use disjoint monotonic IDs>=1000 instead
    /// of corrupting box memory or overwriting living troops. This safe overflow
    /// is a native-port repair, not a claim of an original ring allocator.
    static func safeTrooperID(ordinal:Int)->Int {
        precondition(ordinal>=0);return ordinal<96 ? 358+ordinal:1000+ordinal-96
    }
    static func isTrooperID(_ id:Int)->Bool {(358..<454).contains(id)||id>=1000}
    private var nextParachute = 0
    private var nextBox = [0,0,0,0]
    var initialRequiredForce: Int {
        planes.reduce(0) { result,plane in
            result + ((plane.declaration.delay == nil || (plane.declaration.delay ?? 0)>0)
                ? plane.declaration.troops1+plane.declaration.troops2 : 0)
        }
    }

    init(declarations: [Declaration], direction: Direction, cargoDescent: SupplyDescent = .original) {
        precondition(Set(declarations.map(\.slot)).count == declarations.count, "Duplicate C130 slots")
        self.direction=direction
        self.cargoDescent=cargoDescent
        planes=declarations.sorted { $0.slot < $1.slot }.map(Plane.init)
    }

    /// Scheduler does not create records. It only activates a hidden declared
    /// plane when --delay==0; destroyed planes with delay0 are never revived.
    @discardableResult
    mutating func updateScheduler() -> [Event] {
        var events: [Event]=[]
        for i in planes.indices where !planes[i].visible {
            planes[i].delayCountdown -= 1
            if planes[i].delayCountdown == 0 {
                planes[i].visible=true; planes[i].state = .initialize
                events.append(.planeActivated(sourceIndex:planes[i].sourceIndex,objectID:planes[i].objectID))
            }
        }
        return events
    }

    @discardableResult
    mutating func updateAI(random: () -> UInt32, terrainHeight: (Float,Float)->Float,
                           smokeTick: Bool, allocateTrooperID: () -> Int) -> [Event] {
        updateAircraft(random: random, terrainHeight: terrainHeight, smokeTick: smokeTick,
                       allocateTrooperID: allocateTrooperID) + updatePayloads(terrainHeight: terrainHeight)
    }

    /// FUN_004051c8 visits C130 before Jets, and payloads after CH53.
    @discardableResult
    mutating func updateAircraft(random: () -> UInt32, terrainHeight: (Float,Float)->Float,
                                smokeTick: Bool, deathsOnly: Bool = false, allocateTrooperID: () -> Int) -> [Event] {
        var events: [Event]=[]
        for i in planes.indices where planes[i].visible && (!deathsOnly || planes[i].isCrashing) {
            switch planes[i].state {
            case .inactive:
                planes[i].visible=false
                events.append(.planeDeparted(sourceIndex:planes[i].sourceIndex,objectID:planes[i].objectID))
            case .initialize:
                planes[i].pitch=0; planes[i].position.y=Float(4000+(draw(random)>>4))
                planes[i].speed=140; planes[i].hp=8; planes[i].state = .inbound
                switch direction {
                case .random: planes[i].yaw=Float(draw(random)>>7)*1.40625
                case .north: planes[i].yaw=180
                case .south: planes[i].yaw=0
                case .east: planes[i].yaw=90
                case .west: planes[i].yaw=270
                }
                let distance=Float(draw(random)>>1)+32000
                var lateral=Float(draw(random)>>2)-4096
                if planes[i].declaration.far { lateral += lateral >= 0 ? 4096 : -4096 }
                let angle=Double(planes[i].yaw*0.017453292)
                planes[i].position.x=Float(cos(angle)*Double(lateral)+sin(angle)*Double(distance))
                planes[i].position.z=Float(cos(angle)*Double(distance)-sin(angle)*Double(lateral))
            case .inbound:
                let bound: Float=planes[i].declaration.far ? 9000 : 5000
                if abs(planes[i].position.x)<bound && abs(planes[i].position.z)<bound {
                    planes[i].dropCountdown=1; planes[i].state = .dropping
                    planes[i].dropsRemaining=planes[i].declaration.drops
                }
            case .dropping:
                planes[i].dropCountdown -= 1
                let p=planes[i].position
                if planes[i].dropCountdown<1 && sqrt(p.x*p.x+p.z*p.z)>800 {
                    planes[i].alternateFlag ^= 1
                    var kind=min(4,draw(random)>>12)
                    if (kind<4 && planes[i].dropsRemaining[kind]==0) || (kind==4 && planes[i].troops1==0) {
                        if planes[i].troops1>0 { kind=4 }
                        else if let available=planes[i].dropsRemaining.firstIndex(where:{$0>0}) { kind=available }
                        else {
                            planes[i].state = .outbound
                            planes[i].troops1=planes[i].troops2; planes[i].troops2=0
                            integrate(&planes[i])
                            continue
                        }
                    }
                    let chuteID=294+nextParachute
                    let payloadKind=PayloadKind(rawValue:kind)!
                    let payloadID: Int
                    if kind==4 {
                        payloadID=allocateTrooperID()
                        precondition(Self.isTrooperID(payloadID), "Use original358...453 or safe overflow>=1000")
                        precondition(!airborneTroopers.contains{$0.objectID==payloadID},"Do not overwrite an active airborne infantry ID")
                        airborneTroopers.append(Payload(objectID:payloadID,kind:.trooper,
                            sourceIndex:planes[i].sourceIndex,parentParachuteID:chuteID,
                            visible:true,position:Vector(x:0,y:-300,z:0)))
                        planes[i].troops1 -= 1
                    } else {
                        let boxIndex=kind*4+nextBox[kind]
                        payloadID=454+boxIndex
                        boxes[boxIndex].sourceIndex=planes[i].sourceIndex
                        boxes[boxIndex].parentParachuteID=chuteID; boxes[boxIndex].visible=true
                        boxes[boxIndex].position=Vector(x:0,y:-250,z:0)
                        nextBox[kind]=(nextBox[kind]+1)%4
                        planes[i].dropsRemaining[kind] -= 1
                    }
                    parachutes[nextParachute].sourceIndex=planes[i].sourceIndex
                    parachutes[nextParachute].visible=true; parachutes[nextParachute].position=p
                    parachutes[nextParachute].yaw=planes[i].yaw
                    parachutes[nextParachute].pitch=payloadKind == .trooper ? 45 : cargoDescent.releasePitch(original:45)
                    parachutes[nextParachute].angularVelocity=0; parachutes[nextParachute].payloadID=payloadID
                    parachutes[nextParachute].payloadKind=payloadKind
                    events.append(.parachuteReleased(sourceIndex:planes[i].sourceIndex,
                        parachuteID:chuteID,payloadID:payloadID,kind:payloadKind,position:p))
                    nextParachute=(nextParachute+1)%64
                    planes[i].dropCountdown=8
                }
            case .outbound:
                if abs(planes[i].position.x)>48000 || abs(planes[i].position.z)>48000 {
                    planes[i].passesRemaining -= 1
                    if planes[i].passesRemaining==0 { planes[i].state = .inactive }
                    else {
                        planes[i].yaw += 180; planes[i].state = .inbound
                        events.append(.planeReversed(sourceIndex:planes[i].sourceIndex,objectID:planes[i].objectID))
                    }
                }
            case .beginCrash:
                planes[i].targetPitchRate = -0.5; planes[i].state = .crashing
            case .crashing:
                if smokeTick {
                    let p=planes[i].position
                    events.append(.smoke(sourceIndex:planes[i].sourceIndex,
                        position:Vector(x:p.x+Float((draw(random)>>8)-64),
                                        y:p.y+Float((draw(random)>>9)-32),
                                        z:p.z+Float((draw(random)>>8)-64))))
                }
                if planes[i].pitch < -20 { planes[i].targetPitchRate=0 }
                let p=planes[i].position
                let ground=(abs(p.x)<15000 && abs(p.z)<15000) ? terrainHeight(p.x,p.z) : 0
                if p.y<ground+100 {
                    planes[i].visible=false
                    events.append(.planeCrashed(sourceIndex:planes[i].sourceIndex,objectID:planes[i].objectID,position:p))
                    events.append(.remainingForceChanged(sourceIndex:planes[i].sourceIndex,amount:-(planes[i].troops1+planes[i].troops2)))
                }
            }
            integrate(&planes[i])
        }

        return events
    }

    @discardableResult
    mutating func updatePayloads(terrainHeight: (Float,Float)->Float) -> [Event] {
        var events: [Event]=[]
        // Unlike BH2000, this loop follows C130, so new chutes fall immediately.
        for i in parachutes.indices where parachutes[i].visible {
            let motion:SupplyDescent = parachutes[i].payloadKind == .trooper ? .original : cargoDescent
            let swing=motion.nextSwing(pitch:parachutes[i].pitch,velocity:parachutes[i].angularVelocity)
            parachutes[i].pitch=swing.0; parachutes[i].angularVelocity=swing.1
            parachutes[i].position.y -= motion.centimetresPerTick
        }
        for i in boxes.indices where boxes[i].visible && boxes[i].parentParachuteID>=294 {
            let chuteIndex=boxes[i].parentParachuteID-294
            let p=parachutes[chuteIndex].position
            let height=terrainHeight(p.x,p.z)
            if p.y-300<height {
                parachutes[chuteIndex].visible=false; boxes[i].visible=false
                boxes[i].parentParachuteID = -1; boxes[i].position=Vector(x:p.x,y:height,z:p.z)
                events.append(.boxLanded(sourceIndex:boxes[i].sourceIndex,
                    parachuteID:294+chuteIndex,payloadID:boxes[i].objectID,position:boxes[i].position))
            }
        }
        // Original infantry loop runs in ascending model-slot order.
        airborneTroopers.sort { $0.objectID<$1.objectID }
        for i in airborneTroopers.indices where airborneTroopers[i].visible {
            let chuteIndex=airborneTroopers[i].parentParachuteID-294
            let p=parachutes[chuteIndex].position
            let height=terrainHeight(p.x,p.z)
            if p.y-300<height {
                parachutes[chuteIndex].visible=false
                airborneTroopers[i].visible=false
                events.append(.trooperLanded(sourceIndex:airborneTroopers[i].sourceIndex,
                    parachuteID:294+chuteIndex,objectID:airborneTroopers[i].objectID,
                    position:Vector(x:p.x,y:height,z:p.z)))
            }
        }
        airborneTroopers.removeAll { !$0.visible }
        return events
    }

    /// Explicit external retirement removes only this module's child record;
    /// its old chute keeps falling and no force is changed. The native shared
    /// allocator never reuses live IDs, so normal APC/CH53 allocation does not
    /// call this compatibility hook.
    /// Do not call from updateAI's allocator closure: this is a mutating struct.
    mutating func retireTrooper(objectID:Int) {
        precondition(Self.isTrooperID(objectID))
        airborneTroopers.removeAll {$0.objectID==objectID}
    }

    /// Call after a mesh hit on original C130 shape6. Part0 destroys immediately;
    /// part1 costs2HP, part2 costs1HP, other parts cause impact only. No BH2000
    /// score penalty applies here. Unreleased troops disappear only at destruction.
    @discardableResult
    mutating func hitPlane(objectID: Int, by weapon: PlaneWeapon) -> [Event] {
        guard let i=planes.firstIndex(where:{$0.objectID==objectID}),planes[i].visible else {return []}
        if case .commonBullet(let part)=weapon,part != 0 {
            if planes[i].hp>0 {
                if part==1 {planes[i].hp -= 2}
                if part==2 {planes[i].hp -= 1}
                if planes[i].hp<1 {planes[i].state = .beginCrash}
            }
            return []
        }
        planes[i].visible=false
        return [.planeDestroyed(sourceIndex:planes[i].sourceIndex,objectID:objectID,position:planes[i].position),
                .remainingForceChanged(sourceIndex:planes[i].sourceIndex,amount:-(planes[i].troops1+planes[i].troops2))]
    }

    /// Both common-bullet and cannon supply paths use this rule. The caller
    /// must not route missile hits here: no missile pickup path is established.
    /// Original collision mode7, broad phase<700, segment-depth parameter500
    /// (common bullet) or400 (cannon). The current child ID selects the reward.
    mutating func collect(parachuteID: Int, resources: Resources) -> Collection? {
        guard (294..<358).contains(parachuteID),parachutes[parachuteID-294].visible else {return nil}
        let chute=parachutes[parachuteID-294]
        parachutes[parachuteID-294].visible=false
        let id=chute.payloadID
        if (454..<470).contains(id) {boxes[id-454].visible=false}
        airborneTroopers.removeAll {$0.objectID==id}
        var result=resources
        var reward: PayloadKind?
        if (454..<458).contains(id) {reward = .defense; result.defense += 15}
        if (458..<462).contains(id) {reward = .machineGun; result.machineGun += 50}
        if (462..<466).contains(id) {reward = .cannon; result.cannon += 4}
        // The original skipped its fourth missile slot. Every marked missile
        // crate in Depthline redeems the payload it advertises.
        if (466..<469).contains(id) || (id == 469 && cargoDescent == .depthlineCargo) {
            reward = .missile; result.missile += 2
        }
        return Collection(sourceIndex:chute.sourceIndex,parachuteID:parachuteID,payloadID:id,
            reward:reward,resources:result,remainingForceDelta:chute.payloadKind == .trooper ? -1 : 0,
            transitionCounter:reward == nil ? nil : 150)
    }

    private func draw(_ random:()->UInt32)->Int {
        let n=random(); precondition(n<=32767,"Original RNG must return0...32767"); return Int(n)
    }
    private func integrate(_ p: inout Plane) {
        p.yawRate=Float(Double(p.targetYawRate)*0.08+Double(p.yawRate)*0.92)
        p.pitchRate=Float(Double(p.targetPitchRate)*0.08+Double(p.pitchRate)*0.92)
        p.pitch += p.pitchRate; p.yaw += p.yawRate
        if p.yaw>180 {p.yaw -= 360}; if p.yaw < -180 {p.yaw += 360}
        let pc=Float(cos(Double(p.pitch)*0.017453292)),ps=Float(sin(Double(p.pitch)*0.017453292))
        let yc=Float(cos(Double(p.yaw)*0.017453292)),ys=Float(sin(Double(p.yaw)*0.017453292))
        p.position.x += (-pc*ys)*p.speed; p.position.y += ps*p.speed; p.position.z += (-pc*yc)*p.speed
    }
}

extension Beach2002Supply {
    struct TestFailure: Error,CustomStringConvertible {let description:String}
    static func runTests() throws {
        func check(_ value:@autoclosure()->Bool,_ message:String)throws {
            if !value() {throw TestFailure(description:message)}
        }
        let authored = declarations(from: [
            ["type":"TANK"],
            ["type":"C130","slot":3,"delay":0,"far":true,"troops1":20],
            ["type":"C130","Far":true,"pasess":1],
            ["type":"C130","slot":8]
        ])
        try check(authored.map(\.slot) == [3, 1] && authored.map(\.sourceIndex) == [1, 2],
                  "C130 declarations preserve source IDs, explicit slots and the old implicit ordinals")
        try check(authored[0].far && authored[0].delay == 0 && authored[0].troops1 == 16 &&
                  !authored[1].far && authored[1].delay == nil && authored[1].passes == 127,
                  "C130 reads only the original case-sensitive field names and preserves an explicit zero delay")
        let flat:(Float,Float)->Float={_,_ in 0},zero:()->UInt32={0}
        var nextTroop=358
        func allocate()->Int {defer {nextTroop += 1};return nextTroop}
        func fixture(_ d:Declaration, motion:SupplyDescent = .original)->Beach2002Supply {
            var s=Beach2002Supply(declarations:[d],direction:.south,cargoDescent:motion)
            s.planes[0].visible=true;s.planes[0].state = .dropping
            s.planes[0].position=Vector(x:2000,y:4000,z:0)
            s.planes[0].dropsRemaining=d.drops;s.planes[0].dropCountdown=1
            return s
        }
        func drop(_ s:inout Beach2002Supply,_ random:UInt32=0)->[Event] {
            s.planes[0].state = .dropping;s.planes[0].dropCountdown=1
            return s.updateAI(random:{random},terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        }
        // Drive release to actual landing; newer cargo takes longer, while the
        // soldier carried by the same plane retains his exact source pose/time.
        for (motion, expectedBox) in [(SupplyDescent.original,371),(.depthlineCargo,673)] {
            let d=Declaration(sourceIndex:1,slot:0,troops1:1,hdrop:1)
            var cargo=fixture(d,motion:motion)
            _=cargo.updateAircraft(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:{358})
            cargo.planes[0].dropCountdown=1
            _=cargo.updateAircraft(random:{16384},terrainHeight:flat,smokeTick:false,allocateTrooperID:{358})
            try check(cargo.parachutes[0].pitch==(motion == .depthlineCargo ? 12:45) && cargo.parachutes[1].pitch==45,
                      "Distinct cargo/infantry opening swing")
            var landings:[Int:Int]=[:]
            for tick in 1...700 {
                for event in cargo.updatePayloads(terrainHeight:flat) {
                    switch event {
                    case .boxLanded(_,let chute,_,_),.trooperLanded(_,let chute,_,_):landings[chute]=tick
                    default:break
                    }
                }
            }
            try check(landings==[294:expectedBox,295:371],"40 m cargo and infantry landing times for \(motion)")
        }
        var s=Beach2002Supply(declarations:[],direction:.north)
        for _ in 0..<500 {
            try check(s.updateScheduler().isEmpty,"No undeclared scheduler spawn")
            try check(s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate).isEmpty,"Level01 has no invented C130")
        }
        try check(s.initialRequiredForce==0 && s.planes.isEmpty,"Empty declaration inventory")
        let safeIDs=(0..<220).map(Self.safeTrooperID)
        try check(Set(safeIDs).count==220 && safeIDs[95]==453 && safeIDs[96]==1000 && safeIDs[219]==1123,"Safe shared allocator keeps original96 IDs then unique overflow")
        try check(safeIDs.allSatisfy(Self.isTrooperID) && safeIDs.allSatisfy{!(454..<470).contains($0)},"Expanded infantry never aliases supply boxes")
        let delayed=Declaration(sourceIndex:31,slot:2,delay:3,troops1:2,troops2:3,hdrop:1)
        s=Beach2002Supply(declarations:[delayed],direction:.south)
        try check(s.initialRequiredForce==5 && !s.planes[0].visible,"Delayed cargo already counts toward force")
        _=s.updateScheduler();_=s.updateScheduler()
        try check(s.updateScheduler()==[.planeActivated(sourceIndex:31,objectID:212)],"Exact Delay activation and source attribution")
        var sequence:[UInt32]=[0,0,16384]
        _=s.updateAI(random:{sequence.removeFirst()},terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(s.planes[0].position==Vector(x:0,y:4000,z:31860) && s.planes[0].hp==8,"Source initial position and same-tick forward motion")
        s=Beach2002Supply(declarations:[Declaration(sourceIndex:0,slot:0,delay:0,troops1:3)],direction:.south)
        for _ in 0..<10 {try check(s.updateScheduler().isEmpty,"Explicit Delay0 never reaches0 after decrement")}
        try check(s.initialRequiredForce==0,"Hidden Delay0 does not add force")

        s=fixture(Declaration(sourceIndex:7,slot:0,hdrop:1))
        let first=drop(&s)
        try check(first.first == .parachuteReleased(sourceIndex:7,parachuteID:294,payloadID:454,kind:.defense,position:Vector(x:2000,y:4000,z:0)),"Actual IDs and per-source release event")
        try check(s.parachutes[0].position.y==3990 && abs(s.parachutes[0].pitch-44.64)<0.001,"2002 new drop moves in SAME tick")
        try check(s.boxes[0].position.y == -250 && s.boxes[0].parentParachuteID==294,"Box local link offset")
        let base=Resources(defense:95,machineGun:490,cannon:19,missile:19)
        let health=s.collect(parachuteID:294,resources:base)
        try check(health?.resources.defense==110 && health?.transitionCounter==150,"Reward precedes final global cap")
        var capped=health!.resources;capped.applyOriginalCaps()
        try check(capped.defense==100,"Per-update health cap100")
        try check(s.collect(parachuteID:294,resources:base)==nil,"Collected chute cannot grant twice")

        // All four supply kinds, source caps, and original fourth-missile anomaly.
        s=fixture(Declaration(sourceIndex:8,slot:0,adrop:1,pdrop:1,mdrop:4))
        _=drop(&s,4096)
        let ammo=s.collect(parachuteID:294,resources:base)!
        try check(ammo.resources.machineGun==540 && ammo.reward == .machineGun,"MG+50")
        _=drop(&s,8192)
        let shell=s.collect(parachuteID:295,resources:base)!
        try check(shell.resources.cannon==23 && shell.reward == .cannon,"Cannon+4")
        for j in 0..<4 {_=drop(&s,12288);let m=s.collect(parachuteID:296+j,resources:base)!
            try check(m.payloadID==466+j,"Four independent missile-box ring slots")
            try check(m.resources.missile==(j==3 ? 19:21) && (m.reward == nil)==(j==3),"Original469 exclusion preserved")
        }
        s=fixture(Declaration(sourceIndex:8,slot:0,mdrop:4),motion:.depthlineCargo)
        for j in 0..<4 {
            _=drop(&s,12288)
            let marked=s.collect(parachuteID:294+j,resources:base)!
            try check(marked.payloadID==466+j && marked.reward == .missile && marked.resources.missile==21,"Every marked missile crate redeems its payload")
        }
        capped=Resources(defense:110,machineGun:540,cannon:23,missile:21);capped.applyOriginalCaps()
        try check(capped==Resources(defense:100,machineGun:500,cannon:20,missile:20),"All original post-update caps")

        // Random unavailable kind prefers troops, then H/A/P/M supply order.
        s=fixture(Declaration(sourceIndex:9,slot:0,troops1:1,troops2:2,hdrop:1,adrop:1))
        nextTroop=358;_=drop(&s,8192)
        try check(s.parachutes[0].payloadID==358 && s.planes[0].troops1==0,"Unavailable shell selection falls back to troop")
        try check(s.airborneTroopers[0].position.y == -300,"Paratrooper child offset")
        let killed=s.collect(parachuteID:294,resources:base)!
        try check(killed.remainingForceDelta == -1 && killed.reward==nil && killed.transitionCounter==nil,"Midair trooper hit removes1 force without supply reward")
        _=drop(&s,32767);_=drop(&s,32767)
        try check(s.parachutes[1].payloadID==454 && s.parachutes[2].payloadID==458,"Fallback H then A order")
        _=drop(&s,0)
        try check(s.planes[0].state == .outbound && s.planes[0].troops1==2 && s.planes[0].troops2==0,"Empty first pass transfers second troop load")
        var overflow=fixture(Declaration(sourceIndex:90,slot:0,troops1:1))
        _=overflow.updateAI(random:{16384},terrainHeight:flat,smokeTick:false,allocateTrooperID:{1000})
        try check(overflow.airborneTroopers.first?.objectID==1000 && overflow.parachutes[0].payloadKind == .trooper,"Overflow payload retains its type")
        let overflowHit=overflow.collect(parachuteID:294,resources:base)!
        try check(overflowHit.remainingForceDelta == -1 && overflowHit.reward==nil && overflowHit.resources==base,"Overflow trooper collection removes force without awarding box resources")

        // Gate strictness, eight ticks between drops, and central800 exclusion.
        s=fixture(Declaration(sourceIndex:10,slot:0,hdrop:2))
        s.planes[0].state = .inbound;s.planes[0].position.x=5000
        _=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(s.planes[0].state == .inbound,"Normal gate excludes exactly5000")
        s.planes[0].position.x=4999
        _=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(s.planes[0].state == .dropping && s.planes[0].dropCountdown==1,"Gate prepares next-tick drop")
        _=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        for _ in 0..<7 {_=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)}
        try check(!s.parachutes[1].visible,"Second drop waits eight ticks")
        _=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(s.parachutes[1].visible,"Second drop on eighth tick")
        s=fixture(Declaration(sourceIndex:10,slot:0,hdrop:1));s.planes[0].position.x=800
        try check(drop(&s).isEmpty,"No cargo within radial800")

        // Aircraft preserve HP on reversal and rearm declared supplies each pass.
        s=fixture(Declaration(sourceIndex:11,slot:0,passes:2,hdrop:1));s.planes[0].state = .outbound
        s.planes[0].position.x=48001;s.planes[0].hp=3
        let reversed=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(reversed.contains(.planeReversed(sourceIndex:11,objectID:210)) && s.planes[0].hp==3 && s.planes[0].passesRemaining==1,"Reverse heading preserves HP")
        s.planes[0].state = .outbound;s.planes[0].position.x=48001
        _=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(s.planes[0].visible && s.planes[0].state == .inactive,"Last pass hides on following state0 update")
        _=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(!s.planes[0].visible,"State0 clears all plane parts")

        // Landing hands off troop at terrain, but discards boxes without reward.
        s=fixture(Declaration(sourceIndex:12,slot:0,troops1:1,hdrop:1));nextTroop=358
        _=drop(&s,16384);_=drop(&s,0)
        s.parachutes[0].position.y=310;s.parachutes[1].position.y=309
        s.planes[0].visible=false
        var land=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(!land.contains {if case .trooperLanded = $0{return true};return false},"At y300 troop is still airborne")
        try check(land.contains {if case .boxLanded = $0{return true};return false},"Supply box disappears below y300")
        land=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(land.contains(.trooperLanded(sourceIndex:12,parachuteID:294,objectID:358,position:Vector(x:2000,y:0,z:0))) && s.airborneTroopers.isEmpty,"Troop landing preserves source and does not change force")
        nextTroop=358
        s=fixture(Declaration(sourceIndex:12,slot:0,troops1:1));_=drop(&s,16384)
        let oldChute=s.parachutes[0]
        s.retireTrooper(objectID:358)
        try check(s.airborneTroopers.isEmpty&&s.parachutes[0].visible&&s.parachutes[0].payloadID==358,"Shared infantry reuse retires old child without deleting original stale chute link")
        let afterReuse=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(!afterReuse.contains{if case .remainingForceChanged=$0{return true};if case .trooperLanded=$0{return true};return false},"External slot reuse makes no implicit force or landing event")
        try check(s.parachutes[0].position.y==oldChute.position.y-10,"Old canopy continues its independent falling loop")

        // C130 is not a BH2000 friendly score penalty; carried troop cancellation.
        s=fixture(Declaration(sourceIndex:13,slot:0,troops1:3,troops2:2))
        _=s.hitPlane(objectID:210,by:.commonBullet(part:2))
        _=s.hitPlane(objectID:210,by:.commonBullet(part:1))
        try check(s.planes[0].hp==5,"C130 part2 minus1 and part1 minus2")
        let destroyed=s.hitPlane(objectID:210,by:.commonBullet(part:0))
        try check(destroyed.contains(.remainingForceChanged(sourceIndex:13,amount:-5)) && !s.planes[0].visible,"Part0 immediately destroys and cancels only carried troops")
        try check(s.hitPlane(objectID:210,by:.missile).isEmpty,"Destroyed plane cannot cancel force twice")
        for _ in 0..<100 {try check(s.updateScheduler().isEmpty,"Destroyed original slot never respawns")}

        // Far lateral offset and strict9000 gate come from actual declarations.
        s=Beach2002Supply(declarations:[Declaration(sourceIndex:16,slot:0,far:true,hdrop:1)],direction:.south)
        sequence=[0,0,16384]
        _=s.updateAI(random:{sequence.removeFirst()},terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(s.planes[0].position.x==4096,"Far nonnegative lateral adds4096")
        s.planes[0].position=Vector(x:9000,y:4000,z:0)
        _=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(s.planes[0].state == .inbound,"Far gate excludes exactly9000")
        s.planes[0].position.x=8999
        _=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(s.planes[0].state == .dropping,"Far gate includes8999")

        // Shared rings overwrite fixed original objects, even while older
        // canopies still reference that box. Preserve that behavior explicitly.
        s=fixture(Declaration(sourceIndex:17,slot:0,hdrop:4))
        for _ in 0..<65 {
            s.planes[0].dropsRemaining[0]=1
            _=drop(&s)
        }
        try check(s.nextParachute==1 && s.nextBox[0]==1,"64-canopy and4-box rings wrap independently")
        try check(s.parachutes[0].payloadID==454 && s.boxes[0].parentParachuteID==294,
                  "Ring wraps reassign actual object links")
        try check(s.parachutes[4].payloadID==454 && s.parachutes[4].visible,
                  "Old canopy retains reused child ID as in original array links")

        // Fatal engine hit cancels remaining troops at impact, not on HP0.
        s=fixture(Declaration(sourceIndex:18,slot:0,troops1:2,troops2:1))
        s.planes[0].hp=1
        try check(s.hitPlane(objectID:210,by:.commonBullet(part:2)).isEmpty && s.planes[0].state == .beginCrash,
                  "Fatal part2 starts deferred crash")
        _=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        s.planes[0].position.y=99
        let impact=s.updateAI(random:zero,terrainHeight:flat,smokeTick:false,allocateTrooperID:allocate)
        try check(impact.contains(.remainingForceChanged(sourceIndex:18,amount:-3)) && !s.planes[0].visible,
                  "Impact cancels exact remaining cargo without score fabrication")

        // Real ticks and RNG complete a declared two-pass delivery, no invention.
        s=Beach2002Supply(declarations:[Declaration(sourceIndex:15,slot:0,passes:2,hdrop:1)],direction:.north)
        var rng=Random(seed:42),releaseCount=0
        for tick in 0..<2500 {
            let events=s.updateAI(random:{rng.next()},terrainHeight:flat,smokeTick:tick%2==0,allocateTrooperID:allocate)
            releaseCount += events.filter {if case .parachuteReleased = $0{return true};return false}.count
            _=s.updateScheduler()
            try check(s.planes[0].position.x.isFinite && s.planes[0].position.z.isFinite,"Finite original flight")
        }
        try check(releaseCount==2 && !s.planes[0].visible,"Exactly declared two passes with rearmed supply")
    }
}

#if BEACH2002_SUPPLY_TESTS
@main
private struct Beach2002SupplyTestRunner {
    static func main() throws {
        try Beach2002Supply.runTests()
        print("PASS: BH2002 declared supply, timing, rings, cargo, collection, force, damage and pass rules")
    }
}
#endif
