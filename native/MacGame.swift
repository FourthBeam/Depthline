import AppKit
import SceneKit
import QuartzCore

// Depthline packages independently generated environments, missions and sound.
// Existing simulation modules retain their internal compatibility identifiers.
// Historical extracted resources are excluded by the packaging allowlist.
let arguments = CommandLine.arguments
let selectedGameID: String = {
    if let i = arguments.firstIndex(of: "--game"), i + 1 < arguments.count,
       ["2000", "2002", DepthlineIdentity.trainingID].contains(arguments[i+1]) { return arguments[i+1] }
    return "2002"
}()
func gameResourceRoot(_ gameID: String) -> URL {
    if let i = arguments.firstIndex(of: "--assets"), i + 1 < arguments.count {
        return URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
    }
    return Bundle.main.resourceURL!.appendingPathComponent(gameID == "2002" ? "field-interior" : "field-coast")
}
let resourceRoot = gameResourceRoot(selectedGameID)

func arrayD(_ value: Any?) -> [Double] { (value as? [NSNumber] ?? []).map { $0.doubleValue } }
func vector(_ a: [Double], scale: Double = 1) -> SCNVector3 {
    SCNVector3(a.count > 0 ? a[0] * scale : 0, a.count > 1 ? a[1] * scale : 0, a.count > 2 ? a[2] * scale : 0)
}
func length(_ p: SCNVector3) -> CGFloat { let n:CGFloat = p.x*p.x + p.y*p.y + p.z*p.z; return sqrt(n) }

struct Wave {
    let type: String
    let declaredDelay: Double
    let time: Double
    var direction: String? = nil
    var slot: Int = 0
    var cargoFamily: String? = nil
}
struct Combat {
    var health = 100, score = 0, shots = 0, hits = 0
}

final class Assets {
    /// Metre samples baked by the same generator as the terrain and heightmap.
    struct Shoreline {
        let heights: [Double], originX: Double, spacing: Double
        init?(_ field: [String:Any]?) {
            guard let field, let x=field["originX"] as? Double, let step=field["spacing"] as? Double,
                  step>0 else {return nil}
            heights=arrayD(field["z"]); guard heights.count>=2 else {return nil}
            originX=x;spacing=step
        }
        func z(at x: Double) -> Double {
            let sample=max(0,min(Double(heights.count-1),(x-originX)/spacing))
            let i=min(Int(sample),heights.count-2)
            return heights[i]+(heights[i+1]-heights[i])*(sample-Double(i))
        }
        func coordinates(x: Double, z: Double) -> [Float] {
            let slope=(self.z(at:x+spacing)-self.z(at:x-spacing))/(2*spacing)
            return [Float((z-self.z(at:x))/hypot(1,slope)),Float(slope)]
        }
    }
    let root: URL
    let graphics: NativeGraphics
    let gameID: String
    let isDepthline: Bool
    let objects: [[String: Any]]
    let levels: [[String: Any]]
    let textures: [Int: URL]
    let heightData: [UInt8]
    let materialData: [UInt8]
    let shoreline: Shoreline?
    let heightWidth: Int, heightHeight: Int
    let heightOriginX: CGFloat, heightOriginZ: CGFloat, heightSpacing: CGFloat, heightScale: CGFloat
    let collision: OriginalCollision
    let animations: [[String:Any]]
    var materialCache: [Int: SCNMaterial] = [:]
    var templates: [String: SCNNode] = [:]
    var frameCache: [String:NSImage] = [:]
    func frameImage(_ path:String)->NSImage? {
        if let cached=frameCache[path] {return cached}
        let image=NSImage(contentsOf:root.appendingPathComponent(path));frameCache[path]=image;return image
    }
    init(root: URL, graphics: NativeGraphics = NativeGraphics()) throws {
        self.root = root
        self.graphics = graphics
        let scene = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("scene.json"))) as! [String: Any]
        gameID = scene["gameID"] as? String ?? "2002"
        isDepthline = scene["product"] as? String == "depthline"
        shoreline = Shoreline(scene["shoreline"] as? [String:Any])
        collision = try OriginalCollision(root:root,gameID:gameID)
        animations = scene["animations"] as? [[String:Any]] ?? []
        let map = scene["heightmap"] as? [String:Any] ?? [:]
        heightWidth = map["width"] as? Int ?? 1501; heightHeight = map["height"] as? Int ?? 1501
        heightOriginX = CGFloat((map["originX"] as? NSNumber)?.doubleValue ?? -15000)
        heightOriginZ = CGFloat((map["originZ"] as? NSNumber)?.doubleValue ?? -15000)
        heightSpacing = CGFloat((map["spacing"] as? NSNumber)?.doubleValue ?? 20)
        heightScale = CGFloat((map["heightScale"] as? NSNumber)?.doubleValue ?? 8)
        heightData = Array(try Data(contentsOf: root.appendingPathComponent(map["file"] as? String ?? "HMap1501x1501.hmap")))
        materialData = (try? Data(contentsOf:root.appendingPathComponent("MMap1501x1501.mmap"))).map {Array($0)} ?? []
        objects = scene["objects"] as? [[String: Any]] ?? []
        let levelData = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("levels.json")))
        let decodedLevels = (levelData as? [[String: Any]]) ?? ((levelData as? [String: Any])?["levels"] as? [[String: Any]] ?? [])
        levels = gameID == "2000" ? decodedLevels.filter { ($0["number"] as? Int ?? 0) > 0 } : decodedLevels
        textures = Dictionary(uniqueKeysWithValues: (scene["textures"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? Int, let file = item["file"] as? String else { return nil }
            return (id, root.appendingPathComponent(file))
        })
        guard !objects.isEmpty, !levels.isEmpty, heightData.count == heightWidth*heightHeight else { throw NSError(domain: "Assets", code: 1, userInfo: [NSLocalizedDescriptionKey: DLoc.text("战区资源不完整", "Sector resources are incomplete.")]) }
    }
    func height(x: CGFloat, z: CGFloat) -> CGFloat {
        let cx=max(0,min(CGFloat(heightWidth-1),(x*100-heightOriginX)/heightSpacing))
        let cz=max(0,min(CGFloat(heightHeight-1),(z*100-heightOriginZ)/heightSpacing))
        let x0=Int(cx), z0=Int(cz), x1=min(x0+1,heightWidth-1), z1=min(z0+1,heightHeight-1)
        let fx=cx-CGFloat(x0), fz=cz-CGFloat(z0)
        let a=CGFloat(heightData[z0*heightWidth+x0])*(1-fx)+CGFloat(heightData[z0*heightWidth+x1])*fx
        let b=CGFloat(heightData[z1*heightWidth+x0])*(1-fx)+CGFloat(heightData[z1*heightWidth+x1])*fx
        return (a*(1-fz)+b*fz)*heightScale*0.01
    }
    func terrainMaterial(sourceX:Double,sourceZ:Double)->UInt8 {
        guard materialData.count==heightWidth*heightHeight else {return 0}
        let col=max(0,min(heightWidth-1,Int((sourceX-Double(heightOriginX))/Double(heightSpacing))))
        let row=max(0,min(heightHeight-1,Int((sourceZ-Double(heightOriginZ))/Double(heightSpacing))))
        return materialData[row*heightWidth+col]
    }
    /// Ballistic adapters use centimetres; the generated shoreline uses metres.
    var waterContact: ((Double,Double)->Bool)? {
        shoreline.map { field in { x,z in z*0.01 < field.z(at:x*0.01) } }
    }
    func pointHeight(x:CGFloat,z:CGFloat)->CGFloat {
        let col=max(0,min(heightWidth-1,Int((x*100-heightOriginX)/heightSpacing)))
        let row=max(0,min(heightHeight-1,Int((z*100-heightOriginZ)/heightSpacing)))
        return CGFloat(heightData[row*heightWidth+col])*heightScale*0.01
    }
    func material(texture: Int?, color: [Double], reflected:Bool=false) -> SCNMaterial {
        let key=texture.map {reflected ? -$0-1:$0}
        if let key, let cached = materialCache[key] { return cached }
        let m = SCNMaterial()
        m.isDoubleSided = true
        m.lightingModel = .lambert
        m.diffuse.contents = NSColor(calibratedRed: color.count > 0 ? color[0] : 0.7, green: color.count > 1 ? color[1] : 0.7, blue: color.count > 2 ? color[2] : 0.7, alpha: 1)
        if let id = texture, let url = textures[id], let image = NSImage(contentsOf: url) {
            if reflected {
                OriginalScenePresentation.configureReflection(m,image:image,gameID:gameID)
            } else {
                m.diffuse.contents=image
                m.diffuse.wrapS = .repeat;m.diffuse.wrapT = .repeat
                m.diffuse.magnificationFilter = .linear
                OriginalScenePresentation.configureMeshTexture(m)
            }
            if let key {materialCache[key] = m}
        }
        if !reflected {m.specular.contents = NSColor(calibratedWhite: 0.06, alpha: 1)}
        graphics.configure(material:m,sourceURL:texture.flatMap {textures[$0]},reflected:reflected)
        return m
    }
    func node(for object: [String: Any], transform: Bool = true) -> SCNNode {
        let node = SCNNode(); node.name = object["name"] as? String
        if transform { node.position = vector(arrayD(object["translation"]), scale: 0.01) }
        var source=object,seen=Set<Int>()
        while let id=source["instance"] as? Int,!seen.contains(id),let inherited=objects.first(where:{$0["id"] as? Int == id}) {
            seen.insert(id);source=inherited
        }
        var seenTriangles = Set<NativeMeshSanitizer.Triangle>()
        for group in source["groups"] as? [[String: Any]] ?? [] {
            let vertices = arrayD(group["vertices"]).map { Float($0 * 0.01) }
            let sourceNormals = arrayD(group["normals"]).map { Float($0) }
            let normals = graphics.isRemastered && group["polyType"] as? String == "Reflected"
                ? NativeGraphics.smoothMetalNormals(vertices:vertices,normals:sourceNormals) : sourceNormals
            let uvs = arrayD(group["uvs"]).map { Float($0) }
            let indices = NativeMeshSanitizer.uniqueTriangles(vertices:vertices,indices:(group["indices"] as? [Int] ?? []).map {UInt32($0)},seen:&seenTriangles)
            guard vertices.count >= 9, !indices.isEmpty else { continue }
            func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic, _ components: Int) -> SCNGeometrySource {
                let data = values.withUnsafeBytes { Data($0) }
                return SCNGeometrySource(data: data, semantic: semantic, vectorCount: values.count / components, usesFloatComponents: true, componentsPerVector: components, bytesPerComponent: 4, dataOffset: 0, dataStride: 4 * components)
            }
            var sources = [source(vertices, .vertex, 3)]
            if normals.count == vertices.count { sources.append(source(normals, .normal, 3)) }
            if uvs.count == vertices.count / 3 * 2 { sources.append(source(uvs, .texcoord, 2)) }
            if let textureID=group["texture"] as? Int, let filename=textures[textureID]?.lastPathComponent.lowercased(),
               filename.hasPrefix("terrain") || filename.hasPrefix("ocean") {
                var coordinates=[Float]();coordinates.reserveCapacity(vertices.count/3*2)
                for i in stride(from:0,to:vertices.count,by:3) {
                    coordinates.append(contentsOf:shoreline?.coordinates(x:Double(vertices[i]),z:Double(vertices[i+2])) ?? [10000,0])
                }
                sources.append(source(coordinates,.texcoord,2))
            }
            let indexData = indices.withUnsafeBytes { Data($0) }
            let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: indices.count / 3, bytesPerIndex: 4)
            let geometry = SCNGeometry(sources: sources, elements: [element])
            let polyType=group["polyType"] as? String ?? ""
            let texture = polyType.contains("Textured") || polyType == "Reflected" ? group["texture"] as? Int : nil
            geometry.materials = [material(texture: texture, color: arrayD(group["color"]),reflected:polyType=="Reflected")]
            node.addChildNode(SCNNode(geometry: geometry))
        }
        return node
    }
    func model(_ requested: String) -> SCNNode {
        if requested.uppercased() == "INFANTRY" { return RemasteredInfantryNode(gameID:gameID) }
        let name: String
        switch requested.uppercased() {
        case "APC", "APC1", "APC2", "APC3": name = "APC"
        case "TANK": name = "Tank1"
        case "COBRA": name = "Cobra1"
        case "JET": name = "Jet"
        case "CH53": name = "CH53"
        case "C130": name = "C130"
        case "BOMBER": name = "Bomber"
        case "BARGE": name = "Barge"
        case "BARGE_VEHICLE": name = "BargeVehicle"
        default: name = requested
        }
        let cacheKey=requested.uppercased()
        if let existing = templates[cacheKey] { return existing.clone() }
        let variantID=gameID=="2002" ? ["APC2":77,"APC3":81][cacheKey]:nil
        let object = variantID.flatMap { id in objects.first {$0["id"] as? Int == id} } ?? objects.first { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame && !(($0["groups"] as? [Any]) ?? []).isEmpty }
            ?? objects.first { ($0["name"] as? String)?.lowercased().hasPrefix(name.lowercased()) == true && !(($0["groups"] as? [Any]) ?? []).isEmpty }
        let node = object.map { self.node(for: $0, transform: false) } ?? SCNNode(geometry: SCNSphere(radius: 1))
        // Preserve nested original links (e.g. tank -> turret -> gun), with a
        // path guard so malformed resource links cannot recurse forever.
        if let id = object?["id"] as? Int {
            func attach(to parent: SCNNode, id: Int, visited: Set<Int>) {
                for child in objects {
                    guard let childID = child["id"] as? Int, let link = child["link"] as? Int,
                          link == id, !visited.contains(childID) else { continue }
                    let piece = self.node(for: child)
                    parent.addChildNode(piece)
                    attach(to: piece, id: childID, visited: visited.union([childID]))
                }
            }
            attach(to: node, id: id, visited: [id])
        }
        RemasteredVehicles.apply(to:node,type:cacheKey,gameID:gameID)
        RemasteredAircraft.apply(to:node,type:cacheKey,gameID:gameID)
        RemasteredSupplies.apply(to:node,type:cacheKey,gameID:gameID)
        if RemasteredOrdnanceModels.apply(to:node,type:cacheKey,gameID:gameID)>0 {node.geometry=nil}
        templates[cacheKey] = node
        return node.clone()
    }
    func waves(level: Int) -> [Wave] {
        let l = levels[min(level, levels.count - 1)]
        let raw = l["objects"] as? [[String: Any]] ?? []
        var entries: [(String, Double, Int, String?, Int, String?)] = []
        for (index, item) in raw.enumerated() {
            if (item["visible"] as? Int) == 0 { continue }
            let rawType = (item["type"] as? String ?? "APC1").uppercased()
            let type = ["HELICOPTER1":"COBRA", "HELICOPTER2":"CH53", "APC":"APC1"][rawType] ?? rawType
            let delay = (item["delay"] as? NSNumber)?.doubleValue ?? (gameID == "2000" ? 0 : Double(index * 20))
            entries.append((type, delay, index, item["direction"] as? String, item["slot"] as? Int ?? index, item["cargoFamily"] as? String))
        }
        entries.sort { left, right in
            if left.1 == right.1 { return left.2 < right.2 }
            return left.1 < right.1
        }
        // Kept as a sorted declaration view for camera selection and diagnostics.
        // OriginalCampaign owns activation, recurrence and force accounting.
        var result: [Wave] = []
        for item in entries {
            let time: Double = item.1 * Game.logicalStep
            result.append(Wave(type: item.0, declaredDelay: item.1, time: time, direction: item.3, slot:item.4, cargoFamily:item.5))
        }
        return result
    }
}

