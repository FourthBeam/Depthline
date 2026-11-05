import AppKit
import SceneKit

extension AppDelegate {
    /// New-resource regression suite. Historical extracted-asset assertions are
    /// intentionally kept in their old suite, never relabeled as Depthline evidence.
    func runDepthlineValidation() throws {
        func check(_ ok: @autoclosure () -> Bool, _ detail: String) throws {
            if !ok() { throw NSError(domain:"DepthlineValidation",code:1,userInfo:[NSLocalizedDescriptionKey:detail]) }
        }
        try mouseCaptureSelfTest()
        try originalInputModelSelfTest()
        try campaignStoreSelfTest()
        var results: [CampaignRuntimeValidation.Mission] = []
        var projectionSamples: [[String:Any]] = []
        var helicopterFlights: [[String:Any]] = []
        var supplySamples: [[String:Any]] = []
        var infantrySamples: [[String:Any]] = []
        let reportPath = arguments.firstIndex(of:"--depthline-report").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        let captureDirectory = reportPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        if let captureDirectory {
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        }
        for id in ["2000","2002"] {
            try startGame(id)
            guard let current=game else {throw NSError(domain:"DepthlineValidation",code:2)}
            current.timer?.invalidate();current.timer=nil;current.settings.soundEnabled=false
            try check(current.assets.levels.count == (id == "2000" ? 60:100),"Complete new campaign")
            try check(current.assets.objects.allSatisfy { $0["sourceLine"] == nil },"No extracted geometry line references")
            try check(current.scene.rootNode.childNode(withName:"DepthlineEnvironment",recursively:false) != nil,"Original emplacement installed")
            try check(window.collectionBehavior.contains(.fullScreenPrimary),"Full-screen primary window")
            if id == "2002" { try current.validateCarriageTraverse() }
            helicopterFlights.append(try current.validateDepthlineHelicopterFlight())
            infantrySamples.append(try current.validateDepthlineInfantry(output: captureDirectory))
            for mission in current.assets.levels {
                let number=mission["number"] as! Int
                let campaign=OriginalCampaign(gameID:id,level:number,definition:mission)
                try check(campaign.initialForce>0 && campaign.initialForce.isFinite,"Positive mission force \(id)/\(number)")
                try check(mission["source"]==nil && mission["commands"]==nil,"New mission declarations only")
            }
            if id == "2000" {
                guard let field=current.assets.shoreline, let water=current.assets.waterContact else {
                    throw NSError(domain:"ShoreContact",code:1)
                }
                // At the same Z a shell can now hit the side headland or splash
                // in the open channel. The historical straight Z cutoff could not.
                let x1 = -100.0, x2 = 0.0, z=0.5*(field.z(at:x1)+field.z(at:x2))
                try check(field.z(at:x1)<z && z<field.z(at:x2),"Dry bluff and wet channel at the same depth")
                for (x,expected):(Double,OriginalEnemyImpactKind) in [(x1,.ground),(x2,.water)] {
                    let end=SIMD3<Double>(100*x,-10,100*z)
                    var contact: OriginalEnemyImpact?
                    let retired=OriginalSharedBallistics.resolve(version:.beach2000,bank:.shell,
                        sweep:.init(weapon:.cannon,start:end+SIMD3(0,500,0),end:end),
                        ground:{xx,zz in Double(current.assets.height(x:xx/100,z:zz/100))*100},waterAt:water,
                        onTerrain:{contact=$0},onPlayer:{_ in},hitTargets:{_ in false},hitInfantry:{false})
                    try check(retired && contact?.kind == expected,"Surface impact follows the visible bay")
                }
            }
            for level in (id == "2000" ? [1,12,60]:[1,5,24,100]) {
                results.append(try CampaignRuntimeValidation.run(current,level:level,ticks:1600))
            }
            for canopy in [false,true] {
                supplySamples.append(try current.validateSupplyGunfire(canopy:canopy))
            }
            current.restart();current.settings.soundEnabled=false
            projectionSamples += try validateDepthlinePresentation(current)
            let ammo=current.weapons.ammo.machineGun, shots=current.combat.shots
            // A restarted run preserves the weapon's cadence phase. Wait for
            // its next accepted shot instead of assuming the first phase fires.
            var accepted: OriginalFireAction?
            for _ in 0..<7 {
                if let action=current.weapons.step(triggerDown:true) {accepted=action;break}
            }
            guard let action=accepted else {throw NSError(domain:"DepthlineValidation",code:3)}
            current.weaponPresentation.tick(acceptedFire:action)
            current.fire(action)
            let firedBasis=current.weaponPresentation.basis(for:action)
            guard let tip=firedBasis.muzzle,let round=current.projectiles.snapshots.last else {
                throw NSError(domain:"DepthlineMuzzle",code:1)
            }
            let delta=SIMD3<Float>(Float(round.position.x-tip.x), Float(round.position.y-tip.y), Float(round.position.z-tip.z))
            try check(simd_length(delta)<0.001 && !current.muzzleLamp.isHidden && current.hud.damageFlash==0,
                      "Round and local flash start at the recoiling muzzle without a damage overlay")
            try check(current.combat.shots == shots+1 && current.weapons.ammo.machineGun == ammo-1,"Shot consumes ammo and enters production ballistics")
            current.togglePause();let tick=current.logicalTick;current.tick()
            try check(current.logicalTick==tick,"Pause freezes simulation")
            current.togglePause()
            current.combat.health-=1
            try check(current.hud.damageFlash==1,"Defence loss starts the damage overlay")
            for _ in 0..<5 { current.simulationTick() }
            try check(current.muzzleLamp.isHidden && current.hud.damageFlash==0,"Local light and damage feedback expire on the simulation clock")
            current.effects.clear()
            for kind in OriginalEffectKind.allCases where OriginalEffectProfile.recovered(kind,version:current.version) != nil {
                try check(current.effects.emit(kind,at:SIMD3(0,800,-1600)) != nil,"New effect emitted: \(kind.rawValue)")
            }
            try check(current.effects.missingTexturePaths.isEmpty,"No old sprite dependency")
            current.fragments.clear()
            try check(current.fragments.emit(objectID:id == "2000" ? 88:142,chunkSize:8,style:.airburst,position:SIMD3(0,800,-1600),rotationDegrees:.zero,random15:{12345}),"Original fragment geometry available")
            try check(current.fragments.activeCount>0,"Visible plate fragments")
            let before=current
            showLauncher()
            try check(game==nil && before.timer==nil && !before.view.mouseCapture.isCaptured,"Launcher cleans game and cursor")
        }
        let payload:[String:Any]=[
            "title":DepthlineIdentity.title,
            "scope":"New procedurally authored resources; seven selected production missions, 1600 ticks each, no player fire and health replenished for observation. Not 160 wins or all-mission runtime coverage.",
            "aimMeasurements":projectionSamples,
            "helicopterFlights":helicopterFlights,
            "infantry":infantrySamples,
            "gunMount":"Hills mission two: 37 traverse headings at each of four pitch angles. Both ends of the support stay on their pins and the fork keeps its orientation relative to the receiver.",
            "airdropGunfire":supplySamples,
            "missionResults":try JSONSerialization.jsonObject(with:JSONEncoder().encode(results)),
            "checks":["capture state machine","direct input invariants","isolated named saves","new mission schemas","finite live entities and projectiles","64-degree camera and 55-percent HUD aim at 16:9 and 16:10","world-fixed lighting across four headings","gun offset follows aim","cloud and water simulation time and pause freeze","terrain versus water impacts across the bay","local muzzle and damage-only HUD","pause","shot and ammo","aimed machine-gun flight to falling cargo and canopy in both sectors, resource award and HUD receipt, miss and enemy-fire exclusions, single redemption","all effect kinds without legacy textures","new plate debris","launcher cleanup"]]
        let path = reportPath ?? "build/depthline-validation.json"
        try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        print("PASS: Depthline original resource integration, 7 missions / 11200 ticks")
    }

