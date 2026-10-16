#if os(iOS)
import SwiftUI

/// A schematic carriageway in the router's left-to-right lane order.
/// Perspective is illustrative: route lane data supplies no junction geometry,
/// lane widths, road-marking types, or the vehicle's current lane.
struct LaneGuidanceRoadView: View {
    let guidance: LaneGuidance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let roadColor = Color(red: 0.09, green: 0.13, blue: 0.17)
    private let selectedColor = Color(red: 0.04, green: 0.47, blue: 0.59)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(guidance.instruction)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.naviTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Canvas { context, size in
                drawRoad(in: &context, size: size)
            }
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 126 : 84)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
        .padding(.top, 4)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private func drawRoad(in context: inout GraphicsContext, size: CGSize) {
        let count = guidance.lanes.count
        guard count > 0 else { return }
        let topY: CGFloat = 4
        let bottomY = size.height - 2
        let bottomInset: CGFloat = 3
        let topInset = min(size.width * 0.09, 38)

        func point(_ boundary: CGFloat, at y: CGFloat) -> CGPoint {
            let progress = (y - topY) / (bottomY - topY)
            let inset = topInset + (bottomInset - topInset) * progress
            return CGPoint(x: inset + (size.width - inset * 2) * boundary / CGFloat(count), y: y)
        }

        func laneSurface(_ index: Int) -> Path {
            Path { path in
                path.move(to: point(CGFloat(index), at: bottomY))
                path.addLine(to: point(CGFloat(index), at: topY))
                path.addLine(to: point(CGFloat(index + 1), at: topY))
                path.addLine(to: point(CGFloat(index + 1), at: bottomY))
                path.closeSubpath()
            }
        }

        for (index, lane) in guidance.lanes.enumerated() {
            let selected = guidance.selectedIndices.contains(index)
            context.fill(laneSurface(index), with: .color(roadColor))
            if selected || lane.valid || lane.active {
                context.fill(laneSurface(index), with: .color(selectedColor.opacity(selected ? 0.86 : 0.28)))
            }

            // A shared shaft keeps multiple legal movements on the same physical lane.
            let arrowY = size.height * 0.48
            let center = point(CGFloat(index) + 0.5, at: arrowY)
            let width = point(CGFloat(index + 1), at: arrowY).x - point(CGFloat(index), at: arrowY).x
            let arrowWidth = min(42, width * 0.76)
            let arrowHeight = min(size.height * 0.55, max(28, arrowWidth * 1.7))
            let frame = CGRect(x: center.x - arrowWidth / 2, y: arrowY - arrowHeight / 2,
                               width: arrowWidth, height: arrowHeight)
            let directions = Array(Set(lane.indications.map(LaneRoadDirection.init))).sorted { $0.rawValue < $1.rawValue }
            let selectedDirections = lane.active ? lane.activeIndications : lane.validIndications
            let highlightedDirections = Set(selectedDirections.map(LaneRoadDirection.init))
            func followsRoute(_ direction: LaneRoadDirection) -> Bool {
                (lane.active || lane.valid)
                    && direction != .unknown
                    && (highlightedDirections.isEmpty || highlightedDirections.contains(direction))
            }
            let orderedDirections = (directions.isEmpty ? [.unknown] : directions).sorted {
                !followsRoute($0) && followsRoute($1)
            }
            for direction in orderedDirections {
                context.stroke(direction.arrow(in: frame),
                               with: .color(followsRoute(direction) ? .white : .white.opacity(0.38)),
                               style: StrokeStyle(lineWidth: max(1.5, min(3.6, arrowWidth * 0.10)),
                                                  lineCap: .round, lineJoin: .round))
            }

            if selected {
                // A check is visible without relying on color, and does not suggest a car position.
                let center = point(CGFloat(index) + 0.5, at: size.height * 0.87)
                let radius = min(5, width * 0.17)
                let check = Path { path in
                    path.move(to: CGPoint(x: center.x - radius, y: center.y))
                    path.addLine(to: CGPoint(x: center.x - radius * 0.25, y: center.y + radius * 0.65))
                    path.addLine(to: CGPoint(x: center.x + radius, y: center.y - radius * 0.75))
                }
                context.stroke(check, with: .color(.white),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }

        // Dashed separators communicate distinct lanes; they are schematic, not surveyed markings.
        for boundary in 0...count {
            let edge = boundary == 0 || boundary == count
            let line = Path { path in
                path.move(to: point(CGFloat(boundary), at: topY))
                path.addLine(to: point(CGFloat(boundary), at: bottomY))
            }
            context.stroke(line, with: .color(.white.opacity(edge ? 0.75 : 0.55)),
                           style: StrokeStyle(lineWidth: edge ? 2 : 1.4, dash: edge ? [] : [7, 7]))
        }
    }

    private var accessibilityDescription: String {
        let lanes = guidance.lanes.enumerated().map { index, lane in
            let directions = lane.indications.map { LaneRoadDirection($0).label }.joined(separator: ", ")
            let status = guidance.selectedIndices.contains(index) ? "zalecany do tego manewru"
                : (lane.valid || lane.active ? "również prowadzi trasą" : "nie prowadzi trasą tego manewru")
            return "Pas \(index + 1) od lewej: \(directions.isEmpty ? "kierunek nieokreślony" : directions), \(status)."
        }
        return (["Pasy przed manewrem.", guidance.instruction] + lanes).joined(separator: " ")
    }
}

nonisolated private enum LaneRoadDirection: String, Hashable, Sendable {
    case through, left, right, slightLeft, slightRight, sharpLeft, sharpRight
    case reverseLeft, reverseRight, mergeLeft, mergeRight, unknown

    init(_ indication: String) {
        let value = indication.lowercased().replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if value.contains("uturn") || value.contains("u_turn") || value.contains("reverse") {
            self = value.contains("right") ? .reverseRight : .reverseLeft
        } else if value.contains("merge") {
            self = value.contains("left") ? .mergeLeft : value.contains("right") ? .mergeRight : .unknown
        } else if value.contains("left") {
            self = value.contains("sharp") ? .sharpLeft : value.contains("slight") ? .slightLeft : .left
        } else if value.contains("right") {
            self = value.contains("sharp") ? .sharpRight : value.contains("slight") ? .slightRight : .right
        } else if value.contains("through") || value.contains("straight") {
            self = .through
        } else {
            self = .unknown
        }
    }

    var label: String {
        switch self {
        case .through: "prosto"
        case .left: "w lewo"
        case .right: "w prawo"
        case .slightLeft: "lekko w lewo"
        case .slightRight: "lekko w prawo"
        case .sharpLeft: "ostro w lewo"
        case .sharpRight: "ostro w prawo"
        case .reverseLeft: "zawracanie w lewo"
        case .reverseRight: "zawracanie w prawo"
        case .mergeLeft: "włączenie w lewo"
        case .mergeRight: "włączenie w prawo"
        case .unknown: "kierunek nieokreślony"
        }
    }

    func arrow(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        return Path { path in
            if self == .unknown {
                path.move(to: point(0.43, 0.48))
                path.addLine(to: point(0.57, 0.48))
                return
            }
            let left = [.left, .slightLeft, .sharpLeft, .reverseLeft, .mergeLeft].contains(self)
            let sign: CGFloat = left ? -1 : 1
            var tip = point(0.5, 0.06)
            var angle: CGFloat = -.pi / 2
            path.move(to: point(0.5, 0.94))
            path.addLine(to: point(0.5, 0.52))
            switch self {
            case .through:
                path.addLine(to: tip)
            case .slightLeft, .slightRight, .mergeLeft, .mergeRight:
                tip = point(0.5 + sign * 0.40, 0.08)
                path.addQuadCurve(to: tip, control: point(0.5, 0.30))
                angle = atan2(-rect.height * 0.22, sign * rect.width * 0.40)
            case .reverseLeft, .reverseRight:
                tip = point(0.5 + sign * 0.38, 0.48)
                path.addCurve(to: tip, control1: point(0.5, -0.03),
                              control2: point(0.5 + sign * 0.38, -0.03))
                angle = .pi / 2
            case .sharpLeft, .sharpRight:
                tip = point(0.5 + sign * 0.42, 0.53)
                path.addLine(to: point(0.5, 0.21))
                path.addLine(to: tip)
                angle = atan2(rect.height * 0.32, sign * rect.width * 0.42)
            default:
                tip = point(0.5 + sign * 0.42, 0.22)
                path.addQuadCurve(to: tip, control: point(0.5, 0.22))
                angle = left ? .pi : 0
            }
            let head = min(rect.width * 0.24, rect.height * 0.18)
            for offset: CGFloat in [-0.65, 0.65] {
                path.move(to: tip)
                path.addLine(to: CGPoint(x: tip.x - cos(angle + offset) * head,
                                         y: tip.y - sin(angle + offset) * head))
            }
        }
    }
}
#endif