final class Enemy {
    let id = UUID().uuidString
    let node: SCNNode
    let type: String
    let flying: Bool
    var hp: Int
    var age: Double = 0
    var lastAttack: Double = 0
    let motion: EnemyPath?
    var unloaded = false
    var cargoFamily: String?
    var required = true
    var sourceIndex = -1
    var slot = 0
    var force: Double = 0
    var aiState: Int = 1
    var originalAI: OriginalEnemyAI?
    var infantryAI:Original2002InfantryAI?
    weak var boardingAPC: Enemy?
    var aggregateBoatSlot:Int?
    var aggregateSoldierSlot:Int?
    var aggregateVehicleID:Int?
    var aggregateAircraftID:Int?
    var spritePath = ""
    var thrownVelocity=SIMD3<Double>.zero
    var thrownSpin=0.0
    var deferredDeath: OriginalDeferredDeath?
    var deathMode = OriginalDeathMode.none
    init(node: SCNNode, type: String, flying: Bool, motion: EnemyPath? = nil) {
        self.node = node; self.type = type; self.flying = flying; hp = flying ? 3 : 6
        self.motion = motion
        if type == "INFANTRY" { hp = 1 }
        if type == "BARGE" { hp = 24 }
        node.name = "enemy:" + id
    }
    func updateMotion(assets: Assets) {
        guard let motion else { return }
        node.position = motion.position(age: age, ground: assets.height)
        node.eulerAngles = motion.orientation(age: age)
        node.enumerateChildNodes { child, _ in
            let name = child.name ?? ""
            // Rotor increments recovered from original object AI: Cobra 55°,
            // CH53 25°, tail rotor -40° per original update.
            if name.contains("Rotor") {
                let degrees = self.type == "CH53" ? 25.0 : 55.0
                child.eulerAngles.y = CGFloat((self.age / EnemyMotion.originalStep * degrees).truncatingRemainder(dividingBy: 360) * .pi / 180)
            } else if name.contains("Prop") {
                let angle = CGFloat((self.age / EnemyMotion.originalStep * -40).truncatingRemainder(dividingBy: 360) * .pi / 180)
                if self.type == "C130" { child.eulerAngles.z = angle } else { child.eulerAngles.x = angle }
            }
        }
    }
}

final class GameView: SCNView {
    let mouseCapture: MouseCaptureController
    private let captureContext: (NSView) -> (inside: Bool, active: Bool)
    init(frame: NSRect, cursorBackend: CursorCaptureBackend) {
        mouseCapture = MouseCaptureController(backend: cursorBackend)
        captureContext = cursorBackend.captureContext(in:)
        super.init(frame: frame, options: nil)
    }
    required init?(coder: NSCoder) { fatalError("GameView is created by Game") }
    weak var game: Game? {
        didSet {
            mouseCapture.onChange = { [weak self] captured in
                InteractiveInputTrace.record("capture-changed", ["captured": captured])
                self?.game?.shooting = false
                self?.game?.input.resetCursor()
                self?.game?.hud.mouseCaptured = captured
                self?.game?.training?.noteMouseCapture(captured)
                self?.game?.hud.needsDisplay = true
                self?.game?.refreshBattleOverlays()
            }
        }
    }
    override var acceptsFirstResponder: Bool { true }
    override func setFrameSize(_ newSize:NSSize) {
        super.setFrameSize(newSize)
        if let game,let camera=game.camera.camera {
            DepthlineCamera.configure(camera,gameID:game.assets.gameID,size:bounds.size)
        }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let game {game.assets.graphics.configure(view:self,hud:game.hud)}
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let game {game.assets.graphics.configure(view:self,hud:game.hud); game.refreshBattleOverlays()}
    }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseMoved,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil))
        super.updateTrackingAreas()
    }
    override func mouseMoved(with event:NSEvent) { game?.aim(event) }
    override func mouseDragged(with event:NSEvent) { game?.aim(event) }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        guard let game, game.acceptsBattleInput else { return }
        guard mouseCapture.isCaptured else { game.captureForPlayIfFullscreen(); return }
        game.shooting=true
    }
    override func mouseUp(with event:NSEvent) { game?.shooting=false }
    override func cancelOperation(_ sender: Any?) {
        guard let game else { return }
        if let training = game.training, training.guideOpen { training.toggleGuide(in:game) }
        else { game.togglePause() }
    }
    override func keyDown(with event:NSEvent) {
        InteractiveInputTrace.record("key-down", ["code": event.keyCode, "flags": event.modifierFlags.rawValue, "repeat": event.isARepeat])
        if event.keyCode == 37 && event.modifierFlags.contains(.command) { game?.onReturnToLauncher?(); return }
        if let game, game.isShowingVictoryChoice {
            if [36, 76].contains(event.keyCode), !event.isARepeat {
                game.continueAfterVictoryChoice()
            } else if event.keyCode == 48 {
                if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
                else { window?.selectNextKeyView(self) }
            }
            return
        }
        if game?.training?.guideOpen == true && game?.handleTrainingKey(event) == true { return }
        if event.keyCode == 15 && event.modifierFlags.contains(.command) { if !event.isARepeat {game?.restart()}; return }
        if [53,35].contains(event.keyCode) { if !event.isARepeat {game?.togglePause()}; return }
        guard game?.paused != true else { return }
        if game?.handleTrainingKey(event) == true { return }
        if isMouseCaptureShortcut(keyCode: event.keyCode, flags: event.modifierFlags) {
            if !event.isARepeat { toggleMouseCapture() }
            return
        }
        switch event.keyCode {
        case 49: if !event.isARepeat { game?.weapons.cycleWeapon() }
        case 5: if !event.isARepeat { game?.weapons.pressHandgunKey() }
        case 46: if !event.isARepeat { game?.launchMissile() }
        case 3: if !event.isARepeat { game?.launchFlare() }
        case 0: if !event.isARepeat,game?.assets.gameID=="2000" {game?.requestSupport()}
        case 11: if !event.isARepeat && game?.assets.gameID=="2002" {game?.requestSupport()}
        case 15,34: if !event.isARepeat {game?.changeSetting(.invertY)}
        case 1: if !event.isARepeat {game?.changeSetting(.sound)}
        case 24: if !event.isARepeat {if game?.assets.gameID=="2000" {game?.changeSetting(.sensitivityUp)} else {game?.applyCheat(3)}}
        case 27: if !event.isARepeat && game?.assets.gameID=="2000" {game?.changeSetting(.sensitivityDown)}
        case 18: if !event.isARepeat {game?.applyCheat(1)}
        case 19: if !event.isARepeat {game?.applyCheat(2)}
        default: super.keyDown(with:event)
        }
    }
    func containsScreenPoint(_ screenPoint: NSPoint) -> Bool {
        guard let window = window else { return false }
        return visibleRect.contains(convert(window.convertPoint(fromScreen: screenPoint), from: nil))
    }
    func toggleMouseCapture(requirePointerInside: Bool = true) {
        guard let window = window else { mouseCapture.release(); return }
        if mouseCapture.isCaptured { mouseCapture.release(); return }
        guard game?.acceptsBattleInput == true else { return }
        let context = captureContext(self)
        let centerInWindow = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        let screenCenter = window.convertPoint(toScreen: centerInWindow)
        let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        InteractiveInputTrace.record("capture-request", ["captured": mouseCapture.isCaptured,
            "pointer": NSStringFromPoint(NSEvent.mouseLocation), "inside": containsScreenPoint(NSEvent.mouseLocation),
            "localPointer": NSStringFromPoint(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)),
            "visibleRect": NSStringFromRect(visibleRect), "keyWindow": window.isKeyWindow, "active": NSApp.isActive])
        mouseCapture.toggle(pointerInside: !requirePointerInside || context.inside, windowActive: context.active,
                            anchor: quartzCursorPoint(screenCenter, primaryTop: top))
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { mouseCapture.release() }
        super.viewWillMove(toWindow: newWindow)
    }
}