    private func validateDepthlinePresentation(_ current: Game) throws -> [[String:Any]] {
        func check(_ ok: @autoclosure () -> Bool, _ detail: String) throws {
            if !ok() {throw NSError(domain:"DepthlinePresentation",code:1,userInfo:[NSLocalizedDescriptionKey:detail])}
        }
        func near(_ a: Double, _ b: Double, tolerance: Double = 0.0001) -> Bool {abs(a-b)<tolerance}
        let originalSize=current.view.frame.size, originalAngles=current.camera.eulerAngles
        defer {
            current.camera.eulerAngles=originalAngles
            current.view.setFrameSize(originalSize)
            current.updateHUD()
        }
        guard let camera=current.camera.camera else {throw NSError(domain:"DepthlinePresentation",code:2)}
        var projectionSamples: [[String:Any]] = []
        let renderer = SCNRenderer(device: current.view.device, options: nil)
        renderer.scene = current.scene
        renderer.pointOfView = current.camera
        let marker = SCNNode(geometry: SCNSphere(radius: 0.009))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.magenta
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        marker.geometry?.materials = [material]
        marker.renderingOrder = 5000
        marker.castsShadow = false
        // The marker is fixed in the world on the actual forward firing ray.
        // projectPoint uses the last presented camera, so render the changed
        // pose before comparing it with the model or reading the HUD.
        marker.position = current.camera.convertPosition(SCNVector3(0,0,-1.5),to:nil)
        current.scene.rootNode.addChildNode(marker)
        defer { marker.removeFromParentNode() }
        for size in [NSSize(width:1600,height:900),NSSize(width:1600,height:1000)] {
            current.view.setFrameSize(size)
            current.updateHUD()
            let projection=camera.projectionTransform
            let horizontalDegrees=2*atan(1/Double(projection.m11))*180 / Double.pi
            try check(near(horizontalDegrees,64),"Depthline horizontal FOV is 64 degrees")
            try check(near(Double(projection.m22/projection.m11),Double(size.width/size.height)),"Projection uses the current viewport aspect")
            SCNTransaction.flush()
            let windowFrame = current.view.snapshot()
            let projected = current.view.projectPoint(marker.position)
            let port = current.view.currentViewport
            let projectedFraction = CGPoint(x:(projected.x-port.minX)/port.width,
                                            y:1-(projected.y-port.minY)/port.height)
            let hudFraction = CGPoint(x:0.5,y:current.hud.sightVerticalFraction)
            let windowSample = try measureAimMarker(windowFrame, near:hudFraction)
            let offscreenFrame = renderer.snapshot(atTime:current.elapsed,with:size,antialiasingMode:.none)
            let captureSample = try measureAimMarker(offscreenFrame, near:hudFraction)
            try check(near(Double(hudFraction.y),0.55),"HUD requests 55 percent from the top")
            try check(abs(projectedFraction.x-hudFraction.x)*port.width <= 1 &&
                      abs(projectedFraction.y-hudFraction.y)*port.height <= 1,
                      "Presented world point meets HUD: \(projectedFraction) versus \(hudFraction)")
            for sample in [windowSample,captureSample] {
                try check(abs(sample.center.x-hudFraction.x*sample.size.width) <= 1.25 &&
                          abs(sample.center.y-hudFraction.y*sample.size.height) <= 1.25,
                          "Rendered world marker meets HUD in backing pixels: \(sample)")
            }
            projectionSamples.append([
                "game":current.assets.gameID,"windowPoints":[size.width,size.height],
                "worldMarkerMetres":[marker.position.x,marker.position.y,marker.position.z],
                "sceneKitViewport":[port.minX,port.minY,port.width,port.height],
                "sceneKitProjectedBottomLeft":[projected.x,projected.y],
                "windowPixels":[windowSample.size.width,windowSample.size.height],
                "windowPixelCenterTopLeft":[windowSample.center.x,windowSample.center.y],
                "capturePixels":[captureSample.size.width,captureSample.size.height],
                "capturePixelCenterTopLeft":[captureSample.center.x,captureSample.center.y],
                "hudCenterTopLeftPoints":[hudFraction.x*size.width,hudFraction.y*size.height]
            ])
        }
        marker.removeFromParentNode()

        let root=current.scene.rootNode
        guard let bounce=root.childNode(withName:"DepthlineSkyBounce",recursively:false),
              let day=root.childNode(withName:"RemasteredSkyDay",recursively:false),
              let night=root.childNode(withName:"RemasteredSkyNight",recursively:false) else {
            throw NSError(domain:"DepthlinePresentation",code:3,userInfo:[NSLocalizedDescriptionKey:"World lighting and sky nodes exist"])
        }
        try check(current.sun.parent === root && bounce.parent === root,"Sun and sky bounce belong to the world")
        var cameraLights:[SCNNode]=[]
        current.camera.enumerateChildNodes {node,_ in if node.light != nil {cameraLights.append(node)}}
        try check(cameraLights.allSatisfy {$0 === current.spotlight},"Only the intentional night searchlight follows the camera")
        let fixedNodes=[current.sun,bounce,day,night]
        let fixedTransforms=fixedNodes.map(\.worldTransform)
        for degrees in [0.0,90.0,180.0,270.0] {
            let yaw=degrees * .pi / 180
            current.camera.eulerAngles=SCNVector3(0,yaw,0)
            current.syncGunPose()
            for (node,transform) in zip(fixedNodes,fixedTransforms) {
                try check(SCNMatrix4EqualToMatrix4(node.worldTransform,transform),"World light and sky transforms remain fixed while aiming")
            }
            let offset=current.depthlineGunOffset, position=current.gun.position
            let local=current.camera.convertVector(offset,from:nil)
            if current.usesOffsetTwinMount {
                try check(local.x < -0.5 && local.z < -1 && local.y < 0,"Feed side remains visible while traversing")
                let zero=current.camera.simdConvertPosition(.init(0,0,-80),to:nil)
                let along=current.gun.simdWorldPosition+current.gun.simdWorldFront*simd_distance(zero,current.gun.simdWorldPosition)
                try check(simd_distance(along,zero)<0.001,"Midpoint of twin bore axes crosses the HUD ray at the sight zero")
            } else {
                try check(local.x>0 && local.z < 0,"Support weapon stays on the feed-side sightline while traversing")
            }
            try check(near(Double(position.x),Double(offset.x)) && near(Double(position.y),8+Double(offset.y)) && near(Double(position.z),Double(offset.z)),"Gun world position is mount plus aim displacement")
        }

        var seen=Set<ObjectIdentifier>(), timed:[(SCNMaterial,String)]=[]
        root.enumerateChildNodes {node,_ in
            for material in node.geometry?.materials ?? [] where seen.insert(ObjectIdentifier(material)).inserted {
                if material.name == "HD:terrain" || material.name == "HD:water" {timed.append((material,"bhTime"))}
                if node === day || node === night {timed.append((material,"skyTime"))}
            }
        }
        try check(timed.filter {$0.1 == "skyTime"}.count==2,"Both skies receive simulation time")
        try check(timed.contains {$0.0.name == "HD:terrain"},"Terrain time material is installed")
        if current.assets.gameID == "2000" {try check(timed.contains {$0.0.name == "HD:water"},"Coast water time material is installed")}
        func clocks() throws -> [Double] {
            try timed.map {material,key in
                guard let value=material.value(forKey:key) as? NSNumber,value.doubleValue.isFinite else {
                    throw NSError(domain:"DepthlinePresentation",code:4,userInfo:[NSLocalizedDescriptionKey:"Initialized finite material clock: \(key)"])
                }
                return value.doubleValue
            }
        }
        current.updateHUD()
        let before=try clocks(), beforeElapsed=current.elapsed
        current.simulationTick();current.updateHUD()
        let advanced=try clocks()
        try check(current.elapsed>beforeElapsed && zip(before,advanced).allSatisfy {$0.1>$0.0},"Cloud and water clocks advance with production simulation")
        try check(advanced.allSatisfy {near($0,current.elapsed)},"Every material clock matches elapsed simulation time")
        current.togglePause()
        let frozenElapsed=current.elapsed, frozenTick=current.logicalTick
        for _ in 0..<3 {current.previousTime-=0.1;current.tick()}
        let frozen=try clocks()
        let pauseWasFrozen=current.elapsed==frozenElapsed && current.logicalTick==frozenTick && frozen==advanced
        current.togglePause()
        try check(pauseWasFrozen,"Pause freezes simulation, water and both cloud clocks")
        print("PASS: Depthline camera/HUD aspects, world lighting, rotating gun offset, cloud/water clocks and pause")
        return projectionSamples
    }

