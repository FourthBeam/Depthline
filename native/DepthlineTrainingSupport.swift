import Foundation

enum DepthlineTrainingSupport {
    static let artilleryArea = Original2000BarrageState.Area(
        originCM: .init(-1000, -4900), sizeCM: .init(1800, 1700))

    /// CGRect x/y are world X/Z metres. The boundary encloses impact centres.
    static func area(for stage: DepthlineTraining.Stage) -> CGRect? {
        switch stage {
        case .artillery:
            return CGRect(x: CGFloat(artilleryArea.originCM.x) / 100, y: CGFloat(artilleryArea.originCM.y) / 100,
                          width: CGFloat(artilleryArea.sizeCM.x) / 100, height: CGFloat(artilleryArea.sizeCM.y) / 100)
        case .bombers: return CGRect(x: -10, y: -77, width: 20, height: 52)
        default: return nil
        }
    }

    // From the sea toward the emplacement. The original lateral offset selects
    // an X lane and four releases spread from the shoreline up the beach.
    static let bomberHeading = 180.0

    static func bomberRandomStreams() -> [OriginalEnemyAI.Random] {
        // Three flights, in original bomber slot order. Each row approaches
        // together on left, centre and right lanes across a 20-metre strip.
        // Seed only the existing spawn and delay draws. All flight, release
        // timing, shared bomb slots, gravity and terrain contacts remain live.
        let seeds: [UInt32] = [
            110410,  180654, 963331,
            371596,  843943, 762752,
            161365, 1025587, 221381
        ]
        return seeds.map { OriginalEnemyAI.Random(seed: $0) }
    }
}
