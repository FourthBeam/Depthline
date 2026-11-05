import AppKit
import SceneKit

extension Game {
    /// FUN_004051c8 visits whole model ranges, not append/activation order.
    func updateOriginal2002AI() {
        infantryLandedThisTick.removeAll(keepingCapacity: true)
        OriginalTickOrder.run(gameID: "2002") { phase in
            switch phase {
            case .groundAvoidance:
                let neighbors = enemies.compactMap { e -> OriginalEnemyAI.Neighbor? in
                    guard let ai = e.originalAI, ai.isActive, ai.isGroundVehicle else { return nil }
                    return .init(type: e.type, slot: e.slot, position: ai.position)
                }.sorted { a, b in
                    let base = ["TANK": 37, "APC1": 73, "APC2": 77, "APC3": 81]
                    return (base[a.type] ?? 0) + a.slot < (base[b.type] ?? 0) + b.slot
                }
                for enemy in orderedOriginalGroundEnemies() {
                    if let update = enemy.originalAI?.finishGroundAvoidance(neighbors: neighbors, random: { self.random.next() }) {
                        syncOriginalEnemyPose(enemy, update: update)
                    }
                }
            case .groundAlignment:
                for enemy in orderedOriginalGroundEnemies() {
                    if let update = enemy.originalAI?.finishGroundAlignment(terrainHeight: { [assets] x, z in
                        Double(assets.height(x: CGFloat(x) * 0.01, z: CGFloat(z) * 0.01)) * 100
                    }) { syncOriginalEnemyPose(enemy, update: update) }
                }
            case .c130Aircraft:
                consumeSupply2002Events(supply2002?.updateAircraft(random: { self.random.next() }, terrainHeight: { [assets] x,z in
                    Float(assets.pointHeight(x: CGFloat(x) * 0.01, z: CGFloat(z) * 0.01)) * 100
                }, smokeTick: globalAITick % 2 == 0, allocateTrooperID: { self.allocateTrooperID() }) ?? [])
            case .supplyPayloads:
                consumeSupply2002Events(supply2002?.updatePayloads(terrainHeight: { [assets] x,z in
                    Float(assets.pointHeight(x: CGFloat(x) * 0.01, z: CGFloat(z) * 0.01)) * 100
                }) ?? [])
            case .bombers: updateBombers()
            default:
                OriginalTickOrder.visit(phase, objects: { self.enemies }, type: { $0.type },
                                        objectID: { self.originalObjectIndex($0) ?? Int.max }) { enemy in
                    // A chute landing already executed infantry case1 this tick;
                    // case2 begins on the next one. APC/CH53 cargo still updates now.
                    if phase == .infantry && infantryLandedThisTick.contains(enemy.slot + 358) { return }
                    updateEnemyAI(enemy, deferSharedPhases: true)
                }
            }
        }
        syncSupply2002Nodes()
    }
    func orderedOriginalGroundEnemies() -> [Enemy] {
        enemies.filter { $0.originalAI?.isGroundVehicle == true }.sorted {
            (originalObjectIndex($0) ?? 0) < (originalObjectIndex($1) ?? 0)
        }
    }
    func advanceOriginal2002ObjectTransforms() {
        for enemy in enemies {
            if let update = enemy.originalAI?.advanceObjectTransform() { syncOriginalEnemyPose(enemy, update: update) }
        }
    }
    func syncOriginalEnemyPose(_ enemy: Enemy, update: OriginalEnemyAI.Update, advanceRotors: Bool = false) {
        let p=update.position,r=update.eulerDegrees
        enemy.node.position=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
        enemy.node.eulerAngles=SCNVector3(r.x * .pi/180,r.y * .pi/180,r.z * .pi/180)
        enemy.node.isHidden = !update.isActive;enemy.aiState=update.state
        if enemy.type.hasPrefix("APC"),!update.cargoLoaded {enemy.hp=0}
        enemy.node.enumerateChildNodes { n,_ in
            if ["Turret","AGunTurret","AMissileTurret"].contains(n.name ?? "") {n.eulerAngles.y=CGFloat(update.turretYawDegrees * .pi/180)}
            if ["TMount","APCGun","Launcher"].contains(n.name ?? "") {n.eulerAngles.x=CGFloat(update.barrelPitchDegrees * .pi/180)}
            if ["ARamp","Ramp"].contains(n.name ?? "") {
                let pitch = assets.isDepthline && enemy.type.hasPrefix("APC") ? min(105, update.rampPitchDegrees) : update.rampPitchDegrees
                n.eulerAngles.x=CGFloat(pitch * .pi/180)
            }
            if advanceRotors && (n.name ?? "").contains("Rotor") {n.eulerAngles.y += (enemy.type=="CH53" ? 25:55) * .pi/180}
            if advanceRotors,enemy.type=="CH53",n.name=="Prop" {n.eulerAngles.x -= 40 * .pi/180}
        }
    }
    /// Infantry writes grenade records inside the AI function, so a grenade
    /// thrown this tick already participates in the following flight pass.
    func flushPendingInfantryGrenades() {
        for (state, model, slot) in pendingOrdnance where state.kind == .grenade {
            enemyOrdnance.spawn(state, model: model.map { assets.model($0) }, slot: slot)
        }
        pendingOrdnance.removeAll { $0.0.kind == .grenade }
        for shot in pendingGrenades {
            enemyOrdnance.spawn(.init(version: version, kind: .grenade, position: shot.position, velocity: shot.velocity),
                               model: assets.model("Grenades"), slot: shot.poolIndex)
        }
        pendingGrenades.removeAll(keepingCapacity: true)
    }
    /// Consume flags after hits, generic transforms and player emission, in
    /// emitter-object order. Bomb slots are chosen now, after earlier Jet bombs.
    func emitOriginal2002FireFlags() {
        typealias Emitter = (rank: Int, ai: OriginalEnemyAI?, bomber: Original2002BomberAI.Update?)
        var emitters: [Emitter] = pendingEnemyEmitters.map {
            (OriginalTickOrder.emitterRank2002(type: $0.type, slot: $0.slot), $0, nil)
        }
        emitters += pendingBomberDrops.map { ($0.originalObjectIndex, nil, $0) }
        for emitter in emitters.sorted(by: { $0.rank < $1.rank }) {
            if let ai = emitter.ai {
                for shot in ai.takeShots(random: { self.random.next() }) {
                    let state = OriginalEnemyOrdnanceState(shot, version: version)
                    let model = state.kind == .bomb ? assets.model("BOMBS") : [.airRocket, .groundRocket].contains(state.kind) ? assets.model(state.kind == .airRocket ? "ROCKETS" : "MISSILE") : nil
                    enemyOrdnance.spawn(state, model: model)
                    if state.kind == .shell { playSound("CannonFar") }
                }
            } else if let bomber = emitter.bomber {
                let state = Original2002BomberAI.bomb(from: bomber, sharedBombSlot: enemyOrdnance.nextBombSlot)
                enemyOrdnance.spawn(state, model: assets.model("BOMBS"))
            }
        }
        pendingEnemyEmitters.removeAll(keepingCapacity: true)
        pendingBomberDrops.removeAll(keepingCapacity: true)
    }
    func updateEnemyAI(_ enemy: Enemy, deferSharedPhases: Bool) {
        enemy.age += Self.logicalStep
        if enemy.aggregateBoatSlot != nil || enemy.aggregateVehicleID != nil || enemy.aggregateSoldierSlot != nil || enemy.aggregateAircraftID != nil {return}
        if let ai=enemy.infantryAI {
            let update=ai.tick(terrainHeight:{[assets] x,z in Double(assets.pointHeight(x:CGFloat(x)*0.01,z:CGFloat(z)*0.01))*100},cameraYawDegrees:Double(camera.eulerAngles.y*180 / .pi),cameraPitchDegrees:Double(camera.eulerAngles.x*180 / .pi),random:{self.random.next()})
            let p=update.position;enemy.node.position=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01);enemy.aiState=update.state
            enemy.node.isHidden = ai.apcExit?.isVisible == false
            if !enemy.node.isHidden { enemy.boardingAPC = nil }
            if !RemasteredInfantry.update(enemy.node,gameID:assets.gameID,state:update.state,frame:update.frameIndex,direction:ai.direction,rollDegrees:update.rollDegrees) {
            enemy.node.eulerAngles.y=CGFloat(update.yawDegrees * .pi/180)
            enemy.node.childNodes.first?.eulerAngles.z=CGFloat(update.rollDegrees * .pi/180)
            if update.texturePath != enemy.spritePath {
                enemy.spritePath=update.texturePath
                enemy.node.enumerateChildNodes {n,_ in n.geometry?.firstMaterial?.diffuse.contents=assets.frameImage(update.texturePath)}
            }
            }
            for event in update.events {
                switch event {
                case .rifleFlash(let origin,let damage):
                    combat.health=max(0,combat.health-damage);playSound("Rifle");effects.emit(.muzzleFlash,at:origin,scale:.init(repeating:0.25))
                    if damage>0 {playOriginalPlayerBulletHitSound()}
                case .grenade(let origin,let velocity):pendingOrdnance.append((.init(version:.beach2002,kind:.grenade,position:origin,velocity:velocity),"GRENADES",nil))
                case .forceRemoved(let amount):campaign?.resolveForce(sourceIndex:enemy.sourceIndex,amount:amount)
                case .parachuteReleased:break
                }
            }
            syncBurningInfantry(enemy)
            if !update.isActive {enemy.node.removeFromParentNode();enemies.removeAll {$0===enemy}}
            return
        }
        if let ai=enemy.originalAI {
            let neighbors=enemies.compactMap { e->OriginalEnemyAI.Neighbor? in
                guard e.type=="TANK" || e.type.hasPrefix("APC") else {return nil}
                let p=e.node.position;return .init(type:e.type,slot:e.slot,position:.init(Double(p.x*100),Double(p.y*100),Double(p.z*100)))
            }
            let update=ai.tick(terrainHeight:{[assets] x,z in
                let x=CGFloat(x)*0.01,z=CGFloat(z)*0.01
                return Double(enemy.flying ? assets.pointHeight(x:x,z:z):assets.height(x:x,z:z))*100
            },terrainMaterial:assets.terrainMaterial,neighbors:neighbors,
            earlierLandingTargets:enemies.filter {$0.type=="CH53" && $0.slot<enemy.slot}.compactMap {$0.originalAI?.landingTarget},random:{self.random.next()},globalParity:globalAITick,hoverPhasesDegrees:originalClock.hoverPhasesDegrees,deferSharedPhases:deferSharedPhases)
            let p=update.position,r=update.eulerDegrees
            syncOriginalEnemyPose(enemy, update: update, advanceRotors: true)
            if deferSharedPhases && ai.hasPendingShots { pendingEnemyEmitters.append(ai) }
            for event in update.events {
                switch event {
                case .fire(let shot):pendingEnemyShots.append(shot)
                case .smoke(let p,let scale):effects.emitAircraftSmoke(at:p,scale:scale)
                case .cargo(let troops):
                    enemy.force=max(0,enemy.force-Double(troops.count))
                    for (seat, troop) in troops.enumerated() {
                        let id=allocateTrooperID()
                        let p=troop.position,origin=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
                        let soldier=Enemy(node:assets.model("INFANTRY"),type:"INFANTRY",flying:false)
                        soldier.sourceIndex=enemy.sourceIndex;soldier.slot=id-358;soldier.force=1;soldier.aiState=troop.initialState
                        soldier.infantryAI=Original2002InfantryAI(position:troop.position,direction:troop.direction,speedPerTick:troop.speedPerTick,initialState:troop.initialState,initialDelay:troop.initialDelay ?? 0)
                        if assets.isDepthline && enemy.type.hasPrefix("APC") {
                            soldier.infantryAI?.apcExit = DepthlineAPCExit(hull: .hills, origin: update.position, angles: update.eulerDegrees, seat: seat)
                            soldier.boardingAPC = enemy
                            soldier.node.isHidden = true
                        }
                        soldier.node.position=origin;scene.rootNode.addChildNode(soldier.node);enemies.append(soldier)
                    }
                case .terminal(let force,let damage):
                    let crashed=["COBRA":15,"JET":16,"CH53":14][enemy.type]==update.state
                    if crashed,let id=originalObjectIndex(enemy) {
                        burning.noteCrash(type:enemy.type,objectID:id,position:p);playOriginalCrashSound(at:p)
                        emitOriginalCrashFragments(type:enemy.type,objectID:id,position:p,rotationDegrees:r)
                    }
                    campaign?.resolveForce(sourceIndex:enemy.sourceIndex,amount:force);combat.health=max(0,combat.health-damage)
                    campaign?.enemyRemoved(sourceIndex:enemy.sourceIndex,forceRemoved:0)
                    enemy.node.removeFromParentNode();enemies.removeAll {$0===enemy};if crashed {explode(enemy.node.position)}
                    enemy.deferredDeath=nil
                }
            }
            return
        }
        enemy.updateMotion(assets:assets)
    }
}
