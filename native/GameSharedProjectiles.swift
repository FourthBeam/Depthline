import SceneKit

/// Reused between projectile slots until a unit spawns or is removed. Visibility
/// and damage are read from the live actors, even between two hits in one tick.
struct ProjectileTargets {
    private var byID: [Int: [Enemy]] = [:]
    let infantry: [Enemy]

    init(_ enemies: [Enemy], sourceID: (Enemy) -> Int?) {
        for enemy in enemies {
            if let id = sourceID(enemy) { byID[id, default: []].append(enemy) }
        }
        infantry = enemies.filter { $0.type == "INFANTRY" }.sorted { $0.slot < $1.slot }
    }

    func visibleEnemy(at id: Int) -> Enemy? {
        byID[id]?.first { !$0.node.isHidden }
    }
}

extension Game {
    /// A sighted supply shot still leaves the physical muzzle and must travel
    /// to the cargo. Apply a lead only if the sight ray intersects the fabric
    /// or the box itself; open rigging, other units and misses get no assist.
    func supplyLead(for action:OriginalFireAction,muzzle:SCNVector3,sightRange:Float = 250)->SCNVector3? {
        guard assets.isDepthline,let profile=action.ballistic else {return nil}
        let eye=camera.simdWorldPosition, axis=camera.simdWorldFront
        let sight=OriginalProjectileSweep(kind:.ballistic(action.weapon),start:SCNVector3(eye),end:SCNVector3(eye+axis*sightRange))
        var target:(node:SCNNode,hit:OriginalCollision.Hit,pitch:Float,swing:Float)?
        func consider(_ id:Int,_ pitch:Float,_ swing:Float) {
            guard let node=supplyNodes[id],!node.isHidden,let hit=depthlineDropHit(id:id,node:node,sweep:sight) else {return}
            if target.map({$0.hit.fraction>hit.fraction}) ?? true {target=(node,hit,pitch,swing)}
        }
        if let supply=supply2000 {
            for chute in supply.parachutes where chute.visible {consider(chute.objectID,chute.pitch,chute.angularVelocity)}
        } else if let supply=supply2002 {
            for chute in supply.parachutes where chute.visible && chute.payloadKind != .trooper {
                consider(chute.objectID,chute.pitch,chute.angularVelocity)
            }
        }
        guard let target else {return nil}
        let muzzleWorld=SIMD3<Float>(muzzle)
        let contact=eye+axis*(sightRange*Float(target.hit.fraction))
        let local=target.node.simdConvertPosition(contact,from:nil)
        let centre=SIMD3<Float>(0,target.hit.part==0 ? 0.55 : version == .beach2000 ? -4.5 : -2.5,0)
        let point=(local+centre)*0.5
        let ticks=simd_distance(target.node.simdConvertPosition(point,to:nil),muzzleWorld)/(profile.initialSpeedPerTick*0.01)
        var pitch=target.pitch, swing=target.swing
        for _ in 0..<Int(ticks.rounded()) {(pitch,swing)=SupplyDescent.depthlineCargo.nextSwing(pitch:pitch,velocity:swing)}
        let rotation=simd_quatf(angle:(pitch-target.pitch) * .pi/180,axis:.init(1,0,0))
        var aim=target.node.simdConvertPosition(rotation.act(point),to:nil)-muzzleWorld
        // Integrator advances with current velocity before subtracting gravity.
        aim.y += 0.005*profile.downwardVelocityChangePerTick*ticks*max(0,ticks-1)
        aim.y -= 0.01*SupplyDescent.depthlineCargo.centimetresPerTick*ticks
        return SCNVector3(simd_normalize(aim))
    }