final class Game {
    let training: DepthlineTraining?
    lazy var flightTerrain: DepthlineFlightTerrain? = assets.isDepthline ? DepthlineFlightTerrain(scene: scene) : nil
    let assets:Assets
    let view:GameView
    let hud:OriginalHUD
    let entryPrompt = DepthlineEntryPrompt()
    lazy var pauseMenu = DepthlinePauseMenu(game:self)
    lazy var victoryMenu = DepthlineVictoryMenu(frame: view.bounds, onNext: { [weak self] in
        self?.continueAfterVictoryChoice()
    }, onLauncher: { [weak self] in
        self?.onReturnToLauncher?()
    })
    private var resumeWithCapture = false
    let scene:SCNScene
    let fragments:OriginalFragments
    let camera=SCNNode()
    let gun=SCNNode()
    lazy var gunCarriage=DepthlineGunCarriage(scene:scene,floor:assets.height(x:0,z:0))
    lazy var weaponPresentation:GameWeaponPresentation = {
        let result=GameWeaponPresentation(version:version,objects:assets.objects,parent:gun,makeNode:{self.assets.node(for:$0)})
        RemasteredWeapons.apply(to:result,enabled:true)
        OriginalWeaponCompletion.apply(to:result,remastered:true)
        RemasteredArsenal.apply(to:result)
        gun.categoryBitMask=2
        gun.enumerateChildNodes {node,_ in node.categoryBitMask=2}
        return result
    }()
    let ambient=SCNNode(),sun=SCNNode(),spotlight=SCNNode()
    let muzzleLamp=SCNNode()
    private var muzzlePulse:(action:OriginalFireAction,token:OriginalEffectsRenderer.Token)?
    private(set) var visualLight = DepthlineLight.day
    var night=false
    var flares=OriginalFlares()
    var flareNodes:[SCNNode]=[]
    lazy var bulletEffects = BulletEffects(textureURL: assets.root.appendingPathComponent("textures/Glow.png"))
    lazy var projectiles = OriginalProjectiles(version:assets.gameID == "2000" ? .beach2000 : .beach2002,
        textureURL:assets.root.appendingPathComponent("textures/Glow.png"),parent:scene.rootNode)
    lazy var enemyOrdnance=EnemyOrdnanceRenderer(root:scene.rootNode,texture:assets.root.appendingPathComponent("textures/Glow.png"),sharedPools:projectiles.sharedPools,effects:effects)
    lazy var effects=OriginalEffectsRenderer(resourceRoot:assets.root,parent:scene.rootNode,version:version,ground:assets.height)
    lazy var input=OriginalInputModel(gameID:assets.gameID)
    lazy var sound=OriginalSoundRenderer(gameID:assets.gameID,soundDirectory:assets.root.appendingPathComponent("sounds"))
    lazy var burning=OriginalBurning(gameID:assets.gameID)
    var burningTokens:[Int:OriginalEffectsRenderer.Token]=[:]
    var levelStartScore=0
    var usedCheats = false
    var isInvulnerable = false
    var onSettingsChanged:((CampaignStore.Settings)->Void)?
    var bombers:[Original2002BomberAI]=[]
    var bomberHeading=0.0
    var bomberSources:[Int:Int]=[:]
    var combat=Combat() {
        didSet {
            if combat.health < oldValue.health {
                if isInvulnerable { combat.health = oldValue.health }
                else { hud.damageFlash = 1 }
            }
        }
    }
    var weapons: OriginalWeaponState
    var settings = CampaignStore.Settings()
    var onCheckpoint: ((Int, Int) -> Void)?
    var onRunEnded: ((Int, Int, UUID) -> Void)?
    var onSectorCompleted: (() -> Void)?
    private(set) var pendingNextLevel: Int?
    var runID = UUID()
    var resultRecorded = false
    // 29 ms is a deliberate Mac pacing policy derived from the 2002 limiter,
    // not a claim that every original PC or the 2000 binary ran at this rate.
    static let logicalStep = 0.029
    var logicalAccumulator = 0.0
    var logicalTick = 0
    var originalClock = OriginalTickClock()
    var globalAITick: Int { originalClock.ticks }
    var pendingEnemyEmitters: [OriginalEnemyAI] = []
    var pendingBomberDrops: [Original2002BomberAI.Update] = []
    var infantryLandedThisTick = Set<Int>()
    var supply2000: Beach2000Supply?
    var supply2002: Beach2002Supply?
    var supplyNodes: [Int:SCNNode] = [:]
    var nextTrooperOrdinal = 0
    var pendingEnemyShots:[OriginalEnemyAI.Shot]=[]
    var pendingGrenades:[Original2000EnemyAI.Shot]=[]
    var pendingOrdnance:[(OriginalEnemyOrdnanceState,String?,Int?)]=[]
    var barrage:Original2000BarrageState?
    var pendingBomberSupport=false
    var original2000AI:Original2000EnemyAI?
    var aircraft2000:Original2000AircraftAI?
    var random = Beach2000Supply.Random(seed:UInt32.random(in:1...UInt32.max))
    var campaign: OriginalCampaign?
    var inputLocked = false
    private var collectedSupply: Beach2002Supply.PayloadKind?
    var supplyMessage: String {
        if finished && levelDefinition == nil { return DLoc.text("战区任务未找到，无法继续加载", "This sector's mission could not be loaded.") }
        switch collectedSupply {
        case .defense: return DLoc.text("已领取防御补给", "Defence supplies collected")
        case .machineGun: return DLoc.text("已领取机枪弹药", "Machine gun ammo collected")
        case .cannon: return DLoc.text("已领取炮弹补给", "Cannon shells collected")
        case .missile: return DLoc.text("已领取导弹补给", "Missiles collected")
        case .trooper: return DLoc.text("已领取伞兵", "Paratrooper collected")
        case nil: return ""
        }
    }
    var supplyMessageUntil = 0.0
    var enemies:[Enemy]=[]
    var waves:[Wave]=[]
    var spawned=0, level=0
    var elapsed:Double=0, lastFire:Double = -10, previousTime:Double=0
    var shooting=false, paused=false
    var timer:Timer?
    var finished=false
    var onReturnToLauncher: (() -> Void)?
    var onOpenPauseSettings: (() -> Void)?
    var onEnterCoast: (() -> Void)?
    init(assets:Assets,frame:NSRect,trainingMode:Bool = false,cursorBackend:CursorCaptureBackend = SystemCursorBackend()) throws {
        training = trainingMode ? DepthlineTraining() : nil
        let scene=SCNScene();self.scene=scene
        fragments=try OriginalFragments(resourceRoot:assets.root,version:assets.gameID=="2000" ? .beach2000:.beach2002,
            parent:scene.rootNode,makeNode:{assets.node(for:$0)})
        self.assets=assets;view=GameView(frame:frame,cursorBackend:cursorBackend);hud=OriginalHUD(frame:frame,gameID:assets.gameID,resourceRoot:assets.root)
        weapons=OriginalWeaponState(version:assets.gameID == "2000" ? .beach2000 : .beach2002,machineGunAmmo:0,cannonAmmo:0,missileAmmo:0)
        view.game=self;view.scene=scene;view.backgroundColor=NSColor(calibratedRed:0.45,green:0.65,blue:0.78,alpha:1)
        assets.graphics.configure(view:view,hud:hud)
        view.preferredFramesPerSecond=60;view.rendersContinuously=true
        view.autoresizingMask=[.width,.height];hud.autoresizingMask=[.width,.height]
        view.addSubview(hud)
        entryPrompt.attach(to:view)
        view.addSubview(pauseMenu)
        view.addSubview(victoryMenu)
        camera.camera=SCNCamera()
        DepthlineCamera.configure(camera.camera!,gameID:assets.gameID,size:view.bounds.size)
        // BH2000 0x4160f6 camera translation is float0x444d0000 =820;
        // weapon mounts are at800. Keep the eye above the mount.
        camera.position=SCNVector3(0,8.2,0)
        scene.rootNode.addChildNode(camera);view.pointOfView=camera
        ambient.light=SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity=650;ambient.light?.color=NSColor(calibratedRed:0.76,green:0.82,blue:0.9,alpha:1);scene.rootNode.addChildNode(ambient)
        sun.light=SCNLight();sun.light?.type = .directional;sun.light?.intensity=900;sun.eulerAngles=SCNVector3(-0.8,-0.6,0);scene.rootNode.addChildNode(sun)
        spotlight.light=SCNLight();spotlight.light?.type = .spot;spotlight.light?.intensity=1200
        spotlight.light?.categoryBitMask=1
        // Keep the forward searchlight beyond every first-person weapon. The
        // Metal PBR path still lit category-2 meshes in an actual render probe,
        // so category masks alone cannot prevent near-field gun overexposure.
        spotlight.position=SCNVector3(0,0,-4)
        spotlight.light?.spotInnerAngle=4;spotlight.light?.spotOuterAngle=38
        spotlight.light?.attenuationStartDistance=12;spotlight.light?.attenuationEndDistance=205
        spotlight.light?.color=NSColor(srgbRed:0.87,green:0.90,blue:1,alpha:1)
        camera.addChildNode(spotlight)
        let light=SCNLight();light.type = .omni;light.intensity=0
        light.color=NSColor(srgbRed:1,green:0.66,blue:0.36,alpha:1)
        light.attenuationStartDistance=0.12;light.attenuationEndDistance=2.65
        light.attenuationFalloffExponent=2;light.castsShadow=false
        muzzleLamp.name="DepthlineMuzzleLight";muzzleLamp.light=light;muzzleLamp.isHidden=true
        scene.rootNode.addChildNode(muzzleLamp)
        for object in assets.objects {
            let name=object["name"] as? String ?? ""
            if name.hasPrefix("Terrain") || name == "SkyDay" || name == "SkyNight" {
                let node=assets.node(for:object)
                if name.hasPrefix("Sky") {assets.graphics.configureSky(node)}
                scene.rootNode.addChildNode(node)
            }
        }
        assets.graphics.configureScene(scene,camera:camera.camera!,sun:sun)
        DepthlineEnvironment.install(in:scene,gameID:assets.gameID,
            shoreline:assets.shoreline.map { field in { x in Float(field.z(at:Double(x))) } },ground:assets.height)
        if assets.isDepthline && assets.gameID == "2002" { DepthlineHills.install(in:scene,ground:assets.height) }
        // Original weapon mount is world Y800, eye Y820. Pitch does not rotate
        // the 20-unit vertical separation around the camera.
        gun.position=SCNVector3(0,8,0);scene.rootNode.addChildNode(gun)
        restart()
        previousTime=CACurrentMediaTime()
        timer=Timer.scheduledTimer(withTimeInterval:1.0/60.0,repeats:true) { [weak self] _ in self?.tick() }
    }
    func stop() {
        pendingNextLevel = nil
        timer?.invalidate(); timer=nil; shooting=false; sound.stopAll()
        view.mouseCapture.release(); bulletEffects.clear(); _=projectiles.clear();enemyOrdnance.clear()
        effects.clear();fragments.clear();burningTokens.removeAll()
        scene.rootNode.removeAllActions(); view.rendersContinuously=false
    }
    deinit { timer?.invalidate() }
    func restart(level startLevel: Int = 0, score: Int = 0, usedCheats:Bool=false) {
        pendingNextLevel = nil
        view.mouseCapture.release()
        entryPrompt.reset()
        resumeWithCapture = false
        combat=Combat();combat.score=score;level=startLevel;elapsed=0;spawned=0;lastFire = -10;finished=false;paused=false;shooting=false
        runID=UUID();resultRecorded=false;logicalAccumulator=0;logicalTick=0
        self.usedCheats=usedCheats;weapons.unlimitedAmmo2002=false
        // New process input angles begin at BSS0. BH2002's level loader then
        // writes yaw180; BH2000 never infers a view from the first enemy wave.
        camera.eulerAngles=SCNVector3((assets.gameID == "2000" ? -8.0 : -4.0) * .pi / 180,0,0)
        loadLevel()
        input.setAngles(yawDegrees:Double(camera.eulerAngles.y*180 / .pi),pitchDegrees:Double(camera.eulerAngles.x*180 / .pi));input.resetCursor()
        syncGunPose()
        updateHUD()
        captureForPlayIfFullscreen()
    }
    var levelDefinition: [String:Any]? {
        let logical=level+1
        let source=assets.isDepthline ? (max(1,logical)-1)%assets.levels.count+1 :
            (assets.gameID == "2000" ? (logical>60 ? logical%10+51:logical) : (logical>=100 ? logical%10+91:logical))
        return assets.levels.first {($0["number"] as? Int)==source}
    }
    private func loadLevel(saveCheckpoint: Bool = true) {
        isInvulnerable = false
        if assets.shoreline != nil {assets.graphics.updateWakes([])}
        bulletEffects.clear(); _=projectiles.clear();enemyOrdnance.clear()
        effects.clear();fragments.clear();burningTokens.removeAll();burning=OriginalBurning(gameID:assets.gameID)
        sound.stopAll();input.resetCursor();levelStartScore=combat.score
        collectedSupply=nil;supplyMessageUntil=0
        muzzlePulse=nil;muzzleLamp.isHidden=true;muzzleLamp.light?.intensity=0;hud.damageFlash=0
        weaponPresentation.reset()
        enemies.forEach {$0.node.removeFromParentNode()};enemies=[]
        supplyNodes.values.forEach {$0.removeFromParentNode()};supplyNodes=[:]
        campaign=nil;supply2000=nil;supply2002=nil;original2000AI=nil;aircraft2000=nil
        bombers=[];bomberSources=[:];waves=[];nextTrooperOrdinal=0
        barrage=nil;pendingBomberSupport=false;pendingEnemyShots=[];pendingGrenades=[];pendingOrdnance=[];pendingEnemyEmitters=[];pendingBomberDrops=[]
        flares=OriginalFlares();flareNodes.forEach {$0.removeFromParentNode()};flareNodes=[]
        if let training {
            training.install(in:self)
            return
        }
        guard let data=levelDefinition else {
            finished=true;supplyMessageUntil = .infinity;return
        }
        elapsed=0;logicalTick=0;logicalAccumulator=0;inputLocked=false;combat.health=100;shooting=false
        //2002 FUN_00429201 resets yaw each level but preserves player pitch.
        //2000 leaves both angles untouched between levels.
        if assets.gameID=="2002" {camera.eulerAngles.y = .pi}
        input.setAngles(yawDegrees:Double(camera.eulerAngles.y*180 / .pi),pitchDegrees:Double(camera.eulerAngles.x*180 / .pi))
        barrage=nil;pendingBomberSupport=false;pendingEnemyShots=[];pendingGrenades=[];pendingOrdnance=[];pendingEnemyEmitters=[];pendingBomberDrops=[]
        campaign=OriginalCampaign(gameID:assets.gameID,level:level+1,definition:data)
        bombers=assets.gameID=="2002" ? (0..<9).map {Original2002BomberAI(slot:$0)}:[];bomberSources=[:]
        bomberHeading=Original2002BomberAI.levelHeading(direction:(data["groupDirections"] as? [String:String])?["BOMBER"])
        waves=assets.waves(level:assets.levels.firstIndex {($0["number"] as? Int)==(data["number"] as? Int)} ?? 0)
        configureWeapons(data)
        let flags=data["flags"] as? [String] ?? []
        hud.crosshairVisible=assets.gameID=="2000" || flags.contains("Crosshair")
        night=assets.gameID=="2002" && !flags.contains("Daytime")
        applyLight(.mission(gameID:assets.gameID,level:level+1,night:night), searchlight:flags.contains("Spotlight"))
        scene.rootNode.childNode(withName:"SkyDay",recursively:false)?.isHidden=night
        scene.rootNode.childNode(withName:"SkyNight",recursively:false)?.isHidden = !night
        flares=OriginalFlares();flareNodes.forEach {$0.removeFromParentNode()};flareNodes=[]
        if assets.gameID=="2000" {
            let declarations=(data["objects"] as? [[String:Any]] ?? []).enumerated().compactMap { index,item->Original2000EnemyAI.BargeDeclaration? in
                guard (item["type"] as? String)=="BARGE" else {return nil}
                return .init(slot:item["slot"] as? Int ?? 0,sourceIndex:index,active:false)
            }
            let raw=data["objects"] as? [[String:Any]] ?? []
            let vehicles=raw.enumerated().compactMap { index,item->Original2000EnemyAI.VehicleDeclaration? in
                guard let type=item["type"] as? String,type=="TANK" || type.hasPrefix("APC") else {return nil}
                return .init(kind:type=="TANK" ? .tank:.apc,slot:item["slot"] as? Int ?? 0,sourceIndex:index,active:false)
            }
            let helicopters=raw.enumerated().compactMap { index,item->Original2000EnemyAI.HelicopterDeclaration? in
                guard item["type"] as? String=="CH53" else {return nil}
                return .init(slot:item["slot"] as? Int ?? 0,sourceIndex:index,active:false)
            }
            original2000AI=Original2000EnemyAI(bargeDeclarations:declarations,vehicleDeclarations:vehicles,helicopterDeclarations:helicopters,aggression:data["aggression"] as? [Int] ?? [],
                beachZ:assets.shoreline.map { field in { sourceX in field.z(at:sourceX*0.01)*100 } },random:{self.random.next()})
            let planes=raw.enumerated().compactMap {index,item->Original2000AircraftAI.Declaration? in
                guard let type=item["type"] as? String,let kind:Original2000AircraftAI.Kind=["JET":.jet,"BOMBER":.bomber,"COBRA":.cobra][type] else {return nil}
                return .init(kind:kind,slot:item["slot"] as? Int ?? 0,sourceIndex:index,active:false)
            }
            aircraft2000=Original2000AircraftAI(declarations:planes,aggression:data["aggression"] as? [Int] ?? [],random:{self.random.next()})
            original2000AI?.usesDepthlineAPCExit = assets.isDepthline
            original2000AI?.helicopterAltitude = flightTerrain?.flightAltitude
            original2000AI?.helicopterGround = flightTerrain?.groundForFlight
            aircraft2000?.helicopterAltitude = flightTerrain?.flightAltitude
            aircraft2000?.helicopterGround = flightTerrain?.groundForFlight
            let declaration=(data["objects"] as? [[String:Any]] ?? []).first {($0["type"] as? String)=="C130"}
            supply2000=Beach2000Supply(delay:declaration?["delay"] as? Int ?? 0,initialMachineGunAmmo:weapons.ammo.machineGun,cargoDescent:assets.isDepthline ? .depthlineCargo : .original)
        } else {
            var declarations:[Beach2002Supply.Declaration]=[]
            let raw=data["objects"] as? [[String:Any]] ?? []
            for (index,item) in raw.enumerated() where (item["type"] as? String)=="C130" {
                func n(_ key:String,_ fallback:Int=0)->Int {item[key] as? Int ?? fallback}
                declarations.append(.init(sourceIndex:index,slot:declarations.count,delay:item["delay"] as? Int,passes:n("passes",127),
                    far:n("far")>0 || (item["far"] as? Bool ?? false),troops1:n("troops1"),troops2:n("troops2"),hdrop:n("hdrop"),adrop:n("adrop"),pdrop:n("pdrop"),mdrop:n("mdrop")))
            }
            let name=(data["groupDirections"] as? [String:String])?["C130"] ?? "Random"
            let direction:Beach2002Supply.Direction=["North":.north,"South":.south,"East":.east,"West":.west][name] ?? .random
            supply2002=Beach2002Supply(declarations:declarations,direction:direction,cargoDescent:assets.isDepthline ? .depthlineCargo : .original);nextTrooperOrdinal=0
        }
        for event in campaign?.takeInitialSpawns() ?? [] { spawn(event) }
        if saveCheckpoint { onCheckpoint?(level+1,combat.score) }
    }
    private func completeMission(nextLevel: Int, bonus: Int) {
        pendingNextLevel = nextLevel
        combat.score += bonus
        // The same next-level checkpoint applies to both menu choices, even if
        // the app closes before the player chooses.
        onCheckpoint?(nextLevel, combat.score)
        if level + 1 == assets.levels.count { onSectorCompleted?() }
        resumeWithCapture = view.mouseCapture.isCaptured
        shooting = false
        sound.stopAll()
        view.mouseCapture.release()
        refreshBattleOverlays()
    }

