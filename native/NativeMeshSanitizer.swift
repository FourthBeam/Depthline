import Foundation

/// Legacy two-sided meshes contain overlapping front/back triangles. Metal
/// already shades both sides, so keep one surface and remove depth competitors.
/// Collision JSON and source objects remain intact.
enum NativeMeshSanitizer {
    struct Point: Hashable, Comparable {
        let x: Int64, y: Int64, z: Int64
        static func < (a: Point, b: Point) -> Bool { a.x != b.x ? a.x < b.x : a.y != b.y ? a.y < b.y : a.z < b.z }
    }
    struct Triangle: Hashable { let a: Point, b: Point, c: Point }
    static func uniqueTriangles(vertices: [Float], indices: [UInt32], seen: inout Set<Triangle>) -> [UInt32] {
        var result: [UInt32] = []; result.reserveCapacity(indices.count)
        for i in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
            let triangle = Array(indices[i..<i + 3])
            guard triangle.allSatisfy({ Int($0) * 3 + 2 < vertices.count }) else { continue }
            let points = triangle.map { n -> Point in
                let k = Int(n) * 3
                return Point(x: Int64((vertices[k] * 100000).rounded()), y: Int64((vertices[k + 1] * 100000).rounded()), z: Int64((vertices[k + 2] * 100000).rounded()))
            }.sorted()
            guard points[0] != points[1], points[1] != points[2] else { continue }
            if seen.insert(Triangle(a: points[0], b: points[1], c: points[2])).inserted { result.append(contentsOf: triangle) }
        }
        return result
    }
    static func runTests() throws {
        var seen = Set<Triangle>()
        let v: [Float] = [0,0,0, 1,0,0, 0,1,0]
        let first = uniqueTriangles(vertices:v,indices:[0,1,2,2,1,0],seen:&seen)
        let next = uniqueTriangles(vertices:v,indices:[1,2,0],seen:&seen)
        guard first == [0,1,2], next.isEmpty else {throw NSError(domain:"NativeMeshSanitizer",code:1)}
    }
}
