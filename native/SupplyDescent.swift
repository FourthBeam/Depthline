/// Cargo motion uses centimetres per 29 ms simulation tick. The historical
/// motion stays available to the original rules and all enemy paratroopers.
enum SupplyDescent {
    case original, depthlineCargo

    var centimetresPerTick: Float { self == .depthlineCargo ? 5.5 : 10 }
    func releasePitch(original: Float) -> Float { self == .depthlineCargo ? 12 : original }

    func nextSwing(pitch: Float, velocity: Float) -> (Float, Float) {
        let spring = self == .depthlineCargo ? 0.004 : 0.008
        let damping = self == .depthlineCargo ? 0.955 : 0.992
        let next = Float(-Double(pitch) * spring + Double(velocity) * damping)
        return (pitch + next, next)
    }
}
