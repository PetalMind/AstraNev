import SwiftUI

struct ArrivalCelebration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var burstFinished = false
    private let green = Color(naviHex: NaviAstraColorPalette.success)
    private let pieces = [
        ArrivalConfettiPiece(id: 0, x: -128, y: -8, width: 10, height: 4, angle: -52, color: Color(red: 0.12, green: 0.61, blue: 1)),
        ArrivalConfettiPiece(id: 1, x: -106, y: 25, width: 9, height: 4, angle: 38, color: Color(red: 0.97, green: 0.72, blue: 0.20)),
        ArrivalConfettiPiece(id: 2, x: -88, y: -20, width: 9, height: 4, angle: 66, color: Color(red: 0.97, green: 0.31, blue: 0.58)),
        ArrivalConfettiPiece(id: 3, x: -65, y: 19, width: 8, height: 4, angle: -40, color: Color(red: 0.13, green: 0.80, blue: 0.43)),
        ArrivalConfettiPiece(id: 4, x: -41, y: -37, width: 9, height: 4, angle: 64, color: Color(red: 0.12, green: 0.61, blue: 1)),
        ArrivalConfettiPiece(id: 5, x: -21, y: 28, width: 8, height: 4, angle: 26, color: Color(red: 0.97, green: 0.72, blue: 0.20)),
        ArrivalConfettiPiece(id: 6, x: 21, y: -34, width: 8, height: 4, angle: 72, color: Color(red: 0.13, green: 0.80, blue: 0.43)),
        ArrivalConfettiPiece(id: 7, x: 45, y: 31, width: 9, height: 4, angle: -43, color: Color(red: 0.97, green: 0.31, blue: 0.58)),
        ArrivalConfettiPiece(id: 8, x: 66, y: -15, width: 9, height: 4, angle: 35, color: Color(red: 0.12, green: 0.61, blue: 1)),
        ArrivalConfettiPiece(id: 9, x: 88, y: 17, width: 10, height: 4, angle: -62, color: Color(red: 0.97, green: 0.72, blue: 0.20)),
        ArrivalConfettiPiece(id: 10, x: 108, y: -29, width: 9, height: 4, angle: 58, color: Color(red: 0.13, green: 0.80, blue: 0.43)),
        ArrivalConfettiPiece(id: 11, x: 130, y: 9, width: 10, height: 4, angle: -18, color: Color(red: 0.97, green: 0.31, blue: 0.58))
    ]

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                Capsule()
                    .fill(piece.color)
                    .frame(width: piece.width, height: piece.height)
                    .rotationEffect(.degrees(appeared ? piece.angle : 0))
                    .offset(x: appeared ? piece.x : piece.x * 0.15,
                            y: appeared ? piece.y : 12)
                    .scaleEffect(burstFinished ? 0.7 : 1)
                    .opacity(reduceMotion ? 0 : (appeared && !burstFinished ? 0.85 : 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.7).delay(Double(piece.id % 3) * 0.04), value: appeared)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: burstFinished)
            }

            Circle()
                .stroke(green.opacity(0.13), lineWidth: 13)
                .frame(width: 96, height: 96)
                .scaleEffect(appeared ? 1 : 0.55)
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.65), value: appeared)
            Circle()
                .stroke(green.opacity(0.24), lineWidth: 8)
                .frame(width: 75, height: 75)
                .scaleEffect(appeared ? 1 : 0.65)
                .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.75).delay(0.08), value: appeared)
            Circle()
                .fill(green.gradient)
                .frame(width: 58, height: 58)
                .shadow(color: green.opacity(0.28), radius: 12, y: 4)
                .scaleEffect(appeared ? 1 : 0.6)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.65), value: appeared)
            ArrivalCheckmark()
                .trim(from: 0, to: appeared ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .frame(width: 25, height: 20)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.32).delay(0.18), value: appeared)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        .task {
            guard !appeared else { return }
            appeared = true
            guard !reduceMotion else { return }
            do {
                try await Task.sleep(for: .milliseconds(850))
                burstFinished = true
            } catch { }
        }
    }
}

private struct ArrivalCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.height * 0.5))
        path.addLine(to: CGPoint(x: rect.width * 0.36, y: rect.height * 0.9))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.1))
        return path
    }
}

/// Each section appears once; live trip updates do not replay the entrance.
struct ArrivalSectionEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var delay: Double = 0

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 12)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.38).delay(delay), value: appeared)
            .onAppear { appeared = true }
    }
}

struct ArrivalActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct ArrivalConfettiPiece: Identifiable {
    let id: Int
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let angle: Double
    let color: Color
}
