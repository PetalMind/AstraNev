// Contact sheet of the production CoreGraphics patterns; not a MapLibre screenshot.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let width = 1696, height = 760
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.94, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
func label(_ text: String, x: Int, y: Int, size: CGFloat, color: NSColor = .darkGray) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color])
    NSGraphicsContext.restoreGraphicsState()
}
label("NaviAstra · powierzchnie low poly", x: 32, y: height - 48, size: 24)
label("Próbki dnia i nocy · każda pokazuje powtórzenie 2 × 2 · pełne krycie", x: 32, y: height - 77, size: 14)
let names = ["Water": "Woda", "Grass": "Trawa i łąki", "ForestGround": "Podłoże lasu",
             "Sand": "Piasek", "Rock": "Skały", "Asphalt": "Parkingi"]
for (index, material) in MapTerrainPattern.Material.allCases.enumerated() {
    let x = 32 + (index % 3) * 552
    let top = height - 115 - (index / 3) * 318
    label(names[material.rawValue]!, x: x, y: top, size: 18)
    for dark in [false, true] {
        let image = MapTerrainPattern.image(material, dark: dark)!
        let bottom = top - 266
        let left = x + (dark ? 268 : 0)
        for row in 0..<2 {
            for column in 0..<2 {
                context.draw(image, in: CGRect(x: left + column * 128, y: bottom + row * 128,
                    width: 128, height: 128))
            }
        }
        label(dark ? "Noc" : "Dzień", x: left, y: bottom - 20, size: 12)
    }
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
print(url.path)
