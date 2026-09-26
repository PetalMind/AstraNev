import Foundation

enum ManeuverKind: Int, Sendable {
    case none = 0
    case start = 1
    case startRight = 2
    case startLeft = 3
    case destination = 4
    case destinationRight = 5
    case destinationLeft = 6
    case becomes = 7
    case straight = 8
    case slightRight = 9
    case right = 10
    case sharpRight = 11
    case uTurnRight = 12
    case uTurnLeft = 13
    case sharpLeft = 14
    case left = 15
    case slightLeft = 16
    case rampStraight = 17
    case rampRight = 18
    case rampLeft = 19
    case exitRight = 20
    case exitLeft = 21
    case stayStraight = 22
    case stayRight = 23
    case stayLeft = 24
    case merge = 25
    case roundaboutEnter = 26
    case roundaboutExit = 27
    case ferryEnter = 28
    case ferryExit = 29
    case transit = 30
    case transitTransfer = 31
    case transitRemainOn = 32
    case transitConnectionStart = 33
    case transitConnectionTransfer = 34
    case transitConnectionDestination = 35
    case postTransitConnectionDestination = 36

    var symbolName: String {
        switch self {
        case .startLeft, .destinationLeft, .slightLeft, .sharpLeft, .left, .rampLeft, .exitLeft, .stayLeft:
            "arrow.turn.up.left"
        case .startRight, .destinationRight, .slightRight, .sharpRight, .right, .rampRight, .exitRight, .stayRight:
            "arrow.turn.up.right"
        case .uTurnLeft:
            "arrow.uturn.left"
        case .uTurnRight:
            "arrow.uturn.right"
        case .roundaboutEnter, .roundaboutExit:
            "arrow.clockwise"
        case .merge:
            "arrow.merge"
        case .straight, .stayStraight, .rampStraight:
            "arrow.up"
        case .none, .start, .destination, .becomes, .ferryEnter, .ferryExit, .transit,
             .transitTransfer, .transitRemainOn, .transitConnectionStart,
             .transitConnectionTransfer, .transitConnectionDestination,
             .postTransitConnectionDestination:
            "arrow.up.right"
        }
    }

    var instructionTitle: String? {
        switch self {
        case .straight, .stayStraight: "Jedź prosto"
        case .slightRight: "Lekko skręć w prawo"
        case .right, .startRight, .destinationRight, .stayRight: "Skręć w prawo"
        case .sharpRight: "Skręć ostro w prawo"
        case .uTurnRight: "Zawróć w prawo"
        case .uTurnLeft: "Zawróć w lewo"
        case .sharpLeft: "Skręć ostro w lewo"
        case .left, .startLeft, .destinationLeft, .stayLeft: "Skręć w lewo"
        case .slightLeft: "Lekko skręć w lewo"
        case .exitRight: "Zjedź w prawo"
        case .exitLeft: "Zjedź w lewo"
        case .rampLeft: "Wjedź na zjazd w lewo"
        case .rampRight: "Wjedź na zjazd w prawo"
        case .merge: "Włącz się do ruchu"
        case .roundaboutEnter: "Wjedź na rondo"
        case .roundaboutExit: "Zjedź z ronda"
        default: nil
        }
    }

    var isExit: Bool {
        switch self {
        case .rampStraight, .rampRight, .rampLeft, .exitRight, .exitLeft: true
        default: false
        }
    }

    var isRoundabout: Bool { self == .roundaboutEnter || self == .roundaboutExit }
}

struct Maneuver: Identifiable, Sendable {
    var id: Int { shapeIndex }
    var shapeIndex: Int
    var instruction: String
    var type: Int
    var streetNames: [String] = []
    var lanes: [TurnLaneGuidance] = []
    var exitNumber: String?
    var exitRoad: String?
    var exitToward: String?

    var kind: ManeuverKind { ManeuverKind(rawValue: type) ?? .none }
    var iconName: String { kind.symbolName }
    var displayInstruction: String { kind.instructionTitle ?? instruction }
    var streetName: String? { streetNames.first(where: { !$0.isEmpty }) }
    var streetLine: String? {
        guard kind.instructionTitle != nil, let streetName else { return nil }
        return "w \(streetName)"
    }
    var spokenInstruction: String {
        guard let streetLine else { return displayInstruction }
        return "\(displayInstruction) \(streetLine)"
    }
}

struct TurnLaneGuidance: Identifiable, Sendable {
    var id: Int
    var indications: [String]
    var valid: Bool
}