    /// Only pre-existing rounds. New player/enemy requests are committed by the
    /// host AFTER this phase, in the original firing sequence.
    func updateOriginalSharedProjectiles() {
        projectiles.sharedPools.stepBallistics {token,source in
            let sweep=OriginalProjectileSweep(kind:.ballistic(source.weapon),
                start:SCNVector3(source.start.x*0.01,source.start.y*0.01,source.start.z*0.01),
                end:SCNVector3(source.end.x*0.01,source.end.y*0.01,source.end.z*0.01))
            let playerMachineGun = self.assets.isDepthline && !source.enemyFired && source.weapon == .machineGun
            if playerMachineGun {
                let end = OriginalWeaponVector(x: Float(source.end.x), y: Float(source.end.y), z: Float(source.end.z))
                return end.outsideOriginalProjectileBounds || self.resolveMachineGunContact(sweep)
            }
            if !source.enemyFired, self.training?.hitTarget(sweep,in:self) == true { return true }
            let playerCannon = self.assets.isDepthline && !self.isPlayingVictoryEffects && !source.enemyFired && sweep.kind.isCannon
            return OriginalSharedBallistics.resolve(version:self.version,bank:token.bank,sweep:source,
                ground:{[assets=self.assets] x,z in Double(assets.pointHeight(x:CGFloat(x)*0.01,z:CGFloat(z)*0.01))*100}, waterAt:self.assets.waterContact,
                onTerrain:{self.applyOriginalSharedTerrain($0,weapon:token.bank == .shell ? .cannon:.bullet)},
                onPlayer:{self.applyOriginalSharedPlayerHit($0,bank:token.bank,sweep:source)},
                hitTargets:{self.hitOriginalSharedClass($0,sweep:sweep,enemyFired:source.enemyFired)},
                hitInfantry:{self.hitOriginalSharedInfantry(sweep)},
                sweptCannonContact:playerCannon ? {self.resolveDepthlineInfantryShell(sweep)} : nil)
        }
        // Guidance and collision queries are refreshed per missile, and its
        // damage is applied before the next missile slot can select a target.
        _=projectiles.step(hitCandidates:hitCandidates,ground:assets.height,
            onMissileTrail:{self.effects.emitPlayerMissileSmoke(at:$0,night:self.night)},
            includeBallistics:false,missileTargetProvider:missileTargets,
            resolveMissile:{sweep in
                OriginalSharedBallistics.resolveMissile(version:self.version,
                    end:.init(Double(sweep.end.x*100),Double(sweep.end.y*100),Double(sweep.end.z*100)),
                    ground:{[assets=self.assets] x,z in Double(assets.pointHeight(x:CGFloat(x)*0.01,z:CGFloat(z)*0.01))*100}, waterAt:self.assets.waterContact,
                    onTerrain:{self.applyOriginalSharedTerrain($0,weapon:.missile)},
                    hitTargets:{self.hitOriginalSharedClass($0,sweep:sweep)})
            },
            onEvent:{self.applyProjectileEvents([$0])})
    }

    /// An exposed body can be above the old world-Y gate in either sector.
    /// Walk each live bullet segment in contact order, including sloped ground.
    private func resolveMachineGunContact(_ sweep: OriginalProjectileSweep) -> Bool {
        let cover = emplacementCover?.firstHit(from: SIMD3<Float>(sweep.start), to: SIMD3<Float>(sweep.end))
        let coverFraction = CGFloat(cover?.fraction ?? 1)
        let beforeCover = OriginalProjectileSweep(kind: sweep.kind, start: sweep.start, end: sweep.position(at: coverFraction))
        let waterAt = assets.waterContact
        let terrain = OriginalProjectiles.terrainFraction(sweep: beforeCover) { x, z in
            waterAt?(Double(x * 100), Double(z * 100)) == true ? 0 : self.assets.height(x: x, z: z)
        }
        let stop = terrain.map { $0 * coverFraction } ?? cover.map { CGFloat($0.fraction) }
        func hitTrainingTarget(before fraction: CGFloat) -> Bool {
            guard !isPlayingVictoryEffects, let training else { return false }
            return training.hitTarget(.init(kind: sweep.kind, start: sweep.start, end: sweep.position(at: fraction)), in: self)
        }
        if !isPlayingVictoryEffects {
            let actors = hitCandidates(sweep).filter { $0.fraction < (stop ?? .infinity) }
            for actor in actors.sorted(by: { $0.fraction < $1.fraction }) {
                if hitTrainingTarget(before: actor.fraction) { return true }
                guard let target = actor.target else { continue }
                let enemy = enemies.first { $0.node === target }
                // The hills corpse still intercepts the round. Its prior kill
                // already owns the hit and force accounting.
                if enemy?.type == "INFANTRY", version == .beach2002, let state = enemy?.aiState, state >= 42 { return true }
                let passesThroughDrop = version == .beach2000 && (target === supplyNodes[212] || target === supplyNodes[213])
                applySharedObjectHit(actor, sweep: sweep, enemy: enemy)
                if !passesThroughDrop { return true }
            }
        }
        if hitTrainingTarget(before: stop ?? 1) { return true }
        if let terrain {
            let end = beforeCover.position(at: terrain)
            let p = SIMD3<Double>(end.x, end.y, end.z) * 100
            let water = waterAt?(p.x, p.z) ?? false
            applyOriginalSharedTerrain(.init(kind: water ? .water : .ground, position: p, infantryRadius: nil,
                                             horizontalOnly: false, infantryCenter: p, includesEmbarkedInfantry: false),
                                       weapon: .bullet)
            return true
        }
        if let cover {
            showCoverImpact(cover)
            return true
        }
        return false
    }

