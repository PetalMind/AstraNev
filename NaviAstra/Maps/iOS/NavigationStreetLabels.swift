#if os(iOS)
import MapLibre
import QuartzCore
import UIKit

/// Screen-facing street callouts, anchored to real map geometry even in the tilted view.
@MainActor
final class NavigationStreetLabels {
    private struct Street {
        let name: String
        let coordinates: [CLLocationCoordinate2D]
    }
    private struct StreetAnchor {
        let name: String
        let coordinate: CLLocationCoordinate2D
        let routeDistance: Double
    }
    private struct Placement {
        let name: String
        let anchor: CGPoint
        let frame: CGRect
        let current: Bool
    }

    private let overlay = UIView()
    private var badges: [StreetBadge] = []
    private var streetAnchors: [StreetAnchor] = []
    private var lastQueryTime: CFTimeInterval = 0
    private var geometry: RouteProgressGeometry?
    private var lastManeuverID: Int?
    private var visibleUpcomingID: Int?

    func reset() {
        streetAnchors = []
        lastQueryTime = 0
        overlay.isHidden = true
        geometry = nil
        lastManeuverID = nil
        visibleUpcomingID = nil
    }

    func update(on map: MLNMapView, state: NavigationState, padding: CameraPadding,
                dark: Bool, enabled: Bool) {
        // These callouts explain an active driving decision. Ordinary map labels
        // remain available when browsing, rerouting, or showing the route overview.
        guard enabled, state.status == .navigating, state.cameraState.usesNavigationPerspective,
              !state.weakGPS, state.cameraState != .weakGPS,
              map.zoomLevel >= 14.8, let style = map.style,
              let route = state.route, let match = state.routeMatch, match.routeID == route.id,
              let location = state.location, location.accuracy >= 0, location.accuracy <= 50,
              abs(Date().timeIntervalSince(location.timestamp)) <= 10,
              abs(match.locationTimestamp.timeIntervalSince(location.timestamp)) <= 5,
              match.match.confidence >= 0.4, match.match.projection.distanceFromRoute <= 35 else {
            overlay.isHidden = true
            streetAnchors = []
            lastQueryTime = 0
            visibleUpcomingID = nil
            return
        }
        if geometry?.routeID != route.id {
            geometry = RouteProgressGeometry(route)
            visibleUpcomingID = nil
            lastQueryTime = 0
        }
        guard let geometry else { return }
        let next = state.progress?.nextManeuver
        if lastManeuverID != next?.id {
            lastManeuverID = next?.id
            lastQueryTime = 0
        }
        let speed = max(0, location.speed)
        // Roughly 18 seconds of notice, bounded for slow urban driving and fast roads.
        let noticeDistance = min(450, max(120, speed * 18))
        let upcoming = next.flatMap { maneuver -> Maneuver? in
            guard isDecision(maneuver.kind), maneuver.streetName != nil,
                  route.coordinates.indices.contains(maneuver.shapeIndex),
                  maneuver.shapeIndex > match.match.projection.segment else { return nil }
            let distance = geometry.distance(from: 0, through: maneuver.shapeIndex) - match.match.projection.alongRoute
            // A small margin keeps the label from flashing when GPS or speed varies
            // around the entry threshold. Passing the maneuver still removes it immediately.
            let threshold = noticeDistance + (visibleUpcomingID == maneuver.id ? 35 : 0)
            return distance >= 0 && distance <= threshold ? maneuver : nil
        }
        visibleUpcomingID = upcoming?.id
        let turnCoordinate = upcoming.map { route.coordinates[$0.shapeIndex] }
        let currentName = route.maneuvers.last(where: { $0.shapeIndex <= match.match.projection.segment })
            .flatMap { $0.streetName }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if overlay.superview !== map {
            overlay.isUserInteractionEnabled = false
            overlay.backgroundColor = .clear
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            map.addSubview(overlay)
        }
        overlay.frame = map.bounds
        overlay.isHidden = false
        let safe = CGRect(x: max(12, padding.left), y: max(12, padding.top),
                          width: max(0, Double(map.bounds.width) - max(12, padding.left) - max(56, padding.right)),
                          height: max(0, Double(map.bounds.height) - max(12, padding.top) - max(12, padding.bottom)))
        guard safe.width > 80, safe.height > 70 else {
            overlay.isHidden = true
            return
        }
        let focus = turnCoordinate.map { map.convert($0.cl, toPointTo: map) }
            ?? CGPoint(x: safe.midX, y: safe.midY)
        // Tile queries are bounded in frequency; only screen projection runs as the camera moves.
        let now = CACurrentMediaTime()
        // Side streets matter only close to a turn and at urban speeds. On faster
        // roads show the current road and the actual maneuver target only.
        let showsContext = upcoming != nil && speed < 22 && map.zoomLevel >= 15.5 && safe.contains(focus)
        if !showsContext { streetAnchors = [] }
        if showsContext && (lastQueryTime == 0 || now - lastQueryTime >= 0.8) {
            lastQueryTime = now
            let sourceIDs = Set(style.layers.compactMap { layer -> String? in
                guard let symbol = layer as? MLNSymbolStyleLayer,
                      symbol.sourceLayerIdentifier == "transportation_name" else { return nil }
                return symbol.sourceIdentifier
            })
            let streets = sourceIDs.sorted().flatMap { id -> [Street] in
                guard let source = style.source(withIdentifier: id) as? MLNVectorTileSource else { return [] }
                return source.features(sourceLayerIdentifiers: ["transportation_name"],
                                       predicate: NSPredicate(format: "class IN %@", ["motorway", "trunk", "primary", "secondary", "tertiary", "minor", "service"]))
                    .flatMap { feature -> [Street] in
                        guard let rawName = (feature.attribute(forKey: "name:pl") as? String)
                                ?? (feature.attribute(forKey: "name") as? String) else { return [] }
                        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return [] }
                        let lines: [MLNPolyline]
                        if let line = feature as? MLNPolyline {
                            lines = [line]
                        } else if let multi = feature as? MLNMultiPolyline {
                            lines = multi.polylines
                        } else {
                            return []
                        }
                        return lines.compactMap { line in
                            guard line.pointCount > 1 else { return nil }
                            var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: Int(line.pointCount))
                            line.getCoordinates(&coordinates, range: NSRange(location: 0, length: coordinates.count))
                            return Street(name: name, coordinates: coordinates)
                        }
                    }
            }
            // Keep a small set of geographic anchors. Reproject those each frame instead
            // of walking every road vertex while the navigation camera animates.
            var anchorNames = Set<String>()
            streetAnchors = Array(streets.compactMap { street -> (StreetAnchor, CGFloat)? in
                guard let point = anchor(for: street, on: map, inside: safe, focus: focus),
                      let turnCoordinate else { return nil }
                let coordinate = map.convert(point, toCoordinateFrom: map)
                let value = Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
                guard value.distance(to: turnCoordinate) <= 75,
                      let projection = geometry.project(value, within: 40),
                      projection.distanceFromRoute <= 35,
                      projection.alongRoute >= match.match.projection.alongRoute - 10 else { return nil }
                return (StreetAnchor(name: street.name, coordinate: coordinate, routeDistance: projection.alongRoute),
                        hypot(point.x - focus.x, point.y - focus.y))
            }.sorted { $0.1 < $1.1 }
                .filter { anchorNames.insert($0.0.name.lowercased()).inserted }
                .prefix(24).map { $0.0 })
        }
        var placements: [Placement] = []
        var usedNames = Set<String>()
        var occupied: [CGRect] = []
        if let location = state.cameraLocation ?? state.location {
            let puck = map.convert(location.coordinate.cl, toPointTo: map)
            occupied.append(CGRect(x: puck.x - 28, y: puck.y - 32, width: 56, height: 64))
        }
        // Reserve room for the road after the turn before placing contextual labels.
        if let upcoming, let rawName = upcoming.streetName {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let turnDistance = geometry.distance(from: 0, through: upcoming.shapeIndex)
            let endIndex = route.maneuvers.first(where: { $0.shapeIndex > upcoming.shapeIndex })?.shapeIndex
                ?? (route.coordinates.count - 1)
            let roadLength = geometry.distance(from: upcoming.shapeIndex, through: endIndex)
            if !name.isEmpty, name.lowercased() != currentName?.lowercased(),
               let coordinate = geometry.coordinate(at: turnDistance + min(25, roadLength / 2)),
               let placement = place(name, at: map.convert(coordinate.cl, toPointTo: map),
                                     current: false, safe: safe, occupied: occupied) {
                placements.append(placement)
                usedNames.insert(name.lowercased())
                occupied.append(placement.frame.insetBy(dx: -12, dy: -12))
            }
        }
        // Never use the next maneuver's name to describe the current road.
        if let name = currentName, !name.isEmpty {
            usedNames.insert(name.lowercased())
            let point = map.convert(match.match.projection.coordinate.cl, toPointTo: map)
            if let placement = place(name, at: point, current: true, safe: safe, occupied: occupied) {
                placements.append(placement)
                occupied.append(placement.frame.insetBy(dx: -12, dy: -12))
            }
        }
        let candidates = streetAnchors.compactMap { street -> (StreetAnchor, CGPoint, CGFloat)? in
            let anchor = map.convert(street.coordinate, toPointTo: map)
            let coordinate = Coordinate(latitude: street.coordinate.latitude, longitude: street.coordinate.longitude)
            guard showsContext, let turnCoordinate,
                  coordinate.distance(to: turnCoordinate) <= 75,
                  street.routeDistance >= match.match.projection.alongRoute - 10,
                  !usedNames.contains(street.name.lowercased()), safe.contains(anchor) else { return nil }
            return (street, anchor, hypot(anchor.x - focus.x, anchor.y - focus.y))
        }.sorted {
            if $0.2 == $1.2 { return $0.0.name < $1.0.name }
            return $0.2 < $1.2
        }
        var contextCount = 0
        for (street, point, _) in candidates {
            guard placements.count < 3, contextCount < 1 else { break }
            guard !usedNames.contains(street.name.lowercased()),
                  let placement = place(street.name, at: point, current: false, safe: safe, occupied: occupied) else { continue }
            usedNames.insert(street.name.lowercased())
            contextCount += 1
            placements.append(placement)
            occupied.append(placement.frame.insetBy(dx: -12, dy: -12))
        }
        while badges.count < placements.count {
            let badge = StreetBadge()
            overlay.addSubview(badge)
            badges.append(badge)
        }
        for (index, badge) in badges.enumerated() {
            badge.isHidden = index >= placements.count
            guard index < placements.count else { continue }
            let placement = placements[index]
            badge.frame = placement.frame
            badge.render(name: placement.name, current: placement.current, dark: dark,
                         anchor: CGPoint(x: placement.anchor.x - placement.frame.minX,
                                         y: placement.anchor.y - placement.frame.minY))
        }
    }

    private func isDecision(_ kind: ManeuverKind) -> Bool {
        switch kind {
        case .becomes, .slightRight, .right, .sharpRight, .uTurnRight, .uTurnLeft,
             .sharpLeft, .left, .slightLeft, .rampStraight, .rampRight, .rampLeft,
             .exitRight, .exitLeft, .stayRight, .stayLeft, .merge,
             .roundaboutEnter, .roundaboutExit, .ferryEnter, .ferryExit:
            return true
        default:
            return false
        }
    }

    private func anchor(for street: Street, on map: MLNMapView, inside safe: CGRect,
                        focus: CGPoint) -> CGPoint? {
        var best: CGPoint?
        var distance = CGFloat.infinity
        var previous: CGPoint?
        for coordinate in street.coordinates {
            let point = map.convert(coordinate, toPointTo: map)
            defer { previous = point }
            guard point.x.isFinite, point.y.isFinite, let start = previous else { continue }
            let dx = point.x - start.x, dy = point.y - start.y
            let length = dx * dx + dy * dy
            guard length > 4 else { continue }
            let t = max(0, min(1, ((focus.x - start.x) * dx + (focus.y - start.y) * dy) / length))
            let anchor = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
            let score = hypot(anchor.x - focus.x, anchor.y - focus.y)
            if safe.contains(anchor), score < distance {
                best = anchor
                distance = score
            }
        }
        return best
    }

    private func place(_ name: String, at anchor: CGPoint, current: Bool,
                       safe: CGRect, occupied: [CGRect]) -> Placement? {
        guard safe.contains(anchor) else { return nil }
        let font = UIFont.systemFont(ofSize: current ? 16 : 14, weight: .semibold)
        let width = min(190, ceil((name as NSString).size(withAttributes: [.font: font]).width) + 24)
        let height: CGFloat = current ? 36 : 34
        let centers = [CGPoint(x: anchor.x, y: anchor.y + 50),
                       CGPoint(x: anchor.x - width / 2 - 16, y: anchor.y - 24),
                       CGPoint(x: anchor.x + width / 2 + 16, y: anchor.y - 24),
                       CGPoint(x: anchor.x, y: anchor.y - 50)]
        for center in centers {
            let frame = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            guard safe.contains(frame), !occupied.contains(where: { $0.intersects(frame) }) else { continue }
            return Placement(name: name, anchor: anchor, frame: frame, current: current)
        }
        return nil
    }
}

