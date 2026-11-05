import Foundation
import AppKit

/// Sound buffers recovered from2000 FUN_0042a1e0 and2002 FUN_0042ac3c.
/// Original categories have independent buffers, not a global lastSound gate.
/// Most one-shots have duplicate buffers and rotating writers; single voice/
/// engine/Prize buffers can overlap OTHER sounds without restarting themselves.
/// This catalog preserves filenames, buffer counts and initial attenuation.
/// Engine category selection/distance is recovered below. One-shot positional
/// volume/pan/frequency still belong to AI adapters; this NSSound backend does
/// not claim DirectSound or original hardware mixing parity.
struct OriginalSoundCatalog {
    struct Entry:Equatable {
        let key:String,file:String,capacity:Int,initialHundredthsDB:Int
    }
    let gameID:String
    let entries:[String:Entry]
    init(gameID:String) {
        precondition(gameID=="2000" || gameID=="2002");self.gameID=gameID
        var all:[String:Entry]=[:]
        func add(_ name:String,_ count:Int=1,_ volume:Int=0,file:String?=nil) {
            all[name.lowercased()]=Entry(key:name,file:file ?? name,capacity:count,initialHundredthsDB:volume)
        }
        for name in ["Prize","Metalbig","Metalshort","ExBig","Tank","Jet","C130"] {add(name)}
        for (name,count) in [("AntiAir",10),("Pistol",2),("Missile",2),("Rifle",4),("ExClose",4),("ExFar",4),("ExMuffle",6),("ExHit",2)] {add(name,count)}
        if gameID=="2000" {
            for name in ["Radio","Bombfall","Metallong","HeliAttack","HeliTransport","B52"] {add(name)}
            add("CanonClose",2);add("CanonFar",2)
            for i in 1...5 {add("Ricocht\(i)");add("Soldead\(i)",1,-1000)}
        } else {
            add("MachineGun",10);add("CannonClose",2);add("CannonFar",2)
            for name in ["Truck","Bomber","Cobra","CH53"] {add(name)}
            for i in 1...4 {add("Ricocht\(i)",file:i==4 ? "Ricocht3":nil)}
            // Original0x42ac3c:324 creates slot33 from Ricocht3 a second time.
            // Separate buffer identity remains Ricocht4; do not merge the keys.
            for i in 1...4 {add("Soldead\(i)",1,i%2==1 ? -1500:-500)}
        }
        entries=all
    }
    func entry(_ requested:String)->Entry? {
        var name=requested.lowercased()
        if gameID=="2000" {
            name=["cannonclose":"canonclose","cannonfar":"canonfar","cobra":"heliattack","ch53":"helitransport","bomber":"b52"][name] ?? name
        } else {
            name=["canonclose":"cannonclose","canonfar":"cannonfar","heliattack":"cobra","helitransport":"ch53","b52":"bomber"][name] ?? name
        }
        return entries[name]
    }
    static func gain(hundredthsDB:Int)->Float {
        if hundredthsDB<=(-10000) {return 0}
        return Float(pow(10,Double(min(0,hundredthsDB))/2000))
    }
}

/// Pure per-sound writer state, separately testable without playing audio.
struct OriginalSoundChannels {
    struct Request:Equatable {let entry:OriginalSoundCatalog.Entry,slot:Int}
    let catalog:OriginalSoundCatalog
    private var writers:[String:Int]=[:]
    init(gameID:String) {catalog=OriginalSoundCatalog(gameID:gameID)}
    /// bufferSlot lets the caller preserve a source branch that explicitly uses
    /// a fixed buffer (some explosion branches use0 despite advancing a counter).
    /// With nil, use this category's recovered duplicate-buffer ring.
    mutating func request(_ name:String,bufferSlot:Int?=nil,advanceWriter:Bool=false)->Request? {
        guard let entry=catalog.entry(name) else {return nil}
        let writer=writers[entry.key,default:0]
        let slot=bufferSlot ?? writer
        precondition((0..<entry.capacity).contains(slot))
        // Several2000 branches play the base buffer but advance the same counter
        // later used by a genuinely indexed branch (e.g. artillery ExMuffle).
        if bufferSlot==nil || advanceWriter {writers[entry.key]=(writer+1)%entry.capacity}
        return Request(entry:entry,slot:slot)
    }
    mutating func reset() {writers.removeAll()}
}

