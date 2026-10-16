#if os(iOS)
import Foundation

/// View-only stages. Keep an entered stage until the route, mode, or maneuver
/// changes, so slowing down or GPS jitter cannot collapse guidance mid-approach.
struct CurrentStepGuidancePresentation: Equatable {
    enum Phase: Int, Comparable {
        case distant, preparation, lanes, immediate

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let routeID: UUID
    let maneuverID: Int?
    let mode: TransportMode
    var phase: Phase

    func retainingPhase(from previous: Self?) -> Self {
        guard let previous, previous.routeID == routeID,
              previous.maneuverID == maneuverID, previous.mode == mode else { return self }
        var result = self
        result.phase = max(phase, previous.phase)
        return result
    }
}
#endif
