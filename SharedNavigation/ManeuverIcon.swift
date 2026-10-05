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
            } else if let assetName {
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size, weight: .semibold))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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
