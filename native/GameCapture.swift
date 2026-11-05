import AppKit
import SceneKit

/// Reproducible screenshots of the production mission, without the old preview's
/// manually placed enemies. This path uses the same loader, tick and damage code
/// as interactive play, with a temporary store selected by --screenshot.
extension Game {
    func prepareOriginalCapture(arguments: [String]) throws {
        func value(_ name: String) throws -> String? {
            guard let i = arguments.firstIndex(of: name) else { return nil }
            guard i + 1 < arguments.count else {
                throw NSError(domain: "GameCapture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Missing value for \(name)"])
            }
            return arguments[i + 1]
        }
        func integer(_ name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let text = try value(name) else { return fallback }
            guard let number = Int(text), range.contains(number) else {
                throw NSError(domain: "GameCapture", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid \(name): \(text)"])
            }
            return number
        }
        func angle(_ name: String, default fallback: Double) throws -> Double {
            guard let text = try value(name) else { return fallback }
            guard let number = Double(text), number.isFinite else {
                throw NSError(domain: "GameCapture", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid \(name): \(text)"])
            }
            return number
        }
        let requestedLevel = try integer("--capture-level", default: 1, range: 1...109)
        let ticks = try integer("--capture-ticks", default: 0, range: 0...30_000)
        let fireTicks = try integer("--capture-fire-ticks", default: 0, range: 0...ticks)
        let seed = UInt32(try integer("--capture-seed", default: 20_001_102, range: 0...Int(UInt32.max)))
        timer?.invalidate(); timer = nil
        onCheckpoint = nil; onRunEnded = nil; onSettingsChanged = nil
        settings.soundEnabled = false
        random = Beach2000Supply.Random(seed: seed); originalClock = OriginalTickClock()
        restart(level: requestedLevel - 1)
        guard !finished, levelDefinition != nil else {
            throw NSError(domain: "GameCapture", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Missing authored capture level \(requestedLevel)"])
        }
        if let name = try value("--capture-light") {
            guard let preset = DepthlineLight(rawValue: name) else {
                throw NSError(domain: "GameCapture", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "Expected --capture-light day, dusk, or night"])
            }
            applyLight(preset, searchlight: true)
        }
        let yaw = try angle("--capture-yaw", default: Double(camera.eulerAngles.y) * 180 / .pi)
        let pitch = try angle("--capture-pitch", default: Double(camera.eulerAngles.x) * 180 / .pi)
        input.setAngles(yawDegrees: yaw, pitchDegrees: pitch)
        camera.eulerAngles = SCNVector3(pitch * .pi / 180, yaw * .pi / 180, 0)
        syncGunPose()
        let stress = arguments.contains("--capture-stress")
        let flareAt = try value("--capture-flare-tick").map { _ in try integer("--capture-flare-tick",default:0,range:0...max(0,ticks-1)) }
        for tick in 0..<ticks {
            if stress {combat.health=100}
            if tick == flareAt {
                // Fire the equipped mission flare 32° above the horizon, then
                // measure its illumination from the same camera as the control.
                let angles=camera.eulerAngles
                camera.eulerAngles.x = 32 * .pi/180; launchFlare(); camera.eulerAngles=angles
            }
            shooting = tick >= ticks - fireTicks
            simulationTick()
            if finished { break }
        }
        if stress {
            var bearings = [Int](repeating:0,count:16)
            for enemy in enemies where !enemy.node.isHidden {
                let p=enemy.node.position
                let angle=atan2(Double(-p.x),Double(-p.z))
                let bin=Int((angle/(2 * .pi)*16+16).rounded())%16
                bearings[bin] += 1
            }
            if let index=bearings.indices.max(by:{bearings[$0]<bearings[$1]}) {
                let heading=Double(index)*360/16
                input.setAngles(yawDegrees:heading,pitchDegrees:-6)
                camera.eulerAngles=SCNVector3(-6 * .pi/180,heading * .pi/180,0)
                syncGunPose()
            }
        }
        shooting = false; paused = true; sound.stopAll()
        updateHUD(); hud.paused = false
        if let output = try value("--screenshot") {
            let capture = try NativeCaptureOptions(arguments: arguments)
            let metadata: [String: Any] = [
                "graphicsQuality": assets.graphics.quality.rawValue,
                "renderPixels": [Int(capture.pixels.width), Int(capture.pixels.height)],
                "hudPoints": [Int(capture.points.width), Int(capture.points.height)],
                "renderer": "SceneKit Metal offscreen snapshot at actual output dimensions",
                "scope": stress ? "Renderer stress fixture: production mission and spawns, health replenished every tick, camera aimed toward densest enemy sector. Not gameplay/survival evidence." : "Production mission with fixed seed; no health refill or synthetic enemy placement. Camera may be explicitly selected.",
                "stressFixture": stress,
                "lightPreset": visualLight.rawValue,
                "flareTick":flareAt as Any? ?? NSNull(), "activeFlares":flares.slots.filter(\.active).count,
                "flareLightIntensity":flareNodes.filter{!$0.isHidden}.map{$0.light?.intensity ?? 0}.max() ?? 0,
                "gameID": assets.gameID, "requestedLevel": requestedLevel,
                "actualLevel": level + 1, "seed": seed,
                "requestedTicks": ticks, "actualTick": logicalTick,
                "fireTicks": fireTicks, "health": combat.health, "ammo": weapons.ammo.machineGun,
                "hudVisible": !capture.hideHUD,
                "horizontalFOV": capture.horizontalFOV, "verticalFOV": capture.verticalFOV,
                "bargesXZMetres": enemies.filter { !$0.node.isHidden && $0.type.hasPrefix("BARGE") }.map { [Double($0.node.position.x),Double($0.node.position.z)] },
                "finished": finished, "yawDegrees": Double(camera.eulerAngles.y)*180 / .pi, "pitchDegrees": Double(camera.eulerAngles.x)*180 / .pi,
                "remainingForce": campaign?.remainingForce ?? 0,
                "enemyCount": enemies.count, "activeEffects": effects.activeCount, "playerProjectileCount": projectiles.snapshots.count,
                "enemyProjectileCount": enemyOrdnance.rounds.count,
                "supplyCount": supplyNodes.count
            ]
            let path = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("json")
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: path, options: .atomic)
        }
    }
}

