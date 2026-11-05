import SceneKit

extension Game {
    /// Called synchronously at the source crash helper, before trailing physics
    /// and later units' RNG. The ordinary removed event only handles bookkeeping.
    func consumeOriginal2000CrashVisual(_ type: String, _ objectID: Int,
                                       _ position: SIMD3<Double>, _ rotationDegrees: SIMD3<Double>) {
        emitOriginalCrashFragments(type:type,objectID:objectID,position:position,rotationDegrees:rotationDegrees)
        burning.noteCrash(type:type,objectID:objectID,position:position)
        playOriginalCrashSound(at:position)
    }
}


extension Game {
    /// Exercises the production MacGame wrapper and real decoded debris. This
    /// fails if removed still re-emits fragments from the tick-end aircraft pose.
    func original2000CrashIntegrationTest() throws {
        guard assets.gameID == "2000" else { return }
        settings.soundEnabled=false
        random=Beach2000Supply.Random(seed:19)
        restart()
        let ai=Original2000AircraftAI(declarations:[.init(kind:.jet,slot:0,sourceIndex:-1,active:true)],
                                     aggression:[],random:{self.random.next()})
        aircraft2000=ai
        ai.applyDamage(objectID:76,hp:0,state:14,visible:true)
        var observed=false
        for _ in 0..<2000 {
            let before=ai.jets[0]
            updateOriginal2000Aircraft()
            if !ai.jets[0].visible {
                let pieces=fragments.snapshots
                try CampaignRuntimeValidation.require(!pieces.isEmpty,"2000 live crash wrapper emits decoded Jet debris")
                try CampaignRuntimeValidation.require(pieces.allSatisfy {$0.state.position == before.position && $0.state.rotationDegrees == before.eulerDegrees},
                    "2000 crash debris uses triggering pose, never the post-crash movement pose")
                try CampaignRuntimeValidation.require(ai.jets[0].position != before.position,
                    "fixture distinguishes source crash trigger from trailing physics")
                let count=pieces.count,firstVelocity=pieces.first!.state.velocity,rng=random.state
                updateOriginal2000Aircraft()
                try CampaignRuntimeValidation.require(fragments.snapshots.count==count && fragments.snapshots.first?.state.velocity==firstVelocity && random.state==rng,
                    "hidden aircraft neither re-emits crash debris nor consumes another burst of RNG")
                observed=true;break
            }
            originalClock.advance()
        }
        try CampaignRuntimeValidation.require(observed,"forced source Jet crash occurs within2000ticks")
        restart()
        print("PASS live2000crash: exact trigger pose, real decoded fragments, no deferred re-emission or duplicate RNG")
    }
}
