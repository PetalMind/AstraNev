// swift scripts/environment-models/import-kenney.swift <unpacked packs root> <output folder>
// Packs: nature/, suburban/, commercial/, roads/, holiday/, industrial/, building-kit/, graveyard/.
import Foundation
import CoreGraphics
import ImageIO
import simd

precondition(CommandLine.arguments.count == 3, "Expected packs root and output folder")
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var selection: [(String, String, String)] = [
    ("nature", "tree_default", "tree-rounded"),
    ("nature", "tree_detailed", "tree-branched"),
    ("nature", "tree_oak", "tree-broad"),
    ("nature", "tree_pineTallA_detailed", "tree-conifer"),
    ("suburban", "building-type-a", "house-a"),
    ("suburban", "building-type-b", "house-b"),
    ("suburban", "building-type-c", "house-c"),
    ("commercial", "building-a", "commercial-a"),
    ("commercial", "building-b", "commercial-b"),
    ("roads", "light-curved", "street-lamp"),
    ("roads", "traffic-light", "traffic-signal"),
    ("holiday", "bench", "bench")
]
for name in ["d", "e", "f", "g", "h", "i", "k", "m", "n", "p", "r", "s", "u"] {
    selection.append(("suburban", "building-type-" + name, "house-" + name))
}
for name in ["c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n"] {
    selection.append(("commercial", "building-" + name, "block-" + name))
}
for name in ["a", "b", "c", "d", "e"] {
    selection.append(("commercial", "building-skyscraper-" + name, "tower-" + name))
}
for name in ["a", "g", "h", "i", "j", "k", "m", "p", "q", "s", "t"] {
    selection.append(("industrial", "building-" + name, "industrial-" + name))
}
for name in ["small", "tall", "fat", "thin", "plateau"] {
    selection.append(("nature", "tree_" + name, "tree-" + name))
}
for name in ["pineDefaultA", "pineRoundA"] {
    selection.append(("nature", "tree_" + name, "tree-" + name))
}
selection.append(("building-kit", "column-thin", "bollard-column"))
selection.append(("graveyard", "bench", "bench-park"))
for pack in Set(selection.map { $0.0 }).sorted() {
    let license = try Data(contentsOf: root.appendingPathComponent(pack + "/License.txt"))
    precondition(String(decoding: license, as: UTF8.self).contains("Creative Commons Zero"))
    try license.write(to: output.appendingPathComponent("kenney-" + pack + "-license.txt"))
}
struct Palette {
    let width: Int, height: Int, pixels: [UInt8]
    init(_ url: URL) {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let width = image.width, height = image.height
        self.width = width; self.height = height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            let context = CGContext(data: $0.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        pixels = bytes
    }
    func color(_ uv: SIMD2<Double>) -> Int {
        let x = max(0, min(width - 1, Int(uv.x * Double(width))))
        let y = max(0, min(height - 1, Int((1 - uv.y) * Double(height))))
        let offset = (y * width + x) * 4
        return Int(pixels[offset]) << 16 | Int(pixels[offset + 1]) << 8 | Int(pixels[offset + 2])
    }
}
var manifest: [[String: Any]] = []
for (pack, name, id) in selection {
    let folder = root.appendingPathComponent(pack + "/Models/OBJ format")
    let source = folder.appendingPathComponent(name + ".obj")
    let mtl = try String(contentsOf: folder.appendingPathComponent(name + ".mtl"), encoding: .utf8)
    var colors: [String: Int] = [:], palettes: [String: Palette] = [:], material = ""
    for line in mtl.split(whereSeparator: \.isNewline) {
        let f = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let kind = f.first else { continue }
        if kind == "newmtl" { material = f[1] }
        if kind == "Kd" {
            let rgb = f.dropFirst().prefix(3).map { max(0, min(255, Int((Double($0)! * 255).rounded()))) }
            colors[material] = rgb[0] << 16 | rgb[1] << 8 | rgb[2]
        }
        if kind == "map_Kd" { palettes[material] = Palette(folder.appendingPathComponent(f[1])) }
    }
    var points: [SIMD3<Double>] = [], uvs: [SIMD2<Double>] = []
    var faces: [([Int], Int)] = []
    let text = try String(contentsOf: source, encoding: .utf8)
    for line in text.split(whereSeparator: \.isNewline) {
        let f = line.split(whereSeparator: \.isWhitespace)
        guard let kind = f.first else { continue }
        switch kind {
        case "v": points.append(SIMD3(Double(f[1])!, Double(f[2])!, Double(f[3])!))
        case "vt": uvs.append(SIMD2(Double(f[1])!, Double(f[2])!))
        case "usemtl": material = String(f[1])
        case "f":
            let corners = f.dropFirst().map { $0.split(separator: "/", omittingEmptySubsequences: false) }
            func index(_ value: Substring, count: Int) -> Int {
                let raw = Int(value)!; return raw > 0 ? raw - 1 : count + raw
            }
            let indices = corners.map { index($0[0], count: points.count) }
            let uv = corners.map { $0.count > 1 && !$0[1].isEmpty ? uvs[index($0[1], count: uvs.count)] : .zero }
                .reduce(SIMD2<Double>.zero, +) / Double(corners.count)
            var color = palettes[material]?.color(uv) ?? colors[material] ?? 0xAAAAAA
            // Do not imply a live signal state. All three imported lenses are unlit.
            if id == "traffic-signal" {
                let r = (color >> 16) & 255, g = (color >> 8) & 255, b = color & 255
                if (r > g * 2 && r > b * 2) || (g > r * 2 && g > b * 2) || (r > 120 && g > 90 && b < 60) {
                    color = 0x263238
                }
            }
            for i in 1..<(indices.count - 1) { faces.append(([indices[0], indices[i], indices[i + 1]], color)) }
        default: break
        }
    }
    let minimum = points.reduce(SIMD3<Double>(repeating: .infinity), simd_min)
    let maximum = points.reduce(SIMD3<Double>(repeating: -.infinity), simd_max)
    let dimensions = maximum - minimum
    // Normalized footprint, ground at zero. App axes: east X, north Y, up Z.
    let bottom = points.filter { $0.y <= minimum.y + dimensions.y * 0.001 }
    let bottomMin = bottom.reduce(SIMD3<Double>(repeating: .infinity), simd_min)
    let bottomMax = bottom.reduce(SIMD3<Double>(repeating: -.infinity), simd_max)
    let center = (id.hasPrefix("tree-") || pack == "roads") ? (bottomMin + bottomMax) / 2 : (minimum + maximum) / 2
    let normalized = points.map { p -> SIMD3<Double> in
        var v = SIMD3(-(p.x - center.x) / dimensions.x,
               (p.z - center.z) / dimensions.z, (p.y - minimum.y) / dimensions.y)
        // Align the lamp arm with the existing north-facing schematic template.
        if id == "street-lamp" { v.x = -v.x; v.y = -v.y }
        return v
    }
    func round(_ value: Double) -> Double { (value * 100_000).rounded() / 100_000 }
    let vertices = normalized.map { [round($0.x), round($0.y), round($0.z)] }
    let triangles = faces.filter { indices, _ in
        simd_length(simd_cross(normalized[indices[1]] - normalized[indices[0]], normalized[indices[2]] - normalized[indices[0]])) > 1e-9
    }.map { $0.0 + [$0.1] }
    var result: [String: Any] = ["version": 1, "id": id, "pack": pack,
        "source": name + ".obj", "vertices": vertices, "triangles": triangles,
        "aspect": [round(dimensions.x / dimensions.y), round(dimensions.z / dimensions.y)]]
    if id == "street-lamp" {
        let lens = faces.filter { $0.1 == 0xFFFFFF }.flatMap { $0.0.map { normalized[$0] } }
        precondition(!lens.isEmpty, "Expected the source lamp's white lens material")
        let point = lens.reduce(SIMD3<Double>.zero, +) / Double(lens.count)
        result["lampLens"] = [round(point.x), round(point.y), round(point.z)]
    }
    try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        .write(to: output.appendingPathComponent("environment-" + id + ".json"))
    // Coarse geometry retains the source silhouette and material colors. Cluster
    // vertices rather than dropping arbitrary faces, which would create holes.
    var cells: [String: Int] = [:], remap: [Int] = [], clusters: [[SIMD3<Double>]] = []
    let step = id.hasPrefix("tree-") ? 0.09 : 0.06
    for point in normalized {
        let cell = [Int((point.x / step).rounded()), Int((point.y / step).rounded()), Int((point.z / step).rounded())]
        let key = cell.map(String.init).joined(separator: ":")
        if let index = cells[key] { remap.append(index) }
        else {
            cells[key] = clusters.count; remap.append(clusters.count); clusters.append([])
        }
        clusters[remap.last!].append(point)
    }
    // Minimize error against the original face planes instead of snapping roofs
    // onto a voxel grid. The small centroid term stabilizes planar/linear cells;
    // clamping keeps vertices inside their original cluster's bounds.
    let zero = simd_double3x3(0)
    var quadrics = [simd_double3x3](repeating: zero, count: clusters.count)
    var rhs = [SIMD3<Double>](repeating: .zero, count: clusters.count)
    for triangle in triangles {
        let a = normalized[triangle[0]], b = normalized[triangle[1]], c = normalized[triangle[2]]
        let cross = simd_cross(b - a, c - a), area = simd_length(cross)
        guard area > 1e-9 else { continue }
        let n = cross / area
        let q = simd_double3x3(columns: (n * n.x, n * n.y, n * n.z)) * area
        let r = n * simd_dot(n, a) * area
        for index in Set(triangle.prefix(3).map { remap[$0] }) {
            quadrics[index] += q; rhs[index] += r
        }
    }
    let coarseVertices = clusters.enumerated().map { index, points -> [Double] in
        let average = points.reduce(SIMD3<Double>.zero, +) / Double(points.count)
        let low = points.reduce(SIMD3<Double>(repeating: .infinity), simd_min)
        let high = points.reduce(SIMD3<Double>(repeating: -.infinity), simd_max)
        let q = quadrics[index]
        let weight = max(1e-8, (q[0, 0] + q[1, 1] + q[2, 2]) * 0.001)
        let system = q + matrix_identity_double3x3 * weight
        var point = simd_inverse(system) * (rhs[index] + average * weight)
        if !point.x.isFinite || !point.y.isFinite || !point.z.isFinite { point = average }
        point = simd_clamp(point, low, high)
        if low.z == 0 { point.z = 0 }
        if high.z == 1 { point.z = 1 }
        return [round(point.x), round(point.y), round(point.z)]
    }
    var seenFaces = Set<String>(), coarseFaces: [[Int]] = []
    for triangle in triangles {
        let face = triangle.prefix(3).map { remap[$0] }
        guard Set(face).count == 3 else { continue }
        let key = face.sorted().map(String.init).joined(separator: ":")
        guard seenFaces.insert(key).inserted else { continue }
        coarseFaces.append(face + [triangle[3]])
    }
    // Clustering can be wasteful for tiny props; retain their smaller original.
    if !coarseFaces.isEmpty && coarseFaces.count < triangles.count {
        result["vertices"] = coarseVertices; result["triangles"] = coarseFaces
    }
    result["id"] = id + "-lod"
    try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        .write(to: output.appendingPathComponent("environment-" + id + "-lod.json"))
    manifest.append(["id": id, "pack": pack, "source": name + ".obj", "triangles": triangles.count,
                     "coarseTriangles": (result["triangles"] as! [[Int]]).count,
                     "aspect": [round(dimensions.x / dimensions.y), round(dimensions.z / dimensions.y)]])
    print("\(id): \(triangles.count) / \((result["triangles"] as! [[Int]]).count) triangles (full / coarse)")
}
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("environment-models-manifest.json"))