/// Capture dimensions are physical output pixels, independent of the monitor.
/// The HUD is laid out in points and drawn at 2× for outputs above full HD.
struct NativeCaptureOptions {
    var quality: CampaignStore.GraphicsQuality?
    var hideHUD = false
    var movieURL: URL?
    var motion = "sea"
    var referenceLens = false
    var horizontalFOV: Double {
        referenceLens ? 2*atan(tan(58 * .pi/360)*Double(pixels.width/pixels.height))*180 / .pi : DepthlineCamera.horizontalDegrees
    }
    var verticalFOV: Double { 2*atan(tan(horizontalFOV * .pi/360)*Double(pixels.height/pixels.width))*180 / .pi }
    var profile = false
    var stress = false
    var outputURL: URL?
    var pixels = CGSize(width: 1280, height: 800)
    var points: CGSize {
        let scale: CGFloat = pixels.width > 1920 || pixels.height > 1080 ? 2 : 1
        return CGSize(width: pixels.width / scale, height: pixels.height / scale)
    }
    init(arguments: [String]) throws {
        func value(_ flag: String) throws -> String? {
            guard let index = arguments.firstIndex(of: flag) else { return nil }
            guard index + 1 < arguments.count else { throw NSError(domain: "GameCapture", code: 6, userInfo: [NSLocalizedDescriptionKey: "Missing \(flag)"] ) }
            return arguments[index + 1]
        }
        hideHUD = arguments.contains("--capture-hide-hud")
        referenceLens = arguments.contains("--capture-reference-lens") // reference Three.js camera: 58° vertical
        movieURL = try value("--capture-movie").map { URL(fileURLWithPath:$0) }
        motion = try value("--capture-motion") ?? "sea"
        guard ["sea","turn","fire"].contains(motion) else { throw NSError(domain:"GameCapture",code:10) }
        profile = arguments.contains("--capture-profile")
        stress = arguments.contains("--capture-stress")
        outputURL = try value("--screenshot").map { URL(fileURLWithPath: $0) }
        if let name = try value("--capture-graphics") {
            guard name == "remastered" else {
                throw NSError(domain: "GameCapture", code: 7, userInfo: [NSLocalizedDescriptionKey: "Only remastered graphics is available; remove the legacy --capture-graphics option."])
            }
            quality = .remastered
        }
        for flag in ["--capture-width", "--capture-height"] {
            if let text = try value(flag) {
                guard let n = Int(text), (320...7680).contains(n) else {
                    throw NSError(domain: "GameCapture", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid capture dimensions"])
                }
                if flag == "--capture-width" { pixels.width = CGFloat(n) } else { pixels.height = CGFloat(n) }
            }
        }
    }
}

extension Game {
    func captureNativePixels(options: NativeCaptureOptions) throws -> Data {
        let oldProjection = camera.camera!.projectionTransform
        defer { camera.camera!.projectionTransform = oldProjection }
        DepthlineCamera.configure(camera.camera!, gameID: assets.gameID, size: options.pixels)
        if options.referenceLens {
            var p = camera.camera!.projectionTransform
            p.m22 = 1/tan(58 * .pi/360); p.m11 = p.m22*options.pixels.height/options.pixels.width
            camera.camera!.projectionTransform = p
        }
        let renderer = SCNRenderer(device: view.device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        renderer.isPlaying = false
        assets.graphics.update(time: elapsed)
        let aa = assets.graphics.antialiasing
        if options.profile {
            // Warm shader compilation, image upload and environment convolution.
            for _ in 0..<3 { autoreleasepool { _ = renderer.snapshot(atTime: elapsed, with: options.pixels, antialiasingMode: aa) } }
            var milliseconds: [Double] = []
            for _ in 0..<20 {
                if options.stress {combat.health=100;shooting=true;paused=false;simulationTick();paused=true;assets.graphics.update(time:elapsed)}
                autoreleasepool {
                    let start = CACurrentMediaTime()
                    let frame = renderer.snapshot(atTime: elapsed, with: options.pixels, antialiasingMode: aa)
                    var rect = NSRect(origin: .zero, size: options.pixels)
                    _ = frame.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                    milliseconds.append((CACurrentMediaTime() - start) * 1000)
                }
            }
            let sorted = milliseconds.sorted()
            let stats: [String: Any] = ["frames": 20, "warmupFrames": 3,
                "medianMilliseconds": (sorted[9] + sorted[10]) / 2, "p95Milliseconds": sorted[18],
                "samplesMilliseconds": milliseconds, "simulationTicksAdvanced": options.stress ? 20:0, "finalEnemyCount": enemies.count, "finalActiveEffects": effects.activeCount, "finalTick": logicalTick, "device": view.device?.name ?? "Metal",
                "scope": "Offscreen SceneKit snapshot including GPU readback; excludes loading, PNG encoding and HUD compositing. This is not interactive frame rate."]
            if let output = options.outputURL?.deletingPathExtension().appendingPathExtension("json"),
               let data = try? Data(contentsOf: output),
               var metadata = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                metadata["renderProfile"] = stats
                metadata["persistentMetalProfile"] = try NativeRenderProfiler.measure(scene:scene,camera:camera,size:options.pixels,time:elapsed)
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
            }
            print("4K offscreen profile: median \(stats["medianMilliseconds"]!) ms, p95 \(stats["p95Milliseconds"]!) ms")
        }
        shooting=false
        updateHUD();hud.paused=false
        let rendered = renderer.snapshot(atTime: elapsed, with: options.pixels, antialiasingMode: aa)
        var rect = NSRect(origin: .zero, size: options.pixels)
        guard let cg = rendered.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              cg.width == Int(options.pixels.width), cg.height == Int(options.pixels.height) else {
            throw NSError(domain: "GameCapture", code: 9, userInfo: [NSLocalizedDescriptionKey: "Renderer did not return requested native pixel dimensions"])
        }
        if let metadataURL=options.outputURL?.deletingPathExtension().appendingPathExtension("json"),
           var metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:metadataURL)) as? [String:Any] {
            let px=Double(options.pixels.width), py=Double(options.pixels.height)
            // Project the very same view-projection as the snapshot. The bounds
            // enclose the posed visible hull; they are not a segmented pixel mask.
            let vp=camera.camera!.projectionTransform
            func screen(_ world:SCNVector3)->[Double]? {
                let p=camera.convertPosition(world,from:nil)
                guard -p.z>0.08 else {return nil}
                return [(1 + Double(-p.x/p.z*vp.m11-vp.m31))*px/2,(1 - Double(-p.y/p.z*vp.m22-vp.m32))*py/2]
            }
            metadata["bargeScreenBoundsPx"]=enemies.filter{!$0.node.isHidden && $0.type.hasPrefix("BARGE")}.compactMap { e -> [Double]? in
                let (lo,hi)=e.node.boundingBox
                let pts=[lo.x,hi.x].flatMap{x in [lo.y,hi.y].flatMap{y in [lo.z,hi.z].compactMap{z in screen(e.node.convertPosition(.init(x,y,z),to:nil))}}}
                guard !pts.isEmpty else {return nil}
                return [pts.map{$0[0]}.min()!,pts.map{$0[1]}.min()!,pts.map{$0[0]}.max()!,pts.map{$0[1]}.max()!]
            }
            let forward=camera.worldFront
            metadata["opticalHorizonYTopPx"]=screen(.init(camera.position.x+forward.x*500,camera.position.y,camera.position.z+forward.z*500))?[1]
            try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:metadataURL,options:.atomic)
        }
        let still = try options.hideHUD
            ? NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])
            : hud.compositePNG(over: rendered, pixels: options.pixels, points: options.points)
        if let movie = options.movieURL {
            // The renderer and its camera/projection are shared with the still.
            try recordReviewMovie(to:movie, renderer:renderer, options:options, aa:aa)
        }
        guard let still else { throw NSError(domain:"GameCapture",code:11) }
        return still
    }
}
