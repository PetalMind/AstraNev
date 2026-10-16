import Foundation

struct Scene: Decodable {
    let id: String
    let title: String
    let family: String
    let roads: [DetailedRoad]
    let query: DetailedRoadQuery
    let expectedJunctions: Int?
    let real: Bool
    let expectedNormalized: Int?
    let expectedMarkingsMinimum: Int?
}

let arguments = CommandLine.arguments
let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
let scenes = try JSONDecoder().decode([Scene].self, from: Data(contentsOf: inputURL))
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
let meters = 6_371_008.8 * Double.pi / 180
var summaries: [[String: Any]] = []
for (index, scene) in scenes.enumerated() {
    let began = Date()
    let latitude = (scene.query.south + scene.query.north) / 2
    let longitude = (scene.query.west + scene.query.east) / 2
    let cosine = cos(latitude * .pi / 180)
    func project(_ p: DetailedRoad.Point) -> DetailedRoadGeometry.Vector {
        .init(x: (p.longitude - longitude) * meters * cosine, y: (p.latitude - latitude) * meters)
    }
    func xy(_ p: DetailedRoadGeometry.Vector) -> [Double] { [p.x, p.y] }
    let normalized = scene.roads.compactMap(DetailedRoadNormalizer.normalize)
    var result: [String: Any] = ["id": scene.id, "title": scene.title, "family": scene.family,
        "real": scene.real, "inputRoads": scene.roads.count, "normalizedRoads": normalized.count,
        "bounds": [(scene.query.west - longitude) * meters * cosine, (scene.query.east - longitude) * meters * cosine,
                   (scene.query.south - latitude) * meters, (scene.query.north - latitude) * meters]]
    do {
        let network = try DetailedRoadTopology.build(normalized, project: project)
        let graphics = try DetailedRoadGeometry.build(normalized, in: scene.query)
        result["junctions"] = network.junctions.count
        result["junctionMarkings"] = network.junctions.reduce(0) { $0 + $1.separators.count }
        if let value = scene.expectedNormalized { result["expectedNormalized"] = value }
        if let value = scene.expectedMarkingsMinimum { result["expectedMarkingsMinimum"] = value }
        result["corridors"] = network.corridors.count
        if let expected = scene.expectedJunctions { result["expectedJunctions"] = expected }
        result["graphics"] = graphics.map { graphic -> [String: Any] in
            var feature: [String: Any] = ["kind": graphic.kind.rawValue, "level": graphic.level, "polygon": graphic.polygon,
             "points": graphic.points.map { xy(project($0)) }, "opacity": graphic.opacity,
             "bearing": graphic.bearing, "arrowScale": graphic.arrowScale, "turns": graphic.turnTypes,
             "confidence": graphic.confidence.rawValue]
            #if ROAD_ATLAS_SURFACES
            feature["holes"] = graphic.interiorRings.map { $0.map { xy(project($0)) } }
            #endif
            return feature
        }
        var spine: [[String: Any]] = []
        for road in normalized where road.renderLevel != .underground {
            let points = road.points.map(project)
            let length = DetailedRoadGeometry.pathLength(points)
            var checks: [[Double]] = [], traveled = 0.0
            for (a, b) in zip(points, points.dropFirst()) {
                let delta = b - a, size = delta.length
                guard size >= 0.15 else { continue }
                let count = max(1, min(256, Int(ceil(size / 2))))
                for index in 0..<count {
                    let t = (Double(index) + 0.5) / Double(count)
                    let fraction = (traveled + size * t) / length
                    let center = a + delta * t + delta.unit.left * road.centerOffset(at: fraction)
                    checks.append(xy(center))
                }
                traveled += size
            }
            spine.append(["id": String(road.id), "level": road.layer, "points": points.map(xy),
                "checks": checks, "width": max(road.startWidth, road.endWidth)])
        }
        result["spine"] = spine
        result["vertices"] = graphics.reduce(0) { $0 + $1.points.count }
        result["features"] = graphics.count
    } catch {
        result["error"] = String(describing: error)
        result["graphics"] = []
        result["spine"] = normalized.map { ["id": String($0.id), "level": $0.layer, "points": $0.points.map { xy(project($0)) }, "checks": []] as [String: Any] }
    }
    result["milliseconds"] = Date().timeIntervalSince(began) * 1000
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    try data.write(to: outputURL.appendingPathComponent(scene.id + ".json"))
    var summary = result
    summary.removeValue(forKey: "graphics"); summary.removeValue(forKey: "spine")
    summaries.append(summary)
    if index.isMultiple(of: 100) || index == scenes.count - 1 {
        print("Geometry \(index + 1)/\(scenes.count): \(scene.id)")
        fflush(stdout)
    }
}
try JSONSerialization.data(withJSONObject: summaries, options: [.prettyPrinted, .sortedKeys])
    .write(to: outputURL.appendingPathComponent("summary.json"))

#if ROAD_ATLAS_GLYPHS
let turns = DetailedRoadArrowGeometry.supportedTurns.sorted()
var glyphs: [[String: Any]] = []
for mask in 1..<(1 << turns.count) {
    let values = turns.indices.filter { mask & (1 << $0) != 0 }.map { turns[$0] }
    guard let paths = DetailedRoadArrowGeometry.paths(for: values) else { fatalError("A supported turn combination was rejected") }
    glyphs.append(["turns": values, "width": DetailedRoadArrowGeometry.width, "height": DetailedRoadArrowGeometry.height,
        "paths": paths.map { $0.map { [$0.x, $0.y] } }])
}
try JSONSerialization.data(withJSONObject: glyphs, options: [.sortedKeys])
    .write(to: outputURL.appendingPathComponent("arrow-glyphs.json"))
#endif
