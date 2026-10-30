#if os(iOS)
import CoreGraphics

/// Small, seamless fields of flat facets, shared by all map surface materials.
/// This is cartographic decoration, not a model of terrain elevation or waves.
enum MapTerrainPattern {
    enum Material: String, CaseIterable {
        case water = "Water", grass = "Grass", forestGround = "ForestGround"
        case sand = "Sand", rock = "Rock", asphalt = "Asphalt"

        func palette(dark: Bool) -> UInt32 {
            switch self {
            case .water: return dark ? 0x254754 : 0xB5DCE5
            case .grass: return dark ? 0x344638 : 0xDCE8CF
            case .forestGround: return dark ? 0x293A2D : 0xB9C6A4
            case .sand: return dark ? 0x4A4435 : 0xEEE5CF
            case .rock: return dark ? 0x3C4142 : 0xD6D7D2
            case .asphalt: return dark ? 0x303238 : 0xDAD9D5
            }
        }

        fileprivate var grid: (columns: Int, rows: Int) {
            switch self {
            case .water: return (4, 7) // Wider, quieter facets on water.
            case .grass: return (5, 5)
            case .forestGround: return (4, 5)
            case .sand: return (4, 4)
            case .rock: return (5, 4)
            case .asphalt: return (4, 4)
            }
        }

        fileprivate var amplitude: CGFloat {
            switch self {
            case .water: return 18
            case .grass: return 14
            case .forestGround: return 16
            case .sand: return 12
            case .rock: return 17
            case .asphalt: return 7
            }
        }

        fileprivate var seed: UInt32 {
            switch self {
            case .water: return 17
            case .grass: return 43
            case .forestGround: return 71
            case .sand: return 101
            case .rock: return 137
            case .asphalt: return 173
            }
        }
    }

    static let tileSize = 256

    static func image(_ material: Material, dark: Bool) -> CGImage? {
        guard let context = CGContext(data: nil, width: tileSize, height: tileSize,
            bitsPerComponent: 8, bytesPerRow: tileSize * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let grid = material.grid
        let width = CGFloat(tileSize) / CGFloat(grid.columns)
        let height = CGFloat(tileSize) / CGFloat(grid.rows)
        let base = material.palette(dark: dark)
        let red = CGFloat((base >> 16) & 255)
        let green = CGFloat((base >> 8) & 255)
        let blue = CGFloat(base & 255)
        let amplitude = material.amplitude * (dark ? 0.5 : 1)

        // Periodic vertex positions AND face colors make every edge wrap.
        // The extra cells cover vertices displaced across the tile boundary.
        func hash(_ x: Int, _ y: Int, salt: UInt32) -> UInt32 {
            let column = UInt32((x % grid.columns + grid.columns) % grid.columns)
            let row = UInt32((y % grid.rows + grid.rows) % grid.rows)
            var value = column &* 374_761_393 &+ row &* 668_265_263 &+ material.seed &+ salt
            value = (value ^ (value >> 13)) &* 1_274_126_177
            return value ^ (value >> 16)
        }
        func vertex(_ x: Int, _ y: Int) -> CGPoint {
            let dx = CGFloat(hash(x, y, salt: 11) % 1_001) / 1_000 - 0.5
            let dy = CGFloat(hash(x, y, salt: 29) % 1_001) / 1_000 - 0.5
            return CGPoint(x: (CGFloat(x) + dx * 0.64) * width,
                           y: (CGFloat(y) + dy * 0.64) * height)
        }
        func fill(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, shade: CGFloat) {
            let detail = shade * amplitude
            context.setFillColor(CGColor(red: (red + detail) / 255,
                green: (green + detail) / 255, blue: (blue + detail) / 255, alpha: 1))
            context.beginPath()
            context.move(to: a)
            context.addLine(to: b)
            context.addLine(to: c)
            context.closePath()
            context.fillPath()
        }
        // Adjacent triangles share their exact edges. Antialiasing each face
        // separately would leave hairline seams between otherwise opaque fills.
        context.setShouldAntialias(false)
        for y in -1...grid.rows {
            for x in -1...grid.columns {
                let a = vertex(x, y), b = vertex(x + 1, y)
                let c = vertex(x + 1, y + 1), d = vertex(x, y + 1)
                let tone = CGFloat(Int(hash(x, y, salt: 53) % 5) - 2) * 0.30
                let tilt: CGFloat = hash(x, y, salt: 79) % 2 == 0 ? 0.20 : -0.20
                if hash(x, y, salt: 97) % 2 == 0 {
                    fill(a, b, c, shade: tone + tilt)
                    fill(a, c, d, shade: tone - tilt)
                } else {
                    fill(a, b, d, shade: tone + tilt)
                    fill(b, c, d, shade: tone - tilt)
                }
            }
        }
        return context.makeImage()
    }
}
#endif
