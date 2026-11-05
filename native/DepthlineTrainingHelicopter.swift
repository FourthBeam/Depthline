import SceneKit

/// The range aircraft is a regular coastal Cobra without an attack or patrol AI.
/// Registering it as an enemy lets live rounds and missile guidance use the
/// same target IDs, collision hull and damage rules as the coastal campaign.
final class DepthlineTrainingHelicopter {
    let enemy: Enemy
    private let rotor: SCNNode?
    private let tailRotor: SCNNode?
    private let hoverPosition = SCNVector3(4, 20, -54)

    init(in game: Game) {
        let node = game.assets.model("COBRA")
        enemy = Enemy(node: node, type: "COBRA", flying: true)
        if let hp = OriginalDamage.initialHitPoints(version: game.version, type: enemy.type) { enemy.hp = hp }
        enemy.required = false
        rotor = node.childNode(withName: "Rotor", recursively: false)
        tailRotor = node.childNode(withName: "Prop", recursively: false)
        node.position = hoverPosition
        node.eulerAngles.y = 70 * .pi / 180
        game.scene.rootNode.addChildNode(node)
        game.enemies.append(enemy)
    }

    var aimPoint: SCNVector3 {
        enemy.node.convertPosition(SCNVector3(0, -0.95, 0), to: nil)
    }

    func hover(tick: Int) {
        enemy.node.position.y = hoverPosition.y + 0.12 * sin(CGFloat(tick) * 0.045)
        rotor?.eulerAngles.y = CGFloat((tick % 72) * 55) * .pi / 180
        tailRotor?.eulerAngles.x = CGFloat((tick % 9) * -40) * .pi / 180
    }

    func checkDestruction(after sweep: OriginalProjectileSweep, in game: Game) {
        if enemy.deathMode == .falling {
            // In a campaign the patrol AI finishes a bullet kill with a crash.
            // The stationary range target has no patrol AI to consume that state.
            let node = enemy.node
            if let id = game.originalObjectIndex(enemy) {
                game.consumeOriginal2000CrashVisual(enemy.type, id, game.originalPosition(node), game.originalRotationDegrees(node))
            }
            game.explode(node.position)
            node.removeFromParentNode()
            game.enemies.removeAll { $0 === enemy }
        }
        guard enemy.node.parent == nil else { return }
        game.training?.helicopterDestroyed(byMissile: sweep.kind.missileSlot != nil, in: game)
    }
}
