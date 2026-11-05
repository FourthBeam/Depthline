import AppKit
import SceneKit

/// Bridges the original software/D3D image coordinates to SceneKit. The exported
/// mesh JSON predates the Metal probe and has V inverted; do not apply this to
/// SCNPlane sprites, whose generated UVs already use the image's top-left origin.
enum OriginalScenePresentation {
    static let horizontalFieldOfView = 2 * atan(0.5) * 180 / Double.pi

    static func configureMeshTexture(_ material: SCNMaterial) {
        var transform = SCNMatrix4Identity
        transform.m22 = -1
        transform.m42 = 1
        material.diffuse.contentsTransform = transform
    }

    /// The .rmap/.r24 image is a two-dimensional lookup indexed by the transformed
    /// vertex normal, not an environment cube/sphere map and not a lit gray base.
    /// 2000: parser 0x42658b, renderer 0x42f674. 2002: 0x425391, 0x42f081.
    static func configureReflection(_ material: SCNMaterial, image: NSImage, gameID: String) {
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.diffuse.contentsTransform = SCNMatrix4Identity
        material.reflective.contents = nil
        material.specular.contents = NSColor.black
        material.emission.contents = NSColor.black
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.diffuse.magnificationFilter = gameID == "2000" ? .nearest : .linear
        material.diffuse.minificationFilter = gameID == "2000" ? .nearest : .linear
        material.diffuse.mipFilter = .none
        let coordinates = gameID == "2000"
            ? "(rint(float2(n.x, -n.y) * 125.0) + 128.5) / 256.0"
            : "float2(0.5 + n.x * 0.5, 0.5 - n.y * 0.5)"
        material.shaderModifiers = [.geometry: """
        #pragma body
        float3 n = normalize((scn_node.normalTransform * float4(_geometry.normal, 0.0)).xyz);
        _geometry.texcoords[0] = \(coordinates);
        """]
    }

    static func configureSky(_ node: SCNNode) {
        func configure(_ part: SCNNode) {
            part.renderingOrder = -1000
            // Clone: asset materials are cached, so sky-only depth/fog settings
            // must not leak to a later object that reuses the same texture.
            part.geometry?.materials = part.geometry?.materials.map {
                let material = $0.copy() as! SCNMaterial
                material.lightingModel = .constant
                material.readsFromDepthBuffer = false
                material.writesToDepthBuffer = false
                // Border texels belong to neighboring sky panels. Clamping
                // prevents a linear sample at V=0/1 wrapping to the other pole.
                material.diffuse.wrapS = .clamp
                material.diffuse.wrapT = .clamp
                return material
            } ?? []
        }
        configure(node)
        node.enumerateChildNodes { part, _ in configure(part) }
    }

    /// Both originals project with focal length equal to the viewport width.
    /// 2000 uses (320,300), 2002 (320,240) at 640×480. Preserve the original
    /// horizontal coverage on wider Mac windows; the originals have no 16:10 mode.
    static func projection(gameID: String, size: CGSize, near: Double = 0.1,
                           far: Double = 327) -> SCNMatrix4 {
        let aspect = max(Double(size.width), 1) / max(Double(size.height), 1)
        var result = SCNMatrix4Identity
        result.m11 = 2
        result.m22 = CGFloat(2 * aspect)
        result.m32 = gameID == "2000" ? 0.25 : 0
        result.m33 = CGFloat(-(far + near) / (far - near))
        result.m34 = -1
        result.m43 = CGFloat(-2 * far * near / (far - near))
        result.m44 = 0
        return result
    }

    static func configureCamera(_ camera: SCNCamera, gameID: String, size: CGSize) {
        camera.projectionDirection = .horizontal
        camera.fieldOfView = CGFloat(horizontalFieldOfView)
        camera.zNear = 0.1
        camera.zFar = 327
        camera.projectionTransform = projection(gameID: gameID, size: size)
    }

    static func runTests() throws {
        func require(_ test: Bool, _ message: String) throws {
            if !test { throw NSError(domain: "OriginalScenePresentation", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let old = projection(gameID: "2000", size: CGSize(width: 640, height: 480))
        let new = projection(gameID: "2002", size: CGSize(width: 640, height: 480))
        // A point on the view axis is Y300 in the old game, Y240 in the new.
        try require(abs((1 + old.m32) * 240 - 300) < 0.0001, "2000 principal point")
        try require(abs((1 + new.m32) * 240 - 240) < 0.0001, "2002 principal point")
        // Original x=100,z=-1000 -> center+640*(100/1000)=384.
        try require(abs((1 + old.m11 * 0.1) * 320 - 384) < 0.0001, "original focal length")
        try require(abs(horizontalFieldOfView - 53.13010235415598) < 0.0000001, "FOV")
        let material = SCNMaterial()
        configureMeshTexture(material)
        try require(material.diffuse.contentsTransform.m22 == -1 &&
                    material.diffuse.contentsTransform.m42 == 1, "exported UV correction")
    }
}
