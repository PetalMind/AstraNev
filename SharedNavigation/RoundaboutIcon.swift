import SwiftUI

struct RoundaboutIcon: View {
    var angle: Double
    var clockwise: Bool
    var exitCount: Int?
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: size * 0.055)
                .frame(width: size * 0.48, height: size * 0.48)
                .opacity(0.3)
            RoundaboutRouteShape(angle: angle, clockwise: clockwise)
                .stroke(style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round, lineJoin: .round))
            if size >= 24, let exitCount, exitCount > 0 {
                Text(String(exitCount))
                    .font(.system(size: size * 0.25, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .frame(width: size * 0.34)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct RoundaboutRouteShape: Shape {
    var angle: Double
    var clockwise: Bool

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = side * 0.24
        let exitRadians = (angle - 90) * .pi / 180
        let direction = CGVector(dx: cos(exitRadians), dy: sin(exitRadians))
        let tip = CGPoint(x: center.x + direction.dx * side * 0.43,
                          y: center.y + direction.dy * side * 0.43)
        // Screen angles increase clockwise. Enter from the bottom, with north at the top.
        var sweep = clockwise ? angle - 180 : 180 - angle
        sweep = (sweep.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        if sweep < 5 { sweep = 360 }
        let end = 90 + (clockwise ? sweep : -sweep)
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y + side * 0.43))
        path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        path.addArc(center: center, radius: radius, startAngle: .degrees(90),
                    endAngle: .degrees(end), clockwise: !clockwise)
        path.addLine(to: tip)
        let back = side * 0.13
        let wing = side * 0.10
        path.move(to: CGPoint(x: tip.x - direction.dx * back - direction.dy * wing,
                             y: tip.y - direction.dy * back + direction.dx * wing))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x - direction.dx * back + direction.dy * wing,
                                y: tip.y - direction.dy * back - direction.dx * wing))
        return path
    }
}
