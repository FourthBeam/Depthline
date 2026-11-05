import Foundation

extension DepthlineFlightTerrain {
    /// AI positions are centimetres. The renderer and its ground triangles are metres.
    func groundForFlight(_ x: Double, _ z: Double) -> Double {
        height(x: x * 0.01, z: z * 0.01) * 100
    }

    func flightAltitude(_ p: SIMD3<Double>, _ yaw: Double, _ speed: Double, _ landing: Bool, _ lift: inout Double) -> Double {
        if landing {
            // Hand control to the transport's existing descent/door/takeoff sequence.
            // Its contact test includes the 3.38 m rotor-root-to-wheel offset.
            lift = 0
            return max(p.y, groundForFlight(p.x, p.z) + 338)
        }
        let angle = yaw * .pi / 180
        let forward = SIMD2(-sin(angle), -cos(angle)), right = SIMD2(-forward.y, forward.x)
        let centre = SIMD2(p.x, p.z)
        func floorAt(_ offset: SIMD2<Double>) -> Double {
            groundForFlight(centre.x + offset.x, centre.y + offset.y)
        }
        // Span the rotors and tail, then look several seconds along the current
        // course. A distant summit starts the climb before the nose reaches it.
        let ground = max(floorAt(.zero), floorAt(700 * right), floorAt(-700 * right),
                         floorAt(800 * forward), floorAt(-800 * forward))
        var ahead = ground
        for ticks in [8.0, 16, 24, 32] {
            let distance = speed * ticks
            ahead = max(ahead, floorAt(forward * distance) - distance * 0.17)
        }
        let nominal = p.y - lift
        // Give a banking rotor room above the surface. Shed extra altitude at a
        // bounded rate after a ridge rather than snapping back to the patrol level.
        let plannedLift = min(lift + 45, ahead + 950 - nominal)
        lift = max(0, lift - 28, plannedLift, ground + 950 - nominal)
        return nominal + lift
    }
}