/// Engine mixer from2000 0x4252fc /2002 0x424aef. Distance is the nearest
/// object's max(abs(x),abs(z)), NOT Euclidean distance or camera-relative XYZ.
enum OriginalEngineSound {
    struct Source {let objectID:Int,state:Int,position:SIMD3<Double>,visible:Bool}
    struct Loop {let name:String,active:Bool,attenuationHundredthsDB:Int}
    static func mix(gameID:String,sources:[Source])->[Loop] {
        struct Rule {let name:String,ids:Set<Int>,limit:Int,shift:Int,excludedState:Int?}
        let rules:[Rule]
        if gameID=="2000" {
            rules=[.init(name:"C130",ids:[207],limit:30000,shift:3,excludedState:nil),
                   .init(name:"B52",ids:Set(73..<76),limit:18000,shift:2,excludedState:nil),
                   .init(name:"Jet",ids:Set(76..<88),limit:30000,shift:3,excludedState:nil),
                   .init(name:"HeliAttack",ids:Set(88..<94),limit:18000,shift:2,excludedState:nil),
                   .init(name:"HeliTransport",ids:Set(106..<109),limit:18000,shift:2,excludedState:nil),
                   .init(name:"Tank",ids:Set(Array(37..<43)+Array(61..<64)),limit:6500,shift:0,excludedState:20)]
        } else {
            rules=[.init(name:"Tank",ids:Set(37..<49),limit:6500,shift:0,excludedState:0),
                   .init(name:"Truck",ids:Set(73..<85),limit:6500,shift:0,excludedState:0),
                   .init(name:"Jet",ids:Set(117..<133),limit:30000,shift:3,excludedState:nil),
                   .init(name:"Bomber",ids:Set(133..<142),limit:18000,shift:2,excludedState:nil),
                   .init(name:"Cobra",ids:Set(142..<154),limit:18000,shift:2,excludedState:nil),
                   .init(name:"CH53",ids:Set(178..<186),limit:18000,shift:2,excludedState:nil),
                   .init(name:"C130",ids:Set(210..<218),limit:30000,shift:3,excludedState:nil)]
        }
        return rules.map {rule in
            let distance=sources.filter {$0.visible && rule.ids.contains($0.objectID) && rule.excludedState != $0.state}
                .map {max(Int(abs($0.position.x)),Int(abs($0.position.z)))}.min() ?? 999999
            //2002 Jet alone negates before arithmetic-shifting (0x424aef:110).
            let attenuation=gameID=="2002" && rule.name=="Jet" ? (-distance)>>rule.shift : -(distance>>rule.shift)
            return Loop(name:rule.name,active:distance<=rule.limit,attenuationHundredthsDB:attenuation)
        }
    }
}

/// Native adapter. Usage: sound=OriginalSoundRenderer(gameID:assets.gameID,
/// soundDirectory:assets.root.appendingPathComponent("sounds"));
/// sound.enabled=settings.soundEnabled; sound.play("AntiAir"); sound.play("Prize").
/// One-shot calls don't interrupt other categories or a busy selected buffer.
/// setLoop updates one original engine buffer; stopAll is for pause/level exit.
/// masterVolume0.25 is an explicit Mac mixing policy, not recovered Windows
/// hardware output. The recovered initial DS attenuation is applied on top.
final class OriginalSoundRenderer {
    private var channels:OriginalSoundChannels
    private let soundDirectory:URL
    private var buffers:[String:[NSSound?]]=[:]
    var masterVolume:Float=0.25 {
        didSet {masterVolume=max(0,min(1,masterVolume))}
    }
    var enabled=true {didSet {if !enabled {stopAll()}}}
    init(gameID:String,soundDirectory:URL) {
        channels=OriginalSoundChannels(gameID:gameID);self.soundDirectory=soundDirectory
    }
    @discardableResult
    func play(_ name:String,bufferSlot:Int?=nil,attenuationHundredthsDB:Int?=nil,looping:Bool=false,advanceWriter:Bool=false)->Bool {
        guard enabled,let request=channels.request(name,bufferSlot:bufferSlot,advanceWriter:advanceWriter) else {return false}
        var pool=buffers[request.entry.key] ?? Array(repeating:nil,count:request.entry.capacity)
        let sound:NSSound
        if let existing=pool[request.slot] {sound=existing}
        else {
            guard let loaded=NSSound(contentsOf:soundDirectory.appendingPathComponent(request.entry.file+".wav"),byReference:true) else {return false}
            sound=loaded;pool[request.slot]=loaded;buffers[request.entry.key]=pool
        }
        sound.volume=masterVolume*OriginalSoundCatalog.gain(hundredthsDB:attenuationHundredthsDB ?? request.entry.initialHundredthsDB)
        sound.loops=looping
        // Original Play does not rewind an already playing DirectSound buffer;
        // suppress only this exact slot, never unrelated effects/voices.
        guard !sound.isPlaying else {return false}
        return sound.play()
    }
    func setLoop(_ name:String,active:Bool,attenuationHundredthsDB:Int=0) {
        if active {_=play(name,bufferSlot:0,attenuationHundredthsDB:attenuationHundredthsDB,looping:true)}
        else {stop(name)}
    }
    func updateEngines(_ sources:[OriginalEngineSound.Source]) {
        for loop in OriginalEngineSound.mix(gameID:channels.catalog.gameID,sources:sources) {
            setLoop(loop.name,active:loop.active,attenuationHundredthsDB:loop.attenuationHundredthsDB)
        }
    }
    func stop(_ name:String) {
        guard let entry=channels.catalog.entry(name) else {return}
        for sound in buffers[entry.key] ?? [] {sound?.stop()}
    }
    func stopAll() {for pool in buffers.values {for sound in pool {sound?.stop()}}}
    func isPlaying(_ name:String)->Bool {
        guard let entry=channels.catalog.entry(name) else {return false}
        return (buffers[entry.key] ?? []).contains {$0?.isPlaying==true}
    }
    deinit {stopAll()}

