#if os(iOS)
import Foundation
import CoreLocation

/// Original, schematic models in meters, anchored to real provider points.
/// Planet supplies neither dimensions nor the orientation of these objects.
/// The fixed north-facing template is decorative, not surveyed street geometry.
enum MapStreetFurnitureGeometry {
    enum Kind: String, CaseIterable {
        case bench, streetLamp = "street_lamp", bollard, trafficSignals = "traffic_signals", tree
        case fountain, entrance, kerb, sign, speedCamera, camera, stop, station, charger, parcelLocker
    }
    enum Detail: Int, CaseIterable { case simple, standard, full }
    struct Bounds {
        let minimum: SIMD3<Double>
        let maximum: SIMD3<Double>
    }
    static let lampLensHeight: Float = 5.72
    static let lampLensNorthOffset: Float = 1.05
    struct Part {
        let outline: [SIMD2<Double>]
        let base: Double
        let top: Double
        let material: String
    }

    static let bench: [Part] = {
        var parts: [Part] = []
        // Four wooden seat slats, with genuine gaps between them.
        for row in 0..<4 {
            parts.append(box(x: 0, y: -0.21 + Double(row) * 0.14,
                             width: 1.8, depth: 0.115, base: 0.43, top: 0.49, material: "wood"))
        }
        // Two backrest slats, supported by the rear uprights.
        for base in [0.64, 0.83] {
            parts.append(box(x: 0, y: -0.285, width: 1.8, depth: 0.07,
                             base: base, top: base + 0.14, material: "wood"))
        }
        for x in [-0.67, 0.67] {
            for y in [-0.24, 0.23] {
                parts.append(box(x: x, y: y, width: 0.09, depth: 0.09,
                                 base: 0, top: y < 0 ? 0.98 : 0.70, material: "steel"))
            }
            parts.append(box(x: x, y: 0, width: 0.10, depth: 0.58,
                             base: 0.65, top: 0.71, material: "steel"))
            parts.append(box(x: x, y: 0, width: 0.10, depth: 0.54,
                             base: 0.37, top: 0.43, material: "steel"))
        }
        return parts
    }()

    static let streetLamp: [Part] = [
        cylinder(radius: 0.20, base: 0, top: 0.12),
        cylinder(radius: 0.105, base: 0.12, top: 0.65),
        cylinder(radius: 0.075, base: 0.65, top: 3.6),
        cylinder(radius: 0.055, base: 3.6, top: 5.9),
        box(x: 0, y: 0.55, width: 0.10, depth: 1.2, base: 5.80, top: 5.91, material: "steel"),
        box(x: 0, y: 1.05, width: 0.32, depth: 0.64, base: 5.74, top: 5.90, material: "steel"),
        // The custom light layer adds a luminous core and bloom at this lens.
        box(x: 0, y: 1.05, width: 0.25, depth: 0.49, base: 5.72, top: 5.74, material: "lens")
    ]

    static let bollard: [Part] = [
        cylinder(radius: 0.16, base: 0, top: 0.08),
        cylinder(radius: 0.075, base: 0.08, top: 0.72),
        cylinder(radius: 0.079, base: 0.72, top: 0.82, material: "reflector"),
        cylinder(radius: 0.075, base: 0.82, top: 0.95),
        cylinder(radius: 0.055, base: 0.95, top: 0.99)
    ]

    static let trafficSignals: [Part] = {
        var parts = [
            cylinder(radius: 0.15, base: 0, top: 0.10),
            cylinder(radius: 0.055, base: 0.10, top: 3.25),
            box(x: 0, y: 0.12, width: 0.10, depth: 0.30, base: 2.48, top: 2.56, material: "steel"),
            box(x: 0, y: 0.21, width: 0.32, depth: 0.22, base: 2.28, top: 3.16, material: "signalHousing")
        ]
        // All three lenses are dark. No live signal state or road-facing bearing is supplied.
        for base in [2.36, 2.62, 2.88] {
            parts.append(box(x: 0, y: 0.335, width: 0.19, depth: 0.035,
                             base: base, top: base + 0.18, material: "signalLens"))
            parts.append(box(x: 0, y: 0.38, width: 0.25, depth: 0.18,
                             base: base + 0.18, top: base + 0.21, material: "signalHousing"))
        }
        return parts
    }()

