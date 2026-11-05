import SceneKit
import simd

/// World-space height of the rendered land in metres, including the scenery
/// beyond the playable height map. Only static ground meshes enter the index.
final class DepthlineFlightTerrain {
    private static let surfaces = ["TerrainDepthline", "Broken foothills", "Back range", "DepthlineEnvironmentCutbanks"]
    private static let cellWidth: Float = 8
    private struct Triangle {
        let a: SIMD3<Float>
        let ab: SIMD3<Float>
        let ac: SIMD3<Float>
        let inverseArea: Float

        init?(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            self.a = a
            ab = b - a
            ac = c - a
            let area = ab.x * ac.z - ab.z * ac.x
            guard abs(area) > 1e-7 else { return nil }
            inverseArea = 1 / area
        }

        func height(x: Float, z: Float) -> Float? {
            let dx = x - a.x, dz = z - a.z
            let u = (dx * ac.z - dz * ac.x) * inverseArea
            let v = (dz * ab.x - dx * ab.z) * inverseArea
            guard u >= -0.00001, v >= -0.00001, u + v <= 1.00001 else { return nil }
            return a.y + u * ab.y + v * ac.y
        }
    }

    private var triangles: [Triangle] = []
    private var cells: [SIMD2<Int32>: [Int32]] = [:]
    private var lower = SIMD2<Float>(repeating: .infinity)
    private var upper = SIMD2<Float>(repeating: -.infinity)

    init(scene: SCNScene) {
        for name in Self.surfaces {
            guard let root = scene.rootNode.childNode(withName: name, recursively: true) else { continue }
            index(root)
            root.enumerateChildNodes { node, _ in self.index(node) }
        }
    }

    private static func cell(_ value: Float) -> Int32 { Int32(floor(value / cellWidth)) }

    /// Both the terrain exporter and the ridge mesh writer emit Float XYZ
    /// positions with UInt32 triangle lists. They use different vertex strides.
    private func index(_ node: SCNNode) {
        guard let geometry = node.geometry, let source = geometry.sources(for: .vertex).first,
              source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 3,
              source.vectorCount > 0, source.dataStride >= 12,
              source.data.count >= source.dataOffset + (source.vectorCount - 1) * source.dataStride + 12 else { return }
        let world = node.simdWorldTransform
        let vertices: [SIMD3<Float>] = source.data.withUnsafeBytes { bytes in
            (0..<source.vectorCount).map { index in
                let offset = source.dataOffset + index * source.dataStride
                let p = world * SIMD4(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self),
                                      bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                                      bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self), 1)
                return SIMD3(p.x, p.y, p.z)
            }
        }
        for element in geometry.elements where element.primitiveType == .triangles && element.bytesPerIndex == 4 {
            let data = element.data
            guard data.count >= element.primitiveCount * 12 else { continue }
            triangles.reserveCapacity(triangles.count + element.primitiveCount)
            data.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: element.primitiveCount * 12, by: 12) {
                    let ia = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                    let ib = Int(bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                    let ic = Int(bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self))
                    guard ia < vertices.count, ib < vertices.count, ic < vertices.count else { continue }
                    let a = vertices[ia], b = vertices[ib], c = vertices[ic]
                    guard let triangle = Triangle(a, b, c) else { continue }
                    let lo = simd_min(a, simd_min(b, c)), hi = simd_max(a, simd_max(b, c))
                    lower = simd_min(lower, SIMD2(lo.x, lo.z))
                    upper = simd_max(upper, SIMD2(hi.x, hi.z))
                    let id = Int32(triangles.count)
                    triangles.append(triangle)
                    for z in Self.cell(lo.z)...Self.cell(hi.z) {
                        for x in Self.cell(lo.x)...Self.cell(hi.x) {
                            cells[SIMD2(x, z), default: []].append(id)
                        }
                    }
                }
            }
        }
    }

    func height(x: Double, z: Double) -> Double {
        let px = Float(x), pz = Float(z)
        guard px >= lower.x, px <= upper.x, pz >= lower.y, pz <= upper.y,
              let indices = cells[SIMD2(Self.cell(px), Self.cell(pz))] else { return 0 }
        var highest: Float = 0
        for index in indices {
            if let y = triangles[Int(index)].height(x: px, z: pz) { highest = max(highest, y) }
        }
        return Double(highest)
    }

    /// Compare the cache against SceneKit's own ray/triangle intersections on
    /// the actual level nodes. Samples cover interiors, seams and mesh borders.
    func validate(in scene: SCNScene, gameID: String) throws {
        // SceneKit creates its CPU hit-test structures when pending scene
        // changes commit. Validation runs immediately after level creation.
        SCNTransaction.flush()
        let sampleXZ: [SIMD2<Double>]
        if gameID == "2000" {
            sampleXZ = [SIMD2(-180.4, -425.3), SIMD2(-198.6, -384.9), SIMD2(-299.9, -325.7),
                        SIMD2(-299.9, -299.9), SIMD2(-72.4, -111.8), SIMD2(0.6, -150.3)]
        } else {
            // First ring toe, ridge and back slope. The next ring starts
            // beyond the playable mesh; oblique radii exercise both triangles.
            sampleXZ = [SIMD2(31.2, 124.6), SIMD2(-239.91, 219.63), SIMD2(3.2, 305.6),
                        SIMD2(1.9, 382.1), SIMD2(-268.2, -271.7), SIMD2(160.6, 363.1),
                        SIMD2(-2.3, 489.2), SIMD2(0.11, 574.4), SIMD2(-421.5, -407.8)]
        }
        let surfaces = Self.surfaces.compactMap { scene.rootNode.childNode(withName: $0, recursively: true) }
        let options: [String: Any] = [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue,
                                      SCNHitTestOption.backFaceCulling.rawValue: false]
        var highPoint = 0.0
        for point in sampleXZ {
            let a = SCNVector3(point.x, 250, point.y), b = SCNVector3(point.x, -50, point.y)
            let expected = surfaces.flatMap { node in
                node.hitTestWithSegment(from: node.convertPosition(a, from: nil),
                                        to: node.convertPosition(b, from: nil), options: options)
            }.reduce(0.0) { max($0, Double($1.worldCoordinates.y)) }
            let actual = height(x: point.x, z: point.y)
            guard abs(actual - expected) < 0.015 else {
                throw NSError(domain: "DepthlineFlightTerrain", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "\(gameID) land height at \(point) was \(actual)m, SceneKit ray measured \(expected)m"])
            }
            highPoint = max(highPoint, actual)
        }
        guard highPoint > (gameID == "2000" ? 10 : 48), height(x: -1800, z: 950) == 0 else {
            throw NSError(domain: "DepthlineFlightTerrain", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Distant topography or off-mesh sea level missing from \(gameID)"])
        }
    }
}