    struct TestFailure:Error {let message:String}
    static func runTests() throws {
        func check(_ v:@autoclosure()->Bool,_ message:String)throws {if !v(){throw TestFailure(message:message)}}
        var channels=OriginalSoundChannels(gameID:"2000")
        let gun=(0..<12).map {_ in channels.request("AntiAir")!.slot}
        try check(gun==Array(0..<10)+[0,1],"Original ten machine-gun buffers rotate")
        try check(channels.request("Prize")?.slot==0 && channels.request("ExClose")?.slot==0 && channels.request("AntiAir")?.slot==2,"Unrelated sound categories never share a writer")
        _=channels.request("ExMuffle",bufferSlot:0,advanceWriter:true)
        _=channels.request("ExMuffle",bufferSlot:0,advanceWriter:true)
        try check(channels.request("ExMuffle")?.slot==2,"Fixed base-buffer branches still advance the later indexed artillery writer")
        try check(channels.request("CannonClose")?.entry.file=="CanonClose","2000 original filename alias")
        let old=channels.catalog,new=OriginalSoundCatalog(gameID:"2002")
        try check(old.entry("Rifle")?.capacity==4 && new.entry("ExMuffle")?.capacity==6 && new.entry("MachineGun")?.capacity==10,"Recovered effect and alternate-gun capacities")
        try check(old.entry("Soldead5") != nil && new.entry("Soldead5")==nil,"Do not invent missing2002 fifth voice")
        try check(new.entry("Ricocht4")?.file=="Ricocht3" && new.entry("Ricocht4")?.key != new.entry("Ricocht3")?.key,"Original duplicate ricochet sample retains independent channel")
        try check(abs(OriginalSoundCatalog.gain(hundredthsDB:-1000)-0.31622776)<0.000001 && OriginalSoundCatalog.gain(hundredthsDB:-10000)==0,"Attenuation conversion and silence limit")
        let oldMix=OriginalEngineSound.mix(gameID:"2000",sources:[.init(objectID:37,state:20,position:.zero,visible:true),.init(objectID:61,state:1,position:.init(6500,90000,6500),visible:true),.init(objectID:76,state:1,position:.init(30000,0,0),visible:true)])
        try check(oldMix.first{$0.name=="Tank"}?.attenuationHundredthsDB == -6500 && oldMix.first{$0.name=="Tank"}?.active==true,"Engine mixer excludes wreck and uses Chebyshev distance without altitude")
        try check(oldMix.first{$0.name=="Jet"}?.active==true,"Original inclusive30000 engine cutoff")
        let newMix=OriginalEngineSound.mix(gameID:"2002",sources:[.init(objectID:117,state:1,position:.init(9,0,0),visible:true)])
        try check(newMix.first{$0.name=="Jet"}?.attenuationHundredthsDB == -2 && newMix.first{$0.name=="Tank"}?.active==false,"2002 Jet negative arithmetic shift and absent-loop stop")
    }
}

#if ORIGINAL_SOUND_TESTS
@main private struct OriginalSoundTestRunner {
    static func main() throws {try OriginalSoundRenderer.runTests();print("PASS: original independent sound buffers, rings, filenames, voice levels and no invented assets")}
}
#endif
