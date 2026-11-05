import AppKit
import SceneKit
import simd

/// The light, sky and water all use a world-space vector pointing toward the sun.
enum DepthlineLight: String {
    case day, dusk, night

    static func mission(gameID: String, level: Int, night: Bool) -> Self {
        if night { return .night }
        return gameID == "2002" && level % 5 == 4 ? .dusk : .day
    }

    func sunDirection(inland: Bool) -> SIMD3<Float> {
        switch self {
        case .day:   return simd_normalize(SIMD3(0.59, 0.44, -0.67))
        case .dusk:  return simd_normalize(inland ? SIMD3(0.18, 0.055, 1.0) : SIMD3(-0.32, 0.073, -1.0))
        case .night: return simd_normalize(SIMD3(-0.66, 0.40, 0.62))
        }
    }

    // A low-frequency reflection probe for the twilight metal and wet ground.
    // SceneKit's cube-face order is +X,-X,+Y,-Y,+Z,-Z. Warm light follows
    // the same azimuth as the low key light instead of tinting every surface.
    static func duskEnvironment(sun: SIMD3<Float>) -> [NSImage] {
        let side = 64
        return (0..<6).map { face in
            var bytes = [UInt8](repeating: 255, count: side * side * 4)
            for y in 0..<side {
                for x in 0..<side {
                    let u = 2 * (Float(x) + 0.5) / Float(side) - 1
                    let v = 2 * (Float(y) + 0.5) / Float(side) - 1
                    let ray = simd_normalize([SIMD3<Float>(1,-v,-u), SIMD3(-1,-v,u), SIMD3(u,1,v),
                                              SIMD3(u,-1,-v), SIMD3(u,-v,1), SIMD3(-u,-v,-1)][face])
                    let sky = max(0, min(1, ray.y * 4 + 0.55))
                    let glow = pow(max(0, simd_dot(ray,sun)), 24) * exp(-abs(ray.y - sun.y) * 4)
                    let colour = SIMD3<Float>(0.105,0.13,0.16) + SIMD3<Float>(0.20,0.28,0.39) * sky
                        + SIMD3<Float>(0.56,0.19,0.035) * glow
                    for c in 0..<3 { bytes[(y * side + x) * 4 + c] = UInt8(min(255, colour[c] * 255)) }
                }
            }
            let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                                shouldInterpolate: true, intent: .defaultIntent)!
            return NSImage(cgImage: image, size: NSSize(width: side, height: side))
        }
    }
}