    static let tree: [Part] = {
        var parts = [cylinder(radius: 0.16, base: 0, top: 3.25, material: "bark")]
        // A neutral, rounded low-poly crown. No leaf type, species, age or measured size is inferred.
        let layers = 10, bottom = 2.1, crownHeight = 4.2, radius = 2.05
        for index in 0..<layers {
            let base = bottom + Double(index) * crownHeight / Double(layers)
            let top = bottom + Double(index + 1) * crownHeight / Double(layers)
            let relative = (Double(index) + 0.5) / Double(layers) * 2 - 1
            let width = radius * sqrt(max(0, 1 - relative * relative))
            parts.append(cylinder(radius: width, base: base, top: top,
                                  material: index.isMultiple(of: 3) ? "foliageLight" : "foliage"))
        }
        return parts
    }()

    /// Neutral basin with a raised rim; no running water is inferred from a fountain POI.
    static let fountain: [Part] = {
        var parts = [cylinder(radius: 1.25, base: 0, top: 0.16, material: "stone")]
        for index in 0..<12 {
            let angle = Double(index) * .pi / 6
            let a = SIMD2(cos(angle), sin(angle)) * 1.25
            let b = SIMD2(cos(angle + .pi / 6), sin(angle + .pi / 6)) * 1.25
            let c = b * 0.82, d = a * 0.82
            parts.append(Part(outline: [a, b, c, d, a], base: 0.16, top: 0.48, material: "stone"))
        }
        parts.append(cylinder(radius: 0.17, base: 0.16, top: 1.05, material: "stone"))
        return parts
    }()

    // A schematic access frame, not a door asserted to lie in a surveyed facade.
    static let entrance: [Part] = [
        box(x: -0.53, y: 0, width: 0.12, depth: 0.20, base: 0, top: 2.2, material: "stone"),
        box(x: 0.53, y: 0, width: 0.12, depth: 0.20, base: 0, top: 2.2, material: "stone"),
        box(x: 0, y: 0, width: 1.18, depth: 0.20, base: 2.08, top: 2.2, material: "stone"),
        box(x: 0, y: 0, width: 1.18, depth: 0.45, base: 0, top: 0.04, material: "stone")
    ]