    func continueToNextLevel() {
        guard let next = pendingNextLevel else { return }
        pendingNextLevel = nil
        level = next - 1
        entryPrompt.reset()
        loadLevel(saveCheckpoint: false)
        updateHUD()
        view.window?.makeFirstResponder(view)
        if resumeWithCapture || isBattleFullScreen { captureForPlay() }
        resumeWithCapture = false
        previousTime = CACurrentMediaTime()
    }
    func configureWeapons(_ data:[String:Any]) {
        let ammo=data["ammo"] as? [Int] ?? []
        func amount(_ i:Int)->Int {ammo.indices.contains(i) ? ammo[i] : 0}
        let flags=data["flags"] as? [String] ?? []
        let unlimited=weapons.unlimitedAmmo2002
        weapons=OriginalWeaponState(version:assets.gameID == "2000" ? .beach2000 : .beach2002,
            machineGunAmmo:amount(0),cannonAmmo:amount(1),missileAmmo:amount(2),flareAmmo:amount(3),
            supportAvailable:assets.gameID == "2000" ? (data["artillery"] as? Int ?? 0)>0 : flags.contains("Bombers"),
            machineGunVariant:campaign?.machineGunVariant ?? 0,
            phaseCounter:weapons.phaseCounter,singleShotLatched:weapons.singleShotLatched)
        weapons.unlimitedAmmo2002=unlimited
        weapons.prepareMissileSlots()
        syncWeaponModel()
    }
    func syncWeaponModel() {
        syncGunPose()
        weaponPresentation.sync(selected:weapons.selected,machineGunVariant:weapons.machineGunVariant,cannonVariant:weapons.cannonVariant)
    }
    var isBattleFullScreen: Bool { view.window?.styleMask.contains(.fullScreen) == true }
    var isShowingVictoryChoice: Bool { pendingNextLevel != nil || training?.stage == .complete }
    func continueAfterVictoryChoice() {
        if training?.stage == .complete { onEnterCoast?() }
        else { continueToNextLevel() }
    }
    var acceptsBattleInput: Bool {
        !paused && !finished && !inputLocked && combat.health > 0 && training?.guideOpen != true && training?.stage != .complete
    }
    func refreshBattleOverlays() {
        let hideMenu = !paused || training?.guideOpen == true || isShowingVictoryChoice
        if pauseMenu.isHidden != hideMenu { pauseMenu.isHidden = hideMenu }
        if pendingNextLevel != nil {
            victoryMenu.show(sector: DepthlineIdentity.sector(assets.gameID), completedLevel: level + 1)
        } else if training?.stage == .complete {
            victoryMenu.showTrainingCompletion()
        } else {
            victoryMenu.hide()
        }
        entryPrompt.update(windowed: view.window != nil && !isBattleFullScreen,
                           active: acceptsBattleInput, captured: view.mouseCapture.isCaptured)
    }
    private func captureForPlay() {
        guard acceptsBattleInput, !view.mouseCapture.isCaptured, view.window?.contentView === view else { return }
        view.toggleMouseCapture(requirePointerInside:false)
    }
    func captureForPlayIfFullscreen() {
        if isBattleFullScreen { captureForPlay() }
    }
    func togglePause() {
        guard !isShowingVictoryChoice else { return }
        shooting = false
        input.resetCursor()
        if paused {
            paused = false
            view.window?.makeFirstResponder(view)
            if resumeWithCapture || isBattleFullScreen { captureForPlay() }
            resumeWithCapture = false
        } else {
            resumeWithCapture = view.mouseCapture.isCaptured
            paused = true
            view.mouseCapture.release()
            sound.stopAll()
        }
        hud.paused = paused
        hud.needsDisplay = true
        refreshBattleOverlays()
    }
    enum SettingAction {case sound,invertY,sensitivityUp,sensitivityDown,acceleration}
    func changeSetting(_ action:SettingAction) {
        switch action {
        case .sound:settings.soundEnabled.toggle();if !settings.soundEnabled {sound.stopAll()}
        case .invertY:
            settings.invertY.toggle()
        case .sensitivityUp:settings.sensitivityLevel=min(5,settings.sensitivityLevel+1)
        case .sensitivityDown:settings.sensitivityLevel=max(1,settings.sensitivityLevel-1)
        case .acceleration:break
        }
        onSettingsChanged?(settings)
    }
    func applyCheat(_ key:Int) {
        guard assets.gameID=="2002", !finished, !isShowingVictoryChoice, (1...3).contains(key) else {return}
        markCurrentRunAssisted()
        if key==1 {weapons.unlimitedAmmo2002.toggle()}
        if key==2 {
            isInvulnerable.toggle()
            if isInvulnerable {combat.health=100;hud.damageFlash=0}
        }
        if key==3 {campaign?.applyForceZeroCheat()}
    }
    func aim(_ event:NSEvent) {
        applyDirectAim(deltaX:event.deltaX,deltaY:event.deltaY)
    }
    func spawn(_ wave:Wave,index:Int) {
        let node=assets.model(wave.type == "BARGE" && wave.cargoFamily == "vehicle" ? "BARGE_VEHICLE" : wave.type)
        let motion: EnemyPath = assets.gameID == "2000"
            ? Beach2000Motion(type:wave.type,index:wave.slot)
            : EnemyMotion(type:wave.type,index:index,direction:wave.direction)
        let e=Enemy(node:node,type:wave.type,flying:motion.flying,motion:motion)
        e.cargoFamily = wave.cargoFamily
        if assets.gameID == "2000" && ["C130","BOMBER"].contains(wave.type) { e.required=false }
        e.updateMotion(assets:assets)
        scene.rootNode.addChildNode(node);enemies.append(e)
    }
    func spawn(_ event:OriginalCampaign.SpawnEvent) {
        let base=assets.gameID=="2000" ? ["JET":76,"BOMBER":73,"COBRA":88,"CH53":106][event.type]:nil
        if let base {burning.cancelDelayed(objectID:base+event.slot)}
        // Both generations' C130 lifecycle is owned by the supply modules.
        guard event.type != "C130" else {return}
        if assets.gameID=="2002",event.type=="BOMBER",bombers.indices.contains(event.slot) {
            bombers[event.slot].activate();bomberSources[event.slot]=event.sourceIndex;return
        }
        if assets.gameID=="2000",event.type=="BARGE" {
            original2000AI?.activateBarge(slot:event.slot,sourceIndex:event.sourceIndex)
            return
        }
        if assets.gameID=="2000",event.type=="TANK" || event.type.hasPrefix("APC") {
            original2000AI?.activateVehicle(kind:event.type=="TANK" ? .tank:.apc,slot:event.slot,sourceIndex:event.sourceIndex);return
        }
        if assets.gameID=="2000",event.type=="CH53" {original2000AI?.activateHelicopter(slot:event.slot,sourceIndex:event.sourceIndex);return}
        if assets.gameID=="2000",let kind:Original2000AircraftAI.Kind=["JET":.jet,"BOMBER":.bomber,"COBRA":.cobra][event.type] {
            aircraft2000?.activate(kind:kind,slot:event.slot,sourceIndex:event.sourceIndex,random:{self.random.next()},resetForRevive:event.generation>0);return
        }
        spawn(Wave(type:event.type,declaredDelay:0,time:0,direction:event.direction,slot:event.slot,cargoFamily:event.cargoFamily),index:event.slot)
        guard let enemy=enemies.last else {return}
        enemy.sourceIndex=event.sourceIndex;enemy.slot=event.slot;enemy.force=event.force;enemy.required=event.force>0
        if assets.gameID=="2002" {
            enemy.originalAI=OriginalEnemyAI(type:event.type,slot:event.slot,direction:event.direction,aggression:levelDefinition?["aggression"] as? [Int] ?? [])
            if event.type == "COBRA" || event.type == "CH53" {
                enemy.originalAI?.helicopterAltitude = flightTerrain?.flightAltitude
                enemy.originalAI?.helicopterGround = flightTerrain?.groundForFlight
            }
            if enemy.originalAI != nil {enemy.node.isHidden=true}
        }
        // Original initial durability. Armor still needs the corresponding hit
        // class; HP1 does not make tanks vulnerable to machine-gun bullets.
        enemy.hp=assets.gameID=="2000" ? (["JET":4,"BOMBER":8,"COBRA":8,"CH53":12,"C130":8][enemy.type] ?? 1)
            : (["JET":4,"BOMBER":4,"COBRA":8,"CH53":8,"C130":8][enemy.type] ?? 1)
    }
    var aimDirection:SCNVector3 {camera.convertVector(SCNVector3(0,0,-1),to:nil)}
    var version:OriginalGameVersion {assets.gameID=="2000" ? .beach2000:.beach2002}
    func damageWeapon(_ kind:OriginalProjectileKind)->OriginalDamageWeapon {
        kind.missileSlot != nil ? .missile:kind.isCannon ? .cannon:.bullet
    }
    func originalObjectIndex(_ enemy:Enemy)->Int? {
        let base=assets.gameID=="2000" ? ["BARGE":11,"TANK":37,"APC1":61,"BOMBER":73,"JET":76,"COBRA":88,"CH53":106,"C130":207,"INFANTRY":139][enemy.type]
            : ["TANK":37,"APC1":73,"APC2":77,"APC3":81,"JET":117,"BOMBER":133,"COBRA":142,"CH53":178,"C130":210,"INFANTRY":358][enemy.type]
        return base.map {$0+enemy.slot}
    }
    func fire(_ action:OriginalFireAction) {
        guard !paused,!inputLocked,combat.health>0 else {return}
        syncWeaponModel()
        let basis=weaponPresentation.basis(for:action),forward=basis.forward,right=basis.right
        let muzzle:SCNVector3
        if assets.isDepthline,let tip=basis.muzzle {
            muzzle=tip
        } else {
            guard let launch=originalGunMuzzle(version:version,action:action,
                forward:.init(Double(forward.x),Double(forward.y),Double(forward.z)),
                right:.init(Double(right.x),Double(right.y),Double(right.z)),
                mountRight:.init(Double(basis.mountRight.x),Double(basis.mountRight.y),Double(basis.mountRight.z))) else {return}
            let offset=depthlineGunOffset
            muzzle=SCNVector3(launch.x*0.01+offset.x,launch.y*0.01+offset.y,launch.z*0.01+offset.z)
        }
        let direction = playerShotDirection(for: action, muzzle: muzzle, forward: forward)
        guard projectiles.spawn(action,from:muzzle,direction:direction) else {return}
        combat.shots+=1;lastFire=elapsed
        let sourceMuzzle=SIMD3<Double>(muzzle.x*100,muzzle.y*100,muzzle.z*100)
        if let token=effects.emitGunFlash(action:action,muzzle:sourceMuzzle),assets.isDepthline {
            if let old=muzzlePulse {effects.remove(old.token)}
            muzzlePulse=(action,token)
            updateMuzzleFeedback()
        }
        playSound(action.weapon == .machineGun ? (assets.gameID=="2002" && action.variant != 0 ? "MachineGun":"AntiAir") : action.weapon == .handgun ? "Pistol":"CannonClose")
    }
    /// Update on the same simulation clock used by the live window and captures.
    /// The warm point light and sprite track the recoiling muzzle during a turn.
    func updateMuzzleFeedback() {
        guard let pulse=muzzlePulse else {return}
        let fade=max(0,1-(elapsed-lastFire)/0.085)
        guard fade>0,pulse.action.weapon==weapons.selected,
              let tip=weaponPresentation.basis(for:pulse.action).muzzle else {
            effects.remove(pulse.token);muzzlePulse=nil;muzzleLamp.isHidden=true;muzzleLamp.light?.intensity=0
            return
        }
        effects.move(pulse.token,to:SIMD3<Double>(tip.x*100,tip.y*100,tip.z*100))
        muzzleLamp.position=tip
        muzzleLamp.light?.intensity=CGFloat((pulse.action.weapon == .cannon ? 600:280)*fade*fade)
        muzzleLamp.isHidden=false
    }
    func launchMissile() {
        guard !paused,!inputLocked,combat.health>0,let launch=weapons.requestMissile() else {return}
        let position=camera.convertPosition(SCNVector3(launch.slot == 0 ? -1:1,-0.2,0),to:nil)
        guard projectiles.spawnMissile(launch,from:position,direction:aimDirection,model:assets.model(assets.gameID=="2000" ? "Missile1":"MISSILE")) else {
            weapons.missileFinished(slot:launch.slot)
            return
        }
        playSound("Missile")
    }
    func launchFlare() {
        guard !paused,!inputLocked,combat.health>0,weapons.requestFlare(weaponReady:true,night:night) != nil else {return}
        let p=camera.position,d=aimDirection
        flares.launch(position:.init(Float(p.x*100),Float(p.y*100),Float(p.z*100)),direction:.init(Float(d.x),Float(d.y),Float(d.z)),pitchDegrees:Float(camera.eulerAngles.x*180 / .pi))
        playSound("Missile")
    }
    func requestSupport() {
        guard !paused,!inputLocked,combat.health>0,let action=weapons.consumeSupport() else {return}
        if action == .beach2000GroundBarrage {barrage=Original2000BarrageState();playSound("Radio")}
        else {
            bomberHeading=Original2002BomberAI.supportHeading(random15:{Int(self.random.next())})
            bombers.forEach {$0.activate()}
        }
    }
    func updateFlares() {
        flares.step { [assets] x,z in Float(assets.height(x:CGFloat(x)*0.01,z:CGFloat(z)*0.01))*100 }
        while flareNodes.count<4 {
            let plane=SCNPlane(width:0.3,height:0.3),material=SCNMaterial()
            material.lightingModel = .constant;material.blendMode = .add;material.writesToDepthBuffer=false
            material.diffuse.contents=assets.textures[8].flatMap {NSImage(contentsOf:$0)}
            plane.materials=[material]
            let node=SCNNode(geometry:plane),billboard=SCNBillboardConstraint();billboard.freeAxes = .all;node.constraints=[billboard]
            node.light=SCNLight();node.light?.type = .omni;node.light?.intensity=1400;node.light?.attenuationStartDistance=10;node.light?.attenuationEndDistance=150
            node.light?.color=NSColor(srgbRed:1,green:0.83,blue:0.63,alpha:1)
            RemasteredEffects.configureFlare(node)
            scene.rootNode.addChildNode(node);flareNodes.append(node)
        }
        for (i,flare) in flares.slots.enumerated() {
            let n=flareNodes[i];n.isHidden = !flare.active
            guard flare.active else { n.light?.intensity=0;continue }
            n.position=SCNVector3(flare.position.x*0.01,flare.position.y*0.01,flare.position.z*0.01)
            let clearance = n.position.y - assets.height(x:n.position.x,z:n.position.z)
            let glow = CGFloat(flare.glow(clearanceMetres:Float(clearance)))
            let scale: CGFloat = 1 + 4.5*glow
            n.scale = SCNVector3(scale,scale,scale)
            n.opacity = flare.deployed ? 0.16+0.84*glow : 0.30
            n.light?.intensity = 1250*glow
        }
    }
    func applyLight(_ preset: DepthlineLight, searchlight: Bool) {
        visualLight = preset
        assets.graphics.updateLighting(scene:scene,ambient:ambient,sun:sun,preset:preset,
                                      inland:assets.gameID == "2002",camera:camera.camera!)
        spotlight.isHidden = preset != .night || !searchlight
    }
    func playSound(_ name:String) {
        playOriginalSound(name)
    }
    func hitCandidates(_ sweep:OriginalProjectileSweep)->[OriginalProjectileHit] {
        var hits:[OriginalProjectileHit]=[]
        for enemy in enemies where !enemy.node.isHidden {
            if enemy.type=="INFANTRY" {
                if assets.gameID=="2000",(21...25).contains(enemy.aiState) {continue}
                if assets.gameID=="2002",enemy.aiState<2 {continue}
            }
            // A hills vehicle can shield the infantry behind it at any elevation.
            let armoredCover = assets.isDepthline && sweep.kind.isCannon &&
                (enemy.type == "TANK" || enemy.type.hasPrefix("APC") || enemy.type == "BARGE")
            let eligible: OriginalHitEligibility = armoredCover ? .collisionVolumes :
                OriginalDamage.eligibility(version:version,weapon:damageWeapon(sweep.kind),type:enemy.type,sourceY:Float(sweep.end.y*100))
            guard eligible.blocksProjectile else {continue}
            if case .endpointRadius(let radius)=eligible {
                let p=enemy.node.position
                if length(SCNVector3(sweep.end.x-p.x,sweep.end.y-p.y,sweep.end.z-p.z))<CGFloat(radius)*0.01 {hits.append(.init(fraction:1,target:enemy.node,originalPart:nil))}
                continue
            }
            if let hit=assets.collision.hit(type:enemy.type,cargoFamily:enemy.cargoFamily,node:enemy.node,start:sweep.start,end:sweep.end) {
                hits.append(.init(fraction:hit.fraction,target:enemy.node,originalPart:hit.part))
            } else if enemy.type=="INFANTRY" {
                if let t=OriginalCollision.infantryHit(gameID:assets.gameID,state:enemy.aiState,foot:enemy.node.position,start:sweep.start,end:sweep.end) {hits.append(.init(fraction:t,target:enemy.node,originalPart:nil))}
            }
        }
        for (id,node) in supplyNodes where !node.isHidden {
            let plane=assets.gameID=="2000" ? id==207 : (210..<218).contains(id)
            let chute=assets.gameID=="2000" ? (212...213).contains(id):(294..<358).contains(id)
            guard plane || chute else {continue}
            let type=plane ? "C130":"Parachute"
            let eligible=OriginalDamage.eligibility(version:version,weapon:damageWeapon(sweep.kind),type:type,sourceY:Float(sweep.end.y*100))
            guard eligible.blocksProjectile else {continue}
            if case .endpointRadius(let radius)=eligible {
                let p=node.position
                if length(SCNVector3(sweep.end.x-p.x,sweep.end.y-p.y,sweep.end.z-p.z))<CGFloat(radius)*0.01 {hits.append(.init(fraction:1,target:node,originalPart:nil))}
                continue
            }
            let geometry = chute && assets.isDepthline ? depthlineDropHit(id:id,node:node,sweep:sweep) :
                assets.collision.hit(type:type,node:node,start:sweep.start,end:sweep.end)
            if let hit=geometry {hits.append(.init(fraction:hit.fraction,target:node,originalPart:hit.part))}
        }
        return hits
    }
    func applyProjectileEvents(_ events:[OriginalProjectileEvent],genericSplash:Bool=true) {
        for event in events {
            switch event {
            case .missileEnded(let slot):weapons.missileFinished(slot:slot)
            case .impact(let sweep,let hit):
                if !sweep.kind.isCannon && sweep.kind.missileSlot == nil {
                    let point=sweep.position(at:hit.fraction),p=SIMD3<Double>(Double(point.x*100),Double(point.y*100),Double(point.z*100))
                    let soldier=hit.target.map {target in enemies.contains {$0.node===target && $0.type=="INFANTRY"}} ?? false
                    effects.emit(hit.isGround ? .dirtHit : soldier ? .blood:.impactFlash,at:p)
                }
                if genericSplash && (sweep.kind.isCannon || sweep.kind.missileSlot != nil) {applySplash(at:sweep.position(at:hit.fraction),weapon:damageWeapon(sweep.kind))}
                guard let target=hit.target else {
                    let point=sweep.position(at:hit.fraction)
                    playOriginalGroundImpactSound(weapon:damageWeapon(sweep.kind),at:.init(Double(point.x*100),Double(point.y*100),Double(point.z*100)))
                    continue
                }
                if let id=supplyNodes.first(where:{$0.value===target})?.key,assets.gameID=="2000" {
                    if id==207 {
                        if let p=supply2000?.plane {
                            playOriginalDirectHitSound(.init(version:version,type:"C130",hitPoints:p.hp,aiState:p.state.rawValue,originalObjectIndex:id),weapon:damageWeapon(sweep.kind),part:hit.originalPart,at:.init(Double(p.position.x),Double(p.position.y),Double(p.position.z)))
                        }
                        let weapon:Beach2000Supply.PlaneWeapon=sweep.kind.missileSlot != nil ? .missile:sweep.kind.isCannon ? .cannon:.commonBullet(part:hit.originalPart ?? 2)
                        consumeSupplyEvents(supply2000?.hitPlane(by:weapon) ?? [])
                    } else if let reward=supply2000?.collect(objectID:id,by:sweep.kind.isCannon ? .cannon:.commonBullet,machineGunAmmo:weapons.ammo.machineGun,defense:combat.health) {
                        weapons.ammo.machineGun=reward.machineGunAmmo;combat.health=reward.defense;campaign?.noteSupplyCollected()
                        collectedSupply = reward.kind == .defense ? .defense : .machineGun;supplyMessageUntil=elapsed+3
                        playSound("Prize")
                    }
                    syncSupplyNodes();continue
                }
                if let id=supplyNodes.first(where:{$0.value===target})?.key,assets.gameID=="2002" {
                    if (210..<218).contains(id) {
                        if let p=supply2002?.planes.first(where:{$0.objectID==id}) {
                            playOriginalDirectHitSound(.init(version:version,type:"C130",hitPoints:p.hp,aiState:p.state.rawValue,originalObjectIndex:id),weapon:damageWeapon(sweep.kind),part:hit.originalPart,at:.init(Double(p.position.x),Double(p.position.y),Double(p.position.z)))
                        }
                        let weapon:Beach2002Supply.PlaneWeapon=sweep.kind.missileSlot != nil ? .missile:sweep.kind.isCannon ? .cannon:.commonBullet(part:hit.originalPart ?? 2)
                        consumeSupply2002Events(supply2002?.hitPlane(objectID:id,by:weapon) ?? [],weapon:damageWeapon(sweep.kind),part:hit.originalPart)
                    } else {
                        let resources=Beach2002Supply.Resources(defense:combat.health,machineGun:weapons.ammo.machineGun,cannon:weapons.ammo.cannon,missile:weapons.ammo.missile)
                        if let reward=supply2002?.collect(parachuteID:id,resources:resources) {
                            var values=reward.resources;values.applyOriginalCaps()
                            combat.health=values.defense;weapons.ammo.machineGun=values.machineGun;weapons.ammo.cannon=values.cannon;weapons.ammo.missile=values.missile
                            if reward.transitionCounter != nil {campaign?.noteSupplyCollected()}
                            if reward.remainingForceDelta != 0 {campaign?.resolveForce(sourceIndex:reward.sourceIndex,amount:Double(-reward.remainingForceDelta))}
                            if let kind=reward.reward {collectedSupply=kind;supplyMessageUntil=elapsed+3;playSound("Prize")}
                        }
                    }
                    syncSupply2002Nodes();continue
                }
                guard let enemy=enemies.first(where:{$0.node===target}) else {continue}
                combat.hits+=1
                let context=OriginalDamageContext(version:version,type:enemy.type,hitPoints:enemy.hp,aiState:enemy.aiState,originalObjectIndex:originalObjectIndex(enemy))
                let result=OriginalDamage.resolve(context,weapon:damageWeapon(sweep.kind),part:hit.originalPart)
                playOriginalDirectHitSound(context,weapon:damageWeapon(sweep.kind),part:hit.originalPart,at:originalPosition(enemy.node))
                if result.confirmed {noteBurningHit(enemy,weapon:damageWeapon(sweep.kind),part:hit.originalPart)}
                emitOriginalHitFragments(context:context,weapon:damageWeapon(sweep.kind),part:hit.originalPart,result:result,node:enemy.node)
                applyDamage(result,to:enemy)
            }
        }
    }
    func applyDamage(_ result:OriginalDamageResult,to enemy:Enemy) {
        guard result.confirmed else {return}
        enemy.hp=result.hitPoints
        if let state=result.nextAIState {enemy.aiState=state}
        if let delta=result.scoreDelta {combat.score+=delta}
        if let delta=result.forceDelta,delta != 0 {campaign?.resolveForce(sourceIndex:enemy.sourceIndex,amount:Double(-delta))}
        enemy.deathMode=result.deathMode
        if let deferred=result.deferred {enemy.deferredDeath=deferred}
        if let slot=enemy.aggregateBoatSlot,!result.active {original2000AI?.destroyBarge(slot:slot)}
        if let id=enemy.aggregateVehicleID {original2000AI?.applyVehicleDamage(objectID:id,hp:result.hitPoints,state:enemy.aiState,visible:result.active)}
        if let id=enemy.aggregateAircraftID {aircraft2000?.applyDamage(objectID:id,hp:result.hitPoints,state:enemy.aiState,visible:result.active)}
        if let slot=enemy.aggregateSoldierSlot,result.beginsDeath {original2000AI?.killSoldier(slot:slot,animated:result.deathMode == .infantryDeath)}
        if result.deathMode == .infantryDeath {enemy.infantryAI?.beginBulletDeath()}
        else if result.deathMode == .infantryDebris,let state=result.nextAIState {enemy.infantryAI?.beginThrownDeath(state:state,velocity:enemy.thrownVelocity,spin:enemy.thrownSpin)}
        if let state=result.nextAIState {enemy.originalAI?.applyDamageState(state,active:result.active)}
        else if !result.active {enemy.originalAI?.remove()}
        if result.deathMode == .explode {explode(enemy.node.position)}
        if !result.active {
            if enemy.type.hasPrefix("APC") {
                enemies.removeAll { passenger in
                    guard passenger.boardingAPC === enemy else { return false }
                    passenger.infantryAI?.remove()
                    passenger.node.removeFromParentNode()
                    campaign?.resolveForce(sourceIndex: passenger.sourceIndex, amount: passenger.force)
                    return true
                }
            }
            enemy.infantryAI?.remove()
            if assets.gameID=="2002",enemy.type=="BOMBER",bombers.indices.contains(enemy.slot) {bombers[enemy.slot].kill()}
            enemy.node.removeFromParentNode();enemies.removeAll {$0===enemy}
            campaign?.enemyRemoved(sourceIndex:enemy.sourceIndex,forceRemoved:0)
        }
    }
    func applySplash(at position:SCNVector3,weapon:OriginalDamageWeapon,directTarget:SCNNode?=nil) {
        guard let profile=OriginalDamage.splashProfile(version:version,weapon:weapon) else {return}
        explode(position)
        for enemy in enemies where enemy.type=="INFANTRY" && !enemy.node.isHidden {
            if assets.isDepthline && weapon == .cannon && !exposedToDepthlineShell(enemy) { continue }
            let p=enemy.node.position
            let distance=profile.horizontalOnly ? hypot(p.x-position.x,p.z-position.z):length(SCNVector3(p.x-position.x,p.y-position.y,p.z-position.z))
            guard enemy.node === directTarget || distance<CGFloat(profile.radius)*0.01 else {continue}
            let onBoatRamp = assets.isDepthline && version == .beach2000 && weapon == .cannon && enemy.aiState == 3
            applyInfantryExplosion(enemy,at:position,weapon:weapon,includesEmbarkedInfantry:onBoatRamp)
        }
    }
    func applyInfantryExplosion(_ enemy:Enemy,at position:SCNVector3,weapon:OriginalDamageWeapon,includesEmbarkedInfantry:Bool=false) {
        var variant:Int?
        if assets.gameID=="2002",enemy.aiState>1 && enemy.aiState<42 {
            let p=enemy.node.position
            enemy.thrownVelocity = .init(Double((p.x-position.x)*100)*0.05,Double(random.next())*0.0005+20,Double((p.z-position.z)*100)*0.05)
            enemy.thrownSpin=(Double(random.next())-16384)*0.0005;variant=Int(random.next())
        }
        let context=OriginalDamageContext(version:version,type:enemy.type,hitPoints:enemy.hp,aiState:enemy.aiState,originalObjectIndex:originalObjectIndex(enemy))
        applyDamage(OriginalDamage.splash(context,weapon:weapon,random15:variant,allowEmbarked2000:includesEmbarkedInfantry),to:enemy)
    }
    func consumeSupplyEvents(_ events:[Beach2000Supply.Event]) {
        for event in events {
            switch event {
            case .planeActivated:burning.cancelDelayed(objectID:207)
            case .scoreChanged(let value):combat.score+=value
            case .planeDestroyed(let p,let sourceWeapon):
                let weapon:OriginalDamageWeapon,part:Int?
                switch sourceWeapon {
                case .commonBullet(let hitPart):weapon = .bullet;part=hitPart
                case .cannon:weapon = .cannon;part=nil
                case .missile:weapon = .missile;part=nil
                }
                if let plane=supply2000?.plane {
                    emitOriginalDestroyedFragments(type:"C130",objectID:207,weapon:weapon,part:part,
                        position:.init(Double(p.x),Double(p.y),Double(p.z)),rotationDegrees:.init(Double(plane.pitch),Double(plane.yaw),Double(plane.roll)))
                }
                explode(SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01))
            case .planeCrashed(let p):
                playOriginalCrashSound(at:.init(Double(p.x),Double(p.y),Double(p.z)))
                burning.noteCrash(type:"C130",objectID:207,position:.init(Double(p.x),Double(p.y),Double(p.z)))
                explode(SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01))
            case .smoke(let p):effects.emit(.blackSmoke,at:.init(Double(p.x),Double(p.y),Double(p.z)))
            default:break
            }
        }
    }
    func syncSupplyNodes() {
        guard let supply=supply2000 else {return}
        func node(_ id:Int,_ name:String)->SCNNode {
            if let existing=supplyNodes[id] {return existing}
            let created=assets.model(name);supplyNodes[id]=created;scene.rootNode.addChildNode(created);return created
        }
        let plane=node(207,"C130"),p=supply.plane
        plane.isHidden = !p.visible;plane.position=SCNVector3(p.position.x*0.01,p.position.y*0.01,p.position.z*0.01)
        plane.eulerAngles=SCNVector3(p.pitch*Float.pi/180,p.yaw*Float.pi/180,p.roll*Float.pi/180)
        RemasteredAircraft.updateScrews(on:plane,type:"C130",tick:logicalTick)
        for chute in supply.parachutes {
            let n=node(chute.objectID,chute.objectID==212 ? "Parachute1":"Parachute2")
            n.isHidden = !chute.visible;n.position=SCNVector3(chute.position.x*0.01,chute.position.y*0.01,chute.position.z*0.01)
            n.eulerAngles=SCNVector3(chute.pitch*Float.pi/180,chute.yaw*Float.pi/180,0)
        }
    }
    func updateSupply2002() {
        consumeSupply2002Events(supply2002?.updateAI(random:{self.random.next()},terrainHeight:{[assets] x,z in
            Float(assets.pointHeight(x:CGFloat(x)*0.01,z:CGFloat(z)*0.01))*100
        },smokeTick:logicalTick%2==0,allocateTrooperID:{
            self.allocateTrooperID()
        }) ?? [])
        syncSupply2002Nodes()
    }
    func consumeSupply2002Events(_ events:[Beach2002Supply.Event],weapon:OriginalDamageWeapon?=nil,part:Int?=nil) {
        for event in events {
            switch event {
            case .remainingForceChanged(let index,let amount):campaign?.resolveForce(sourceIndex:index,amount:Double(-amount))
            case .planeDestroyed(_,let id,let p):
                if let weapon,let plane=supply2002?.planes.first(where:{$0.objectID==id}) {
                    emitOriginalDestroyedFragments(type:"C130",objectID:id,weapon:weapon,part:part,
                        position:.init(Double(p.x),Double(p.y),Double(p.z)),rotationDegrees:.init(Double(plane.pitch),Double(plane.yaw),Double(plane.roll)))
                }
                explode(SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01))
            case .planeCrashed(_,let id,let p):
                if let plane=supply2002?.planes.first(where:{$0.objectID==id}) {
                    emitOriginalCrashFragments(type:"C130",objectID:id,position:.init(Double(p.x),Double(p.y),Double(p.z)),
                        rotationDegrees:.init(Double(plane.pitch),Double(plane.yaw),Double(plane.roll)))
                }
                playOriginalCrashSound(at:.init(Double(p.x),Double(p.y),Double(p.z)))
                burning.noteCrash(type:"C130",objectID:id,position:.init(Double(p.x),Double(p.y),Double(p.z)))
                explode(SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01))
            case .smoke(_,let p):effects.emit(.blackSmoke,at:.init(Double(p.x),Double(p.y),Double(p.z)))
            case .trooperLanded(let index,_,let id,let p):
                infantryLandedThisTick.insert(id)
                supplyNodes[id]?.removeFromParentNode();supplyNodes[id]=nil
                let origin=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
                let soldier=Enemy(node:assets.model("INFANTRY"),type:"INFANTRY",flying:false)
                soldier.sourceIndex=index;soldier.slot=id-358;soldier.force=1;soldier.node.position=origin
                soldier.aiState=2
                soldier.infantryAI=Original2002InfantryAI(position:.init(Double(p.x),Double(p.y),Double(p.z)),initialState:2)
                scene.rootNode.addChildNode(soldier.node);enemies.append(soldier)
            default:break
            }
        }
    }
    func allocateTrooperID()->Int {
        // The executable increments past its96 model slots in late levels.
        // Native compatibility fix: preserve those IDs, then allocate outside
        // all original object ranges. Never erase a live soldier or its force.
        defer {nextTrooperOrdinal += 1}
        return Beach2002Supply.safeTrooperID(ordinal:nextTrooperOrdinal)
    }
    func syncSupply2002Nodes() {
        guard let supply=supply2002 else {return}
        func node(_ id:Int,_ name:String)->SCNNode {
            if let existing=supplyNodes[id] {return existing}
            let created=assets.model(name);supplyNodes[id]=created;scene.rootNode.addChildNode(created);return created
        }
        for plane in supply.planes {
            let n=node(plane.objectID,"C130"),p=plane.position
            n.isHidden = !plane.visible;n.position=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
            n.eulerAngles=SCNVector3(plane.pitch*Float.pi/180,plane.yaw*Float.pi/180,plane.roll*Float.pi/180)
            RemasteredAircraft.updateScrews(on:n,type:"C130",tick:logicalTick)
        }
        for chute in supply.parachutes {
            guard chute.visible || supplyNodes[chute.objectID] != nil else {continue}
            let n=node(chute.objectID,"Parachute"),p=chute.position
            n.isHidden = !chute.visible;n.position=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
            n.eulerAngles=SCNVector3(chute.pitch*Float.pi/180,chute.yaw*Float.pi/180,0)
        }
        for payload in supply.boxes+supply.airborneTroopers {
            guard payload.parentParachuteID>=0 else {continue}
            guard payload.visible || supplyNodes[payload.objectID] != nil else {continue}
            let names=["HealthBoxes","AmmoBoxes","ProjectileBoxes","MissileBoxes","INFANTRY"]
            let n=node(payload.objectID,names[payload.kind.rawValue]),p=payload.position
            n.isHidden = !payload.visible
            if let parent=supplyNodes[payload.parentParachuteID],n.parent !== parent {n.removeFromParentNode();parent.addChildNode(n)}
            n.position=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
            if payload.kind.rawValue == 4 {_=RemasteredInfantry.update(n,gameID:"2002",state:1,frame:230,direction:.init(0,0,-1))}
        }
    }
    func explode(_ position:SCNVector3) {
        let ground=assets.pointHeight(x:position.x,z:position.z)
        let water = assets.shoreline.map { Double(position.z) < $0.z(at:Double(position.x)) } ?? (assets.gameID=="2000" && ground<0)
        let kind:OriginalEffectKind=position.y>ground+1 ? .explosion : water ? .waterSplash:.groundExplosion
        effects.emit(kind,at:.init(Double(position.x*100),Double(position.y*100),Double(position.z*100)))
    }
    func tick() {
        let now=CACurrentMediaTime();let dt=min(0.15,max(0,now-previousTime));previousTime=now
        guard !paused, !finished, !isShowingVictoryChoice else {hud.needsDisplay=true;return}
        logicalAccumulator += dt
        while logicalAccumulator >= Self.logicalStep {
            logicalAccumulator -= Self.logicalStep
            simulationTick()
            if finished || isShowingVictoryChoice {break}
        }
        projectiles.interpolate(alpha:logicalAccumulator/Self.logicalStep)
        updateHUD()
    }
    func simulationTick() {
        guard !isShowingVictoryChoice else { return }
        let dt=Self.logicalStep
        elapsed += dt;logicalTick += 1
        hud.damageFlash=max(0,hud.damageFlash-CGFloat(dt)*8)
        defer { originalClock.advance();updateMuzzleFeedback() }
        syncGunPose()
        training?.advance(in:self)
        if combat.health>0 {
            if assets.gameID=="2000" {
                updateOriginal2000AI()
                for enemy in enemies {updateEnemyAI(enemy,deferSharedPhases:false)}
            } else {updateOriginal2002AI()}
            syncSupplyNodes()
            flushPendingInfantryGrenades()
            updateOriginalSharedProjectiles()
            updateEnemyOrdnance()
            if let tick=barrage?.step(random15:{Int(self.random.next())}) {
                if tick.playApproachSound {playSound("Bombfall")}
                if let hit=tick.impact {
                    let x=CGFloat(hit.x)*0.01,z=CGFloat(hit.z)*0.01
                    applySplash(at:SCNVector3(x,assets.height(x:x,z:z)+0.1,z),weapon:.artillery)
                    playOriginalGroundImpactSound(weapon:.artillery,at:.init(Double(hit.x),0,Double(hit.z)))
                }
                if barrage?.remainingTicks==0 {barrage=nil}
            }
            if assets.gameID=="2002" {updateFlares()}
            consumeBurningPhase()
            advanceOriginal2002ObjectTransforms()
            syncWeaponModel()
            let action=weapons.step(triggerDown:shooting && !inputLocked,weaponReady:!inputLocked && weaponPresentation.pose.ready)
            weaponPresentation.tick(acceptedFire:action)
            if let action {fire(action)} else if weapons.selected == .cannon {syncGunPose()}
            emitPendingEnemyOrdnance()
            weapons.prepareMissileSlots()
        }
        if let outcome=campaign?.tickOutcome(health:combat.health,ammunitionExhausted:!isInvulnerable && weapons.allCombatAmmoEmpty,
                                             wallTimeDelta:dt,immediateVictory:assets.isDepthline) {
            combat.health=outcome.health;inputLocked=outcome.inputLocked
            if inputLocked {shooting=false}
            if let transition=outcome.transition {
                switch transition {
                case .nextLevel(let next,let bonus):
                    completeMission(nextLevel: next, bonus: bonus)
                case .defeat:
                    finished=true
                    if !resultRecorded {resultRecorded=true;onRunEnded?(level+1,combat.score,runID)}
                }
                return
            }
        }
        for event in campaign?.tick() ?? [] {spawn(event)}
        consumeSupplyEvents(supply2000?.updateScheduler() ?? [])
        consumeSupply2002Events(supply2002?.updateScheduler() ?? [])
        syncSupplyNodes();syncSupply2002Nodes()
        effects.tick(cameraEuler:camera.eulerAngles,night:night)
        fragments.tick()
        updateOriginalEngineSounds()
    }
    func updateOriginal2000AI() {
        guard let ai=original2000AI else {return}
        let events=ai.tick(terrainHeight:{[assets] x,z in Double(assets.pointHeight(x:CGFloat(x)*0.01,z:CGFloat(z)*0.01))*100},viewPitchDegrees:Double(camera.eulerAngles.x*180 / .pi),random:{self.random.next()},soundEnabled:settings.soundEnabled,
            hoverPhasesDegrees:originalClock.hoverPhasesDegrees,smokeTick:globalAITick%4==0,
            terrainBilinearHeight:{[assets] x,z in Double(assets.height(x:CGFloat(x)*0.01,z:CGFloat(z)*0.01))*100},
            betweenGroundAndHelicopters:{self.updateOriginal2000Aircraft()},
            betweenHelicoptersAndInfantry:{self.consumeSupplyEvents(self.supply2000?.updateAI(random:{self.random.next()},terrainHeight:{[assets=self.assets] x,z in
                Float(assets.pointHeight(x:CGFloat(x)*0.01,z:CGFloat(z)*0.01))*100
            },smokeTick:self.globalAITick%2==0) ?? [])},
            onCrashVisual:{self.consumeOriginal2000CrashVisual($0,$1,$2,$3)})
        for event in events {
            switch event {
            case .defenseChanged(let amount):combat.health=max(0,combat.health+amount)
            case .forceAndScore(let index,let force,let score):campaign?.resolveForce(sourceIndex:index,amount:Double(-force));combat.score+=score
            case .grenade(let shot):pendingGrenades.append(shot)
            case .rifleFlash(_,_,let p):playSound("Rifle");effects.emit(.muzzleFlash,at:p)
            case .playerHurtVoice(let index):playOriginalPlayerBulletHitSound(bucket:index)
            case .soldierRemoved:break
            case .tankShell(let shot):pendingOrdnance.append((.init(version:.beach2000,kind:.shell,position:shot.position,velocity:shot.velocity),nil,nil))
            case .vehicleRemoved(let index,_):
                campaign?.enemyRemoved(sourceIndex:index,forceRemoved:0)
            case .explosion(_,let p,_):explode(SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01))
            case .smoke(_,let p):effects.emit(.blackSmoke,at:p)
            }
        }
        assets.graphics.updateWakes(ai.boats)
        for boat in ai.boats where boat.visible {
            let enemy:Enemy
            if let existing=enemies.first(where:{$0.aggregateBoatSlot==boat.slot}) {enemy=existing}
            else {
                enemy=Enemy(node:assets.model(boat.hasInfantry ? "BARGE":"BARGE_VEHICLE"),type:"BARGE",flying:false)
                enemy.aggregateBoatSlot=boat.slot;enemy.slot=boat.slot;enemy.hp=1;enemy.sourceIndex=boat.sourceIndex;enemy.force=0
                enemy.cargoFamily=boat.hasInfantry ? "infantry":"vehicle";enemies.append(enemy);scene.rootNode.addChildNode(enemy.node)
            }
            let p=boat.position;enemy.node.position=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
            enemy.node.eulerAngles.y=CGFloat(boat.yawDegrees * .pi/180);enemy.aiState=boat.state
            enemy.node.enumerateChildNodes { n,_ in if (n.name ?? "").lowercased().contains("door") || (n.name ?? "").lowercased().contains("ramp") {n.eulerAngles.x=CGFloat(boat.rampPitchDegrees * .pi/180)} }
        }
        func vehicleNode(id:Int,type:String,slot:Int,index:Int,hp:Int,state:Int,position:SIMD3<Double>,angles:SIMD3<Double>,turret:Double,barrel:Double,ramp:Double,rotor:Double=0) {
            let enemy:Enemy
            if let existing=enemies.first(where:{$0.aggregateVehicleID==id}) {enemy=existing}
            else {
                enemy=Enemy(node:assets.model(type),type:type,flying:type=="CH53")
                enemy.aggregateVehicleID=id;enemy.slot=slot;enemy.sourceIndex=index
                enemies.append(enemy);scene.rootNode.addChildNode(enemy.node)
            }
            enemy.hp=hp;enemy.aiState=state
            enemy.node.position=SCNVector3(position.x*0.01,position.y*0.01,position.z*0.01)
            enemy.node.eulerAngles=SCNVector3(angles.x * .pi/180,angles.y * .pi/180,angles.z * .pi/180)
            enemy.node.enumerateChildNodes {n,_ in
                let name=(n.name ?? "").lowercased()
                // BH2000 calls hull, turret and gun all Tank1. Original links
                //37->43->49 distinguish the two articulated template children.
                let tankTurret=type=="TANK" && name=="tank1" && n.parent === enemy.node
                let tankBarrel=type=="TANK" && name=="tank1" && n.parent?.parent === enemy.node
                if name.contains("turret") || tankTurret {n.eulerAngles.y=CGFloat(turret * .pi/180)}
                if name.contains("barrel") || name.contains("tgun") || tankBarrel {n.eulerAngles.x=CGFloat(barrel * .pi/180)}
                if name.contains("door") || name.contains("ramp") {
                    let pitch = assets.isDepthline && type.hasPrefix("APC") ? ramp * (105.0 / 90.0) : ramp
                    n.eulerAngles.x=CGFloat(pitch * .pi/180)
                }
                if name.contains("rotor") {n.eulerAngles.y += CGFloat(rotor * .pi/180)}
                if type=="CH53" && name=="prop" {n.eulerAngles.x -= 40 * .pi/180}
            }
        }
        for v in ai.tanks+ai.apcs where v.visible {vehicleNode(id:v.objectID,type:v.kind == .tank ? "TANK":"APC1",slot:v.slot,index:v.sourceIndex,hp:v.hp,state:v.state,position:v.position,angles:v.eulerDegrees,turret:v.turretYawDegrees,barrel:v.barrelPitchDegrees,ramp:v.rampPitchDegrees)}
        for v in ai.helicopters where v.visible {vehicleNode(id:v.objectID,type:"CH53",slot:v.slot,index:v.sourceIndex,hp:v.hp,state:v.state,position:v.position,angles:v.eulerDegrees,turret:0,barrel:0,ramp:v.rampPitchDegrees,rotor:v.rotorDegreesPerTick)}
        for soldier in ai.soldiers where soldier.visible {
            let enemy:Enemy
            if let existing=enemies.first(where:{$0.aggregateSoldierSlot==soldier.slot}) {enemy=existing}
            else {
                enemy=Enemy(node:assets.model("INFANTRY"),type:"INFANTRY",flying:false)
                enemy.aggregateSoldierSlot=soldier.slot;enemy.slot=soldier.slot;enemy.sourceIndex=soldier.sourceIndex;enemy.force=1
                enemies.append(enemy);scene.rootNode.addChildNode(enemy.node)
            }
            let p=soldier.position;enemy.node.position=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
            enemy.aiState=soldier.state;enemy.node.scale=SCNVector3(soldier.scale,soldier.scale,soldier.scale)
            let flame=soldier.burningVisual
            syncBurningVisual(id:139+soldier.slot,position:flame?.position,
                scale:.init(flame?.horizontalScale ?? 0.25,flame?.verticalScale ?? 0.5))
            if !RemasteredInfantry.update(enemy.node,gameID:assets.gameID,state:soldier.state,frame:soldier.frame,direction:.init(soldier.direction.x,0,soldier.direction.y)), enemy.spritePath != soldier.texturePath {
                enemy.spritePath=soldier.texturePath
                enemy.node.enumerateChildNodes { n,_ in n.geometry?.firstMaterial?.diffuse.contents=assets.frameImage(soldier.texturePath) }
            }
        }
        enemies.removeAll { enemy in
            let activeVehicles=Set((ai.tanks+ai.apcs).filter(\.visible).map(\.objectID)+ai.helicopters.filter(\.visible).map(\.objectID))
            let hidden=enemy.aggregateBoatSlot.map {!ai.boats[$0].visible} ?? enemy.aggregateSoldierSlot.map {!ai.soldiers[$0].visible} ?? enemy.aggregateVehicleID.map {!activeVehicles.contains($0)} ?? false
            if hidden {enemy.node.removeFromParentNode()};return hidden
        }
    }
    func updateOriginal2000Aircraft() {
        guard let ai=aircraft2000 else {return}
        for event in ai.tick(terrainHeight:{[assets] x,z in Double(assets.pointHeight(x:CGFloat(x)*0.01,z:CGFloat(z)*0.01))*100},random:{self.random.next()},
                             hoverPhasesDegrees:originalClock.hoverPhasesDegrees,smokeEveryTwoTicks:globalAITick%2==0,smokeEveryFourTicks:globalAITick%4==0,
                             onCrashVisual:{self.consumeOriginal2000CrashVisual($0,$1,$2,$3)}) {
            switch event {
            case .forceAndScore(let index,let force,let score):campaign?.resolveForce(sourceIndex:index,amount:Double(-force));combat.score+=score
            case .defenseChanged(let amount):combat.health=max(0,combat.health+amount)
            case .removed(let index,_):
                campaign?.enemyRemoved(sourceIndex:index,forceRemoved:0)
            case .explosion(_,let p,_):explode(SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01))
            case .smoke(_,let p):effects.emit(.blackSmoke,at:p)
            }
        }
        syncOriginal2000Aircraft(advanceRotors:true)
    }
    func syncOriginal2000Aircraft(advanceRotors:Bool=false) {
        guard let ai=aircraft2000 else {return}
        let planes=ai.jets+ai.bombers+ai.cobras
        for plane in planes where plane.visible {
            let enemy:Enemy
            if let existing=enemies.first(where:{$0.aggregateAircraftID==plane.objectID}) {enemy=existing}
            else {
                let type=plane.kind == .jet ? "JET":plane.kind == .bomber ? "BOMBER":"COBRA"
                enemy=Enemy(node:assets.model(type),type:type,flying:true)
                enemy.aggregateAircraftID=plane.objectID;enemy.slot=plane.slot;enemy.sourceIndex=plane.sourceIndex
                enemy.required=plane.kind != .bomber;enemy.force=0
                enemies.append(enemy);scene.rootNode.addChildNode(enemy.node)
            }
            enemy.hp=plane.hp;enemy.aiState=plane.state
            let p=plane.position,r=plane.eulerDegrees
            enemy.node.position=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
            enemy.node.eulerAngles=SCNVector3(r.x * .pi/180,r.y * .pi/180,r.z * .pi/180)
            if advanceRotors {enemy.node.enumerateChildNodes {n,_ in
                if (n.name ?? "").contains("Rotor") {n.eulerAngles.y += CGFloat(plane.rotorDegreesPerTick * .pi/180)}
                if n.name=="Prop" {n.eulerAngles.x -= 40 * .pi/180}
            }}
        }
        let active=Set(planes.filter(\.visible).map(\.objectID))
        enemies.removeAll {enemy in
            guard let id=enemy.aggregateAircraftID,!active.contains(id) else {return false}
            enemy.node.removeFromParentNode();return true
        }
    }
    func updateBombers() {
        guard assets.gameID=="2002" else {return}
        if pendingBomberSupport {
            pendingBomberSupport=false;bomberHeading=Original2002BomberAI.supportHeading(random15:{Int(self.random.next())})
            bombers.forEach {$0.activate()}
        }
        for (slot,ai) in bombers.enumerated() {
            let update=ai.step(groupHeadingDegrees:bomberHeading,random15:{Int(self.random.next())})
            let existing=enemies.first {$0.type=="BOMBER" && $0.slot==slot}
            guard update.active else {existing?.node.removeFromParentNode();if let existing {enemies.removeAll {$0===existing}};continue}
            let enemy:Enemy
            if let existing {enemy=existing}
            else {
                enemy=Enemy(node:assets.model("BOMBER"),type:"BOMBER",flying:true)
                enemy.slot=slot;enemy.sourceIndex=bomberSources[slot] ?? -1;enemy.hp=4;enemy.force=0;enemy.required=false
                enemies.append(enemy);scene.rootNode.addChildNode(enemy.node)
            }
            let p=update.position,r=update.eulerDegrees
            enemy.node.position=SCNVector3(p.x*0.01,p.y*0.01,p.z*0.01)
            enemy.node.eulerAngles=SCNVector3(r.x * .pi/180,r.y * .pi/180,r.z * .pi/180);enemy.aiState=update.state
            if update.dropBomb {
                pendingBomberDrops.append(update)
            }
        }
    }
    func updateEnemyOrdnance() {
        enemyOrdnance.step(ground:{[assets] x,z in Double(assets.pointHeight(x:CGFloat(x)*0.01,z:CGFloat(z)*0.01))*100},waterAt:assets.waterContact,infantry:{ [self] in
            enemies.filter {$0.type=="INFANTRY" && !$0.node.isHidden && $0.aiState>1 && $0.aiState<42}.sorted {$0.slot<$1.slot}.map {e in
                let p=e.node.position;return SIMD3<Double>(Double(p.x*100),Double(p.y*100),Double(p.z*100))
            }
        },includeShared:false,onUnitHit:{ [self] kind,a,b in
            hitOriginalEnemyOrdnanceUnits(kind:kind,previous:a,position:b)
        },onImpact:{ [self] tick,kind in
            applyOriginalEnemyOrdnancePhase(tick,kind:kind)
        })
    }
    func emitPendingEnemyOrdnance() {
        emitOriginal2002FireFlags()
        for (state,model,slot) in pendingOrdnance {
            enemyOrdnance.spawn(state,model:model.map {assets.model($0)},slot:slot)
            if state.kind == .shell {playSound("CannonFar")}
        }
        for shot in pendingEnemyShots {
            let state=OriginalEnemyOrdnanceState(shot,version:version)
            let mesh:SCNNode?=state.kind == .bomb ? assets.model("BOMBS") : [.airRocket,.groundRocket].contains(state.kind) ? assets.model(state.kind == .airRocket && assets.gameID=="2002" ? "ROCKETS":"MISSILE"):nil
            enemyOrdnance.spawn(state,model:mesh)
            if state.kind == .shell {playSound("CannonFar")}
        }
        // Original aircraft launch flags are consumed after pre-existing hits.
        // Shared bullet allocation belongs to the renderer; claiming here too
        // would skip every other slot. Rocket/bomb rings are owned by this AI.
        for shot in aircraft2000?.takeShots(random:{self.random.next()}) ?? [] {
            let kind:OriginalEnemyOrdnanceKind=shot.kind == .bullet ? .bullet:shot.kind == .airRocket ? .airRocket:.bomb
            let state=OriginalEnemyOrdnanceState(version:.beach2000,kind:kind,position:shot.origin,velocity:shot.velocity,remainingTicks:shot.lifetimeTicks,bombHorizontalSpeed:shot.bombHorizontalSpeed,bombForward:shot.bombForward)
            let mesh:SCNNode?=kind == .bomb ? assets.model("Bomb1"):kind == .airRocket ? assets.model("Rocket1"):nil
            enemyOrdnance.spawn(state,model:mesh,slot:shot.poolIndex)
        }
        syncOriginal2000Aircraft()
        for shot in pendingGrenades {enemyOrdnance.spawn(.init(version:version,kind:.grenade,position:shot.position,velocity:shot.velocity),model:assets.model("Grenades"),slot:shot.poolIndex)}
        pendingEnemyShots=[];pendingGrenades=[];pendingOrdnance=[];pendingEnemyEmitters=[];pendingBomberDrops=[]
    }
    func missileTargets()->[OriginalMissileTarget] {
        var result:[OriginalMissileTarget]=[]
        for enemy in enemies where enemy.flying && enemy.hp>0 {
            let base=assets.gameID=="2000" ? ["BOMBER":73,"JET":76,"COBRA":88,"CH53":106,"C130":207][enemy.type]
                : ["JET":117,"BOMBER":133,"COBRA":142,"CH53":178,"C130":210][enemy.type]
            if let base {let p=enemy.node.position;result.append(.init(originalObjectIndex:base+enemy.slot,position:.init(x:Float(p.x*100),y:Float(p.y*100),z:Float(p.z*100)),active:true))}
        }
        if let p=supply2000?.plane,p.visible && p.hp>0 {result.append(.init(originalObjectIndex:207,position:.init(x:p.position.x,y:p.position.y,z:p.position.z),active:true))}
        for p in supply2002?.planes ?? [] where p.visible && p.hp>0 {result.append(.init(originalObjectIndex:p.objectID,position:.init(x:p.position.x,y:p.position.y,z:p.position.z),active:true))}
        return result
    }
    func updateHUD() {
        assets.graphics.update(time:elapsed)
        for enemy in enemies {RemasteredAircraft.updateScrews(on:enemy.node,type:enemy.type,tick:logicalTick)}
        syncWeaponModel()
        updateOriginalHUD()
        refreshBattleOverlays()
    }
    func preview() {
        camera.eulerAngles=SCNVector3(-0.04,0,0)
        bulletEffects.clear()
        enemies.forEach {$0.node.removeFromParentNode()};enemies=[]
        spawn(Wave(type:"COBRA",declaredDelay:0,time:0),index:0)
        spawn(Wave(type:"APC1",declaredDelay:0,time:0),index:2)
        spawn(Wave(type:"TANK",declaredDelay:0,time:0),index:4)
        enemies[0].node.position=SCNVector3(-14,13,-49)
        enemies[1].node.position=SCNVector3(-3,2,-37)
        enemies[2].node.position=SCNVector3(17,3,-51)
        for e in enemies where !e.flying {e.node.position.y=assets.height(x:e.node.position.x,z:e.node.position.z)}
        paused=true;hud.paused=false;updateHUD();hud.paused=false
        if arguments.contains("--effects-preview") {
            let muzzle=camera.convertPosition(SCNVector3(0.13,-0.38,-1.2),to:nil)
            for (offset,age) in [(CGFloat(-2),0.025),(CGFloat(0),0.065),(CGFloat(2),0.11)] {
                bulletEffects.spawn(from:muzzle,to:camera.convertPosition(SCNVector3(offset,0,-40),to:nil),weapon:0,parent:scene.rootNode)
                if let shot=bulletEffects.shots.last {shot.flight.advance(age);shot.node.position=shot.flight.position}
            }
        }
    }
    func integrationTest() throws {
        try testBulletEffects(textureURL: assets.root.appendingPathComponent("textures/Glow.png"))
        try testOriginalProjectiles(textureURL:assets.root.appendingPathComponent("textures/Glow.png"))
        func check(_ good:Bool,_ message:String) throws {
            if !good {throw NSError(domain:"IntegrationTest",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
        }
        if let window = view.window {
            let r = view.visibleRect
            func screenPoint(_ p: NSPoint) -> NSPoint { window.convertPoint(toScreen: view.convert(p, to: nil)) }
            try check(view.containsScreenPoint(screenPoint(NSPoint(x:r.midX,y:r.midY))), "content center allows capture")
            for p in [NSPoint(x:r.minX-1,y:r.midY), NSPoint(x:r.maxX+1,y:r.midY),
                      NSPoint(x:r.midX,y:r.minY-1), NSPoint(x:r.midX,y:r.maxY+1)] {
                try check(!view.containsScreenPoint(screenPoint(p)), "outside content rejects capture")
            }
            let contentTop = screenPoint(NSPoint(x:r.midX,y:r.maxY)).y
            let titlebar = NSPoint(x:window.frame.midX,y:(contentTop+window.frame.maxY)/2)
            try check(window.frame.maxY > contentTop && !view.containsScreenPoint(titlebar), "titlebar rejects capture")
            print("PASS: live window capture bounds include content center and exclude all four outer edges and titlebar")
        } else {
            try check(false, "capture geometry test requires a real window")
        }
        restart();camera.eulerAngles=SCNVector3(0,0,0)
        enemies.forEach {$0.node.removeFromParentNode()};enemies=[]
        let target=Enemy(node:assets.model("COBRA"),type:"COBRA",flying:true)
        target.node.position=SCNVector3(0,8,-40)
        scene.rootNode.addChildNode(target.node);enemies=[target]
        weapons.ammo.cannon=2;weapons.cycleWeapon()
        guard let action=weapons.step(triggerDown:true) else {throw NSError(domain:"IntegrationTest",code:2)}
        weaponPresentation.tick(acceptedFire:action)
        fire(action)
        try check(enemies.count==1 && combat.hits==0 && projectiles.ballisticCount==1,"launch cannot cause immediate damage")
        for _ in 0..<15 {updateOriginalSharedProjectiles()}
        // ShapeData places the Cobra body below its authored origin. At Y800,
        // a horizontal cannon shot correctly passes above the uppermost panel.
        try check(enemies.count==1 && combat.hits==0,"cannon passes above original Cobra at Y800 without a false hit")
        _=projectiles.clear()
        target.node.position=SCNVector3(0,9,-40)
        for _ in 0..<30 {_=weapons.step(triggerDown:false);weaponPresentation.tick(acceptedFire:nil)}
        guard let hitAction=weapons.step(triggerDown:true) else {throw NSError(domain:"IntegrationTest",code:2)}
        weaponPresentation.tick(acceptedFire:hitAction);fire(hitAction)
        try check(combat.hits==0,"second launch still waits for flight")
        for _ in 0..<15 {updateOriginalSharedProjectiles()}
        try check(enemies.isEmpty && combat.hits==1,"flying cannon shell hits original Cobra collision polygons")
        try check(fragments.activeCount>0 && fragments.unsupportedRequests.isEmpty,"source Cobra destruction emits decoded polygon fragments")
        try check(weapons.ammo.cannon==0,"two accepted cannon shots consume exactly two rounds")
        togglePause();let count=combat.shots;fire(action)
        try check(combat.shots==count,"pause prevents projectile spawn")
        togglePause()
        weapons.ammo.missile=3;weapons.prepareMissileSlots();launchMissile();launchMissile();launchMissile()
        try check(projectiles.missileCount==2 && weapons.ammo.missile==1,"only two airborne missiles consume ammunition")
        restart();try check(level==0 && combat.health==100 && combat.score==0 && projectiles.ballisticCount==0 && projectiles.missileCount==0,"restart clears projectile state")
        try check(weapons.ammo.handgun==15,"original finite handgun reserve")
        if assets.gameID=="2000" {
            try check(supply2000 != nil,"2000 invisible C130 declaration still owns supply lifecycle")
        } else {try check(supply2002?.planes.isEmpty==true,"2002 first level does not invent a supply plane")}
        print("PASS: shot travel before source-polygon hit, ammo, pause, two missile slots, finite handgun, independent supply rules and restart")

    }
}

final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    private var displayedLanguage: DepthlineLanguage?
    var window:NSWindow!
    var game:Game?
    var launcher:LauncherView?
    var lastGameID: String? = arguments.contains("--game") ? selectedGameID : nil
    let store = CampaignStore(directory: arguments.contains(where: { $0.hasSuffix("-test") || $0 == "--screenshot" })
        ? FileManager.default.temporaryDirectory.appendingPathComponent("Depthline-Test-\(UUID().uuidString)") : nil)
    func applicationDidFinishLaunching(_ notification:Notification) {
        DLoc.language = store.settings.language
        let frame=NSRect(x:0,y:0,width:1280,height:800)
        window=NSWindow(contentRect:frame,styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title=DepthlineIdentity.title
        window.minSize=NSSize(width:1000,height:650);window.delegate=self;window.acceptsMouseMovedEvents=true
        window.collectionBehavior.insert(.fullScreenPrimary)
        InteractiveInputTrace.record("session-start", ["store": store.directory.path])
        showLauncher()
        refreshApplicationLanguage()
        NotificationCenter.default.addObserver(self, selector: #selector(systemLanguageChanged), name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        window.center();window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        if arguments.contains("--menu-test") {
            DispatchQueue.main.async { [self] in
                do { try runDepthlineMenuValidation(); NSApp.terminate(nil) }
                catch { fputs("Menu validation failed: \(error)\n",stderr); exit(9) }
            }
            return
        }
        if arguments.contains("--window-profile-test") {
            do {try runWindowProfile()} catch {fputs("Window profile setup failed: \(error)\n",stderr);exit(8)}
            return
        }
        if arguments.contains("--depthline-test") {
            DispatchQueue.main.async { [self] in
                do {try runDepthlineValidation();NSApp.terminate(nil)}
                catch {fputs("Depthline validation failed: \(error)\n",stderr);exit(7)}
            }
            return
        }
        if arguments.contains("--campaign-test") {
            DispatchQueue.main.async { [self] in
                do {try runCampaignValidation();NSApp.terminate(nil)}
                catch {fputs("Campaign test failed: \(error)\n",stderr);exit(4)}
            }
            return
        }
        if arguments.contains("--graphics-test") {
            do {try startGame(selectedGameID);game?.timer?.invalidate();game?.timer=nil}
            catch {fputs("Graphics test setup failed: \(error)\n",stderr);exit(6)}
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { [self] in
                do {
                    let index=arguments.firstIndex(of:"--graphics-output")
                    let folder=index.flatMap {$0+1<arguments.count ? arguments[$0+1]:nil} ?? "build/graphics-validation"
                    try game?.validateGraphicsDynamics(output:URL(fileURLWithPath:folder))
                    NSApp.terminate(nil)
                } catch {fputs("Graphics test failed: \(error)\n",stderr);exit(6)}
            }
            return
        }
        if arguments.contains("--collection-test") {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { [self] in
                do {
                    for id in ["2000","2002"] {
                        try startGame(id)
                        guard let current = game, current.assets.gameID == id else { throw NSError(domain:"CollectionTest",code:1) }
                        try current.integrationTest()
                        try current.burningIntegrationTest()
                        try current.aiPhaseIntegrationTest()
                        let oldTimer = current.timer
                        showLauncher()
                        guard game == nil, launcher?.selectedGameID == id, oldTimer?.isValid == false, !current.view.mouseCapture.isCaptured else { throw NSError(domain:"CollectionTest",code:2) }
                    }
                    print("PASS: both independent games start, validate and return to the library with timer/cursor cleanup")
                    NSApp.terminate(nil)
                } catch { fputs("Collection test failed: \(error)\n",stderr); exit(3) }
            }
            return
        }
        if arguments.contains("--game") || arguments.contains("--integration-test") || arguments.contains("--screenshot") {
            do { try startGame(selectedGameID) } catch { report(error); return }
        }
        if arguments.contains("--integration-test") {
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { [self] in
                do {try game?.integrationTest();game?.preview();if !arguments.contains("--screenshot") {NSApp.terminate(nil)}} catch {fputs("Integration test failed: \(error)\n",stderr);exit(3)}
            }
        }
        if let i=arguments.firstIndex(of:"--screenshot"),i+1<arguments.count {
            do {try game?.prepareOriginalCapture(arguments:arguments)} catch {fputs("Capture preparation failed: \(error)\n",stderr);exit(5)}
            DispatchQueue.main.asyncAfter(deadline:.now()+2) { [self] in
                guard let game else { return }
                do {
                    let data=try game.captureNativePixels(options:NativeCaptureOptions(arguments:arguments))
                    try data.write(to:URL(fileURLWithPath:arguments[i+1]));print("Screenshot: \(arguments[i+1])")
                } catch {fputs("Capture failed: \(error)\n",stderr);exit(5)}
                NSApp.terminate(nil)
            }
        }
    }
    @objc func showLauncher() {
        if let selected = launcher?.selectedGameID { lastGameID = selected }
        game?.stop(); game=nil
        window.title=DepthlineIdentity.title
        let root = Bundle.main.resourceURL!.appendingPathComponent("launcher-assets")
        let view = LauncherView(frame:window.contentView?.bounds ?? NSRect(x:0,y:0,width:1280,height:800), resourceRoot:root,store:store,
            onContinue: { [weak self] id, checkpoint in
                do { try self?.startGame(id,checkpoint:checkpoint) } catch { self?.report(error) }
            },onSettingsChanged: { [weak self] _ in self?.refreshApplicationLanguage() }) { [weak self] id in
            do { try self?.startGame(id) } catch { self?.report(error) }
        }
        if let lastGameID { view.selectGame(lastGameID) }
        launcher=view; window.contentView=view; window.makeFirstResponder(view)
    }
    func startGame(_ id: String, checkpoint: CampaignStore.Checkpoint? = nil) throws {
        _ = try NativeCaptureOptions(arguments:arguments)
        let isTraining = id == DepthlineIdentity.trainingID
        guard isTraining || CampaignStore.supportedGames.contains(id) else { throw CampaignStore.StoreError.invalidGame }
        let graphics = NativeGraphics(antialiasingSamples:store.settings.antialiasingSamples)
        try graphics.validateResources()
        let assets=try Assets(root:gameResourceRoot(id),graphics:graphics)
        game?.stop()
        let backend: CursorCaptureBackend = arguments.contains("--menu-test") ? MenuValidationCursor() : SystemCursorBackend()
        let current=try Game(assets:assets,frame:window.contentView?.bounds ?? NSRect(x:0,y:0,width:1280,height:800),
                             trainingMode:isTraining,cursorBackend:backend)
        current.onReturnToLauncher = { [weak self] in self?.showLauncher() }
        if isTraining {
            current.onEnterCoast = { [weak self, weak current] in
                guard let self, let current, self.game === current else { return }
                do { try self.startGame("2000", checkpoint: self.store.checkpoint(for: "2000")) }
                catch { self.report(error) }
            }
        }
        current.onOpenPauseSettings = { [weak self, weak current] in
            if let current { self?.showSettings(for: current) }
        }
        if isTraining {
            current.onSectorCompleted = { [weak self] in
                guard let self else { return }
                do { try self.store.markSectorCompleted(id) }
                catch { self.reportStorage(error) }
            }
        }
        current.settings=store.settings
        current.settings.graphicsQuality=graphics.quality
        current.onSettingsChanged = { [weak self] settings in
            do {try self?.store.updateSettings(settings)} catch {self?.reportStorage(error)}
        }
        if !isTraining {
            current.onCheckpoint = { [weak self,weak current] level, score in
                guard let self, let current else { return }
                let completesSector = current.pendingNextLevel == level && current.level + 1 == current.assets.levels.count
                do { try self.store.saveCheckpoint(gameID:id,level:level,score:score,playerName:self.store.playerName(for:id),
                                                   usedCheats:current.usedCheats,completesSector:completesSector) }
                catch { self.reportStorage(error) }
            }
            current.onRunEnded = { [weak self,weak current] level, score, runID in
                guard let self else { return }
                do { try self.store.recordScore(gameID:id,level:level,score:score,playerName:self.store.playerName(for:id),runID:runID,usedCheats:current?.usedCheats ?? false) }
                catch { self.reportStorage(error) }
            }
            current.restart(level:(checkpoint?.level ?? 1)-1,score:checkpoint?.score ?? 0,usedCheats:checkpoint?.usedCheats ?? false)
        }
        game=current; launcher=nil; lastGameID=id
        window.title="\(DepthlineIdentity.title) · \(DepthlineIdentity.sector(id))"
        window.contentView=current.view;window.makeFirstResponder(current.view)
        current.refreshBattleOverlays()
        current.captureForPlayIfFullscreen()
    }
    private func showSettings(for current: Game) {
        guard game === current, current.paused, window.contentView === current.view else { return }
        let settings = LauncherView(frame: current.view.bounds,
            resourceRoot: Bundle.main.resourceURL!.appendingPathComponent("launcher-assets"), store: store,
            onSettingsChanged: { [weak self, weak current] settings in
                guard let current else { return }
                current.settings = settings
                current.assets.graphics.setAntialiasing(samples: settings.antialiasingSamples, view: current.view)
                self?.refreshApplicationLanguage()
            }, onReturnToPause: { [weak self, weak current] in
                guard let self, let current, self.game === current else { return }
                self.window.contentView = current.view
                self.window.makeFirstResponder(current.view)
            }, onSubmitCheat: { [weak current] cheat in
                guard let current, current.paused else { return DLoc.text("请先暂停战斗。", "Pause the battle first.") }
                return current.applyDepthlineCheat(cheat)
            }, onStart: { _ in })
        window.contentView = settings
        settings.layoutSubtreeIfNeeded()
        window.makeFirstResponder(settings)
    }

    func report(_ error: Error) {
        let alert=NSAlert();alert.messageText=DLoc.text("游戏资源加载失败", "Could not load the game");alert.informativeText=error.localizedDescription;alert.runModal()
    }
    func reportStorage(_ error: Error) {
        fputs("Checkpoint storage: \(error)\n",stderr)
        game?.hud.message=DLoc.text("存档未保存：\(error.localizedDescription)", "Could not save: \(error.localizedDescription)")
    }
    @objc private func systemLanguageChanged() {
        guard DLoc.language == .system else { return }
        DLoc.refreshSystemPreference()
        refreshApplicationLanguage()
    }
    private func refreshApplicationLanguage() {
        guard displayedLanguage != DLoc.resolvedLanguage else { return }
        displayedLanguage = DLoc.resolvedLanguage
        installMainMenu()
        if let game {
            window.title = DepthlineIdentity.title + " · " + DepthlineIdentity.sector(game.training == nil ? game.assets.gameID : DepthlineIdentity.trainingID)
            game.pauseMenu.refreshLanguage()
            game.entryPrompt.refreshLanguage()
            game.hud.refreshLanguage()
            game.updateHUD()
        } else {
            window.title = DepthlineIdentity.title
        }
        (window.contentView as? LauncherView)?.refreshLanguage()
    }
    private func installMainMenu() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            item.title = title
            menu.addItem(item)
            let group = NSMenu(title: title)
            item.submenu = group
            return group
        }
        let app = submenu(DepthlineIdentity.title)
        let library = app.addItem(withTitle: DLoc.text("返回游戏选择", "Return to Game Selection"), action: #selector(showLauncher), keyEquivalent: "l")
        library.target = self
        app.addItem(.separator())
        app.addItem(withTitle: DLoc.text("退出纵深防线", "Quit Depthline"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = submenu(DLoc.text("编辑", "Edit"))
        edit.addItem(withTitle: DLoc.text("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: DLoc.text("复制", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: DLoc.text("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: DLoc.text("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let view = submenu(DLoc.text("显示", "View"))
        let fullscreen = view.addItem(withTitle: DLoc.text("切换全屏", "Toggle Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.control, .command]
        NSApp.mainMenu = menu
    }
    func applicationWillResignActive(_ notification: Notification) { game?.view.mouseCapture.release() }
    func applicationWillTerminate(_ notification: Notification) { game?.view.mouseCapture.release() }
    func windowDidResignKey(_ notification: Notification) { game?.view.mouseCapture.release() }
    func windowWillClose(_ notification: Notification) { game?.view.mouseCapture.release() }
    func windowWillMiniaturize(_ notification: Notification) { game?.view.mouseCapture.release() }
    func windowWillEnterFullScreen(_ notification: Notification) {
        game?.view.mouseCapture.release()
        InteractiveInputTrace.record("fullscreen-will-enter")
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        game?.view.mouseCapture.release()
        InteractiveInputTrace.record("fullscreen-will-exit")
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        game?.refreshBattleOverlays()
        game?.captureForPlayIfFullscreen()
        InteractiveInputTrace.record("fullscreen-entered", ["frame": NSStringFromRect(window.frame)])
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        game?.refreshBattleOverlays()
        InteractiveInputTrace.record("fullscreen-exited", ["frame": NSStringFromRect(window.frame)])
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
}

func selfTest(_ assets:Assets) throws {
    try testEnemyMotion()
    try testBeach2000Motion()
    try testBulletFlight()
    try mouseCaptureSelfTest()
    let groups=assets.objects.flatMap {$0["groups"] as? [[String:Any]] ?? []}
    let vertices=groups.reduce(0) {$0 + arrayD($1["vertices"]).count/3}
    let triangles=groups.reduce(0) {$0 + (($1["indices"] as? [Int])?.count ?? 0)/3}
    guard vertices>1000,triangles>1000,assets.levels.count>=1 else {throw NSError(domain:"Test",code:1)}
    for group in groups {
        let count=arrayD(group["vertices"]).count/3
        guard (group["indices"] as? [Int] ?? []).allSatisfy({$0>=0 && $0<count}) else {throw NSError(domain:"Test",code:2)}
    }
    for (_,url) in assets.textures {guard FileManager.default.fileExists(atPath:url.path) else {throw NSError(domain:"Test",code:3,userInfo:[NSLocalizedDescriptionKey:url.path])}}
    let first=assets.waves(level:0)
    if assets.gameID == "2000" {
        guard first.count == 3, first.allSatisfy({$0.type=="BARGE"}), assets.levels.count == 60,
              assets.levels.first?["ammo"] as? [Int] == [150,0,0] else {throw NSError(domain:"Test",code:4)}
    } else {
        guard first.contains(where:{$0.type=="COBRA"}),first.contains(where:{$0.type=="APC1"}) else {throw NSError(domain:"Test",code:4)}
    }
    try originalTickOrderSelfTest()
    try testOriginalSharedProjectiles(textureURL:assets.root.appendingPathComponent("textures/Glow.png"))
    try testOriginalWeapons()
    try OriginalCollision.selfTest()
    try OriginalFlares.selfTest()
    try testOriginalDamage()
    try campaignStoreSelfTest()
    try originalCampaignSelfTest()
    try Beach2000Supply.runTests()
    try Beach2002Supply.runTests()
    try Original2000EnemyAI.runTests()
    try Original2000AircraftAI.runTests()
    try OriginalBurning.runTests()
    try OriginalSoundRenderer.runTests()
    try OriginalCombatSounds.runTests()
    try OriginalScenePresentation.runTests()
    try NativeMeshSanitizer.runTests()
    try testOriginalWeaponCompletion(objects:assets.objects,version:assets.gameID=="2000" ? .beach2000:.beach2002)
    try testRemasteredInfantry()
    try testRemasteredVehicles(objects:assets.objects,gameID:assets.gameID)
    try testRemasteredAircraft(objects:assets.objects,gameID:assets.gameID)
    try testRemasteredArsenal(objects:assets.objects,version:assets.gameID=="2000" ? .beach2000:.beach2002)
    try testRemasteredSupplies()
    try testRemasteredOrdnanceModels()
    try testOriginalWeaponRecoil()
    try testOriginalWeaponDeployment()
    try testGameWeaponPresentation(objects:assets.objects,version:assets.gameID=="2000" ? .beach2000:.beach2002)
    try testOriginalEffects(resource2000:gameResourceRoot("2000"),resource2002:gameResourceRoot("2002"))
    try testOriginalRocketFlames(resource2000:gameResourceRoot("2000"),resource2002:gameResourceRoot("2002"))
    try testOriginalFragments(resource2000:gameResourceRoot("2000"),resource2002:gameResourceRoot("2002"))
    print("PASS: \(assets.objects.count) objects, \(vertices) vertices, \(triangles) triangles, \(assets.textures.count) textures, \(assets.levels.count) levels")
    print("PASS: \(assets.gameID) mesh ranges, texture paths, original first-level declarations, ammo and health bounds")
    print("SCOPE: core gameplay checks; rendering is intentionally remastered; original pixel/replay equivalence is not required")
}

do {
    if arguments.contains("--mouse-self-test") { try mouseCaptureSelfTest(); exit(0) }
    if arguments.contains("--self-test") {try selfTest(Assets(root:resourceRoot));exit(0)}
    let app=NSApplication.shared;app.setActivationPolicy(.regular)
    let delegate=AppDelegate()
    app.delegate=delegate;app.run()
} catch {
    fputs("Depthline: \(error)\n",stderr);exit(1)
}