    /// Read actual sRGB raster pixels around the sight, independent of the
    /// projection API, backing scale or a window system's bottom-left origin.
    private func measureAimMarker(_ image: NSImage, near aim: CGPoint) throws -> (center: CGPoint, size: CGSize) {
        let error = NSError(domain:"DepthlinePresentation",code:5,
                            userInfo:[NSLocalizedDescriptionKey:"Cannot find the world marker beside the HUD sight in the rendered frame"])
        var rect = NSRect(origin:.zero,size:image.size)
        guard let full = image.cgImage(forProposedRect:&rect,context:nil,hints:nil) else { throw error }
        let crop = CGRect(x:floor(CGFloat(full.width)*aim.x)-20,y:floor(CGFloat(full.height)*aim.y)-20,
                          width:40,height:40)
        guard let patch = full.cropping(to:crop) else { throw error }
        var rgba = [UInt8](repeating:0,count:40*40*4)
        try rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data:bytes.baseAddress,width:40,height:40,bitsPerComponent:8,
                                          bytesPerRow:160,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                                          bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw error }
            context.draw(patch,in:CGRect(x:0,y:0,width:40,height:40))
        }
        var x:CGFloat=0,y:CGFloat=0,count:CGFloat=0
        for i in 0..<1600 {
            let r=Int(rgba[i*4]),g=Int(rgba[i*4+1]),b=Int(rgba[i*4+2])
            if r>100 && b>100 && r>3*g && b>3*g {
                x+=CGFloat(i%40)+0.5; y+=CGFloat(i/40)+0.5; count+=1
            }
        }
        guard count>=12 else { throw error }
        return (CGPoint(x:crop.minX+x/count,y:crop.minY+y/count), CGSize(width:full.width,height:full.height))
    }
}
