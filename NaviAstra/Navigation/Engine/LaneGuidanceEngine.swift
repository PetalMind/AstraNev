import Foundation

nonisolated struct LaneGuidance: Sendable {
    let lanes: [TurnLaneGuidance]
    let selectedIndices: [Int]
    let providerPreferred: Bool
    let instruction: String
}

nonisolated enum LaneGuidanceEngine {
    static func guidance(for maneuver: Maneuver) -> LaneGuidance? {
        let lanes = maneuver.lanes
        guard lanes.count >= 2, lanes.count <= 16 else { return nil }
        let active = lanes.indices.filter { lanes[$0].active }
        let valid = lanes.indices.filter { lanes[$0].valid || lanes[$0].active }
        guard !valid.isEmpty else { return nil }
        let selected = active.isEmpty ? valid : active
        let contiguous = zip(selected, selected.dropFirst()).allSatisfy { $1 == $0 + 1 }
        let instruction: String
        if selected.count == lanes.count {
            instruction = "Możesz korzystać ze wszystkich wskazanych pasów."
        } else if !contiguous {
            instruction = "Wybierz jeden z wyróżnionych pasów."
        } else {
            // Lane order is the router's physical order, also used by the arrow strip.
            let side = selected.last == lanes.count - 1 ? "praw" : selected.first == 0 ? "lew" : nil
            let action = active.isEmpty ? "Wybierz jeden z" : "Trzymaj się"
            if selected.count == 1, let side {
                instruction = active.isEmpty ? "Wybierz \(side)y pas." : "Trzymaj się \(side)ego pasa."
            } else if let side {
                let count = [2: "dwóch", 3: "trzech", 4: "czterech"][selected.count] ?? String(selected.count)
                instruction = "\(action) \(count) \(side)ych pasów."
            } else {
                instruction = "\(action) wyróżnionych pasów."
            }
        }
        return LaneGuidance(lanes: lanes, selectedIndices: selected,
                            providerPreferred: !active.isEmpty, instruction: instruction)
    }
}
