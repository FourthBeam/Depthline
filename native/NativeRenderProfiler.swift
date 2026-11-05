import Foundation
import SceneKit
import Metal
import QuartzCore

/// Persistent private render targets; no NSImage creation, pixel readback or PNG
/// conversion inside the measurement. GPU timestamps distinguish CPU stalls.
enum NativeRenderProfiler {
    static func measure(scene:SCNScene,camera:SCNNode,size:CGSize,frames:Int=60,time:Double=0) throws -> [String:Any] {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {throw NSError(domain:"MetalProfile",code:1)}
        let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
        let samples=device.supportsTextureSampleCount(4) ? 4:1
        func texture(_ format:MTLPixelFormat,_ multisampled:Bool)->MTLTexture? {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:Int(size.width),height:Int(size.height),mipmapped:false)
            descriptor.storageMode = .private;descriptor.usage = [.renderTarget,.shaderRead]
            if multisampled {descriptor.textureType = .type2DMultisample;descriptor.sampleCount=samples}
            return device.makeTexture(descriptor:descriptor)
        }
        guard let color=texture(.bgra8Unorm_srgb,samples>1),let resolve=texture(.bgra8Unorm_srgb,false),let depth=texture(.depth32Float_stencil8,samples>1) else {throw NSError(domain:"MetalProfile",code:2)}
        let pass=MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=color;pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor=MTLClearColor(red:0,green:0,blue:0,alpha:1)
        if samples>1 {pass.colorAttachments[0].resolveTexture=resolve;pass.colorAttachments[0].storeAction = .multisampleResolve}
        else {pass.colorAttachments[0].storeAction = .store}
        pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .dontCare;pass.depthAttachment.clearDepth=1
        pass.stencilAttachment.texture=depth;pass.stencilAttachment.loadAction = .clear;pass.stencilAttachment.storeAction = .dontCare
        var gpu:[Double]=[],wall:[Double]=[]
        for index in 0..<frames+5 {
            try autoreleasepool {
                guard let buffer=queue.makeCommandBuffer() else {throw NSError(domain:"MetalProfile",code:3)}
                let begin=CACurrentMediaTime()
                renderer.render(atTime:time,viewport:CGRect(origin:.zero,size:size),commandBuffer:buffer,passDescriptor:pass)
                buffer.commit();buffer.waitUntilCompleted()
                guard buffer.status == .completed,buffer.gpuEndTime>buffer.gpuStartTime else {
                    throw buffer.error ?? NSError(domain:"MetalProfile",code:4)
                }
                if index>=5 {gpu.append((buffer.gpuEndTime-buffer.gpuStartTime)*1000);wall.append((CACurrentMediaTime()-begin)*1000)}
            }
        }
        func summary(_ values:[Double])->[String:Any] {
            let sorted=values.sorted();return ["medianMilliseconds":(sorted[(frames-1)/2]+sorted[frames/2])/2,"p95Milliseconds":sorted[Int(ceil(Double(frames)*0.95))-1],"samplesMilliseconds":values]
        }
        return ["device":device.name,"pixels":[Int(size.width),Int(size.height)],"samples":samples,"frames":frames,"warmupFrames":5,"gpu":summary(gpu),"encodeAndCompletionWall":summary(wall),"sceneTime":time,"simulation":"Static pose: no simulation ticks advance during these 60 measured frames.","scope":"Persistent private Metal render targets; GPU command-buffer start/end timestamps. No NSImage, readback, PNG, loading or HUD. Completion wall includes SceneKit encoding and GPU wait; not end-to-end interactive FPS."]
    }
}