@MainActor
private final class StreetBadge: UIView {
    private let bubble = CAShapeLayer()
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.addSublayer(bubble)
        label.lineBreakMode = .byTruncatingTail
        label.textAlignment = .center
        addSubview(label)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(name: String, current: Bool, dark: Bool, anchor: CGPoint) {
        label.text = name
        label.font = .systemFont(ofSize: current ? 16 : 14, weight: .semibold)
        label.textColor = current ? UIColor(red: 0.12, green: 0.32, blue: 0.92, alpha: 1) : .white
        label.frame = bounds.insetBy(dx: 10, dy: 4)
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: current ? bounds.height / 2 : 10)
        if !current {
            // The short pointer faces the street without covering its geometry.
            let bottom = anchor.y >= bounds.midY
            let x = max(12, min(bounds.width - 12, anchor.x))
            let y = bottom ? bounds.height - 1 : 1
            path.move(to: CGPoint(x: x - 6, y: y))
            path.addLine(to: CGPoint(x: x + (anchor.x < bounds.midX ? -7 : 7), y: bottom ? y + 9 : y - 9))
            path.addLine(to: CGPoint(x: x + 6, y: y))
            path.close()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubble.path = path.cgPath
        bubble.fillColor = (current ? UIColor.white : UIColor(white: dark ? 0.24 : 0.40, alpha: 0.96)).cgColor
        bubble.strokeColor = UIColor.white.cgColor
        bubble.lineWidth = current ? 0 : 2
        bubble.shadowColor = UIColor.black.cgColor
        bubble.shadowOpacity = 0.22
        bubble.shadowRadius = 3
        bubble.shadowOffset = CGSize(width: 0, height: 1)
        bubble.shadowPath = path.cgPath
        CATransaction.commit()
        accessibilityLabel = current ? "Bieżąca ulica: \(name)" : "Ulica: \(name)"
    }
}
#endif
