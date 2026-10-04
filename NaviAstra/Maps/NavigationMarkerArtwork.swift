import CoreGraphics
import Foundation

/// Small authored 3D meshes projected into cached transparent 2.5D sprites.
/// No map SDK, SwiftUI tree, network resource or live 3D scene is needed to draw a model.
@MainActor
enum NavigationMarkerArtwork {
    private struct Point {
        var x: Double, y: Double, z: Double
        static func + (a: Self, b: Self) -> Self { Self(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
        static func - (a: Self, b: Self) -> Self { Self(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
        static func * (a: Self, b: Double) -> Self { Self(x: a.x * b, y: a.y * b, z: a.z * b) }
        func dot(_ p: Self) -> Double { x * p.x + y * p.y + z * p.z }
        func cross(_ p: Self) -> Self {
            Self(x: y * p.z - z * p.y, y: z * p.x - x * p.z, z: x * p.y - y * p.x)
        }
        var unit: Self { self * (1 / max(0.0001, sqrt(dot(self)))) }
    }
    private struct Face {
        var points: [Point]
        var color: UInt32
        var outlined = false
        var shadingNormal: Point?
    }
    private final class CachedImage: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private static let cache: NSCache<NSString, CachedImage> = {
        let value = NSCache<NSString, CachedImage>()
        value.totalCostLimit = 12 * 1024 * 1024
        return value
    }()
    private static var meshes: [String: [Face]] = [:]

    /// Angles are sampled only for tilted maps. A top-down image rotates continuously in the view.
    static func image(model: NavigationMarkerModel, paint: NavigationMarkerPaint,
                      bearing: Double, pitch: Double, night: Bool) -> CGImage? {
        let yaw = Int((normalized(bearing) / 5).rounded()) % 72 * 5
        let tilt = Int((max(0, min(60, pitch)) / 5).rounded()) * 5
        let key = "\(model.rawValue):\(paint.rawValue):\(yaw):\(tilt):\(night)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        let meshKey = "\(model.rawValue):\(paint.rawValue)"
        let faces: [Face]
        if let stored = meshes[meshKey] { faces = stored }
        else {
            faces = makeMesh(model, paint: paint.hex)
            meshes[meshKey] = faces
        }
        let pixels = 160
        guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                      bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2.5, y: 2.5)
        context.translateBy(x: 0, y: 64)
        context.scaleBy(x: 1, y: -1)
        context.setAllowsAntialiasing(true)
        let angle = Double(yaw) * .pi / 180
        let tiltAngle = Double(tilt) * .pi / 180
        let c = cos(angle), s = sin(angle), ct = cos(tiltAngle), st = sin(tiltAngle)
        let viewing = Point(x: 0, y: -st, z: ct)
        let light = Point(x: -0.45, y: -0.55, z: 1).unit
        let halfLight = (light + viewing).unit
        func rotate(_ p: Point) -> Point {
            Point(x: p.x * c + p.y * s, y: -p.x * s + p.y * c, z: p.z)
        }
        func screen(_ p: Point) -> CGPoint {
            CGPoint(x: 32 + p.x * 11, y: 32 - (p.y * ct + p.z * st) * 11)
        }
        // Contact shadow is centered on the ground anchor, independent of model height.
        context.saveGState()
        context.translateBy(x: 32, y: 33)
        context.scaleBy(x: 1, y: max(0.45, ct))
        context.rotate(by: CGFloat(angle))
        context.setFillColor(color(0x07101E, alpha: night ? 0.17 : 0.065))
        context.setShadow(offset: .zero, blur: 2.5, color: color(0x07101E, alpha: night ? 0.18 : 0.11))
        let pedestrian = model == .pedestrian
        context.fillEllipse(in: CGRect(x: pedestrian ? -7 : -10, y: pedestrian ? -7 : -18,
                                       width: pedestrian ? 14 : 20, height: pedestrian ? 14 : 36))
        context.restoreGState()
        let visible = faces.compactMap { face -> (points: [Point], color: UInt32, shade: Double, reflection: Double, depth: Double, outlined: Bool)? in
            let points = face.points.map(rotate)
            guard points.count >= 3 else { return nil }
            let normal = (points[1] - points[0]).cross(points[2] - points[0]).unit
            guard normal.dot(viewing) > 0.001 else { return nil }
            let depth = points.reduce(0) { $0 + $1.dot(viewing) } / Double(points.count)
            let shading = face.shadingNormal.map(rotate) ?? normal
            let diffuse = max(0, shading.dot(light))
            let reflection = pow(max(0, shading.dot(halfLight)), 18) * (night ? 0.15 : 0.1)
            return (points, face.color, (night ? 0.62 : 0.54) + 0.43 * diffuse,
                    reflection, depth, face.outlined)
        }.sorted { $0.depth < $1.depth }
        for face in visible {
            let path = CGMutablePath()
            path.addLines(between: face.points.map(screen))
            path.closeSubpath()
            context.addPath(path)
            // Black paint needs a broader cool reflection to keep its silhouette on dark roads.
            let nightReflection = face.color == NavigationMarkerPaint.graphite.hex ? 0.2 : 0.055
            let material = night ? blend(face.color, with: 0x8AA5C8, amount: nightReflection) : face.color
            let reflected = blend(material, with: night ? 0xB1C5E4 : 0xEDF4FF, amount: face.reflection)
            let fill = color(reflected, brightness: face.shade)
            context.setFillColor(fill)
            // Overlap adjacent fills slightly: antialiased mesh edges must not become wire outlines.
            context.setStrokeColor(face.outlined
                ? color(night ? 0xA6BFDD : 0x172237, alpha: night ? 0.07 : 0.16) : fill)
            context.setLineWidth(face.outlined ? 0.25 : 0.35)
            context.setLineJoin(.round)
            context.drawPath(using: .fillStroke)
        }
        guard let image = context.makeImage() else { return nil }
        cache.setObject(CachedImage(image), forKey: key, cost: pixels * pixels * 4)
        return image
    }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func color(_ hex: UInt32, brightness: Double = 1, alpha: Double = 1) -> CGColor {
        CGColor(red: min(1, Double((hex >> 16) & 255) / 255 * brightness),
                green: min(1, Double((hex >> 8) & 255) / 255 * brightness),
                blue: min(1, Double(hex & 255) / 255 * brightness), alpha: alpha)
    }

    private static func blend(_ value: UInt32, with other: UInt32, amount: Double) -> UInt32 {
        let a = max(0, min(1, amount))
        func channel(_ shift: UInt32) -> UInt32 {
            UInt32((Double((value >> shift) & 255) * (1 - a) + Double((other >> shift) & 255) * a).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    private static func makeMesh(_ model: NavigationMarkerModel, paint: UInt32) -> [Face] {
        var faces: [Face] = []
        let glass: UInt32 = 0x253F58
        let tire: UInt32 = 0x202938
        let silver: UInt32 = 0xBBC9D9
        func prism(_ base: [Point], _ top: [Point], _ color: UInt32) {
            faces.append(Face(points: top, color: color))
            for i in base.indices {
                let next = (i + 1) % base.count
                faces.append(Face(points: [base[i], base[next], top[next], top[i]], color: color))
            }
        }
        func box(x: Double = 0, y: Double = 0, z: Double, width: Double,
                 length: Double, height: Double, color: UInt32, bevel: Double = 0.12) {
            let w = width / 2, l = length / 2, b = min(bevel, min(w, l) * 0.5)
            let contour = [(-w + b, -l), (w - b, -l), (w, -l + b), (w, l - b),
                           (w - b, l), (-w + b, l), (-w, l - b), (-w, -l + b)]
            prism(contour.map { Point(x: $0.0 + x, y: $0.1 + y, z: z) },
                  contour.map { Point(x: $0.0 + x, y: $0.1 + y, z: z + height) }, color)
        }
        func tube(_ start: Point, _ end: Point, radius: Double, color: UInt32, sides: Int = 10) {
            let axis = (end - start).unit
            let helper = abs(axis.z) < 0.8 ? Point(x: 0, y: 0, z: 1) : Point(x: 1, y: 0, z: 0)
            let u = helper.cross(axis).unit * radius
            let v = axis.cross(u).unit * radius
            let ring = (0..<sides).map { index in
                let a = Double(index) * 2 * .pi / Double(sides)
                return u * cos(a) + v * sin(a)
            }
            prism(ring.map { start + $0 }, ring.map { end + $0 }, color)
            faces.append(Face(points: ring.reversed().map { start + $0 }, color: color))
        }
        func sphere(_ center: Point, rx: Double, ry: Double, rz: Double, color: UInt32) {
            let bands = 10, sides = 20
            func point(_ band: Int, _ side: Int) -> Point {
                let latitude = -.pi / 2 + Double(band) * .pi / Double(bands)
                let longitude = Double(side) * 2 * .pi / Double(sides)
                return center + Point(x: rx * cos(latitude) * cos(longitude),
                                      y: ry * cos(latitude) * sin(longitude), z: rz * sin(latitude))
            }
            for band in 0..<bands {
                for side in 0..<sides {
                    let a = point(band, side), b = point(band, side + 1)
                    let c = point(band + 1, side + 1), d = point(band + 1, side)
                    // Avoid degenerate first edges at the poles.
                    let polygon = band == 0 ? [a, c, d] : (band == bands - 1 ? [a, b, c] : [a, b, c, d])
                    faces.append(Face(points: polygon, color: color, shadingNormal: (polygon.reduce(Point(x: 0, y: 0, z: 0), +) * (1 / Double(polygon.count)) - center).unit))
                }
            }
        }
        func wheel(y: Double, width: Double, radius: Double, x: Double = 0) {
            tube(Point(x: x - width / 2, y: y, z: radius), Point(x: x + width / 2, y: y, z: radius),
                 radius: radius, color: tire, sides: 14)
            for side in [-1.0, 1.0] {
                let edge = x + side * (width / 2 + 0.005)
                tube(Point(x: edge - 0.008, y: y, z: radius), Point(x: edge + 0.008, y: y, z: radius),
                     radius: radius * 0.62, color: silver, sides: 12)
            }
        }
        switch model {
        case .compact, .sedan, .suv, .estate:
            let sedan = model == .sedan || model == .estate
            let suv = model == .suv
            let length = sedan ? 4.05 : (suv ? 3.85 : 3.35)
            let width = suv ? 1.78 : (sedan ? 1.65 : 1.62)
            let shoulder = suv ? 0.95 : 0.78
            // Longitudinal sections make the nose, shoulders and tail genuinely curved.
            let sections: [(Double, Double, Double)] = [
                (-0.5, 0.73, 0.82), (-0.46, 0.91, 0.95), (-0.32, 1, 1),
                (-0.05, 1, 1), (0.25, 0.98, 0.98), (0.42, 0.89, 0.88), (0.5, 0.68, 0.76)
            ]
            let cross: [(Double, Double)] = [(-0.78, 0), (0.78, 0), (0.96, 0.16), (1, 0.42),
                (0.92, 0.75), (0.75, 0.93), (0.35, 1), (-0.35, 1), (-0.75, 0.93), (-0.92, 0.75), (-1, 0.42), (-0.96, 0.16)]
            let rings = sections.map { section in
                cross.map { Point(x: $0.0 * width / 2 * section.1, y: section.0 * length,
                                   z: 0.25 + $0.1 * (shoulder - 0.25) * section.2) }
            }
            for row in 0..<(rings.count - 1) {
                for side in cross.indices {
                    let next = (side + 1) % cross.count
                    let polygon = [rings[row][side], rings[row + 1][side], rings[row + 1][next], rings[row][next]]
                    let normal = (polygon[1] - polygon[0]).cross(polygon[2] - polygon[0]).unit
                    faces.append(Face(points: polygon, color: paint, shadingNormal: normal))
                }
            }
            faces.append(Face(points: rings[0], color: paint))
            faces.append(Face(points: Array(rings.last!.reversed()), color: paint))
            for y in [-length * 0.29, length * 0.28] {
                for x in [-width * 0.47, width * 0.47] {
                    tube(Point(x: x - 0.11, y: y, z: 0.32), Point(x: x + 0.11, y: y, z: 0.32),
                         radius: suv ? 0.33 : 0.29, color: 0x222B34, sides: 16)
                }
            }
            // Distinct cabin/trunk proportions: short hatch, low sedan, broad upright SUV.
            let cabinRear = suv ? -1.36 : (sedan ? -1.16 : -1.12)
            let roofRear = suv ? -1.02 : (sedan ? -0.62 : -0.85)
            let roofFront = suv ? 0.34 : (sedan ? 0.28 : 0.22)
            let cabinFront = suv ? 0.98 : (sedan ? 0.92 : 0.73)
            let cabinHeight = suv ? 0.62 : 0.47
            let cabinSections: [(Double, Double, Double)] = [
                (cabinRear, width * 0.39, shoulder + 0.035),
                (roofRear, width * 0.34, shoulder + cabinHeight),
                (roofFront, width * 0.33, shoulder + cabinHeight),
                (cabinFront, width * 0.39, shoulder + 0.035)
            ]
            let cabin = cabinSections.map { y, w, z in
                [Point(x: -width * 0.41, y: y, z: shoulder - 0.04),
                 Point(x: width * 0.41, y: y, z: shoulder - 0.04),
                 Point(x: w, y: y, z: z), Point(x: -w, y: y, z: z)]
            }
            for row in 0..<(cabin.count - 1) {
                for side in 1...3 {
                    let next = (side + 1) % 4
                    let isRoof = row == 1 && side == 2
                    let tone = isRoof ? paint : glass
                    faces.append(Face(points: [cabin[row][side], cabin[row + 1][side], cabin[row + 1][next], cabin[row][next]], color: tone))
                }
            }
            // One broad windscreen reflection survives at marker size; no fine seams or wire outlines.
            let reflectionY = roofFront + (cabinFront - roofFront) * 0.32
            let reflectionZ = shoulder + cabinHeight * 0.7 + 0.035
            faces.append(Face(points: [Point(x: -width * 0.29, y: reflectionY, z: reflectionZ),
                Point(x: width * 0.29, y: reflectionY, z: reflectionZ),
                Point(x: width * 0.28, y: reflectionY - 0.095, z: reflectionZ + 0.065),
                Point(x: -width * 0.28, y: reflectionY - 0.095, z: reflectionZ + 0.065)], color: 0x5C748A))
            for side in [-1.0, 1.0] {
                box(x: side * width * 0.28, y: length * 0.44, z: shoulder * 0.9,
                    width: 0.43, length: 0.105, height: 0.035, color: 0xDEE8F0, bevel: 0.04)
                box(x: side * width * 0.27, y: -length * 0.445, z: shoulder * 0.92,
                    width: 0.4, length: 0.1, height: 0.035, color: 0xAF343C, bevel: 0.04)
            }
        case .cityBike, .roadBike:
            // One restrained rider silhouette, matte wheels and a single readable frame triangle.
            for y in [-1.12, 1.12] {
                tube(Point(x: -0.075, y: y, z: 0.55), Point(x: 0.075, y: y, z: 0.55),
                     radius: 0.55, color: tire, sides: 20)
            }
            let rear = Point(x: 0, y: -1.12, z: 0.55), front = Point(x: 0, y: 1.12, z: 0.55)
            let crank = Point(x: 0, y: -0.15, z: 0.48), saddle = Point(x: 0, y: -0.42, z: 1.22)
            let stem = Point(x: 0, y: 0.64, z: 1.2)
            for pair in [(rear, crank), (crank, saddle), (saddle, rear), (saddle, stem), (stem, crank), (stem, front)] {
                tube(pair.0, pair.1, radius: 0.065, color: paint, sides: 8)
            }
            tube(Point(x: -0.4, y: 0.72, z: 1.34), Point(x: 0.4, y: 0.72, z: 1.34), radius: 0.055, color: tire, sides: 8)
            sphere(Point(x: 0, y: -0.08, z: 1.48), rx: 0.27, ry: 0.43, rz: 0.35, color: paint)
            sphere(Point(x: 0, y: 0.28, z: 1.89), rx: 0.23, ry: 0.25, rz: 0.23, color: 0xABB7C4)
            for side in [-1.0, 1.0] {
                tube(Point(x: side * 0.22, y: 0.04, z: 1.58), Point(x: side * 0.36, y: 0.72, z: 1.34), radius: 0.08, color: paint, sides: 8)
                tube(Point(x: side * 0.14, y: -0.4, z: 1.19), Point(x: side * 0.25, y: -0.04, z: 0.56), radius: 0.1, color: tire, sides: 8)
            }
        case .pedestrian:
            // Universal neutral form: no face, backpack, oversized shoes or game-avatar details.
            sphere(Point(x: 0, y: 0, z: 1.06), rx: 0.34, ry: 0.24, rz: 0.4, color: paint)
            sphere(Point(x: 0, y: 0.04, z: 1.61), rx: 0.24, ry: 0.25, rz: 0.26, color: 0xABB7C4)
            for side in [-1.0, 1.0] {
                tube(Point(x: side * 0.14, y: 0, z: 0.74), Point(x: side * 0.18, y: side * 0.08, z: 0.13), radius: 0.115, color: tire)
                tube(Point(x: side * 0.32, y: 0, z: 1.22), Point(x: side * 0.38, y: -side * 0.1, z: 0.74), radius: 0.085, color: paint)
            }
        case .bus, .tram, .train:
            let length = model == .bus ? 3.5 : 3.9
            box(z: 0.25, width: 1.6, length: length, height: 1.1, color: paint, bevel: model == .train ? 0.35 : 0.18)
            box(z: 1.35, width: 1.45, length: length - 0.18, height: 0.12, color: 0xDEE7F2)
            box(y: length / 2 - 0.03, z: 0.7, width: 1.22, length: 0.09, height: 0.51, color: glass)
            for x in [-0.81, 0.81] {
                for y in [-1.1, -0.3, 0.5] {
                    box(x: x, y: y, z: 0.68, width: 0.025, length: 0.56, height: 0.48, color: glass, bevel: 0.01)
                }
            }
            if model != .bus { box(z: 1.48, width: 0.72, length: 0.7, height: 0.18, color: silver) }
            for x in [-0.5, 0.5] {
                box(x: x, y: length / 2 - 0.1, z: 0.45, width: 0.22, length: 0.17, height: 0.05, color: 0xF4F8FC)
            }
        case .ferry:
            let base = [Point(x: -0.55, y: -1.7, z: 0.1), Point(x: 0.55, y: -1.7, z: 0.1),
                        Point(x: 0.75, y: 0.9, z: 0.1), Point(x: 0, y: 1.85, z: 0.1), Point(x: -0.75, y: 0.9, z: 0.1)]
            prism(base, base.map { Point(x: $0.x * 1.15, y: $0.y, z: 0.6) }, paint)
            box(y: -0.15, z: 0.62, width: 1.15, length: 2.05, height: 0.65, color: 0xDEE7F2)
            box(y: 0.6, z: 1.01, width: 0.9, length: 0.13, height: 0.25, color: glass)
            box(y: -0.5, z: 1.3, width: 0.42, length: 0.4, height: 0.45, color: paint)
        }
        return faces
    }
}
