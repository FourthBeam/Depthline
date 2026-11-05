import AppKit
import SceneKit

/// Render adapter only. State.step owns recovered flight/impact/defense rules.
final class EnemyOrdnanceRenderer {
    final class Round {
        var state:OriginalEnemyOrdnanceState
        let node:SCNNode
        let key:String
        var poolToken:OriginalProjectilePools.Token?
        init(state:OriginalEnemyOrdnanceState,node:SCNNode,key:String) {self.state=state;self.node=node;self.key=key}
    }
    let root:SCNNode
    let material:SCNMaterial
    let sharedPools:OriginalProjectilePools
    let rocketFlames:OriginalRocketFlames?
    var rounds:[Round]=[]
    private var next:[String:Int]=[:]
    init(root:SCNNode,texture:URL,sharedPools:OriginalProjectilePools,effects:OriginalEffectsRenderer?=nil) {
        self.root=root;self.sharedPools=sharedPools;material=SCNMaterial();material.lightingModel = .constant;material.blendMode = .add
        rocketFlames=effects.map {OriginalRocketFlames(version:sharedPools.version,effects:$0)}
        material.diffuse.contents=NSImage(contentsOf:texture);material.isDoubleSided=true;material.writesToDepthBuffer=false
    }
    var nextBombSlot:Int {next["bomb",default:0]}
    func spawn(_ state:OriginalEnemyOrdnanceState,model:SCNNode?=nil,slot:Int?=nil) {
        let pool=state.kind == .airRocket ? "airRocket":state.kind == .groundRocket ? "groundRocket":state.kind.rawValue
        // 2002 updates 16 Cobra-rocket slots, but the original writer wraps at 12.
        let capacity:[String:Int]=["bullet":80,"shell":state.version == .beach2000 ? 4:6,"airRocket":12,"groundRocket":8,"bomb":state.version == .beach2000 ? 16:24,"grenade":8]
        var token:OriginalProjectilePools.Token?
        if state.kind == .bullet || state.kind == .shell {
            token=sharedPools.claim(state.kind == .shell ? .shell:.bullet) { [weak self] old in
                self?.rounds.removeAll { round in if round.poolToken==old {round.node.removeFromParentNode();return true};return false }
            }
        }
        let index=token?.slot ?? slot ?? next[pool,default:0]
        next[pool]=(index+1)%(capacity[pool] ?? 8)
        let key="\(pool)-\(index)"
        rounds.removeAll {round in if round.key==key {round.node.removeFromParentNode();return true};return false}
        let node:SCNNode
        if let model {node=model}
        else {
            let size:CGFloat=state.kind == .bullet ? 0.45:0.6
            node=RemasteredBallisticVisual.make(size:size,name:"enemy-round")
        }
        node.name="enemy-\(key)";root.addChildNode(node)
        let p=state.position;node.position=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
        if model == nil { RemasteredBallisticVisual.orient(node,direction:SIMD3(Float(state.velocity.x),Float(state.velocity.y),Float(state.velocity.z))) }
        let round=Round(state:state,node:node,key:key);round.poolToken=token;rounds.append(round)
        if let token {
            sharedPools.registerAdvance(token) { [weak self,weak round] in
                guard let self,let round,self.sharedPools.isCurrent(token),round.state.active else {return nil}
                let previous=round.state.advanceFlight(),p=round.state.position
                round.node.position=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
                RemasteredBallisticVisual.orient(round.node,direction:SIMD3(Float(round.state.velocity.x),Float(round.state.velocity.y),Float(round.state.velocity.z)))
                return .init(weapon:token.bank == .shell ? .cannon:.machineGun,start:previous,end:p,enemyFired:true)
            }
        }
    }
    func step(ground:(Double,Double)->Double,waterAt:((Double,Double)->Bool)?=nil,infantry:()->[SIMD3<Double>],
              includeShared:Bool=true,
              onUnitHit:((OriginalEnemyOrdnanceKind,SIMD3<Double>,SIMD3<Double>)->Bool)?=nil,
              onImpact:@escaping (OriginalEnemyOrdnanceTick,OriginalEnemyOrdnanceKind)->Void) {
        var flameFrames:[OriginalRocketFlames.Frame]=[]
        func order(_ round:Round)->Int {
            let slot=round.poolToken?.slot ?? round.key.split(separator:"-").last.flatMap {Int($0)} ?? 0
            let base:[OriginalEnemyOrdnanceKind:Int]=[.bullet:0,.shell:100,.airRocket:200,.bomb:300,.groundRocket:400,.grenade:500]
            return base[round.state.kind]!+slot
        }
        for round in rounds.sorted(by:{order($0)<order($1)}) {
            if !includeShared,round.poolToken != nil {continue}
            let before=round.state
            let tick=round.state.step(ground:ground,waterAt:waterAt,eligibleInfantryPositions:infantry(),
                onUnits:{previous,end in onUnitHit?(before.kind,previous,end) ?? false},
                onPhase:{onImpact($0,before.kind)})
            let p=tick.position;round.node.position=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
            if before.kind == .bullet || before.kind == .shell {
                RemasteredBallisticVisual.orient(round.node,direction:SIMD3(Float(round.state.velocity.x),Float(round.state.velocity.y),Float(round.state.velocity.z)))
            }
            if round.state.kind == .bomb || round.state.kind == .airRocket || round.state.kind == .groundRocket {
                let v=round.state.velocity;round.node.eulerAngles=SCNVector3(atan2(v.y,hypot(v.x,v.z)),atan2(-v.x,-v.z),0)
            }
            if before.kind == .airRocket || before.kind == .groundRocket,
               let slot=round.key.split(separator:"-").last.flatMap({Int($0)}) {
                flameFrames.append(.init(slot:slot,groundRocket:before.kind == .groundRocket,previous:before.position,
                                         velocity:before.velocity,wasActive:before.active,remainsActive:round.state.active))
            }
        }
        rocketFlames?.step(flameFrames)
        rounds.removeAll {round in if !round.state.active {if let token=round.poolToken {sharedPools.release(token)};round.node.removeFromParentNode();return true};return false}
    }
    func clear() {rocketFlames?.clear();rounds.forEach {if let token=$0.poolToken {sharedPools.release(token)};$0.node.removeFromParentNode()};rounds=[];next=[:]}
}
