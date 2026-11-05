import AppKit
import SceneKit
import ImageIO
import UniformTypeIdentifiers

extension Game {
    /// Deliberate visual fixture, separate from campaign evidence: source terrain
    /// and production models, repeated still/jitter frames, falling supplies and
    /// explicit submerged/above-water occlusion probes.
    func validateGraphicsDynamics(output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let testScene = SCNScene(), eye = SCNNode(), ambient = SCNNode(), sun = SCNNode()
        eye.camera = SCNCamera(); eye.position = SCNVector3(0,8.2,0); eye.eulerAngles.x = -0.08
        let size = CGSize(width:1280,height:720)
        DepthlineCamera.configure(eye.camera!,gameID:assets.gameID,size:size)
        testScene.rootNode.addChildNode(eye)
        ambient.light=SCNLight();ambient.light?.type = .ambient;testScene.rootNode.addChildNode(ambient)
        sun.light=SCNLight();sun.light?.type = .directional;sun.eulerAngles=SCNVector3(-0.8,-0.6,0);testScene.rootNode.addChildNode(sun)
        for object in assets.objects {
            let name=object["name"] as? String ?? ""
            if name.hasPrefix("Terrain") || name=="SkyDay" || name=="SkyNight" {
                let node=assets.node(for:object)
                if name.hasPrefix("Sky") {assets.graphics.configureSky(node)}
                node.isHidden = name=="SkyNight"
                testScene.rootNode.addChildNode(node)
            }
        }
        assets.graphics.configureScene(testScene,camera:eye.camera!,sun:sun)
        assets.graphics.updateLighting(scene:testScene,ambient:ambient,sun:sun,preset:.day,inland:assets.gameID=="2002",camera:eye.camera!)
        let chutes = [assets.model(assets.gameID=="2000" ? "Parachute1":"Parachute"),
                      assets.model(assets.gameID=="2000" ? "Parachute2":"Parachute")]
        chutes[0].position=SCNVector3(-4,9,-24);chutes[1].position=SCNVector3(9,15,-70)
        for chute in chutes {testScene.rootNode.addChildNode(chute)}
        if assets.gameID=="2002" {
            for (i,chute) in chutes.enumerated() {
                let box=assets.model(i==0 ? "HealthBoxes":"AmmoBoxes");box.position=SCNVector3(0,-3,0);chute.addChildNode(box)
            }
        }
        let boat=assets.model("BARGE");boat.position=SCNVector3(0,0,-70);testScene.rootNode.addChildNode(boat)
        let renderer=SCNRenderer(device:view.device,options:nil);renderer.scene=testScene;renderer.pointOfView=eye
        func frame() throws -> CGImage {
            let image=renderer.snapshot(atTime:0,with:size,antialiasingMode:.multisampling4X)
            var rect=NSRect(origin:.zero,size:size)
            guard let cg=image.cgImage(forProposedRect:&rect,context:nil,hints:nil) else {throw NSError(domain:"GraphicsValidation",code:1)}
            return cg
        }
        func pixels(_ cg:CGImage)->Data {
            let rep=NSBitmapImageRep(cgImage:cg)
            return Data(bytes:rep.bitmapData!,count:rep.bytesPerRow*rep.pixelsHigh)
        }
        func png(_ cg:CGImage,_ name:String)throws {
            try NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name))
        }
        assets.graphics.update(time:2)
        for _ in 0..<3 {_=try frame()}
        let stable=try frame(); let reference=pixels(stable)
        var stableMatches=0
        for _ in 0..<12 {if pixels(try frame())==reference {stableMatches += 1}}
        guard stableMatches==12 else {throw NSError(domain:"GraphicsValidation",code:2,userInfo:[NSLocalizedDescriptionKey:"Static render changed between identical frames"])}
        try png(stable,"\(assets.gameID)-airdrop-still.png")
        let gifURL=output.appendingPathComponent("\(assets.gameID)-shore-airdrop-motion.gif")
        guard let gif=CGImageDestinationCreateWithURL(gifURL as CFURL,UTType.gif.identifier as CFString,36,nil) else {throw NSError(domain:"GraphicsValidation",code:3)}
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for i in 0..<36 {
            eye.eulerAngles.y=CGFloat(sin(Double(i)*Double.pi/18)*0.018)
            chutes[0].position.y=9-CGFloat(i)*0.10;chutes[1].position.y=15-CGFloat(i)*0.12
            chutes[0].eulerAngles.y=CGFloat(i)*0.008;chutes[1].eulerAngles.y = -CGFloat(i)*0.012
            assets.graphics.update(time:2+Double(i)/12)
            let cg=try frame()
            if [0,12,24,35].contains(i) {try png(cg,"\(assets.gameID)-motion-\(i).png")}
            CGImageDestinationAddImage(gif,cg,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/12]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(gif) else {throw NSError(domain:"GraphicsValidation",code:4)}
        var submergedPixels: Int? = nil, abovePixels: Int? = nil
        if assets.gameID=="2000" {
            eye.eulerAngles=SCNVector3(-0.08,0,0)
            let marker=SCNNode(geometry:SCNBox(width:2,height:1,length:2,chamferRadius:0))
            let mat=SCNMaterial();mat.lightingModel = .constant;mat.diffuse.contents=NSColor(srgbRed:1,green:0,blue:1,alpha:1)
            marker.geometry?.materials=[mat];marker.position=SCNVector3(7,0.7,-70);testScene.rootNode.addChildNode(marker)
            func magenta(_ cg:CGImage)->Int {
                // SceneKit HDR snapshots may carry linear float pixels. Convert
                // explicitly to sRGB8, matching the PNG evidence, before using
                // fixed color thresholds; deviceRGB is display-dependent.
                var rgba=[UInt8](repeating:0,count:cg.width*cg.height*4)
                rgba.withUnsafeMutableBytes { bytes in
                    let context=CGContext(data:bytes.baseAddress,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                    context.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
                }
                var count=0
                for i in stride(from:0,to:rgba.count,by:4) {
                    let r=Int(rgba[i]),g=Int(rgba[i+1]),b=Int(rgba[i+2])
                    if r>127,b>127,g<51,r>g*3,b>g*3 {count += 1}
                }
                return count
            }
            let above=try frame();abovePixels=magenta(above);try png(above,"2000-water-marker-above.png")
            marker.position.y = -0.8
            let below=try frame();submergedPixels=magenta(below);try png(below,"2000-water-marker-submerged.png")
            guard abovePixels!>20,submergedPixels!<max(4,abovePixels!/100) else {
                throw NSError(domain:"GraphicsValidation",code:5,userInfo:[NSLocalizedDescriptionKey:"Water failed submerged-object occlusion: \(abovePixels!)/\(submergedPixels!) pixels"])
            }
        }
        let report:[String:Any]=["game":assets.gameID,"scope":"Synthetic visual fixture using production terrain/models; no campaign fidelity claim", "renderPixels":[1280,720],"identicalFrameMatches":stableMatches,"motionFrames":36,"motionSeconds":3,"nearSupplyDistance":24,"farSupplyDistance":70,"aboveWaterMarkerPixels":abovePixels as Any,"submergedMarkerPixels":submergedPixels as Any,"markerColorReadback":"explicit sRGB8 RGBA; R/B>127,G<51,R/B>3G; fixed above/submerged samex7,z-70", "seaLevelDatumMetres":0.0,"waterSurface":"Two wind swells, a shoaling breaker and signed-distance run-up around the heightfield zero contour.","duplicateSourceTrianglesRemoved":true]
        var serial=report; if abovePixels==nil {serial.removeValue(forKey:"aboveWaterMarkerPixels");serial.removeValue(forKey:"submergedMarkerPixels")}
        try JSONSerialization.data(withJSONObject:serial,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("\(assets.gameID)-validation.json"))
        print("PASS graphics \(assets.gameID): 12 identical still frames, 36 moving shoreline/near-far supply frames, water occlusion \(abovePixels ?? -1)/\(submergedPixels ?? -1)")
    }
}
