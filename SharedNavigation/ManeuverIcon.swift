import SwiftUI

/// Shared by the app and Live Activity; raw values are Valhalla maneuver types.
struct ManeuverIcon: View {
    var type: Int?
    var fallbackSymbol: String = "arrow.up"
    var size: CGFloat = 24
    var roundabout: RoundaboutGuidance?

    var body: some View {
        Group {
            if type == 26 || type == 27, let roundabout,
               let angle = roundabout.exitAngle, angle.isFinite, (0..<360).contains(angle),
               let clockwise = roundabout.clockwise {
                RoundaboutIcon(angle: angle, clockwise: clockwise,
                               exitCount: roundabout.exitCount, size: size)
            } else {
#if os(iOS)
                if let type, IOSRoadManeuverShape.supportedTypes.contains(type) {
                    ZStack {
                        if [20, 21, 22, 23, 24].contains(type) {
                            IOSRoadManeuverShape(type: type, alternative: true)
                                .stroke(style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round, lineJoin: .round))
                                .opacity(0.55)
                        }
                        IOSRoadManeuverShape(type: type)
                            .stroke(style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round, lineJoin: .round))
                    }
                } else {
                    standardIcon
                }
#else
                standardIcon
#endif
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var standardIcon: some View {
        if let assetName {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size, weight: .semibold))
        }
    }

    private var assetName: String? {
        let name: String
        switch type {
        case 1: name = "depart"
        case 2: name = "depart_right"
        case 3: name = "depart_left"
        case 4: name = "arrive"
        case 5: name = "arrive_right"
        case 6: name = "arrive_left"
        case 7, 8: name = "turn_straight"
        case 9: name = "turn_slight_right"
        case 10: name = "turn_right"
        case 11: name = "turn_sharp_right"
        case 12: name = "uturn_right"
        case 13: name = "uturn"
        case 14: name = "turn_sharp_left"
        case 15: name = "turn_left"
        case 16: name = "turn_slight_left"
        case 17: name = "on_ramp_straight"
        case 18: name = "on_ramp_right"
        case 19: name = "on_ramp_left"
        case 20: name = "off_ramp_right"
        case 21: name = "off_ramp_left"
        case 22: name = "fork_straight"
        case 23: name = "fork_right"
        case 24: name = "fork_left"
        case 26, 27: name = "roundabout"
        default: return nil
        }
        return "navi_\(name)"
    }
}

#if os(iOS)
/// Consistent road symbols for the app and Live Activity. The faint continuing
/// road distinguishes an exit or fork from a turn at an intersection.
private struct IOSRoadManeuverShape: Shape {
    static let supportedTypes: Set<Int> = [7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 20, 21, 22, 23, 24]
    let type: Int
    var alternative = false

    func path(in rect: CGRect) -> Path {
        let left = [13, 14, 15, 16, 21, 24].contains(type)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * (left ? 1 - x : x),
                    y: rect.minY + rect.height * y)
        }
        var path = Path()
        if alternative {
            if type == 20 || type == 21 {
                path.move(to: point(0.34, 0.9))
                path.addLine(to: point(0.34, 0.1))
            } else {
                path.move(to: point(0.5, 0.9))
                path.addLine(to: point(0.5, 0.58))
                path.addLine(to: point(type == 22 ? 0.84 : 0.16, 0.14))
            }
            return path
        }

        var tip: CGPoint
        var beforeTip: CGPoint
        switch type {
        case 7, 8, 22:
            path.move(to: point(0.5, 0.9))
            beforeTip = point(0.5, 0.5)
            tip = point(0.5, 0.1)
            path.addLine(to: tip)
        case 9, 16, 20, 21, 23, 24:
            let startX: CGFloat = (type == 20 || type == 21) ? 0.34 : 0.5
            path.move(to: point(startX, 0.9))
            path.addLine(to: point(startX, 0.58))
            beforeTip = point(0.64, 0.36)
            tip = point(0.84, 0.14)
            path.addQuadCurve(to: beforeTip, control: point(startX, 0.5))
            path.addLine(to: tip)
        case 11, 14:
            path.move(to: point(0.34, 0.9))
            beforeTip = point(0.34, 0.22)
            tip = point(0.84, 0.62)
            path.addLine(to: beforeTip)
            path.addLine(to: tip)
        case 12, 13:
            path.move(to: point(0.28, 0.9))
            path.addLine(to: point(0.28, 0.34))
            beforeTip = point(0.74, 0.34)
            tip = point(0.74, 0.64)
            path.addCurve(to: beforeTip, control1: point(0.28, 0.04), control2: point(0.74, 0.04))
            path.addLine(to: tip)
        default:
            path.move(to: point(0.3, 0.9))
            path.addLine(to: point(0.3, 0.57))
            beforeTip = point(0.56, 0.3)
            tip = point(0.86, 0.3)
            path.addQuadCurve(to: beforeTip, control: point(0.3, 0.3))
            path.addLine(to: tip)
        }
        let angle = atan2(tip.y - beforeTip.y, tip.x - beforeTip.x)
        let head = min(rect.width, rect.height) * 0.22
        for offset: CGFloat in [-0.7, 0.7] {
            path.move(to: tip)
            path.addLine(to: CGPoint(x: tip.x - cos(angle + offset) * head,
                                    y: tip.y - sin(angle + offset) * head))
        }
        return path
    }
}
#endif
