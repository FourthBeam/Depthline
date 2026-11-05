import AppKit
import SceneKit
import QuartzCore

/// Intervals between live SCNView render callbacks, including missed refreshes.
private final class WindowCadence: NSObject, SCNSceneRendererDelegate {
    private let lock = NSLock()
    private var stamps: [Double] = []
    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock(); stamps.append(CACurrentMediaTime()); lock.unlock()
    }
    func times() -> [Double] { lock.lock(); defer { lock.unlock() }; return stamps }
}

extension AppDelegate {
    func runWindowProfile() throws {
        guard let pos=arguments.firstIndex(of:"--window-report"), pos+1<arguments.count else {throw NSError(domain:"WindowProfile",code:1)}
        let url=URL(fileURLWithPath:arguments[pos+1]), opts=try NativeCaptureOptions(arguments:arguments)
        let scale = window.backingScaleFactor
        window.setContentSize(.init(width:opts.pixels.width/scale,height:opts.pixels.height/scale)); window.center()
        try startGame(selectedGameID)
        guard let g=game else {throw NSError(domain:"WindowProfile",code:2)}
        try g.prepareOriginalCapture(arguments:arguments)
        g.paused=false; g.hud.paused=false; g.previousTime=CACurrentMediaTime()
        let meter=WindowCadence(), smoke=arguments.contains("--profile-smoke")
        g.view.delegate=meter
        let start=CACurrentMediaTime()
        let initialTick=g.logicalTick
        var smokeStep=0, counts:[Int]=[], timerTimes:[Double]=[], lastBurst = -1.0
        var pulseStart:Double?, pulseMilliseconds:[Double]=[], unhurtOverlaySamples=0, observedShots=0
        // Same 60 Hz timer, 29 ms simulation and HUD code as ordinary play.
        g.timer=Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { _ in
            g.combat.health=100
            if smoke && g.elapsed-lastBurst >= 0.22 {
                lastBurst=g.elapsed
                for i in 0..<3 {
                    let n=Double(smokeStep*3+i), x=12*sin(n*1.14), z = -34+8*cos(n*0.73)
                    let y=Double(g.assets.height(x:CGFloat(x),z:CGFloat(z)))
                    _ = g.effects.emit(.blackSmoke,at:.init(x*100,(y+1.8)*100,z*100),scale:.init(repeating:1.25))
                }
                smokeStep+=1
            }
            let wall=CACurrentMediaTime()-start
            g.shooting=smoke && wall>=12 && wall<16
            let shots=g.combat.shots
            g.tick()
            if g.shooting {
                observedShots+=g.combat.shots-shots
                if g.hud.damageFlash>0 && g.combat.health==100 {unhurtOverlaySamples+=1}
            }
            if !g.muzzleLamp.isHidden && pulseStart==nil {pulseStart=wall}
            if g.muzzleLamp.isHidden, let began=pulseStart {pulseMilliseconds.append(1000*(wall-began));pulseStart=nil}
            let stamp=CACurrentMediaTime()
            if stamp >= start+10 && stamp < start+70 { counts.append(g.effects.activeCount); timerTimes.append(stamp) }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+70) { [self,meter] in
            g.timer?.invalidate(); g.view.delegate=nil
            let times=meter.times().filter { $0 >= start+10 && $0 < start+70 }
            guard times.count>2 else {fputs("Window profile: no visible SCNView frames\n",stderr);exit(8)}
            let ms=zip(times.dropFirst(),times).map { ($0.0-$0.1)*1000 }.sorted()
            func p(_ q:Double)->Double {ms[max(0,Int(ceil(q*Double(ms.count)))-1)]}
            func drawable(_ layer:CALayer?) -> CGSize? {
                if let m=layer as? CAMetalLayer {return m.drawableSize}
                return layer?.sublayers?.compactMap(drawable).first
            }
            let backing=g.view.convertToBacking(g.view.bounds).size
            let size=drawable(g.view.layer)
            let hudMS=zip(timerTimes.dropFirst(),timerTimes).map{($0.0-$0.1)*1000}.sorted()
            guard !hudMS.isEmpty else {fputs("Window profile: HUD timer did not advance\n",stderr);exit(8)}
            let report:[String:Any]=[
                "source":"Intervals between live SCNView didRenderScene callbacks, while the production simulation and AppKit HUD run. This measures window render cadence, not GPU completion or compositor presentation.",
                "scene":smoke ? "Coast + deterministic smoke emitters":"Coast, campaign vessels",
                "fixture":"Health replenished while measuring; no changes to the campaign save.",
                "device":g.view.device?.name ?? "unknown","os":ProcessInfo.processInfo.operatingSystemVersionString,
                "windowPoints":[g.view.bounds.width,g.view.bounds.height],"backingScale":window.backingScaleFactor,
                "backingPixels":[backing.width,backing.height],"drawablePixels":size.map{[$0.width,$0.height]} ?? [],
                "warmupSeconds":10,"requestedSeconds":60,"sampleSpanSeconds":times.last!-times.first!,
                "hudAndSimulationTimerP50Milliseconds":hudMS[(hudMS.count-1)/2],
                "hudAndSimulationTimerP95Milliseconds":hudMS[Int(ceil(Double(hudMS.count)*0.95))-1],
                "controlledBurstDurationSeconds":smoke ? 4:0,"controlledBurstShots":observedShots,
                "muzzlePulseMillisecondsSampledAtHUDUpdates":pulseMilliseconds,
                "undamagedBurstSamplesWithHUDOverlay":unhurtOverlaySamples,
                "intervals":ms.count,"p50Milliseconds":p(0.5),"p95Milliseconds":p(0.95),
                "startTick":initialTick,"endTick":g.logicalTick,"effectRange":[counts.min() ?? 0,counts.max() ?? 0],
                "requestedPixels":[opts.pixels.width,opts.pixels.height],"targetFPS":g.view.preferredFramesPerSecond,
                "windowVisible":window.isVisible,"windowOcclusionVisible":window.occlusionState.contains(.visible)]
            do {try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic);print("Window profile:",p(0.5),p(0.95));NSApp.terminate(nil)}
            catch {fputs("Window profile: \(error)\n",stderr);exit(8)}
        }
    }
}