    /// The coastal crate belongs to the chute mesh; inland it is a distinct
    /// child. Hit in each visible model's local frame as the drop swings.
    func depthlineDropHit(id:Int,node:SCNNode,sweep:OriginalProjectileSweep)->OriginalCollision.Hit? {
        let p=node.position, reach:CGFloat=6
        // A fast round can cross the whole target and end outside its bounds.
        guard OriginalProjectiles.segmentAABB(start:sweep.start,end:sweep.end,
            minimum:SCNVector3(p.x-reach,p.y-reach,p.z-reach),
            maximum:SCNVector3(p.x+reach,p.y+reach,p.z+reach)) != nil else {return nil}
        let fabric=assets.collision.hit(type:"Parachute",node:node,start:sweep.start,end:sweep.end)
        guard version == .beach2002, (294..<358).contains(id),let chute=supply2002?.parachutes[id-294],
              chute.payloadKind != .trooper,let box=supplyNodes[chute.payloadID],
              box.parent === node,!box.isHidden,let name=box.name,
              let cargo=assets.collision.hit(type:name,node:box,start:sweep.start,end:sweep.end) else {return fabric}
        return fabric.map { $0.fraction < cargo.fraction ? $0 : cargo } ?? cargo
    }

    func hitOriginalSharedClass(_ target:OriginalSharedBallistics.TargetClass,sweep:OriginalProjectileSweep,enemyFired:Bool=false)->Bool {
        guard !isPlayingVictoryEffects else { return false }
        var anyHit=false
        for id in target.objects {
            if assets.isDepthline,target.type=="Parachute" {
                guard let node=supplyNodes[id],!node.isHidden else {continue}
                let airborneEnemy = version == .beach2002 && supply2002?.parachutes[id-294].payloadKind == .trooper
                guard !enemyFired || airborneEnemy, let hull=depthlineDropHit(id:id,node:node,sweep:sweep) else {continue}
                anyHit=true
                applyProjectileEvents([.impact(sweep:sweep,hit:.init(fraction:hull.fraction,target:node,originalPart:hull.part))],genericSplash:false)
                continue
            }
            let enemy = projectileTargets.visibleEnemy(at: id)
            guard let node=enemy?.node ?? supplyNodes[id],!node.isHidden else {continue}
            let p=originalPosition(node),end=SIMD3(Double(sweep.end.x*100),Double(sweep.end.y*100),Double(sweep.end.z*100)),d=p-end
            if let radius=target.radius,d.x*d.x+d.y*d.y+d.z*d.z>=radius*radius {continue}
            if target.bargeBox,!(abs(d.x)<230 && abs(d.z)<690 && d.y<260) {continue}
            let hit:OriginalProjectileHit
            if target.endpointOnly {hit = .init(fraction:1,target:node,originalPart:nil)}
            else {
                guard let geometry=assets.collision.hit(type:enemy?.type ?? target.type,cargoFamily:enemy?.cargoFamily,
                    node:node,start:sweep.start,end:sweep.end) else {continue}
                hit = .init(fraction:geometry.fraction,target:node,originalPart:geometry.part)
            }
            // Do not stop after this hit: the EXE keeps testing later object
            // IDs/classes even though this slot's active flag is now zero.
            anyHit=true
            applySharedObjectHit(hit, sweep: sweep, enemy: enemy)
        }
        return anyHit
    }

