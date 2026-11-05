import SceneKit

extension Game {
    /// Exercise the asymmetric M60 installation from the second hills mission.
    /// Its offset from the camera makes an incorrectly rolling fork easy to detect.
    func validateCarriageTraverse() throws {
        try CampaignRuntimeValidation.require(assets.gameID == "2002", "The M60 traverse test requires the hills campaign")
        let previousLevel = level, previousScore = levelStartScore, previousCheats = usedCheats
        defer { restart(level: previousLevel, score: previousScore, usedCheats: previousCheats) }
        restart(level: 1)
        try CampaignRuntimeValidation.require(campaign?.level == 2 && weapons.selected == .machineGun && weapons.machineGunVariant == 1,
                                              "Hills mission two must equip the M60")
        guard let receiver = weaponPresentation.nodes[23],
              let pedestal = scene.rootNode.childNode(withName: "Depthline turret pedestal", recursively: true),
              let arm = scene.rootNode.childNode(withName: "Depthline elevation arm", recursively: true) else {
            throw NSError(domain: "DepthlineCarriage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing M60, pedestal or elevation arm"])
        }
        let fixed = pedestal.simdWorldTransform
        let lowerBearing = pedestal.simdConvertPosition(.init(0, 0.83, 0), to: nil)
        let trunnion = SIMD3<Float>(0, -0.032, -0.15)
        for pitch in [-25, 0, 35, 80] {
            var initialCameraAxis: SIMD3<Float>?
            for yaw in stride(from: 0, through: 360, by: 10) {
                let pose = "at yaw \(yaw)°, pitch \(pitch)°"
                camera.eulerAngles = SCNVector3(CGFloat(pitch) * .pi / 180, CGFloat(yaw) * .pi / 180, 0)
                syncGunPose()
                let upperBearing = receiver.simdConvertPosition(trunnion, to: nil)
                let bottom = arm.simdConvertPosition(.zero, to: nil)
                let top = arm.simdConvertPosition(.init(0, 1, 0), to: nil)
                let axis = simd_normalize(arm.simdConvertVector(.init(1, 0, 0), to: nil))
                let span = simd_normalize(top - bottom)
                let expectedAxis = simd_normalize(camera.simdWorldRight - span * simd_dot(camera.simdWorldRight, span))
                try CampaignRuntimeValidation.require(!arm.isHidden && simd_distance(bottom, lowerBearing) < 0.001 &&
                                                      simd_distance(top, upperBearing) < 0.001, "M60 mounting pins disconnected \(pose)")
                try CampaignRuntimeValidation.require(simd_dot(axis, expectedAxis) > 0.999, "M60 fork turned across the receiver \(pose)")
                let cameraAxis = camera.simdConvertVector(axis, from: nil)
                if let initialCameraAxis {
                    try CampaignRuntimeValidation.require(simd_distance(cameraAxis, initialCameraAxis) < 0.002, "M60 fork rolled during traverse \(pose)")
                } else {
                    initialCameraAxis = cameraAxis
                }
                for column in 0..<4 {
                    try CampaignRuntimeValidation.require(simd_distance(pedestal.simdWorldTransform[column], fixed[column]) < 0.0001,
                                                          "Floor pedestal moved \(pose)")
                }
            }
        }
        weapons.pressHandgunKey()
        syncWeaponModel()
        try CampaignRuntimeValidation.require(weapons.selected == .handgun && arm.isHidden && !pedestal.isHidden,
                                              "The handgun must stow the elevation arm and retain the floor pedestal")
    }
}
