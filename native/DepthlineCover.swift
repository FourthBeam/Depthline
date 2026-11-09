import SceneKit
import simd

/// The emplacement is stationary. Copy its rendered triangles once so neither
/// infantry sight checks nor projectile sweeps need the renderer's scene lock.
final class DepthlineCover {
    enum Surface { case concrete, sandbag, metal, stone }
    struct Hit {
        let position: SIMD3<Float>
        let normal: SIMD3<Float>
        let surface: Surface
        let fraction: Float
    }

    private struct Triangle {
        let origin, ab, ac: SIMD3<Float>
        let normal: SIMD3<Float>
        var centroid: SIMD3<Float> { origin + (ab + ac) / 3 }

        func contact(start: SIMD3<Float>, delta: SIMD3<Float>, limit: Float) -> (fraction: Float, normal: SIMD3<Float>)? {
            let across = simd_cross(delta, ac)
            let determinant = simd_dot(ab, across)
            guard abs(determinant) > 1e-12 else { return nil }
            let offset = start - origin
            let u = simd_dot(offset, across) / determinant
            guard u >= 0, u <= 1 else { return nil }
            let cross = simd_cross(offset, ab)
            let v = simd_dot(delta, cross) / determinant
            guard v >= 0, u + v <= 1 else { return nil }
            let t = simd_dot(ac, cross) / determinant
            guard t >= 0, t <= limit else { return nil }
            return (t, simd_dot(normal, delta) > 0 ? -normal : normal)
        }
    }

    private struct Bounds {
        var lower = SIMD3<Float>(repeating: .infinity)
        var upper = SIMD3<Float>(repeating: -.infinity)

        mutating func include(_ point: SIMD3<Float>) {
            lower = simd_min(lower, point)
            upper = simd_max(upper, point)
        }

        func intersects(start: SIMD3<Float>, delta: SIMD3<Float>, inverse: SIMD3<Float>, limit: Float) -> Bool {
            var entry: Float = 0, exit = limit
            for axis in 0..<3 {
                if delta[axis] == 0 {
                    if start[axis] < lower[axis] || start[axis] > upper[axis] { return false }
                } else {
                    let a = (lower[axis] - start[axis]) * inverse[axis]
                    let b = (upper[axis] - start[axis]) * inverse[axis]
                    entry = max(entry, min(a, b))
                    exit = min(exit, max(a, b))
                    if entry > exit { return false }
                }
            }
            return true
        }
    }

    private struct Branch {
        let bounds: Bounds
        let faces: Range<Int>
        var splitAxis = 0
        var left = -1, right = -1
    }

    private struct Part {
        let surface: Surface
        var triangles: [Triangle]
        var tree: [Branch] = []

        init(surface: Surface, triangles: [Triangle]) {
            self.surface = surface
            self.triangles = triangles
            _ = index(triangles.indices)
        }

        private mutating func index(_ range: Range<Int>) -> Int {
            var box = Bounds(), centers = Bounds()
            for i in range {
                let t = triangles[i]
                box.include(t.origin); box.include(t.origin + t.ab); box.include(t.origin + t.ac)
                centers.include(t.centroid)
            }
            // Leave enough room for rounding in the ray/slab and ray/triangle
            // calculations at a shared mesh edge.
            box.lower -= SIMD3(repeating: 0.00002)
            box.upper += SIMD3(repeating: 0.00002)
            let index = tree.count
            tree.append(Branch(bounds: box, faces: range))
            guard range.count > 8 else { return index }
            let size = centers.upper - centers.lower
            let axis = size.x >= size.y && size.x >= size.z ? 0 : (size.y >= size.z ? 1 : 2)
            let middle = (centers.lower[axis] + centers.upper[axis]) * 0.5
            var split = triangles[range].partition { $0.centroid[axis] >= middle }
            if split == range.lowerBound || split == range.upperBound { split = range.lowerBound + range.count / 2 }
            let left = self.index(range.lowerBound..<split)
            let right = self.index(split..<range.upperBound)
            tree[index].splitAxis = axis
            tree[index].left = left; tree[index].right = right
            return index
        }

        func intersect(_ index: Int, start: SIMD3<Float>, delta: SIMD3<Float>, inverse: SIMD3<Float>, closest: inout Hit?) {
            let branch = tree[index]
            guard branch.bounds.intersects(start: start, delta: delta, inverse: inverse, limit: closest?.fraction ?? 1) else { return }
            if branch.left >= 0 {
                let forward = delta[branch.splitAxis] >= 0
                intersect(forward ? branch.left : branch.right, start: start, delta: delta, inverse: inverse, closest: &closest)
                intersect(forward ? branch.right : branch.left, start: start, delta: delta, inverse: inverse, closest: &closest)
                return
            }
            for i in branch.faces {
                guard let contact = triangles[i].contact(start: start, delta: delta, limit: closest?.fraction ?? 1),
                      contact.fraction < (closest?.fraction ?? .infinity) else { continue }
                closest = Hit(position: start + delta * contact.fraction, normal: contact.normal,
                              surface: surface, fraction: contact.fraction)
            }
        }
    }

    private let worldFromRoot: simd_float4x4
    private var parts: [Part] = []

    init(root: SCNNode) { worldFromRoot = root.simdWorldTransform }

    /// Each batch is authored in the emplacement root's local coordinates.
    /// SceneKit segment hits report geometric face normals, even on smooth surfaces.
    func register(_ mesh: NativeDetailMesh, as surface: Surface) {
        guard !mesh.indices.isEmpty else { return }
        let transform = worldFromRoot
        let vertices = mesh.positions.map { source -> SIMD3<Float> in
            let point = transform * SIMD4(source, 1)
            return SIMD3(point.x, point.y, point.z)
        }
        var triangles: [Triangle] = []
        triangles.reserveCapacity(mesh.indices.count / 3)
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = Int(mesh.indices[i]), b = Int(mesh.indices[i+1]), c = Int(mesh.indices[i+2])
            let ab = vertices[b] - vertices[a], ac = vertices[c] - vertices[a]
            let perpendicular = simd_cross(ab, ac)
            guard simd_length_squared(perpendicular) > 0 else { continue }
            triangles.append(Triangle(origin: vertices[a], ab: ab, ac: ac, normal: simd_normalize(perpendicular)))
        }
        guard !triangles.isEmpty else { return }
        parts.append(Part(surface: surface, triangles: triangles))
    }

    func firstHit(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Hit? {
        let delta = end - start
        let lengthSquared = simd_length_squared(delta)
        guard lengthSquared.isFinite, lengthSquared > 1e-12 else { return nil }
        let inverse = 1 / delta
        var closest: Hit?
        for part in parts { part.intersect(0, start: start, delta: delta, inverse: inverse, closest: &closest) }
        return closest
    }
}
