#if os(iOS)
import CoreGraphics
import Foundation

/// Boolean road envelopes. Unlike an offset ring, a union remains valid at a hairpin,
/// an acute fork and an overlapping short connector, and retains enclosed islands.
nonisolated enum DetailedRoadSurfaceGeometry {
    typealias Vector = DetailedRoadGeometry.Vector
    typealias Sample = DetailedRoadGeometry.Sample

    struct Polygon {
        let outer: [Vector]
        let holes: [[Vector]]
    }

    static func signedArea(_ points: [Vector]) -> Double {
        guard points.count > 2 else { return 0 }
        return points.indices.reduce(0) { sum, index in
            let a = points[index], b = points[(index + 1) % points.count]
            return sum + a.cross(b) / 2
        }
    }

    static func path(_ points: [Vector], closed: Bool = true) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        let ordered = closed && signedArea(points) < 0 ? Array(points.reversed()) : points
        path.move(to: CGPoint(x: ordered.first?.x ?? first.x, y: ordered.first?.y ?? first.y))
        for point in ordered.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
        if closed { path.closeSubpath() }
        return path
    }

    static func corridor(_ samples: [Sample], road: NormalizedDetailedRoad) -> CGPath {
        let result = CGMutablePath()
        guard samples.count > 1 else { return result }
        var previousCenter: Vector?
        for index in 1..<samples.count {
            let a = samples[index - 1], b = samples[index]
            let heading = (b.point - a.point).unit, normal = heading.left
            let ca = a.point + normal * road.centerOffset(at: a.fraction)
            let cb = b.point + normal * road.centerOffset(at: b.fraction)
            let wa = road.width(at: a.fraction) / 2, wb = road.width(at: b.fraction) / 2
            result.addPath(path([ca + normal * wa, cb + normal * wb, cb - normal * wb, ca - normal * wa]))
            if let previousCenter {
                // Round joins bridge the two section centres, including explicit placement shifts.
                if (ca - previousCenter).length > 0.001 {
                    let normal = (ca - previousCenter).unit.left * wa
                    result.addPath(path([previousCenter + normal, ca + normal, ca - normal, previousCenter - normal]))
                }
                for center in [previousCenter, ca] {
                    let circle = (0..<32).map { index in
                        let angle = Double(index) * 2 * .pi / 32
                        return center + Vector(x: cos(angle), y: sin(angle)) * wa
                    }
                    result.addPath(path(circle))
                }
            }
            previousCenter = cb
        }
        return result
    }

    static func lines(_ input: CGPath, closed: Bool = false) -> [[Vector]] {
        var result: [[Vector]] = [], current: [Vector] = []
        func finish() {
            if closed, let first = current.first, let last = current.last, (last - first).length > 0.001 { current.append(first) }
            if current.count >= (closed ? 4 : 2) { result.append(current) }
            current = []
        }
        input.flattened(threshold: 0.04).applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                finish()
                current = [Vector(x: element.points[0].x, y: element.points[0].y)]
            case .addLineToPoint:
                let next = Vector(x: element.points[0].x, y: element.points[0].y)
                if current.last.map({ ($0 - next).length > 0.001 }) ?? true { current.append(next) }
            case .closeSubpath: finish()
            default: break // flattened paths contain only moves, lines and closes.
            }
        }
        finish()
        return result
    }

    static func polygons(_ input: CGPath) -> [Polygon] {
        input.normalized(using: .winding).componentsSeparated(using: .winding).compactMap { component in
            let rings = lines(component, closed: true).filter { abs(signedArea($0)) > 0.0001 }
                .sorted { abs(signedArea($0)) > abs(signedArea($1)) }
            guard let outer = rings.first else { return nil }
            return Polygon(outer: outer, holes: Array(rings.dropFirst()))
        }
    }
}
#endif
