import Foundation

/// Pure native tests, callable by build.sh without launching AppKit or an application.
func originalAISelfTests() throws {
    try originalEnemyAISelfTest()
    try original2002InfantrySelfTest()
    try originalCampaignSelfTest()
}

/// Validates all exported level declarations and force accounting independently of rendering.
func originalCampaignAssetSelfTest(resourceRoot2000: URL, resourceRoot2002: URL) throws {
    func require(_ value: Bool, _ reason: String) throws {
        if !value { throw NSError(domain: "OriginalCampaignAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
    }
    for (game, root, maximum) in [("2000", resourceRoot2000, 60), ("2002", resourceRoot2002, 99)] {
        let exported = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("levels.json"))) as! [[String: Any]]
        let levels = exported.filter { game != "2000" || ($0["number"] as? Int) != 0 }
        try require(levels.count == maximum, "\(game) playable mission count")
        let indexed = Dictionary(uniqueKeysWithValues: levels.map { ($0["number"] as! Int, $0) })
        for number in 1...maximum {
            guard let definition = indexed[number] else { try require(false, "\(game) missing mission\(number)"); continue }
            let campaign = OriginalCampaign(gameID: game, level: number, definition: definition)
            try require(campaign.initialForce.isFinite && campaign.initialForce > 0, "\(game) mission\(number) has an active or scheduled enemy force")
            var events = campaign.takeInitialSpawns()
            if number == 1 {
                if game == "2000" {
                    try require(events.map(\.type) == ["BARGE", "BARGE", "BARGE"] && campaign.initialForce == 24,
                                "Coast opens with three infantry landing craft")
                } else {
                    try require(events.isEmpty && campaign.pendingSpawnCount == 5 && campaign.initialForce == 38,
                                "Hills opens with three scheduled APCs and two attack helicopters")
                }
            }
            var sourceCounts: [Int: Int] = [:]
            // Simulate immediate elimination to prove every active/delayed/revive allocation can
            // resolve its accounted force. AI trajectories and player skill are tested separately.
            for _ in 0..<30000 {
                for event in events {
                    sourceCounts[event.sourceIndex, default: 0] += 1
                    campaign.enemyRemoved(sourceIndex: event.sourceIndex)
                }
                if campaign.remainingForce == 0 && campaign.pendingSpawnCount == 0 { break }
                events = campaign.tick()
            }
            try require(campaign.remainingForce == 0, "\(game) mission\(number) unresolved scheduler force")
            try require(campaign.pendingSpawnCount == 0, "\(game) mission\(number) unresolved delayed activations")
            if game == "2002", number == 32 {
                try require(sourceCounts.keys.filter { (definition["objects"] as! [[String: Any]])[$0]["type"] as? String == "APC3" }.count == 4,
                            "Level32 must not turn seven turret declarations into hulls")
            }
            if game == "2002", number == 79 {
                try require(sourceCounts.keys.filter { (definition["objects"] as! [[String: Any]])[$0]["type"] as? String == "COBRA" }.count == 12,
                            "Level79 must not turn a rotor declaration into a helicopter")
            }
        }
        let firstRepeated = OriginalCampaign.sourceLevel(gameID: game, level: maximum + 1)
        try require(indexed[firstRepeated] != nil, "\(game) first repeated mission exists")
        if game == "2000" {
            try require(OriginalCampaign.sourceLevel(gameID: game, level: 69) == 60 && OriginalCampaign.sourceLevel(gameID: game, level: 70) == 51, "2000 original loop boundary")
        } else {
            try require(OriginalCampaign.sourceLevel(gameID: game, level: 109) == 100 && indexed[100] == nil, "2002 original missing Level100 remains explicit")
        }
    }
}
