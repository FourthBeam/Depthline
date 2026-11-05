import SceneKit

extension Game {
    func originalRotationDegrees(_ node:SCNNode)->SIMD3<Double> {
        let r=node.eulerAngles
        return SIMD3(Double(r.x),Double(r.y),Double(r.z)) * (180 / .pi)
    }

    /// Invoke before applyDamage removes the source node or changes its AI state.
    /// Supply planes use their destruction event and the helper below instead.
    func emitOriginalHitFragments(context:OriginalDamageContext,weapon:OriginalDamageWeapon,part:Int?,
                                  result:OriginalDamageResult,node:SCNNode,objectID:Int?=nil) {
        guard let id=objectID ?? context.originalObjectIndex else {return}
        if context.active,result.confirmed,result.deathMode == .wreck {
            RemasteredVehicles.applyWreck(to:node)
        }
        if context.version == .beach2000 {
            var source = context; source.originalObjectIndex = id
            fragments.wrecks2000?.apply(context: source, weapon: weapon, part: part, result: result, body: node)
        }
        if context.version == .beach2002,context.canonicalType == "TANK",
           context.active,result.confirmed,result.deathMode == .wreck,
           context.aiState != nil,context.aiState != 0,weapon == .cannon || weapon == .missile {
            fragments.detachTankTurret(bodyObjectID:id,body:node,position:originalPosition(node),random15:{Int(self.random.next())})
        }
        guard let recipe=OriginalFragmentRecipe.hit(context:context,weapon:weapon,part:part,result:result) else {return}
        fragments.emit(objectID:id,chunkSize:recipe.chunkSize,style:recipe.style,position:originalPosition(node),
                       rotationDegrees:originalRotationDegrees(node),random15:{Int(self.random.next())})
    }

    /// Only a confirmed supply planeDestroyed event may call this. Positions are
    /// original units; pass event position and model source Euler degrees before
    /// sync hides/removes the plane. No score/sprite/sound/damage is emitted here.
    func emitOriginalDestroyedFragments(type:String,objectID:Int,weapon:OriginalDamageWeapon,part:Int?=nil,
                                        position:SIMD3<Double>,rotationDegrees:SIMD3<Double>) {
        guard let recipe=OriginalFragmentRecipe.destroyed(version:version,type:type,weapon:weapon,part:part) else {return}
        fragments.emit(objectID:objectID,chunkSize:recipe.chunkSize,style:recipe.style,position:position,
                       rotationDegrees:rotationDegrees,random15:{Int(self.random.next())})
    }

    /// Call for source crash terminal events, never ordinary offscreen departure.
    func emitOriginalCrashFragments(type:String,objectID:Int,position:SIMD3<Double>,rotationDegrees:SIMD3<Double>) {
        guard let recipe=OriginalFragmentRecipe.crash(version:version,type:type) else {return}
        fragments.emit(objectID:objectID,chunkSize:recipe.chunkSize,style:recipe.style,position:position,
                       rotationDegrees:rotationDegrees,random15:{Int(self.random.next())})
    }
}
