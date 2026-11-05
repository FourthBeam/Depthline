import Foundation

/// Calls of FUN_00423e55/004242a0 (2000),004232fa/004237f2 (2002).
/// This is geometry selection only; source damage and force remain their owners.
struct OriginalFragmentRecipe: Equatable {
    let style: OriginalFragmentStyle
    let chunkSize: Int

    static func hit(context:OriginalDamageContext,weapon:OriginalDamageWeapon,part:Int?,
                    result:OriginalDamageResult)->Self? {
        guard context.active,result.confirmed,!result.active,result.deathMode == .explode else {return nil}
        return destroyed(version:context.version,type:context.canonicalType,weapon:weapon,part:part)
    }

    /// Use only for an actual planeDestroyed event; supply owns its own damage
    /// state, so the host must not run a second damage resolution for its effects.
    static func destroyed(version:OriginalGameVersion,type:String,weapon:OriginalDamageWeapon,part:Int?)->Self? {
        let type=OriginalDamageContext(version:version,type:type,hitPoints:0).canonicalType
        guard weapon != .artillery else {return nil}
        if version == .beach2000 {
            if weapon == .bullet {
                guard part == 0 else {return nil}
                if type == "JET" {return .init(style:.airburst,chunkSize:20)}
                if type == "CH53" {return .init(style:.airburst,chunkSize:40)}
                return nil
            }
            if type == "BARGE" {return weapon == .cannon ? .init(style:.groundBurst,chunkSize:8):nil}
            if ["JET","BOMBER"].contains(type) {return .init(style:.airburst,chunkSize:20)}
            if ["COBRA","CH53"].contains(type) {return .init(style:.airburst,chunkSize:40)}
            if type == "C130" {return .init(style:.airburst,chunkSize:weapon == .cannon ? 20:40)}
        } else {
            if type == "APC",weapon == .cannon || weapon == .missile {return .init(style:.groundBurst,chunkSize:20)}
            if ["JET","BOMBER","COBRA","CH53","C130"].contains(type) {
                guard weapon != .bullet || type == "BOMBER" || part == 0 else {return nil}
                return .init(style:.airburst,chunkSize:40)
            }
        }
        return nil
    }

    static func crash(version:OriginalGameVersion,type:String)->Self? {
        let types=version == .beach2000 ? ["JET","COBRA","CH53"]:["JET","COBRA","CH53","C130"]
        return types.contains(type.uppercased()) ? .init(style:.groundBurst,chunkSize:40):nil
    }
}

func testOriginalFragmentRecipes() throws {
    func check(_ good:Bool,_ message:String) throws {
        if !good {throw NSError(domain:"OriginalFragmentRecipes",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
    }
    for version in [OriginalGameVersion.beach2000,.beach2002] {
        for type in ["JET","BOMBER","COBRA","CH53","C130","APC2","TANK","BARGE"] {
            for weapon in [OriginalDamageWeapon.bullet,.cannon,.missile] {
                for part in 0...2 {
                    let context=OriginalDamageContext(version:version,type:type,hitPoints:1,aiState:3,originalObjectIndex:37,c130RemainingTroops:0)
                    let result=OriginalDamage.resolve(context,weapon:weapon,part:part)
                    let recipe=OriginalFragmentRecipe.hit(context:context,weapon:weapon,part:part,result:result)
                    if result.active || !result.confirmed || result.deathMode != .explode {
                        try check(recipe==nil,"falling, parked wreck, armored hit or unknown result cannot emit immediate mesh debris")
                    } else {
                        try check(recipe != nil,"confirmed source destruction has an explicit recipe: \(version) \(type) \(weapon)")
                    }
                }
            }
        }
        try check(OriginalFragmentRecipe.crash(version:version,type:"BOMBER")==nil,"neither source bomber crash invokes polygon splitter")
    }
    try check(OriginalFragmentRecipe.destroyed(version:.beach2000,type:"C130",weapon:.cannon,part:nil)?.chunkSize==20 && OriginalFragmentRecipe.destroyed(version:.beach2000,type:"C130",weapon:.missile,part:nil)?.chunkSize==40,"supply destruction preserves cannon20 versus missile40")
    try check(OriginalFragmentRecipe.crash(version:.beach2000,type:"C130")==nil && OriginalFragmentRecipe.crash(version:.beach2002,type:"C130")?.chunkSize==40,"C130 crash fragments are 2002 only")
    print("PASS original fragment call recipes: version, weapon, lethal volume, falling versus immediate destruction, supply and crash differences")
}
