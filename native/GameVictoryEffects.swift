import SceneKit

/// Keep the battlefield visible until the last hit has finished playing.
/// An idle supply plane, a wreck, or a looping flame has no natural last frame.
extension Game {
    private var bombersDropping: Bool {
        bombers.contains { $0.active && ($0.state == 4 || ($0.state == 3 && $0.counter > 0)) }
    }

    var hasPendingVictoryEffects: Bool {
        hasPendingVictoryDeaths || effects.hasOneShotEffects || fragments.hasMovingDebris ||
        projectiles.ballisticCount > 0 || projectiles.missileCount > 0 || !enemyOrdnance.rounds.isEmpty ||
        barrage != nil || bombersDropping || flares.slots.contains { $0.active }
    }

    func advanceVictoryEffects() {
        advanceVictoryDeaths()
        // Complete flights and their impacts without letting them alter the recorded result.
        updateOriginalSharedProjectiles()
        updateEnemyOrdnance()
        if bombersDropping {
            updateBombers()
            emitOriginal2002FireFlags()
        }
        if let tick = barrage?.step(random15: { Int(self.random.next()) }) {
            if tick.playApproachSound { playSound("Bombfall") }
            if let hit = tick.impact {
                let x = CGFloat(hit.x) / 100, z = CGFloat(hit.z) / 100
                let position = SCNVector3(Float(x), Float(assets.height(x: x, z: z)) + 0.1, Float(z))
                explode(position)
                playOriginalGroundImpactSound(weapon: .artillery, at: .init(Double(hit.x), 0, Double(hit.z)))
            }
            if barrage?.remainingTicks == 0 { barrage = nil }
        }
        if flares.slots.contains(where: { $0.active }) { updateFlares() }
        weaponPresentation.tick(acceptedFire: nil)
        effects.tick(cameraEuler: camera.eulerAngles, night: night)
        fragments.tick()
    }
}
