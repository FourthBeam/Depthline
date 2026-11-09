import AppKit
import SceneKit
import simd

/// Strike marks live in world space: the contact triangle, rather than the camera,
/// determines where the mark rests and which side of the surface shows it.
final class DepthlineCoverImpacts {
    static let capacity = 96
    private(set) var marks: [SCNNode] = []
    private let parent: SCNNode
    private var serial = 0
    private static var patches: [DepthlineCover.Surface: SCNPlane] = [:]

    init(parent: SCNNode) { self.parent = parent }

    func emit(_ hit: DepthlineCover.Hit) {
        if marks.count == Self.capacity { marks.removeFirst().removeFromParentNode() }
        let normal = hit.normal
        let node = SCNNode(geometry: Self.patch(hit.surface))
        node.name = "cover-strike"
        node.castsShadow = false
        parent.addChildNode(node)
        node.simdWorldPosition = hit.position + normal * 0.002
        node.simdWorldOrientation = simd_quatf(from: SIMD3<Float>(0,0,1), to: normal)
            * simd_quatf(angle: Float(serial % 360) * 2.39996, axis: .init(0,0,1))
        node.simdScale = .init(repeating: 0.90 + Float(serial % 5) * 0.045)
        node.renderingOrder = 1
        marks.append(node); serial += 1
    }

    func clear() {
        marks.forEach { $0.removeFromParentNode() }; marks.removeAll(keepingCapacity: true); serial = 0
    }

    private static func patch(_ surface: DepthlineCover.Surface) -> SCNPlane {
        if let cached = patches[surface] { return cached }
        let rim: SIMD3<Float>, core: SIMD3<Float>, width: CGFloat, aspect: CGFloat
        switch surface {
        case .sandbag: (rim,core,width,aspect) = (.init(0.64,0.53,0.32),.init(0.12,0.09,0.055),0.12,0.77)
        case .concrete: (rim,core,width,aspect) = (.init(0.79,0.76,0.63),.init(0.15,0.14,0.12),0.15,0.92)
        case .stone: (rim,core,width,aspect) = (.init(0.68,0.65,0.54),.init(0.13,0.12,0.11),0.13,0.90)
        case .metal: (rim,core,width,aspect) = (.init(0.78,0.80,0.76),.init(0.12,0.13,0.13),0.092,0.94)
        }
        let pixels = 64
        var data = [UInt8](repeating: 0, count: pixels*pixels*4)
        for y in 0..<pixels { for x in 0..<pixels {
            let dx = (Float(x)+0.5)/32-1, dy = (Float(y)+0.5)/32-1
            let angle = atan2(dy,dx)
            let edge: Float = 0.73 + 0.086*sin(7*angle) + 0.056*cos(11*angle+1) + 0.046*sin(19*angle)
            let r = hypot(dx,dy)/edge
            let alpha = min(1,max(0,(1-r)*12))
            let grain = Float((x*157 + y*139 + x*y*17) % 31)/30
            let lip = max(0,min(1,(r - 0.49)*5 + 0.13*dy))
            let tint = (core + (rim-core)*lip) * (0.76 + 0.24*grain)
            let i = (y*pixels+x)*4
            for c in 0..<3 { data[i+c] = UInt8(tint[c]*alpha*255) }; data[i+3] = UInt8(alpha*255)
        }}
        let bitmap = CGImage(width:pixels,height:pixels,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:pixels*4,
            space:CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
            provider:CGDataProvider(data:Data(data) as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
        let material = SCNMaterial()
        material.lightingModel = .lambert; material.diffuse.contents = bitmap
        material.diffuse.mipFilter = .linear; material.blendMode = .alpha
        material.readsFromDepthBuffer = true; material.writesToDepthBuffer = false
        let plane = SCNPlane(width:width,height:width*aspect); plane.materials = [material]
        patches[surface] = plane
        return plane
    }
}

extension Game {
    func showCoverImpact(_ hit: DepthlineCover.Hit) {
        coverImpacts.emit(hit)
        let point = SIMD3<Double>(hit.position + hit.normal * 0.025) * 100
        if hit.surface == .metal {
            effects.emit(.impactFlash, at: point, scale: .init(0.09,0.09))
        } else {
            effects.emit(.dirtHit, at: point, scale: .init(0.22,0.26))
        }
    }
}