    static let sign: [Part] = [
        cylinder(radius: 0.045, base: 0, top: 2.65, sides: 8),
        box(x: 0, y: 0, width: 0.62, depth: 0.07, base: 2.05, top: 2.67, material: "signFace")
    ]
    static let speedCamera: [Part] = [
        cylinder(radius: 0.09, base: 0, top: 2.35, sides: 8),
        box(x: 0, y: 0, width: 0.40, depth: 0.45, base: 2.10, top: 2.85, material: "cameraHousing"),
        box(x: 0, y: 0.24, width: 0.18, depth: 0.04, base: 2.48, top: 2.66, material: "signalLens"),
        box(x: 0, y: 0.24, width: 0.18, depth: 0.04, base: 2.23, top: 2.36, material: "signalLens")
    ]
    static let camera: [Part] = [
        cylinder(radius: 0.065, base: 0, top: 3.3, sides: 8),
        box(x: 0, y: 0.24, width: 0.07, depth: 0.50, base: 3.05, top: 3.12, material: "steel"),
        box(x: 0, y: 0.44, width: 0.22, depth: 0.44, base: 3.10, top: 3.32, material: "signFace"),
        box(x: 0, y: 0.67, width: 0.15, depth: 0.035, base: 3.12, top: 3.28, material: "signalLens")
    ]
    static let stop: [Part] = [
        cylinder(radius: 0.055, base: 0, top: 2.8, sides: 8),
        box(x: 0, y: 0, width: 0.48, depth: 0.09, base: 2.25, top: 2.85, material: "transit"),
        box(x: 0, y: 0.06, width: 0.32, depth: 0.03, base: 2.38, top: 2.70, material: "signFace"),
        box(x: 0, y: 0.02, width: 0.28, depth: 0.12, base: 1.05, top: 1.65, material: "signFace")
    ]
    static let station: [Part] = [
        box(x: 0, y: 0, width: 0.50, depth: 0.38, base: 0, top: 2.6, material: "transit"),
        box(x: 0, y: 0.20, width: 0.38, depth: 0.035, base: 1.40, top: 2.35, material: "signFace")
    ]
    static let charger: [Part] = [
        box(x: 0, y: 0, width: 0.70, depth: 0.52, base: 0, top: 0.12, material: "stone"),
        box(x: 0, y: 0, width: 0.54, depth: 0.38, base: 0.12, top: 1.65, material: "charger"),
        box(x: 0, y: 0.20, width: 0.32, depth: 0.035, base: 1.05, top: 1.40, material: "signalLens"),
        box(x: 0.33, y: 0, width: 0.05, depth: 0.08, base: 0.40, top: 1.35, material: "signalHousing"),
        box(x: 0.28, y: 0, width: 0.15, depth: 0.08, base: 1.30, top: 1.36, material: "signalHousing"),
        box(x: 0.28, y: 0, width: 0.15, depth: 0.08, base: 0.40, top: 0.46, material: "signalHousing")
    ]
    static let parcelLocker: [Part] = {
        var parts = [box(x: 0, y: 0, width: 2.45, depth: 0.62, base: 0, top: 2.0, material: "locker")]
        // Individual recessed-looking fronts keep the model recognisable without a brand claim.
        for column in 0..<4 { for row in 0..<5 {
            parts.append(box(x: -0.9 + Double(column) * 0.60, y: 0.32, width: 0.55, depth: 0.025,
                base: 0.10 + Double(row) * 0.37, top: 0.43 + Double(row) * 0.37, material: "lockerDoor"))
        } }
        parts.append(box(x: 0.30, y: 0.35, width: 0.28, depth: 0.03, base: 1.20, top: 1.45, material: "signalLens"))
        return parts
    }()

    static func parts(for kind: Kind) -> [Part] {
        switch kind {
        case .bench: bench
        case .streetLamp: streetLamp
        case .bollard: bollard
        case .trafficSignals: trafficSignals
        case .tree: tree
        case .fountain: fountain
        case .entrance: entrance
        case .kerb: [box(x: 0, y: 0, width: 0.35, depth: 0.18, base: 0, top: 0.14, material: "stone")]
        case .sign: sign
        case .speedCamera: speedCamera
        case .camera: camera
        case .stop: stop
        case .station: station
        case .charger: charger
        case .parcelLocker: parcelLocker
        }
    }

    /// Geometry is authored once per type/detail, rather than rebuilt for every point.
    private static let templates: [Kind: [Detail: [Part]]] = Dictionary(uniqueKeysWithValues: Kind.allCases.map { kind in
        let simple: [Part], standard: [Part]
        switch kind {
        case .bench:
            let seat = box(x: 0, y: 0, width: 1.8, depth: 0.54, base: 0.43, top: 0.49, material: "wood")
            let back = box(x: 0, y: -0.285, width: 1.8, depth: 0.07, base: 0.64, top: 0.97, material: "wood")
            let legs = [-0.67, 0.67].map {
                box(x: $0, y: 0, width: 0.10, depth: 0.54, base: 0, top: 0.43, material: "steel")
            }
            simple = [seat, back] + legs
            standard = simple + [-0.67, 0.67].map {
                box(x: $0, y: 0, width: 0.10, depth: 0.58, base: 0.65, top: 0.71, material: "steel")
            }
        case .streetLamp:
            let pole = cylinder(radius: 0.075, base: 0, top: 5.9, sides: 6)
            simple = [pole, streetLamp[4], streetLamp[5]]
            standard = [streetLamp[0], pole, streetLamp[4], streetLamp[5], streetLamp[6]]
        case .bollard:
            simple = [cylinder(radius: 0.075, base: 0, top: 0.99, sides: 6)]
            standard = simple + [bollard[2], bollard[4]]
        case .trafficSignals:
            simple = [cylinder(radius: 0.055, base: 0, top: 3.25, sides: 6), trafficSignals[2], trafficSignals[3]]
            standard = simple + [trafficSignals[4], trafficSignals[6], trafficSignals[8]]
        case .tree:
            // Keep the crown profile, height and materials identical across LODs.
            // Only ring tessellation changes; two tall cylinders used to turn
            // abruptly into a rounded crown after the delayed detail upgrade.
            func crown(sides: Int) -> [Part] {
                tree.map { part in
                    let radius = part.outline.map { sqrt($0.x * $0.x + $0.y * $0.y) }.max() ?? 0
                    return cylinder(radius: radius, base: part.base, top: part.top,
                                    material: part.material, sides: sides)
                }
            }
            simple = crown(sides: 6)
            standard = crown(sides: 8)
        case .fountain:
            simple = [fountain[0], cylinder(radius: 1.25, base: 0.16, top: 0.48, material: "stone", sides: 8)]
            standard = Array(fountain.dropLast())
        case .entrance, .kerb, .sign, .station:
            simple = parts(for: kind)
            standard = simple
        case .speedCamera, .camera, .stop:
            simple = Array(parts(for: kind).prefix(2))
            standard = parts(for: kind)
        case .charger:
            simple = Array(charger.prefix(2))
            standard = Array(charger.prefix(3))
        case .parcelLocker:
            simple = [parcelLocker[0]]
            standard = [parcelLocker[0], parcelLocker.last!]
        }
        return (kind, [.simple: simple, .standard: standard, .full: parts(for: kind)])
    })

