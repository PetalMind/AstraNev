// Offline contact sheet, not a screenshot of MapLibre.
// swift scripts/environment-models/preview.swift <models folder> <output.png> [--coarse] [prefix]
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import simd

precondition(CommandLine.arguments.count >= 3)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let options = Array(CommandLine.arguments.dropFirst(3))
let coarse = options.contains("--coarse")
let prefix = options.first { !$0.hasPrefix("--") } ?? ""
let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
    $0.lastPathComponent.hasPrefix("environment-" + prefix)
        && $0.pathExtension == "json" && $0.lastPathComponent != "environment-models-manifest.json"
        && $0.lastPathComponent.hasSuffix("-lod.json") == coarse
}.sorted { $0.lastPathComponent < $1.lastPathComponent }
precondition(!files.isEmpty)
let columns = min(6, files.count), cellWidth = 240, cellHeight = 250
let width = columns * cellWidth, height = ((files.count + columns - 1) / columns) * cellHeight
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(gray: 0.94, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

func label(_ id: String) -> String {
    if id.hasPrefix("house-") { return "Dom " + id.suffix(1).uppercased() }
    if id.hasPrefix("block-") { return "Blok " + id.suffix(1).uppercased() }
    if id.hasPrefix("tower-") { return "Wieżowiec " + id.suffix(1).uppercased() }
    if id.hasPrefix("industrial-") { return "Obiekt przemysłowy " + id.suffix(1).uppercased() }
    let names = ["bench": "Ławka", "bench-park": "Ławka parkowa", "bollard-column": "Słupek",
        "commercial-a": "Budynek usługowy A", "commercial-b": "Budynek usługowy B",
        "street-lamp": "Latarnia", "traffic-signal": "Sygnalizator", "tree-branched": "Drzewo rozłożyste",
        "tree-broad": "Drzewo z szeroką koroną", "tree-conifer": "Drzewo iglaste A",
        "tree-pineDefaultA": "Drzewo iglaste B", "tree-pineRoundA": "Drzewo iglaste C",
        "tree-rounded": "Drzewo z okrągłą koroną", "tree-fat": "Drzewo przysadziste",
        "tree-thin": "Drzewo smukłe", "tree-tall": "Drzewo wysokie", "tree-small": "Drzewo niewielkie",
        "tree-plateau": "Drzewo z płaską koroną"]
    return names[id] ?? "Model otoczenia"
}

for (index, file) in files.enumerated() {
    let document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    let id = (document["id"] as! String).replacingOccurrences(of: "-lod", with: "")
    let vertices = (document["vertices"] as! [[Double]]).map { SIMD3<Double>($0[0], $0[1], $0[2]) }
    let triangles = document["triangles"] as! [[Int]]
    let aspect = document["aspect"] as! [Double]
    let points = vertices.map { $0 * SIMD3(aspect[0], aspect[1], 1) }
    let cosine = cos(0.55), sine = sin(0.55)
    func project(_ point: SIMD3<Double>) -> CGPoint {
        CGPoint(x: cosine * point.x + sine * point.y,
                y: point.z * 0.85 + (-sine * point.x + cosine * point.y) * 0.52)
    }
    let projected = points.map(project)
    let minX = projected.map(\.x).min()!, maxX = projected.map(\.x).max()!
    let minY = projected.map(\.y).min()!, maxY = projected.map(\.y).max()!
    let scale = min(210 / max(0.01, maxX - minX), 195 / max(0.01, maxY - minY))
    let x = index % columns * cellWidth, y = height - (index / columns + 1) * cellHeight
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (label(id) as NSString).draw(at: NSPoint(x: x + 10, y: y + 12), withAttributes: [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    func depth(_ face: [Int]) -> Double {
        face.prefix(3).map { points[$0].y * cosine - points[$0].x * sine - points[$0].z * 0.5 }.reduce(0, +)
    }
    for face in triangles.sorted(by: { depth($0) > depth($1) }) {
        let a = points[face[0]], b = points[face[1]], c = points[face[2]]
        let cross = simd_cross(b - a, c - a)
        guard simd_length(cross) > 1e-9 else { continue }
        let normal = simd_normalize(cross)
        var shade = 0.66 + 0.34 * max(0, simd_dot(normal, simd_normalize(SIMD3(-0.4, 0.55, 0.8))))
        let hex = face[3]
        var color = SIMD3<Double>(Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255)
        if id.hasPrefix("tree-") {
            if color.y >= color.x * 1.2 { color = color * 0.35 + SIMD3(0.30, 0.49, 0.25) * 0.65 }
            let z = face.prefix(3).map { vertices[$0].z }.reduce(0, +) / 3
            let q = max(0, min(1, z / 0.7)); shade *= 0.77 + 0.23 * q * q * (3 - 2 * q)
        } else if ["house-", "commercial-", "block-", "tower-", "industrial-"].contains(where: id.hasPrefix),
                  color.y > color.x * 1.35, color.y > color.z * 1.05, vertices[face[0]].z > 0.28 {
            color = SIMD3(0.43, 0.39, 0.35)
        }
        context.setFillColor(CGColor(red: color.x * shade, green: color.y * shade, blue: color.z * shade, alpha: 1))
        let path = CGMutablePath()
        for (corner, vertex) in face.prefix(3).enumerated() {
            let p = projected[vertex]
            let point = CGPoint(x: Double(x + cellWidth / 2) + (p.x - (minX + maxX) / 2) * scale,
                                y: Double(y + 135) + (p.y - (minY + maxY) / 2) * scale)
            if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath(); context.addPath(path); context.fillPath()
    }
}
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL,
    UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
