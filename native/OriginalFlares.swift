import Foundation

/// BH2 0x4154b7 (saved update-game.c:2591–2642,3357–3395).
/// Source units per original tick. Four physical slots, source gravity2, and
/// deployed descent7.5/20 are preserved. Light rendering is a separate adapter.
struct OriginalFlares {
    struct Flare {
        var active=false
        var position=SIMD3<Float>(repeating:0)
        var velocity=SIMD3<Float>(repeating:0)
        var ticks=0
        var deployed=false
        var burnTicks=0

        /// Ignition starts at the actual apex, including shots that rise for
        /// more than 20 ticks. The glow fades over the last four metres.
        func glow(clearanceMetres: Float) -> Float {
            guard active && deployed else { return 0 }
            func ease(_ fraction: Float) -> Float {
                let t=max(0,min(1,fraction))
                return t*t*(3-2*t)
            }
            return ease(Float(burnTicks)/10) * ease(clearanceMetres/4)
        }
    }
    private(set) var slots=Array(repeating:Flare(),count:4)
    private var next=0
    mutating func launch(position:SIMD3<Float>,direction:SIMD3<Float>,pitchDegrees:Float) {
        let angle=abs(pitchDegrees)
        let speed:Float=angle>=60 ? (80-angle)*10:200
        slots[next]=Flare(active:true,position:position,velocity:direction*speed,ticks:0,deployed:false)
        next=(next+1)%4
    }
    mutating func step(terrainHeight:(Float,Float)->Float) {
        for i in slots.indices where slots[i].active {
            slots[i].position += slots[i].velocity
            if slots[i].velocity.y>=0 {slots[i].velocity.y-=2}
            slots[i].ticks+=1
            let p=slots[i].position
            if slots[i].ticks>20 && slots[i].velocity.y<0 {
                slots[i].deployed=true;slots[i].burnTicks+=1
                slots[i].velocity=SIMD3<Float>(0,p.y>4000 ? -20:-7.5,0)
            }
            let ground=abs(p.x)>=15000 || abs(p.z)>=15000 ? 0:terrainHeight(p.x,p.z)
            if p.y<ground {slots[i].active=false}
        }
    }
    static func selfTest() throws {
        var model=Self()
        model.launch(position:.init(0,1000,0),direction:.init(0,0,-1),pitchDegrees:0)
        model.step(terrainHeight:{_,_ in 0})
        guard model.slots[0].position.z == -200,model.slots[0].velocity.y == -2 else {throw NSError(domain:"FlareTest",code:1)}
        for _ in 0..<20 {model.step(terrainHeight:{_,_ in 0})}
        guard model.slots[0].deployed,model.slots[0].velocity == .init(0,-7.5,0) else {throw NSError(domain:"FlareTest",code:2)}
        guard model.slots[0].glow(clearanceMetres:20) < 0.04 else { throw NSError(domain:"FlareTest",code:4) }
        for _ in 0..<9 { model.step(terrainHeight:{_,_ in 0}) }
        guard model.slots[0].glow(clearanceMetres:20) == 1,
              model.slots[0].glow(clearanceMetres:2) == 0.5,
              model.slots[0].glow(clearanceMetres:0) == 0 else { throw NSError(domain:"FlareTest",code:5) }
        for _ in 0..<5 {model.launch(position:.init(0,5000,0),direction:.init(0,0,-1),pitchDegrees:70)}
        guard model.slots.count==4,model.slots.allSatisfy({$0.velocity.z == -100}) else {throw NSError(domain:"FlareTest",code:3)}
        for _ in 0..<21 {model.step(terrainHeight:{_,_ in 0})}
        guard model.slots.allSatisfy({$0.velocity.y == -20}) else {throw NSError(domain:"FlareTest",code:4)}
        print("PASS: original four-slot flare ring, launch elevation, gravity and delayed high/low descent")
    }
}
