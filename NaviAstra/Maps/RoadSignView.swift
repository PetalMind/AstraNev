import SwiftUI

enum RoadSignSymbol: Equatable {
    case stop
    case giveWay
    case noEntry
    case noOvertaking
    case noTrucks
    case speedLimit(Int?)
    case speedLimitEnd(Int?)
    case weightLimit(String?)
    case heightLimit(String?)
    case zone(isEnd: Bool, speedLimit: Int?, label: String)
    case railwayCrossing
    case railwayCrossbuck
    case unknown(String?)

    init(_ alert: RoadSafetyAlert) {
        let codes = (alert.signCode ?? "").split(separator: ",").map { raw in
            String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ":").last ?? "").uppercased()
        }
        switch alert.type {
        case .stopSign: self = .stop
        case .giveWaySign: self = .giveWay
        case .noEntrySign: self = .noEntry
        case .noOvertakingSign: self = .noOvertaking
        case .speedLimitSign:
            self = codes.contains("B-34") ? .speedLimitEnd(alert.speedLimitKph) : .speedLimit(alert.speedLimitKph)
        case .weightLimitSign: self = .weightLimit(alert.signValue)
        case .heightLimitSign: self = .heightLimit(alert.signValue)
        case .trafficZoneSign:
            let zoneCode = codes.last
            let isEnd = zoneCode == "D-41" || zoneCode == "D-43"
            let speedZone = zoneCode == "B-43" || zoneCode == "B-44"
            self = .zone(isEnd: isEnd || zoneCode == "B-44",
                         speedLimit: speedZone ? alert.speedLimitKph : nil,
                         label: speedZone ? "STREFA" : zoneCode == "D-42" || zoneCode == "D-43" ? "OBSZAR" : "STREFA")
        case .railwayCrossing:
            self = codes.contains("G-3") || codes.contains("G-4") || codes.contains("RAILWAY=LEVEL_CROSSING")
                ? .railwayCrossbuck : .railwayCrossing
        case .trafficSign:
            self = codes.contains("B-5") ? .noTrucks : .unknown(codes.last)
        default:
            self = .unknown(codes.last)
        }
    }

    var displaySize: CGFloat {
        switch self {
        case .stop: 27
        case .speedLimit, .speedLimitEnd, .noEntry, .giveWay, .railwayCrossing, .railwayCrossbuck: 25
        default: 24
        }
    }

    func displaySize(isNavigating: Bool) -> CGFloat {
        let base = displaySize
        guard isNavigating else { return base }
        return min(32, base + (self == .stop ? 5 : 4))
    }
}

struct RoadSignView: View {
    let symbol: RoadSignSymbol
    let size: CGFloat
    var isSelected = false

    private var red: Color { Color(red: 0.82, green: 0.04, blue: 0.08) }
    private var blue: Color { Color(red: 0.02, green: 0.22, blue: 0.52) }

    var body: some View {
        ZStack {
            artwork
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.36), radius: 1.4, x: 0, y: 1)