    func applySharedObjectHit(_ hit: OriginalProjectileHit, sweep: OriginalProjectileSweep, enemy: Enemy?) {
        if version == .beach2000, sweep.kind.isCannon || sweep.kind.missileSlot != nil, let enemy,
           enemy.type == "TANK" || enemy.type.hasPrefix("APC") || enemy.type == "BARGE" {
            // Vehicle smoke consumes its RNG before the debris and damage step.
            let p = originalPosition(enemy.node)
            effects.emitBlastSmoke(at: .init(p.x, Double(sweep.start.y * 100), p.z), recipe: .vehicle2000,
                                   random15: { Int(self.random.next()) })
        }
        applyProjectileEvents([.impact(sweep: sweep, hit: hit)], genericSplash: false)
        if let helicopter = training?.helicopter, helicopter.enemy === enemy {
            helicopter.checkDestruction(after: sweep, in: self)
        }
    }

    func hitOriginalSharedInfantry(_ sweep:OriginalProjectileSweep)->Bool {
        guard !isPlayingVictoryEffects else { return false }
        // The recovered helper returns the FIRST qualifying source ID, not the
        // nearest body. BH2002 death60 still occludes another soldier; BH2000
        // death21...25 is excluded. Extra native safety slots retain ID order.
        for enemy in projectileTargets.infantry where !enemy.node.isHidden {
            guard let fraction=OriginalCollision.infantryHit(gameID:assets.gameID,state:enemy.aiState,
                foot:enemy.node.position,start:sweep.start,end:sweep.end) else {continue}
            let living=enemy.aiState>1 && enemy.aiState<(assets.gameID=="2000" ? 46:42)
            if living {
                applyProjectileEvents([.impact(sweep:sweep,hit:.init(fraction:fraction,target:enemy.node,originalPart:nil))],genericSplash:false)
            }
            //2000 clears active only inside its damage-state predicate;2002
            //clears it as soon as the helper returned an ID, including corpses.
            return assets.gameID=="2002" || living
        }
        return false
    }

    private func emitRoundContact(_ hit:OriginalEnemyImpact) {
        if hit.kind == .water { effects.emit(.waterSplash,at:hit.position,scale:.init(0.10,0.17)) }
        else { effects.emit(.dirtHit,at:hit.position) }
    }
    func applyOriginalSharedTerrain(_ hit:OriginalEnemyImpact,weapon:OriginalDamageWeapon,exposedOnly:Bool=false) {
        if weapon == .bullet {emitRoundContact(hit);return}
        effects.emit(hit.kind == .water ? .waterSplash:.groundExplosion,at:hit.position)
        playOriginalGroundImpactSound(weapon:weapon,at:hit.position)
        if hit.kind == .ground,abs(hit.position.x)>400 || abs(hit.position.z)>400 {
            var smokePosition=hit.position
            if version == .beach2000 {smokePosition.y -= 10}
            effects.emitBlastSmoke(at:smokePosition,recipe:.groundImpact(version:version),random15:{Int(self.random.next())})
        }
        guard !isPlayingVictoryEffects, let radius=hit.infantryRadius else {return}
        let center=hit.infantryCenter,point=SCNVector3(center.x*0.01,center.y*0.01,center.z*0.01)
        for enemy in enemies.filter({$0.type=="INFANTRY" && !$0.node.isHidden}).sorted(by:{$0.slot<$1.slot}) {
            if exposedOnly && !exposedToDepthlineShell(enemy) {continue}
            let delta=originalPosition(enemy.node)-center
            let distance=hit.horizontalOnly ? hypot(delta.x,delta.z):sqrt(delta.x*delta.x+delta.y*delta.y+delta.z*delta.z)
            if distance<radius {
                let onBoatRamp = exposedOnly && version == .beach2000 && enemy.aiState == 3
                applyInfantryExplosion(enemy,at:point,weapon:weapon,includesEmbarkedInfantry:hit.includesEmbarkedInfantry || onBoatRamp)
            }
        }
    }

    func applyOriginalSharedPlayerHit(_ damage:Int,bank:OriginalProjectilePools.Bank,sweep:OriginalSharedBallisticSweep) {
        if !isPlayingVictoryEffects { combat.health=max(0,combat.health-damage) }
        let hit=OriginalEnemyImpact(kind:.player,position:sweep.end,infantryRadius:nil,horizontalOnly:false,
                                   infantryCenter:sweep.end,includesEmbarkedInfantry:false)
        playOriginalEnemyImpactSounds(.init(previous:sweep.start,position:sweep.end,active:false,shieldDamage:damage,impacts:[hit]),
                                     kind:bank == .bullet ? .bullet:.shell)
        if assets.gameID=="2000",bank == .bullet {
            var velocity=sweep.end-sweep.start;velocity.y -= 0.16
            effects.emit(.impactFlash,at:sweep.end-velocity*0.4+SIMD3(0,30,0),scale:.init(repeating:0.7))
        }
    }

