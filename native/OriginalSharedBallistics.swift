import Foundation

/// The EXEs have no shooter/faction field in either ballistic bank. Each slot
/// executes this complete sequence even after a preceding block clears active.
/// Source:2000 0x416a09:219-1819;2002 0x4154b7:229-1534.
enum OriginalSharedBallistics {
    struct TargetClass {
        let type:String
        let objects:Range<Int>
        let radius:Double?
        var bargeBox=false
        var endpointOnly=false
    }

    static func resolveMissile(version:OriginalGameVersion,end:SIMD3<Double>,ground:(Double,Double)->Double,
                               waterAt:((Double,Double)->Bool)?=nil,
                               onTerrain:(OriginalEnemyImpact)->Void,hitTargets:(TargetClass)->Bool)->Bool {
        let old=version == .beach2000,p=end
        if abs(p.x)>25000 || abs(p.z)>25000 || p.y>10000 {return true}
        let inMap=old ? abs(p.x)<15000 && p.z<7500 && p.z>=(-30000) : abs(p.x)<15000 && abs(p.z)<15000
        guard inMap || waterAt != nil else {return p.y<0}
        let coastWater=waterAt?(p.x,p.z)
        let height=(coastWater ?? (old && p.z<=(-7500))) ? 0:ground(p.x,p.z)
        var retired=false
        if p.y<height {
            retired=true
            let water=coastWater ?? (old && p.z<=(-5000))
            onTerrain(.init(kind:water ? .water:.ground,position:.init(p.x,height+(old ? 10:0),p.z),
                infantryRadius:water ? nil:old ? 300:400,horizontalOnly:!old,
                infantryCenter:p,includesEmbarkedInfantry:old))
        }
        let targets:[TargetClass]
        if p.y<(old ? 750:800) {
            targets=[.init(type:"TANK",objects:old ? 37..<43:37..<49,radius:500),
                     .init(type:"APC",objects:old ? 61..<67:73..<85,radius:old ? 400:500)] +
                    (old ? []:[.init(type:"CH53",objects:178..<186,radius:900)])
        } else if old {
            targets=[.init(type:"BOMBER",objects:73..<76,radius:300,endpointOnly:true),
                     .init(type:"JET",objects:76..<88,radius:300,endpointOnly:true),
                     .init(type:"COBRA",objects:88..<94,radius:300,endpointOnly:true),
                     .init(type:"CH53",objects:106..<109,radius:300,endpointOnly:true),
                     .init(type:"C130",objects:207..<208,radius:300,endpointOnly:true)]
        } else {
            targets=[.init(type:"JET",objects:117..<133,radius:300,endpointOnly:true),
                     .init(type:"BOMBER",objects:133..<142,radius:300,endpointOnly:true),
                     .init(type:"COBRA",objects:142..<154,radius:300,endpointOnly:true),
                     .init(type:"CH53",objects:178..<186,radius:300,endpointOnly:true),
                     .init(type:"C130",objects:210..<218,radius:300,endpointOnly:true)]
        }
        for target in targets {retired = hitTargets(target) || retired}
        return retired
    }
    enum Stage {case targets(TargetClass),infantry,player}

    static func stages(version:OriginalGameVersion,bank:OriginalProjectilePools.Bank,end:SIMD3<Double>)->[Stage] {
        let old=version == .beach2000,bullet=bank == .bullet
        func t(_ type:String,_ ids:Range<Int>,_ radius:Double)->Stage {
            .targets(.init(type:type,objects:ids,radius:radius))
        }
        var result:[Stage]=[t("CH53",old ? 106..<109:178..<186,old ? 800:900),
                            t("Parachute",old ? 212..<214:294..<358,old ? 600:700)]
        if !old {result.append(.player)}
        if end.y>=750 {
            if old {
                result += [t("COBRA",88..<94,580),t("BOMBER",73..<76,1600),t("JET",76..<88,620),t("C130",207..<208,1200)]
            } else {
                result += [t("JET",117..<133,670),t("BOMBER",133..<142,bullet ? 1100:640),t("COBRA",142..<154,590),t("C130",210..<218,1270)]
            }
        } else {
            if bullet {result.append(.infantry)}
            else if old {result.append(.targets(.init(type:"BARGE",objects:11..<23,radius:nil,bargeBox:true)))}
            result += [t("TANK",old ? 37..<43:37..<49,500),
                       t("APC",old ? 61..<67:73..<85,old && !bullet ? 400:500)]
            if old && bullet {result.append(.player)}
        }
        if old && !bullet {result.append(.player)}
        return result
    }

    /// Return whether this source slot becomes inactive. Geometry callbacks are
    /// synchronous and re-read live units; never collect hits for later replay.
    static func resolve(version:OriginalGameVersion,bank:OriginalProjectilePools.Bank,sweep:OriginalSharedBallisticSweep,
                        ground:(Double,Double)->Double,waterAt:((Double,Double)->Bool)?=nil,onTerrain:(OriginalEnemyImpact)->Void,
                        onPlayer:(Int)->Void,hitTargets:(TargetClass)->Bool,hitInfantry:()->Bool,
                        sweptCannonContact:(()->Bool)?=nil)->Bool {
        let p=sweep.end,old=version == .beach2000,bullet=bank == .bullet
        let outside=abs(p.x)>25000 || abs(p.z)>25000 || p.y>(old && !bullet ? 8000:10000)
        let inMap=old ? (bullet ? abs(p.x)<15000 && abs(p.z)<7500 : abs(p.x)<15000 && p.z<7500 && p.z>=(-30000)) : abs(p.x)<15000 && abs(p.z)<15000
        var retired=outside || (!inMap && p.y<0)
        if let sweptCannonContact {
            if !outside && (inMap || waterAt != nil) && sweptCannonContact() {return true}
        } else if !outside && (inMap || waterAt != nil) {
            let coastWater=waterAt?(p.x,p.z)
            let height=(coastWater ?? (old && !bullet && p.z<=(-7500))) ? 0:ground(p.x,p.z)
            if p.y<height {
                retired=true
                let water=coastWater ?? (old && !bullet && p.z<=(-5000))
                onTerrain(.init(kind:water ? .water:.ground,position:.init(p.x,height+(old && !bullet ? 10:0),p.z),
                                infantryRadius:bullet ? nil:old ? 300:400,horizontalOnly:!old,
                                infantryCenter:p,includesEmbarkedInfantry:old && !water))
            }
        }
        //2000 shell entity/player blocks are nested inside the map-valid else.
        //Both bullet passes and2002 shell continue even after bounds/ground kill.
        if old && !bullet && (outside || !inMap) {return retired}
        // In Depthline the player's shell has already swept terrain and actors
        // along its full step. Keep the bank's range and bunker checks.
        let remaining: [Stage] = sweptCannonContact == nil ? stages(version:version,bank:bank,end:p) : [.player]
        for stage in remaining {
            switch stage {
            case .targets(let target):
                let hit=hitTargets(target)
                //2000 common bullet collection clears chute but NOT bullet.
                if !(old && bullet && target.type=="Parachute") {retired = hit || retired}
            case .infantry:retired = hitInfantry() || retired
            case .player:
                let r=bullet ? 300.0:250.0,d=p-SIMD3(0,800,0)
                if d.x*d.x+d.y*d.y+d.z*d.z<r*r {retired=true;onPlayer(bullet ? 1:5)}
            }
        }
        return retired
    }
}
