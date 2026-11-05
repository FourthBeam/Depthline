import Foundation

/// Recovered single-source ignition latch, NOT a persistent damaging ground zone.
/// Original coordinates/ticks. Evidence:2000 0x416a09:2983...3054,3627...3796;
/// 2002 0x4154b7:2651...2702; crash writes in0x4051c8:1809,2338,3041,5006.
/// Call noteCrash during AI, noteHit AFTER a confirmed original collision (using
/// its pre-hit state), takeIgnition after old projectiles, then endProjectilePhase
/// before the scheduler. The latter writes next tick's latch. Multiple writes
/// overwrite one source, matching DAT46eee4 / DAT447900; there is no repeated DOT.
///
/// if let trigger=burning.takeIgnition(),let p=trigger.position(using:objectPosition) {
///   //2000: consume(original2000AI.burnInfantry(near:p,random:rand))
///   //2002: for active infantry with matches(gameID,state,position,center:p),
///   // consume(infantry.beginBurning()). Render flame from its burningVisual.
/// }
/// burning.endProjectilePhase()
/// Do not separately subtract force:2000 burnInfantry owns immediate-1/+1;
///2002 beginBurning removes prone30/38 immediately, others at death-frame end.
/// Attached flame animation has12 original slots; it is removed by the soldier
/// animation, not a fixed seconds timer. OriginalEffects owns that render pool.
struct OriginalBurning {
    enum Weapon:String {case bullet,cannon,missile}
    struct Trigger:Equatable {
        let sourceObjectID:Int
        let fallbackPosition:SIMD3<Double>?
        func position(using lookup:(Int)->SIMD3<Double>?)->SIMD3<Double>? {
            // Lookup wins: source position can change before this latch is read.
            lookup(sourceObjectID) ?? fallbackPosition
        }
    }
    private struct Delayed {
        let ownerID:Int,trigger:Trigger
        var ticks:Int
    }
    let gameID:String
    private(set) var pending:Trigger?
    private var delayed:[Int:Delayed]=[:]
    init(gameID:String) {precondition(gameID=="2000" || gameID=="2002");self.gameID=gameID}

    mutating func request(sourceObjectID:Int,position:SIMD3<Double>?=nil) {
        precondition(sourceObjectID>0)
        pending=Trigger(sourceObjectID:sourceObjectID,fallbackPosition:position)
    }

    /// Call only for an actual hit, with state BEFORE applying OriginalDamage.
    /// Tank part0 triggers even when it becomes a stationary wreck; a generic
    /// explosion/death boolean is insufficient to identify this original branch.
    @discardableResult
    mutating func noteHit(type:String,objectID:Int,position:SIMD3<Double>,previousState:Int,
                          weapon:Weapon,part:Int?)->Bool {
        let type=type.uppercased()
        let applies:Bool
        if gameID=="2000" {
            if type=="CH53" {
                applies=(previousState==11 || previousState==12) &&
                    ((weapon == .bullet && part==0) || weapon == .cannon)
            } else {
                applies=type=="TANK" && previousState != 20 && part==0 && (weapon == .cannon || weapon == .missile)
            }
        } else {
            if type=="CH53" {applies=weapon == .bullet && part==0 && (previousState==7 || previousState==8)}
            else {applies=type.hasPrefix("APC") && (weapon == .cannon || weapon == .missile) && (part ?? -1)>=0}
        }
        if applies {request(sourceObjectID:objectID,position:position)}
        return applies
    }

    /// Call on actual aircraft ground crash, not departure or midair breakup.
    @discardableResult
    mutating func noteCrash(type:String,objectID:Int,position:SIMD3<Double>)->Bool {
        let type=type.uppercased()
        if gameID=="2002" {
            guard ["JET","COBRA","CH53","C130"].contains(type) else {return false}
            request(sourceObjectID:objectID,position:position)
        } else {
            guard ["JET","BOMBER","B52","COBRA","CH53","C130"].contains(type) else {return false}
            // Original bug confirmed by assembly0x421c4f/53: C130 writes the
            // preceding CH53 loop's terminating index109, NOT its own207.
            // ev_008d8ed1f4e0804a2bd9ba8277551d7e6aeb6482c248ac4bbfc5dfe99c675eb0.
            // Resolver must supply object109's ORIGINAL LOCAL translation;
            // do not substitute the plane crash or transformed world position.
            let trigger=Trigger(sourceObjectID:type=="C130" ? 109:objectID,fallbackPosition:type=="C130" ? nil:position)
            delayed[objectID]=Delayed(ownerID:objectID,trigger:trigger,ticks:5)
        }
        return true
    }
    mutating func cancelDelayed(objectID:Int) {delayed.removeValue(forKey:objectID)}
    mutating func takeIgnition()->Trigger? {defer {pending=nil};return pending}

