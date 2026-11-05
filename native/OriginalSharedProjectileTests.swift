import SceneKit

func testOriginalSharedProjectiles(textureURL:URL) throws {
    func require(_ value:Bool,_ reason:String) throws {
        if !value {throw NSError(domain:"OriginalSharedProjectiles",code:1,userInfo:[NSLocalizedDescriptionKey:reason])}
    }
    for version in [OriginalGameVersion.beach2000,.beach2002] {
        let scene=SCNScene(),pools=OriginalProjectilePools(version:version)
        let player=OriginalProjectiles(version:version,textureURL:textureURL,parent:scene.rootNode,sharedPools:pools)
        let enemy=EnemyOrdnanceRenderer(root:scene.rootNode,texture:textureURL,sharedPools:pools)
        let speed=version == .beach2000 ? 400.0:500.0
        enemy.spawn(.init(version:version,kind:.bullet,position:.init(1000,100,0),velocity:.init(0,0,-speed)))
        let action=OriginalFireAction(weapon:.machineGun,barrel:.center,variant:0,recoilTicks:0,
                                      ballistic:OriginalWeaponProfile(version:version).ballistic(.machineGun))
        _=player.spawn(action,from:SCNVector3(10,1,0),direction:SCNVector3(0,0,-1))
        // Later shellbank slot0 must follow BOTH emitter types in bulletbank.
        enemy.spawn(.init(version:version,kind:.shell,position:.init(2000,100,0),velocity:.init(0,0,-400)))
        var states=[2,2],victims:[Int]=[],visited:[String]=[]
        pools.stepBallistics {token,source in
            visited.append("\(token.bank.rawValue)\(token.slot)")
            let start=SCNVector3(source.start.x*0.01,source.start.y*0.01,source.start.z*0.01)
            let end=SCNVector3(source.end.x*0.01,source.end.y*0.01,source.end.z*0.01)
            return OriginalSharedBallistics.resolve(version:version,bank:token.bank,sweep:source,ground:{_,_ in 0},onTerrain:{_ in},onPlayer:{_ in},hitTargets:{_ in false},hitInfantry:{
                for i in states.indices {
                    if OriginalCollision.infantryHit(gameID:version.rawValue,state:states[i],foot:SCNVector3(10,0,i==0 ? -1:-3),start:start,end:end) != nil {
                        let living=states[i]<(version == .beach2000 ? 21:42)
                        if living {states[i]=version == .beach2000 ? 21:60;victims.append(i)}
                        return version == .beach2002 || living
                    }
                }
                return false
            })
        }
        try require(visited==["bullet0","bullet1","shell0"],"authoritative bank slot order interleaves enemy then player before shells")
        try require(victims==(version == .beach2000 ? [0,1]:[0]),"first round's immediate death changes second round occlusion:2000 exposed soldier dies,2002 corpse blocks")
        try require(player.ballisticCount==0 && enemy.rounds.count==1 && enemy.rounds[0].state.kind == .shell,"both owners retire through same slot scheduler")
        let shellZ=enemy.rounds[0].state.position.z
        enemy.step(ground:{_,_ in 0},infantry:{[]},includeShared:false,onImpact:{_,_ in})
        try require(enemy.rounds[0].state.position.z==shellZ,"nonshared ordnance pass cannot move shell a second time")
        _=player.clear();enemy.clear()

        var stages:[String]=[]
        let source=OriginalSharedBallisticSweep(weapon:.machineGun,start:.init(0,700,400),end:.init(0,700,0))
        let retired=OriginalSharedBallistics.resolve(version:version,bank:.bullet,sweep:source,ground:{_,_ in 1000},
            onTerrain:{_ in stages.append("ground")},onPlayer:{_ in stages.append("player")},
            hitTargets:{stages.append($0.type);return true},hitInfantry:{stages.append("infantry");return true})
        let expected=version == .beach2000 ? ["ground","CH53","Parachute","infantry","TANK","APC","player"] : ["ground","CH53","Parachute","player","infantry","TANK","APC"]
        try require(retired && stages==expected,"ground and first-object retirement must not suppress remaining source collision classes")
        let collectible=OriginalSharedBallisticSweep(weapon:.machineGun,start:.init(1000,1000,0),end:.init(1000,1000,-400))
        let collected=OriginalSharedBallistics.resolve(version:version,bank:.bullet,sweep:collectible,ground:{_,_ in 0},onTerrain:{_ in},onPlayer:{_ in},hitTargets:{$0.type=="Parachute"},hitInfantry:{false})
        try require(collected==(version == .beach2002),"2000 chute reward preserves flying bullet;2002 collection consumes it")
        var missileTypes:[String]=[]
        let missileHit=OriginalSharedBallistics.resolveMissile(version:version,end:.init(1000,1000,0),ground:{_,_ in 0},onTerrain:{_ in},hitTargets:{
            missileTypes.append($0.type);return true
        })
        try require(missileHit && missileTypes==(version == .beach2000 ? ["BOMBER","JET","COBRA","CH53","C130"]:["JET","BOMBER","COBRA","CH53","C130"]),"homing missile retains source aircraft class order after an earlier endpoint hit")
        missileTypes=[]
        _=OriginalSharedBallistics.resolveMissile(version:version,end:.init(1000,700,0),ground:{_,_ in 0},onTerrain:{_ in},hitTargets:{missileTypes.append($0.type);return false})
        try require(missileTypes==(version == .beach2000 ? ["TANK","APC"]:["TANK","APC","CH53"]),"low missile source CH53 collision is2002 only")
    }
    // A2000 rocket can hit terrain, a vehicle and the bunker in ONE iteration.
    var phases:[String]=[]
    var rocket=OriginalEnemyOrdnanceState(version:.beach2000,kind:.airRocket,position:.init(0,710,100),velocity:.init(0,0,-100),remainingTicks:1)
    let tick=rocket.step(ground:{_,_ in 800},onUnits:{_,_ in phases.append("vehicle");return true},
        onPhase:{phases.append($0.impacts.contains(where:{$0.kind == .ground}) ? "terrain":"direct-player")})
    try require(phases==["terrain","vehicle","direct-player"] && tick.shieldDamage==10 && !tick.active,"expired/ground-retired rocket still runs vehicle and direct player blocks, without double-applying phase callbacks")
    let missiles=OriginalProjectiles(version:.beach2002,textureURL:textureURL,parent:SCNNode())
    var weapons=OriginalWeaponState(version:.beach2002,machineGunAmmo:0,cannonAmmo:0,missileAmmo:2)
    weapons.prepareMissileSlots()
    for _ in 0..<2 {_=missiles.spawnMissile(weapons.requestMissile()!,from:SCNVector3(10,10,0),direction:SCNVector3(0,0,-1))}
    var live=true,queries:[Int]=[],resolved=0
    _=missiles.step(hitCandidates:{_ in []},includeBallistics:false,missileTargetProvider:{
        let targets=live ? [OriginalMissileTarget(originalObjectIndex:117,position:.init(x:1000,y:1000,z:-1000),active:true)]:[]
        queries.append(targets.count);return targets
    },resolveMissile:{_ in if live {live=false;resolved+=1;return true};return false})
    try require(queries==[1,0] && resolved==1 && missiles.missileCount==1,"missile0 destruction is visible to missile1 guidance and collision in same tick")
    print("PASS shared ballistic banks: emitter-independent slot order, immediate death/occlusion differences, continuation after retirement, nonconsuming2000 supply, phase-correct rocket friendly fire")
}
