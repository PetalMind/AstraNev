// Run with: swift scripts/navigation-markers/import-kenney.swift <unpacked Car Kit 3.1> <output folder>
// Offline authoring tool; Foundation/ImageIO are supplied with Xcode. No app dependency.
import Foundation
import CoreGraphics
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("Expected unpacked Car Kit folder and output folder") }
let source = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let license = try Data(contentsOf: source.appendingPathComponent("License.txt"))
precondition(String(decoding: license, as: UTF8.self).contains("Car Kit (3.1)"), "Expected Car Kit 3.1")
let objFolder = source.appendingPathComponent("Models/OBJ format")
let textureURL = objFolder.appendingPathComponent("Textures/colormap.png")
let imageSource = CGImageSourceCreateWithURL(textureURL as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
pixels.withUnsafeMutableBytes { bytes in
    let context = CGContext(data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}
let names = ["hatchback-sports", "sedan", "suv", "sedan-sports", "suv-luxury", "van", "race"]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try license.write(to: output.appendingPathComponent("kenney-car-kit-license.txt"))
for name in names {
    let text = try String(contentsOf: objFolder.appendingPathComponent(name + ".obj"), encoding: .utf8)
    var vertices: [[Double]] = [], uvs: [[Double]] = [], faces: [([Int], [Int], String)] = []
    var group = ""
    for line in text.split(whereSeparator: \.isNewline) {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard let kind = fields.first else { continue }
        switch kind {
        case "g": group = String(fields[1])
        case "v": vertices.append(fields.dropFirst().prefix(3).map { Double($0)! })
        case "vt": uvs.append(fields.dropFirst().prefix(2).map { Double($0)! })
        case "f":
            let corners = fields.dropFirst().map { $0.split(separator: "/", omittingEmptySubsequences: false) }
            precondition(corners.count == 3, "Expected triangulated OBJ")
            faces.append((corners.map { Int($0[0])! - 1 }, corners.map { Int($0[1])! - 1 }, group))
        default: break
        }
    }
    let minX = vertices.map { $0[0] }.min()!, maxX = vertices.map { $0[0] }.max()!
    let minY = vertices.map { $0[1] }.min()!
    let minZ = vertices.map { $0[2] }.min()!, maxZ = vertices.map { $0[2] }.max()!
    // OBJ +Y is up; nose is +Z. Rotation preserves winding: app +Y is forward, +Z is up.
    // Equal display length keeps long vehicles legible without clipping when the map tilts.
    let scale = 3.8 / (maxZ - minZ)
    func rounded(_ value: Double) -> Double { (value * 100_000).rounded() / 100_000 }
    let points = vertices.map { p in
        [rounded(-(p[0] - (minX + maxX) / 2) * scale),
         rounded((p[2] - (minZ + maxZ) / 2) * scale), rounded((p[1] - minY) * scale)]
    }
    var triangles: [[Int]] = []
    for (indices, textureIndices, group) in faces {
        let uv = textureIndices.map { uvs[$0] }
        let u = uv.reduce(0) { $0 + $1[0] } / 3
        let v = uv.reduce(0) { $0 + $1[1] } / 3
        let x = max(0, min(width - 1, Int(u * Double(width))))
        let y = max(0, min(height - 1, Int((1 - v) * Double(height))))
        let offset = (y * width + x) * 4
        let color = Int(pixels[offset]) << 16 | Int(pixels[offset + 1]) << 8 | Int(pixels[offset + 2])
        // Row 2 contains the body paints. Preserve orange wheels/accents on the racing car.
        let paint = Int(v * 4) == 2 && !group.hasPrefix("wheel") && (name != "race" || Int(u * 16) == 13)
        triangles.append(indices + [paint ? -1 : color])
    }
    let data: [String: Any] = ["vertices": points, "triangles": triangles]
    try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]).write(to: output.appendingPathComponent("kenney-" + name + ".json"))
    print("\(name): \(vertices.count) vertices, \(faces.count) triangles, \(triangles.filter { $0[3] == -1 }.count) paintable faces")
}