    /// Called once AFTER takeIgnition, even if the source model is now hidden.
    /// These loops follow the original Cobra,CH53,C130,B52,Jet writer order.
    mutating func endProjectilePhase() {
        guard gameID=="2000" else {return}
        let order=Array(88..<94)+Array(106..<109)+[207]+Array(73..<76)+Array(76..<88)
        for id in order {
            guard var item=delayed[id] else {continue}
            item.ticks -= 1
            if item.ticks==0 {pending=item.trigger;delayed.removeValue(forKey:id)}
            else {delayed[id]=item}
        }
    }

    static func matches(gameID:String,state:Int,position:SIMD3<Double>,center:SIMD3<Double>)->Bool {
        let valid=gameID=="2000" ? ((5..<21).contains(state)||(26..<32).contains(state)) : (1..<42).contains(state)
        return valid && hypot(position.x-center.x,position.z-center.z)<600
    }

    struct TestFailure:Error {let message:String}
    static func runTests() throws {
        func check(_ value:@autoclosure()->Bool,_ message:String)throws {if !value(){throw TestFailure(message:message)}}
        let zero=SIMD3<Double>.zero
        var old=OriginalBurning(gameID:"2000")
        try check(!old.noteHit(type:"TANK",objectID:37,position:zero,previousState:20,weapon:.cannon,part:0),"Dead tank cannot ignite again")
        try check(!old.noteHit(type:"CH53",objectID:106,position:zero,previousState:11,weapon:.bullet,part:1),"CH53 non-body hit does not ignite immediately")
        try check(old.noteHit(type:"TANK",objectID:37,position:zero,previousState:4,weapon:.missile,part:0),"Tank original hull-hit ignition")
        _=old.noteHit(type:"CH53",objectID:107,position:zero,previousState:12,weapon:.cannon,part:2)
        try check(old.takeIgnition()?.sourceObjectID==107 && old.takeIgnition()==nil,"Only last writer, consumed once")
        _=old.noteCrash(type:"COBRA",objectID:88,position:zero)
        _=old.noteCrash(type:"JET",objectID:76,position:zero)
        for _ in 0..<4 {old.endProjectilePhase();try check(old.takeIgnition()==nil,"No ignition before fifth post-hit phase")}
        old.endProjectilePhase()
        try check(old.takeIgnition()?.sourceObjectID==76,"Simultaneous crash timers preserve original writer order")
        _=old.noteCrash(type:"C130",objectID:207,position:SIMD3(9000,500,9000))
        for _ in 0..<5 {old.endProjectilePhase()}
        let c130=old.takeIgnition()!
        try check(c130.sourceObjectID==109 && c130.fallbackPosition==nil && c130.position(using:{$0==109 ? zero:nil})==zero,"Original C130 source109 bug preserved from assembly")
        _=old.noteCrash(type:"JET",objectID:76,position:zero);old.cancelDelayed(objectID:76)
        for _ in 0..<7 {old.endProjectilePhase()}
        try check(old.takeIgnition()==nil,"Revive clears original delayed fire flag")
        var newer=OriginalBurning(gameID:"2002")
        _=newer.noteCrash(type:"C130",objectID:210,position:zero)
        try check(newer.takeIgnition()?.sourceObjectID==210,"2002 crash ignites same tick")
        try check(!newer.noteCrash(type:"BOMBER",objectID:133,position:zero),"No invented2002 bomber ignition")
        try check(newer.noteHit(type:"APC2",objectID:77,position:zero,previousState:9,weapon:.cannon,part:3),"2002 APC all valid parts ignite")
        try check(!matches(gameID:"2000",state:21,position:zero,center:zero) && matches(gameID:"2002",state:21,position:zero,center:zero),"Version-specific infantry state gates")
        try check(matches(gameID:"2002",state:1,position:SIMD3(599,90000,0),center:zero) && !matches(gameID:"2002",state:2,position:SIMD3(600,0,0),center:zero),"Radius strictly below600, horizontal, includes2002 airborne state1")
    }
}

#if ORIGINAL_BURNING_TESTS
@main private struct OriginalBurningTestRunner {
    static func main() throws {try OriginalBurning.runTests();print("PASS: original ignition hit gates, last-writer latch, crash delays, C130109 bug, cancellation and infantry radius/states")}
}
#endif
