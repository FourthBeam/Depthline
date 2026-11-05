import SceneKit

extension Game {
    func originalPosition(_ node:SCNNode)->SIMD3<Double> {
        let p=node.position
        return SIMD3(Double(p.x*100),Double(p.y*100),Double(p.z*100))
    }

    func burningSourcePosition(_ id:Int)->SIMD3<Double>? {
        // The original latch reads authored/local object translation, including
        // the confirmed BH2000 C130 -> CH53 ramp109 indexing quirk.
        if assets.gameID=="2000",id==109,
           let source=assets.objects.first(where:{$0["id"] as? Int==id}) {
            let p=arrayD(source["translation"])
            if p.count==3 {return SIMD3(p[0],p[1],p[2])}
        }
        if let enemy=enemies.first(where:{originalObjectIndex($0)==id}) {return originalPosition(enemy.node)}
        if let node=supplyNodes[id] {return originalPosition(node)}
        return nil
    }

    func noteBurningHit(_ enemy:Enemy,weapon:OriginalDamageWeapon,part:Int?) {
        guard let id=originalObjectIndex(enemy),
              let kind=OriginalBurning.Weapon(rawValue:weapon.rawValue) else {return}
        burning.noteHit(type:enemy.type,objectID:id,position:originalPosition(enemy.node),
                        previousState:enemy.aiState,weapon:kind,part:part)
    }

    func syncBurningVisual(id:Int,position:SIMD3<Double>?,scale:SIMD2<Double> = .init(0.25,0.5)) {
        guard let position else {
            if let token=burningTokens.removeValue(forKey:id) {effects.remove(token)}
            return
        }
        if let token=burningTokens[id] {effects.move(token,to:position,scale:scale)}
        else {
            let frame=assets.gameID=="2002" ? Int(random.next()>>10):nil
            burningTokens[id]=effects.emit(.fire,at:position,scale:scale,initialFrame:frame)
        }
    }

    func syncBurningInfantry(_ enemy:Enemy) {
        guard let id=originalObjectIndex(enemy) else {return}
        if let v=enemy.infantryAI?.burningVisual {
            syncBurningVisual(id:id,position:v.position,scale:.init(v.horizontalScale,v.verticalScale))
        } else {syncBurningVisual(id:id,position:nil)}
    }

    func consumeBurningPhase() {
        if let trigger=burning.takeIgnition(),let center=trigger.position(using:burningSourcePosition) {
            if assets.gameID=="2000" {
                for event in original2000AI?.burnInfantry(near:center,random:{self.random.next()}) ?? [] {
                    if case .forceAndScore(let index,let force,let score)=event {
                        campaign?.resolveForce(sourceIndex:index,amount:Double(-force));combat.score+=score
                    }
                }
                for soldier in original2000AI?.soldiers ?? [] {
                    let v=soldier.burningVisual
                    syncBurningVisual(id:139+soldier.slot,position:v?.position,
                        scale:.init(v?.horizontalScale ?? 0.25,v?.verticalScale ?? 0.5))
                }
            } else {
                // The source radius test also includes state1 parachutists and
                // reads their LOCAL coordinates. Burning changes state without
                // unlinking the chute. Keep that parent and retire only the
                // supply-owned child record, so it cannot land/spawn twice.
                for payload in supply2002?.airborneTroopers ?? [] where payload.visible {
                    let p=SIMD3(Double(payload.position.x),Double(payload.position.y),Double(payload.position.z))
                    guard OriginalBurning.matches(gameID:"2002",state:1,position:p,center:center),
                          let node=supplyNodes.removeValue(forKey:payload.objectID) else {continue}
                    supply2002?.retireTrooper(objectID:payload.objectID)
                    let enemy=Enemy(node:node,type:"INFANTRY",flying:false)
                    enemy.slot=payload.objectID-358;enemy.sourceIndex=payload.sourceIndex;enemy.force=1;enemy.aiState=1
                    enemy.infantryAI=Original2002InfantryAI(position:p,initialState:1)
                    enemies.append(enemy)
                }
                for enemy in enemies where enemy.type=="INFANTRY" && !enemy.node.isHidden {
                    guard let ai=enemy.infantryAI,
                          OriginalBurning.matches(gameID:"2002",state:ai.state,position:ai.position,center:center) else {continue}
                    for event in ai.beginBurning() {
                        if case .forceRemoved(let amount)=event {campaign?.resolveForce(sourceIndex:enemy.sourceIndex,amount:amount)}
                    }
                    enemy.aiState=ai.state;syncBurningInfantry(enemy)
                    if !ai.isActive {enemy.node.removeFromParentNode();enemies.removeAll {$0===enemy}}
                }
            }
        }
        burning.endProjectilePhase()
        let live=Set(enemies.filter {$0.type=="INFANTRY"}.compactMap {originalObjectIndex($0)})
        for id in Array(burningTokens.keys) where !live.contains(id) {syncBurningVisual(id:id,position:nil)}
    }
}
