import SceneKit

/// A world-anchored aiming cue. Its ellipse and pictogram share a camera-facing
/// plane so the beach slope cannot kink the line or flatten the symbol.
enum DepthlineTrainingMarker {
    static func make(footprint: CGRect, action: OriginalSupportAction, ground: (CGFloat, CGFloat) -> CGFloat) -> SCNNode {
        let center = SCNNode()
        center.name = "TrainingSupportArea"
        center.position = SCNVector3(footprint.midX, max(0, ground(footprint.midX, footprint.midY)) + 0.15, footprint.midY)
        center.constraints = [SCNBillboardConstraint()]
        center.castsShadow = false

        let width = footprint.width * 0.8
        let ring = layer(size: CGSize(width: width, height: width * 88 / 396), material: ringMaterial)
        ring.name = "TrainingSupportRing"
        ring.renderingOrder = 3
        center.addChildNode(ring)

        let side = width * 0.17
        let icon = layer(size: CGSize(width: side, height: side), material: iconMaterial(action))
        switch action {
        case .beach2000GroundBarrage: icon.name = "TrainingSupportArtilleryIcon"
        case .beach2002NineBomberAirstrike: icon.name = "TrainingSupportBombingIcon"
        }
        icon.renderingOrder = 4
        center.addChildNode(icon)
        return center
    }

    private static func layer(size: CGSize, material: SCNMaterial) -> SCNNode {
        let plane = SCNPlane(width: size.width, height: size.height)
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.castsShadow = false
        return node
    }

    private static func artwork(width: Int, height: Int, draw: (CGContext) -> Void) -> SCNMaterial {
        let scale = 2
        let ctx = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        draw(ctx)

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = ctx.makeImage()
        material.diffuse.mipFilter = .linear
        material.blendMode = .alpha
        // This is an observation cue. The terrain crosses its plane at the anchor.
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        return material
    }

    private static let ringMaterial = artwork(width: 396, height: 88) { ctx in
        let oval = CGRect(x: 4, y: 4, width: 388, height: 80)
        ctx.setFillColor(red: 1, green: 0.14, blue: 0.09, alpha: 0.065)
        ctx.fillEllipse(in: oval)
        ctx.setStrokeColor(red: 0.32, green: 0.035, blue: 0.025, alpha: 0.88)
        ctx.setLineWidth(6)
        ctx.strokeEllipse(in: oval)
        ctx.setStrokeColor(red: 1, green: 0.23, blue: 0.17, alpha: 1)
        ctx.setLineWidth(3.2)
        ctx.strokeEllipse(in: oval)
    }

    private static func iconMaterial(_ action: OriginalSupportAction) -> SCNMaterial {
        artwork(width: 64, height: 64) { ctx in
            ctx.translateBy(x: 32, y: 32)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(3.5)
            ctx.setStrokeColor(red: 0.32, green: 0.035, blue: 0.025, alpha: 1)
            ctx.setFillColor(red: 1, green: 0.94, blue: 0.78, alpha: 1)
            let body = CGMutablePath()
            switch action {
            case .beach2000GroundBarrage:
                // Pointed shell with a flat base and a driving band.
                ctx.rotate(by: -0.56)
                body.move(to: CGPoint(x: -9, y: -21))
                body.addLine(to: CGPoint(x: -9, y: 6))
                body.addQuadCurve(to: CGPoint(x: 0, y: 25), control: CGPoint(x: -8, y: 17))
                body.addQuadCurve(to: CGPoint(x: 9, y: 6), control: CGPoint(x: 8, y: 17))
                body.addLine(to: CGPoint(x: 9, y: -21))
            case .beach2002NineBomberAirstrike:
                // Broad tail fins at the top and a rounded, falling nose.
                ctx.rotate(by: 0.64)
                body.move(to: CGPoint(x: -13, y: 23))
                body.addLine(to: CGPoint(x: 0, y: 17))
                body.addLine(to: CGPoint(x: 13, y: 23))
                body.addLine(to: CGPoint(x: 11, y: 11))
                body.addLine(to: CGPoint(x: 4, y: 6))
                body.addCurve(to: CGPoint(x: 0, y: -24), control1: CGPoint(x: 20, y: -3), control2: CGPoint(x: 11, y: -24))
                body.addCurve(to: CGPoint(x: -4, y: 6), control1: CGPoint(x: -11, y: -24), control2: CGPoint(x: -20, y: -3))
                body.addLine(to: CGPoint(x: -11, y: 11))
            }
            body.closeSubpath()
            ctx.addPath(body)
            ctx.drawPath(using: .fillStroke)
            if action == .beach2000GroundBarrage {
                ctx.setFillColor(red: 0.66, green: 0.12, blue: 0.075, alpha: 1)
                ctx.fill(CGRect(x: -9, y: -15, width: 18, height: 3.5))
            }
        }
    }
}