            if isSelected {
                Circle()
                    .stroke(Color.cyan.opacity(0.95), lineWidth: 1.7)
                    .frame(width: size + 5, height: size + 5)
                    .shadow(color: .cyan.opacity(0.35), radius: 3)
            }
        }
        .frame(width: size + 8, height: size + 8)
        .scaleEffect(isSelected ? 1.15 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isSelected)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artwork: some View {
        switch symbol {
        case .stop:
            ZStack {
                RoadSignOctagon().fill(red)
                RoadSignOctagon().stroke(.white, lineWidth: max(1, size * 0.055))
                Text("STOP")
                    .font(.system(size: size * 0.29, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                    .foregroundStyle(.white)
            }
        case .giveWay:
            ZStack {
                RoadSignTriangle(inverted: true).fill(red)
                RoadSignTriangle(inverted: true).inset(by: size * 0.13).fill(Color.white)
            }
        case .noEntry:
            ZStack {
                Circle().fill(red)
                Capsule()
                    .fill(.white)
                    .frame(width: size * 0.58, height: max(3, size * 0.18))
            }
        case .noOvertaking:
            prohibitionRing {
                HStack(spacing: size * 0.015) {
                    RoadSignCar().fill(Color(red: 0.1, green: 0.1, blue: 0.12))
                    RoadSignCar().fill(red)
                }
                .frame(width: size * 0.66, height: size * 0.36)
                .offset(y: size * 0.03)
            }
        case .noTrucks:
            prohibitionRing {
                Image(systemName: "truck.box.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.black)
                    .frame(width: size * 0.55, height: size * 0.38)
            }
        case let .speedLimit(value):
            prohibitionRing {
                if let value {
                    Text(String(value))
                        .font(.system(size: size * (value >= 100 ? 0.37 : 0.47),
                                      weight: .heavy, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.66)
                        .lineLimit(1)
                        .foregroundStyle(.black)
                        .frame(width: size * 0.68)
                } else {
                    Text("?").font(.system(size: size * 0.48, weight: .bold)).foregroundStyle(.black)
                }
            }
        case let .speedLimitEnd(value):
            ZStack {
                Circle().fill(Color.white).overlay(Circle().strokeBorder(Color.gray, lineWidth: size * 0.13))
                if let value {
                    Text(String(value))
                        .font(.system(size: size * 0.40, weight: .heavy, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)
                        .foregroundStyle(.black)
                        .frame(width: size * 0.67)
                }
                RoadSignDiagonalStripe().stroke(Color.gray.opacity(0.85), style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                    .padding(size * 0.17)
            }
        case let .weightLimit(value):
            prohibitionRing {
                Text(value ?? "t")
                    .font(.system(size: size * ((value?.count ?? 1) > 3 ? 0.29 : 0.34),
                                  weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.64)
                    .lineLimit(1)
                    .foregroundStyle(.black)
                    .frame(width: size * 0.72)
            }
        case let .heightLimit(value):
            prohibitionRing {
                VStack(spacing: -size * 0.08) {
                    if size >= 29 {
                        Text("↕")
                            .font(.system(size: size * 0.29, weight: .bold))
                    }
                    Text(value ?? "m")
                        .font(.system(size: size * ((value?.count ?? 1) > 3 ? 0.28 : 0.33),
                                      weight: .heavy, design: .rounded))
                        .minimumScaleFactor(0.62)
                        .lineLimit(1)
                }
                .foregroundStyle(.black)
                .frame(width: size * 0.72)
            }
        case let .zone(isEnd, speedLimit, label):
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.08)
                    .fill(isEnd ? Color(white: 0.34) : blue)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.08).strokeBorder(.white, lineWidth: 1.2))
                VStack(spacing: 0) {
                    Text(label)
                        .font(.system(size: size * 0.21, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                    if let speedLimit {
                        ZStack {
                            Circle().fill(.white).overlay(Circle().strokeBorder(red, lineWidth: size * 0.065))
                            Text(String(speedLimit))
                                .font(.system(size: size * 0.25, weight: .heavy, design: .rounded).monospacedDigit())
                                .minimumScaleFactor(0.65)
                                .lineLimit(1)
                                .foregroundStyle(.black)
                        }
                        .frame(width: size * 0.48, height: size * 0.48)
                    } else {
                        Image(systemName: label == "STREFA" ? "house.fill" : "building.2.fill")
                            .font(.system(size: size * 0.42, weight: .semibold))
                    }
                    if isEnd {
                        RoadSignDiagonalStripe()
                            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round))
                            .padding(.horizontal, size * 0.12)
                    }
                }
                .foregroundStyle(.white)
                .padding(size * 0.08)
            }
            .frame(width: size * 0.9, height: size * 0.78)
            .opacity(isEnd ? 0.78 : 1)
        case .railwayCrossing:
            ZStack {
                RoadSignTriangle().fill(Color(red: 1, green: 0.96, blue: 0.83))
                RoadSignTriangle().stroke(red, lineWidth: size * 0.11)
                RailwayTrainSymbol().fill(.black).frame(width: size * 0.38, height: size * 0.30)
                    .offset(y: size * 0.08)
            }
        case .railwayCrossbuck:
            ZStack {
                crossbuckBar.rotationEffect(.degrees(45))
                crossbuckBar.rotationEffect(.degrees(-45))
            }
        case let .unknown(code):
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.12)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.12).strokeBorder(Color.gray, lineWidth: 1.5))
                Text(code ?? "?")
                    .font(.system(size: size * 0.23, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.58)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.black)
                    .padding(2)
            }
        }
    }

    private var crossbuckBar: some View {
        Capsule()
            .fill(.white)
            .overlay(Capsule().strokeBorder(red, lineWidth: max(1, size * 0.08)))
            .frame(width: size * 0.91, height: size * 0.25)
    }

    private func prohibitionRing<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Circle().fill(.white).overlay(Circle().strokeBorder(red, lineWidth: size * 0.13))
            content()
        }
    }
}

private struct RoadSignOctagon: Shape {
    func path(in rect: CGRect) -> Path {
        let cut = min(rect.width, rect.height) * 0.27
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
            path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cut))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
            path.closeSubpath()
        }
    }
}

private struct RoadSignTriangle: InsettableShape {
    var inverted = false
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        return Path { path in
            if inverted {
                path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
                path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
                path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
            } else {
                path.move(to: CGPoint(x: bounds.midX, y: bounds.minY))
                path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
                path.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY))
            }
            path.closeSubpath()
        }
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

private struct RoadSignCar: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY * 0.68))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.maxY * 0.38))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.31, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.22, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.43))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.68))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

private struct RailwayTrainSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            let body = rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.04)
            path.addRoundedRect(in: body, cornerSize: CGSize(width: rect.width * 0.08,
                                                              height: rect.height * 0.08))
            path.addRect(CGRect(x: body.minX + body.width * 0.15, y: body.minY + body.height * 0.16,
                                width: body.width * 0.7, height: body.height * 0.23))
            path.move(to: CGPoint(x: body.minX + body.width * 0.2, y: body.maxY))
            path.addLine(to: CGPoint(x: body.minX + body.width * 0.02, y: rect.maxY))
            path.move(to: CGPoint(x: body.maxX - body.width * 0.2, y: body.maxY))
            path.addLine(to: CGPoint(x: body.maxX - body.width * 0.02, y: rect.maxY))
        }
    }
}

private struct RoadSignDiagonalStripe: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
    }
}
