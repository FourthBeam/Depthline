import Foundation
import simd

/// Per-soldier approach to a firing position outside the emplacement. Distances
/// here are in the original infantry FSM's centimetres.
struct DepthlineInfantryPositioning {
    struct Field {
        let ground: (Double, Double) -> Double
        let openShot: (SIMD3<Double>) -> Bool
        let clearSegment: (SIMD3<Double>, SIMD3<Double>) -> Bool

        func foot(at xz: SIMD2<Double>) -> SIMD3<Double> {
            SIMD3(xz.x, ground(xz.x, xz.y), xz.y)
        }

        func canWalk(_ from: SIMD2<Double>, _ to: SIMD2<Double>) -> Bool {
            let delta = to - from
            let distance = simd_length(delta)
            guard distance > 0.0001 else { return true }
            let direction = delta / distance
            let side = SIMD2(-direction.y, direction.x) * 19
            // The shin pair catches low walls. The chest and shoulders keep
            // the upright actor out of bags and overhanging slabs.
            let offsets = [SIMD3(side.x, 23, side.y), SIMD3(-side.x, 23, -side.y), SIMD3(0, 88, 0),
                           SIMD3(side.x, 138, side.y), SIMD3(-side.x, 138, -side.y)]
            func clear(_ start: SIMD3<Double>, _ end: SIMD3<Double>) -> Bool {
                start == end || offsets.allSatisfy { clearSegment(start + $0, end + $0) }
            }
            // The original walkers follow a point-sampled height map. A long
            // downhill chord can otherwise pass underneath a wall that the
            // next actual four-centimetre footstep would walk straight into.
            var flatStart = foot(at: from), previous = flatStart
            for i in 1...Int(ceil(distance / 4)) {
                let next = foot(at: from + direction * min(Double(i) * 4, distance))
                if next.y != previous.y {
                    guard clear(flatStart, previous), clear(previous, next) else { return false }
                    flatStart = next
                }
                previous = next
            }
            return clear(flatStart, previous)
        }
    }

    enum Order { case walk(SIMD2<Double>), hold, wait }
    private var waypoints: [SIMD2<Double>] = []
    private var post: SIMD2<Double>?
    private var recheck = 0
    private var search: FlankSearch?
    private var attempts = 0

    mutating func order(slot: Int, at position: SIMD3<Double>, attacking: Bool = false, field: Field) -> Order? {
        let desired = nextOrder(slot: slot, at: position, attacking: attacking, field: field)
        guard case .walk(let step) = desired else { return desired }
        let here = SIMD2(position.x, position.z)
        guard !field.canWalk(here, here + step * 4) else { return desired }
        // A carrier-avoidance manoeuvre or a height discontinuity may have
        // put the actor off the route that was originally tested.
        let goal = waypoints.last ?? here
        waypoints.removeAll()
        search = FlankSearch(origin: here, goal: goal, attempt: attempts, side: slot.isMultiple(of: 2) ? 1 : -1)
        attempts += 1
        return .wait
    }

