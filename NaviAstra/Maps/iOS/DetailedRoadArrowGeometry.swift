#if os(iOS)
import Foundation

/// The complete glyph contract is shared by the iOS sprite renderer and the road atlas.
/// Every non-empty subset of the ten supported OSM turn values can be rendered.
nonisolated enum DetailedRoadArrowGeometry {
    struct Point: Sendable { let x: Double; let y: Double }
    static let width = 16.0
    static let height = 30.0
    static let supportedTurns: Set<String> = [
        "left", "slight_left", "sharp_left", "through", "right", "slight_right", "sharp_right",
        "reverse", "merge_to_left", "merge_to_right"
    ]

    static func paths(for turns: [String]) -> [[Point]]? {
        guard !turns.isEmpty, turns.count <= supportedTurns.count,
              Set(turns).count == turns.count, turns.allSatisfy(supportedTurns.contains) else { return nil }
        var paths: [[Point]] = []
        let tail = Point(x: 8, y: 27)
        func curve(_ a: Point, _ c: Point, _ b: Point) -> [Point] {
            (0...10).map { index in
                let t = Double(index) / 10, s = 1 - t
                return Point(x: a.x * s * s + c.x * 2 * s * t + b.x * t * t,
                             y: a.y * s * s + c.y * 2 * s * t + b.y * t * t)
            }
        }
        for turn in turns.sorted() {
            let side = turn.contains("left") ? -1.0 : 1.0
            var stem = [tail, Point(x: 8, y: 18)]
            let tip: Point
            let direction: Point
            switch turn {
            case "through":
                tip = Point(x: 8, y: 3); direction = Point(x: 0, y: -1)
                stem.append(tip)
            case "reverse":
                stem += curve(Point(x: 8, y: 18), Point(x: 8, y: 7), Point(x: 3, y: 7))
                stem += curve(Point(x: 3, y: 7), Point(x: 3, y: 7), Point(x: 3, y: 12))
                tip = Point(x: 3, y: 23); direction = Point(x: 0, y: 1); stem.append(tip)
            case "sharp_left", "sharp_right":
                stem += curve(Point(x: 8, y: 18), Point(x: 8, y: 10), Point(x: 8 + side * 3, y: 10))
                stem += curve(Point(x: 8 + side * 3, y: 10), Point(x: 8 + side * 5, y: 10), Point(x: 8 + side * 5, y: 15))
                tip = Point(x: 8 + side * 5, y: 21); direction = Point(x: 0, y: 1); stem.append(tip)
            case "slight_left", "slight_right", "merge_to_left", "merge_to_right":
                tip = Point(x: 8 + side * 6, y: turn.hasPrefix("merge") ? 8 : 4)
                let length = hypot(tip.x - 8, tip.y - 15)
                direction = Point(x: (tip.x - 8) / length, y: (tip.y - 15) / length)
                stem += curve(Point(x: 8, y: 18), Point(x: 8, y: 15), tip)
            default:
                tip = Point(x: 8 + side * 6, y: 11); direction = Point(x: side, y: 0)
                stem += curve(Point(x: 8, y: 18), Point(x: 8, y: 11), tip)
            }
            paths.append(stem)
            let normal = Point(x: -direction.y, y: direction.x)
            paths.append([Point(x: tip.x - direction.x * 3 + normal.x * 1.7, y: tip.y - direction.y * 3 + normal.y * 1.7),
                          tip,
                          Point(x: tip.x - direction.x * 3 - normal.x * 1.7, y: tip.y - direction.y * 3 - normal.y * 1.7)])
        }
        return paths
    }
}
#endif