    static func parts(for kind: Kind, detail: Detail, conifer: Bool = false) -> [Part] {
        let parts = templates[kind]?[detail] ?? parts(for: kind)
        guard kind == .tree, conifer else { return parts }
        return parts.enumerated().map { index, part in
            guard index > 0 else { return part }
            let radius = max(0.15, 2.05 * (1 - (part.base - 2.1) / 4.2))
            return cylinder(radius: radius, base: part.base, top: part.top, material: "foliage", sides: detail == .full ? 12 : 8)
        }
    }

    /// Ring-vertex budget approximates both extrusion walls and roof tessellation.
    static func cost(for kind: Kind, detail: Detail) -> Int {
        parts(for: kind, detail: detail).reduce(0) { $0 + max(3, $1.outline.count - 1) }
    }

    private static let modelBounds: [Kind: Bounds] = Dictionary(uniqueKeysWithValues: Kind.allCases.map { kind in
        let parts = parts(for: kind)
        let points = parts.flatMap(\.outline)
        return (kind, Bounds(minimum: SIMD3(points.map(\.x).min() ?? 0, points.map(\.y).min() ?? 0, 0),
                             maximum: SIMD3(points.map(\.x).max() ?? 0, points.map(\.y).max() ?? 0,
                                            parts.map(\.top).max() ?? 0)))
    })

    static func bounds(for kind: Kind) -> Bounds { modelBounds[kind]! }

    static func coordinates(for part: Part, at origin: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let degreesPerMeter = 180 / (.pi * 6_378_137.0)
        let longitudeScale = degreesPerMeter / cos(origin.latitude * .pi / 180)
        return part.outline.map {
            CLLocationCoordinate2D(latitude: origin.latitude + $0.y * degreesPerMeter,
                                   longitude: origin.longitude + $0.x * longitudeScale)
        }
    }

    static func box(x: Double, y: Double, width: Double, depth: Double,
                            base: Double, top: Double, material: String) -> Part {
        let left = x - width / 2, right = x + width / 2
        let bottom = y - depth / 2, upper = y + depth / 2
        return Part(outline: [SIMD2(left, bottom), SIMD2(right, bottom), SIMD2(right, upper),
                              SIMD2(left, upper), SIMD2(left, bottom)],
                    base: base, top: top, material: material)
    }

    static func cylinder(radius: Double, base: Double, top: Double, material: String = "steel", sides: Int = 12) -> Part {
        let outline = (0...sides).map { index in
            let angle = Double(index % sides) * 2 * .pi / Double(sides)
            return SIMD2(cos(angle) * radius, sin(angle) * radius)
        }
        return Part(outline: outline, base: base, top: top, material: material)
    }
}
#endif