    private mutating func nextOrder(slot: Int, at position: SIMD3<Double>, attacking: Bool, field: Field) -> Order? {
        let here = SIMD2(position.x, position.z)
        let distance = simd_length(here)
        // Outside the original close combat area the landing and approach FSMs
        // retain their long-range headings, distances and random choices.
        guard max(abs(here.x), abs(here.y)) < 2500 || attacking || search != nil || !waypoints.isEmpty else { return nil }
        if let post, simd_distance_squared(here, post) < 25 { return .hold }
        post = nil
        while let next = waypoints.first {
            let delta = next - here
            let remaining = simd_length(delta)
            if remaining > 0.01 { return .walk(delta / max(4, remaining)) }
            waypoints.removeFirst()
            if waypoints.isEmpty, (735...2400).contains(distance), field.openShot(position) {
                post = here
                return .hold
            }
        }
        if let search {
            if let path = search.advance(in: field) {
                self.search = nil
                if !path.isEmpty {
                    waypoints = path
                    let delta = path[0] - here
                    return .walk(delta / max(4, simd_length(delta)))
                }
                // The next search changes its grid orientation and resolution.
                recheck = 10 + slot % 9
            }
            return .wait
        }
        if recheck > 0 {
            recheck -= 1
            return distance > 1450 ? nil : .wait
        }
        let interval = 22 + slot % 13
        if distance > 1450, field.openShot(position) {
            recheck = interval
            return nil
        }
        // Split a squad across several ranges and bearings. A visible post
        // has enough stand-off for the player to depress the gun onto it.
        let radius = Double(835 + (slot * 47) % 225)
        if abs(distance - radius) < 65, field.openShot(position) {
            post = here
            return .hold
        }
        let bearing = atan2(here.y, here.x)
        let side: Double = slot.isMultiple(of: 2) ? 1 : -1
        let spread = Double((slot * 13) % 15 - 7) * 0.035
        let offsets = [0, 0.22, -0.22, 0.45, -0.45, 0.75, -0.75, 1.1, -1.1, 1.55, -1.55]
        for range in [radius, radius + 505, radius + 915] {
            for angle in offsets {
                let a = bearing + spread + side * angle
                let spot = SIMD2(cos(a), sin(a)) * range
                if field.canWalk(here, spot), field.openShot(field.foot(at: spot)) {
                    waypoints = [spot]
                    let delta = spot - here
                    return .walk(delta / max(4, simd_length(delta)))
                }
            }
        }
        search = FlankSearch(origin: here, goal: SIMD2(cos(bearing + spread), sin(bearing + spread)) * radius,
                             attempt: attempts, side: side)
        attempts += 1
        return .wait
    }

    /// Direct routes are cheap and resolve most approaches. A blocked soldier
    /// searches around a corner a few cells per tick and retains the entire
    /// walkable path, so the following step cannot send him back to the wall.
    private final class FlankSearch {
        typealias Cell = SIMD2<Int>
        let origin, goal, xAxis, zAxis: SIMD2<Double>
        var queue: [Cell] = [.zero]
        var parent: [Cell: Cell] = [.zero: .zero]
        var index = 0
        var best = Cell.zero

        init(origin: SIMD2<Double>, goal: SIMD2<Double>, attempt: Int, side: Double) {
            self.origin = origin; self.goal = goal
            let angle = Double(attempt) * 0.47
            let spacing = attempt.isMultiple(of: 2) ? 85.0 : 63.0
            xAxis = SIMD2(cos(angle), sin(angle)) * spacing * side
            zAxis = SIMD2(-sin(angle), cos(angle)) * spacing
        }

        func point(_ cell: Cell) -> SIMD2<Double> { origin + xAxis * Double(cell.x) + zAxis * Double(cell.y) }

        func path(to end: Cell) -> [SIMD2<Double>] {
            var result: [SIMD2<Double>] = [], cell = end
            while cell != .zero, let previous = parent[cell] {
                result.append(point(cell)); cell = previous
            }
            return result.reversed()
        }

        func advance(in field: Field) -> [SIMD2<Double>]? {
            for _ in 0..<4 {
                guard index < queue.count, index < 1200 else {
                    return simd_distance(point(best), goal) + 100 < simd_distance(origin, goal) ? path(to: best) : []
                }
                let cell = queue[index], here = point(cell)
                index += 1
                if cell != .zero, (740...2380).contains(simd_length(here)), field.openShot(field.foot(at: here)) {
                    return path(to: cell)
                }
                let offsets: [Cell] = [.init(1,0), .init(-1,0), .init(0,1), .init(0,-1),
                                       .init(1,1), .init(-1,1), .init(1,-1), .init(-1,-1)]
                for offset in offsets {
                    let next = cell &+ offset
                    guard parent[next] == nil, field.canWalk(here, point(next)) else { continue }
                    parent[next] = cell; queue.append(next)
                    if simd_distance_squared(point(next), goal) < simd_distance_squared(point(best), goal) { best = next }
                }
            }
            return nil
        }
    }
}
