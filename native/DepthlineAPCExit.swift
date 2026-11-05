import Foundation

/// Rear ramp and hull footprint in the AI's centimetres, with +Z pointing aft.
enum DepthlineAPCHull {
    case coast, hills
    var rear: Double { self == .coast ? 152 : 164 }
    var front: Double { self == .coast ? -152 : -254 }
    var halfWidth: Double { self == .coast ? 92 : 103 }
}

struct DepthlineAPCExit {
    private let origin: SIMD3<Double>
    private let right, rearward: SIMD2<Double>
    private let waypoints: [SIMD2<Double>]
    private let rampTop: Double
    private var next = 1
    private var wait: Int
    private var local: SIMD2<Double>
    private var travelled = 0.0
    private(set) var isVisible = false
    var isFinished: Bool { next == waypoints.count }

    init(hull: DepthlineAPCHull, origin: SIMD3<Double>, angles: SIMD3<Double>, seat: Int) {
        self.origin = origin
        let yaw = angles.y * .pi / 180
        right = SIMD2(cos(yaw), -sin(yaw))
        rearward = SIMD2(sin(yaw), cos(yaw))
        // Keep the entire standing figure clear of the rear armour on its first visible tick.
        local = SIMD2(0, hull.rear + 45)
        rampTop = origin.y + 21 - sin(angles.x * .pi / 180) * local.y
        wait = seat * 11
        let toBunker = SIMD2(-origin.x, -origin.z) / max(1, hypot(origin.x, origin.z))
        let lateral = toBunker.x * right.x + toBunker.y * right.y
        let aft = toBunker.x * rearward.x + toBunker.y * rearward.y
        let side: Double = abs(lateral) > 0.55 ? (lateral > 0 ? 1 : -1) : (seat.isMultiple(of: 2) ? 1 : -1)
        let flank = side * (hull.halfWidth + 85 + Double(seat / 2) * 30)
        let clearRamp = SIMD2<Double>(0, hull.rear + 108)
        let behindCorner = SIMD2(flank, hull.rear + 145)
        let clearHull = SIMD2(flank, aft > 0.5 ? hull.rear + 270 : hull.front - 140)
        waypoints = [local, clearRamp, behindCorner, clearHull]
    }

    mutating func step(ground: (Double, Double) -> Double) -> (position: SIMD3<Double>, direction: SIMD2<Double>)? {
        guard !isFinished else { return nil }
        if wait > 0 { wait -= 1; return nil }
        let delta = waypoints[next] - local
        let length = hypot(delta.x, delta.y)
        let heading = delta / length
        if isVisible {
            let stride = min(10, length)
            local += heading * stride
            travelled += stride
            if stride == length { next += 1 }
        }
        isVisible = true
        let offset = right * local.x + rearward * local.y
        let x = origin.x + offset.x, z = origin.z + offset.y
        let floor = ground(x, z)
        let height = floor + max(0, rampTop - floor) * max(0, 1 - travelled / 65)
        return (SIMD3(x, height, z), right * heading.x + rearward * heading.y)
    }
}