    /// Called at each nonshared terrain/player phase, not once after all rounds.
    /// Enemy2002 rocket smoke uses radialXZ>400; the shared shell/missile branch
    /// uses absX>400||absZ>400. Both place smoke at the sampled ground height.
    func applyOriginalEnemyOrdnancePhase(_ tick:OriginalEnemyOrdnanceTick,kind:OriginalEnemyOrdnanceKind) {
        if !isPlayingVictoryEffects { combat.health=max(0,combat.health-tick.shieldDamage) }
        playOriginalEnemyImpactSounds(tick,kind:kind)
        for hit in tick.impacts where hit.kind != .player {
            if kind == .bullet {emitRoundContact(hit);continue}
            if kind == .grenade {effects.emit(.impactFlash,at:hit.position,scale:.init(repeating:4));continue}
            var effectPosition=hit.position
            if version == .beach2000 {effectPosition.y += 10}
            let effect = effects.emit(hit.kind == .water ? .waterSplash:.groundExplosion,at:effectPosition)
            if kind == .bomb { training?.noteSupportImpact(effect) }
            let smokeFar=version == .beach2002 && kind != .shell ? hypot(hit.position.x,hit.position.z)>400 : abs(hit.position.x)>400 || abs(hit.position.z)>400
            if hit.kind == .ground,smokeFar {
                effects.emitBlastSmoke(at:hit.position,recipe:.groundImpact(version:version),random15:{Int(self.random.next())})
            }
            guard !isPlayingVictoryEffects, let radius=hit.infantryRadius else {continue}
            let center=hit.infantryCenter,point=SCNVector3(center.x*0.01,center.y*0.01,center.z*0.01)
            for enemy in enemies.filter({$0.type=="INFANTRY" && !$0.node.isHidden}).sorted(by:{$0.slot<$1.slot}) {
                let d=originalPosition(enemy.node)-center
                let distance=hit.horizontalOnly ? hypot(d.x,d.z):sqrt(d.x*d.x+d.y*d.y+d.z*d.z)
                if distance<radius {applyInfantryExplosion(enemy,at:point,weapon:.cannon,includesEmbarkedInfantry:hit.includesEmbarkedInfantry)}
            }
        }
    }

    ///2000 rocket/bomb tests are endpoint spheres200, not swept polygon rays.
    /// They also continue from Tank to APC after retiring the projectile. Tank
    /// force/score5 is unconditional in this source branch, even for state20.
    func hitOriginalEnemyOrdnanceUnits(kind:OriginalEnemyOrdnanceKind,previous:SIMD3<Double>,position:SIMD3<Double>)->Bool {
        guard !isPlayingVictoryEffects else { return false }
        guard version == .beach2000,kind == .airRocket || kind == .bomb else {return false}
        var hit=false
        for ids in [37..<43,61..<67] {
            for id in ids {
                guard let enemy = projectileTargets.visibleEnemy(at: id) else { continue }
                let d=originalPosition(enemy.node)-position
                guard d.x*d.x+d.y*d.y+d.z*d.z<200*200 else {continue}
                hit=true
                let tank=enemy.type=="TANK"
                let result=OriginalDamageResult(hitPoints:tank ? enemy.hp:0,nextAIState:20,active:true,deathMode:.wreck,
                    scoreDelta:tank ? 5:0,forceDelta:tank ? -5:0,evidence:"2000 0x416a09:2750-2895 rocket/bomb endpoint vehicle hit")
                applyDamage(result,to:enemy)
                var smokePosition=originalPosition(enemy.node);smokePosition.y=(previous.y+position.y)*0.5
                effects.emitBlastSmoke(at:smokePosition,recipe:.vehicle2000,random15:{Int(self.random.next())})
                effects.emit(.impactFlash,at:(previous+position)*0.5,scale:.init(repeating:4))
                playOriginalSoundRequests([.init(name:"ExFar",bufferSlot:0,advanceWriter:true)])
            }
        }
        return hit
    }
}
