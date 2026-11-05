import AppKit
import AVFoundation
import SceneKit

extension Game {
    /// A 10 s fixed-step review reel of the live mission. Offline readback and
    /// H.264 encoding speed do not enter the window cadence measurements.
    func recordReviewMovie(to url:URL, renderer:SCNRenderer, options:NativeCaptureOptions, aa:SCNAntialiasingMode) throws {
        let fps = 24, count = 240, w=Int(options.pixels.width), h=Int(options.pixels.height)
        let writer = try AVAssetWriter(outputURL:url,fileType:.mp4)
        let inputVideo = AVAssetWriterInput(mediaType:.video,outputSettings:[
            AVVideoCodecKey:AVVideoCodecType.h264, AVVideoWidthKey:w, AVVideoHeightKey:h,
            AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:max(3_000_000, w*h*9)]])
        let buffers=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:inputVideo,sourcePixelBufferAttributes:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String:w,kCVPixelBufferHeightKey as String:h,
            kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
        writer.add(inputVideo)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain:"ReviewMovie",code:1) }
        writer.startSession(atSourceTime:.zero)
        let yaw0=Double(camera.eulerAngles.y)*180 / .pi, pitch=Double(camera.eulerAngles.x)*180 / .pi
        let srgb=CGColorSpace(name: CGColorSpace.sRGB)!
        let startTick=logicalTick
        var ticksAdvanced=0
        let originalBounds=hud.bounds; hud.setBoundsSize(options.points)
        paused=false
        defer { shooting=false;paused=true; hud.bounds=originalBounds }
        for i in 0..<count {
            try autoreleasepool {
                let t=Double(i)/Double(fps)
                let yaw = yaw0 + (options.motion == "turn" ? 360 * t/10 : 0)
                input.setAngles(yawDegrees:yaw,pitchDegrees:pitch)
                camera.eulerAngles = SCNVector3(pitch * .pi/180,yaw * .pi/180,0); syncGunPose()
                shooting = options.motion == "fire" && t >= 2 && t < 8
                while ticksAdvanced < Int(t/Self.logicalStep) && !finished { simulationTick(); ticksAdvanced+=1 }
                updateHUD(); hud.paused=false
                let frame = renderer.snapshot(atTime:elapsed,with:options.pixels,antialiasingMode:aa)
                let display = options.hideHUD ? frame : hud.composited(over:frame)
                var rect=CGRect(origin:.zero,size:options.pixels)
                guard let image=display.cgImage(forProposedRect:&rect,context:nil,hints:nil), let pool=buffers.pixelBufferPool else {throw NSError(domain:"ReviewMovie",code:2)}
                let deadline=CACurrentMediaTime()+10
                while !inputVideo.isReadyForMoreMediaData && writer.status == .writing && CACurrentMediaTime()<deadline { Thread.sleep(forTimeInterval:0.003) }
                var pixel:CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&pixel) == kCVReturnSuccess, let pixel else {throw NSError(domain:"ReviewMovie",code:3)}
                CVPixelBufferLockBaseAddress(pixel,[])
                let ctx=CGContext(data:CVPixelBufferGetBaseAddress(pixel),width:w,height:h,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),space:srgb,bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue)
                ctx?.draw(image,in:rect)
                CVPixelBufferUnlockBaseAddress(pixel,[])
                guard ctx != nil && inputVideo.isReadyForMoreMediaData && buffers.append(pixel,withPresentationTime:CMTime(value:Int64(i),timescale:Int32(fps))) else { throw writer.error ?? NSError(domain:"ReviewMovie",code:4) }
            }
        }
        inputVideo.markAsFinished(); let done=DispatchSemaphore(value:0)
        writer.finishWriting { done.signal() }; done.wait()
        guard writer.status == .completed else {throw writer.error ?? NSError(domain:"ReviewMovie",code:5)}
        let log:[String:Any]=["frames":count,"fps":fps,"durationSeconds":10,"startTick":startTick,"endTick":logicalTick,"motion":options.motion,"yawStart":yaw0,"yawSweepDegrees":options.motion == "turn" ? 360:0,"pitch":pitch,"healthAtEnd":combat.health,"ammoAtEnd":weapons.ammo.machineGun,"hudVisible": !options.hideHUD,"source":"Deterministic SceneKit mission playback; offline readback. Not a frame-rate benchmark."]
        try JSONSerialization.data(withJSONObject:log,options:[.prettyPrinted,.sortedKeys]).write(to:url.deletingPathExtension().appendingPathExtension("json"))
    }
}
