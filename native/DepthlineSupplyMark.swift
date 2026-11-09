import AppKit
import SceneKit
import simd

/// Four distinct, high-contrast stencils on the physical crate.
enum DepthlineSupplyMark: String, CaseIterable {
    case health, cartridges, shell, missile

    static func coast(_ reward: Beach2000Supply.RewardKind?) -> Self? {
        switch reward { case .defense: return .health; case .machineGunAmmo: return .cartridges; case nil: return nil }
    }
    static func hills(_ kind: Beach2002Supply.PayloadKind?) -> Self? {
        switch kind {
        case .defense: return .health; case .machineGun: return .cartridges
        case .cannon: return .shell; case .missile: return .missile
        case .trooper, nil: return nil
        }
    }

    private static let materials: [Self:SCNMaterial] = Dictionary(uniqueKeysWithValues: allCases.map { mark in
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = mark.artwork()
        m.diffuse.minificationFilter = .linear; m.diffuse.mipFilter = .linear
        m.blendMode = .alpha; m.writesToDepthBuffer = false; m.readsFromDepthBuffer = true
        m.name = "supply-sign-" + mark.rawValue
        return (mark,m)
    })

    private func artwork() -> CGImage {
        let n = 128
        let c = CGContext(data:nil,width:n,height:n,bitsPerComponent:8,bytesPerRow:n*4,
                          space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.scaleBy(x:2,y:2)
        typealias RGB = (CGFloat,CGFloat,CGFloat)
        func ink(_ color: RGB) { c.setFillColor(red:color.0,green:color.1,blue:color.2,alpha:1) }
        func plate(_ inset: CGFloat, _ radius: CGFloat) {
            c.addPath(CGPath(roundedRect:CGRect(x:inset,y:inset,width:64-2*inset,height:64-2*inset),
                             cornerWidth:radius,cornerHeight:radius,transform:nil)); c.fillPath()
        }
        func rect(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat) { c.fill(CGRect(x:x,y:y,width:w,height:h)) }
        func shape(_ pts:[CGPoint]) {
            c.beginPath(); c.move(to:pts[0]); for p in pts.dropFirst() { c.addLine(to:p) }; c.closePath(); c.fillPath()
        }
        let accent: RGB
        switch self {
        case .health: accent=(1,0.98,0.93)
        case .cartridges: accent=(1,0.81,0.34)
        case .shell: accent=(1,0.65,0.32)
        case .missile: accent=(0.57,0.87,1)
        }
        ink((0.08,0.12,0.14)); plate(0.5,9)
        ink(accent); plate(2.5,7)
        if self != .health { ink((0.11,0.16,0.18)); plate(5.2,4.5); ink(accent) }
        switch self {
        case .health:
            ink((0.82,0.06,0.105)); rect(25,11,14,42); rect(11,25,42,14)
        case .cartridges:
            for x:CGFloat in [13,27,41] {
                shape([.init(x:x,y:19),.init(x:x+10,y:19),.init(x:x+10,y:39),
                       .init(x:x+8,y:44),.init(x:x+5,y:51),.init(x:x+2,y:44),.init(x:x,y:39)])
                rect(x,13,10,3.5)
            }
        case .shell:
            c.beginPath(); c.move(to:.init(x:20,y:22)); c.addLine(to:.init(x:20,y:32))
            c.addQuadCurve(to:.init(x:32,y:54),control:.init(x:21,y:44))
            c.addQuadCurve(to:.init(x:44,y:32),control:.init(x:43,y:44))
            c.addLine(to:.init(x:44,y:22)); c.closePath(); c.fillPath()
            rect(20,16,24,3.5); rect(18,10,28,4)
        case .missile:
            // Swept fins, a pointed nose and an exhaust gap distinguish it from a shell at distance.
            c.translateBy(x:32,y:32); c.rotate(by:-0.49)
            shape([.init(x:0,y:25),.init(x:5,y:15),.init(x:5,y:-3),.init(x:13,y:-14),
                   .init(x:13,y:-20),.init(x:4,y:-15),.init(x:-4,y:-15),.init(x:-13,y:-20),
                   .init(x:-13,y:-14),.init(x:-5,y:-3),.init(x:-5,y:15)])
            shape([.init(x:-3.5,y:-18),.init(x:3.5,y:-18),.init(x:0,y:-26)])
        }
        return c.makeImage()!
    }

    private func tile(side: CGFloat) -> SCNNode {
        let plane = SCNPlane(width:side,height:side); plane.materials = [Self.materials[self]!]
        let node = SCNNode(geometry:plane); node.castsShadow = false; node.renderingOrder = 2
        return node
    }

    // Coast reuses each crate for different rewards; rebuild only when its own load changes.
    func paint(_ cargo: SCNNode, center: SIMD3<Float>, size: SIMD3<Float>) {
        let groupName = "cargo-stencil"
        if let old = cargo.childNode(withName:groupName,recursively:false) {
            if old.childNodes.first?.geometry?.firstMaterial === Self.materials[self] { return }
            old.removeFromParentNode()
        }
        let group = SCNNode(); group.name = groupName; cargo.addChildNode(group)
        for i in 0..<4 {
            let yaw = Float(i) * .pi/2, normal = SIMD3<Float>(sin(yaw),0,cos(yaw))
            let faceWidth = i.isMultiple(of:2) ? size.x : size.z
            let depth = i.isMultiple(of:2) ? size.z : size.x
            let face = tile(side:CGFloat(min(faceWidth,size.y)*0.77))
            face.simdPosition = center + normal * (depth*0.5 + (i.isMultiple(of:2) ? 0.026 : 0.045))
            face.simdEulerAngles.y = yaw
            group.addChildNode(face)
        }
    }
}
