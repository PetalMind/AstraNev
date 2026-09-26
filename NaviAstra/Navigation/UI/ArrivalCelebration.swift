import SwiftUI

struct ArrivalCelebration: View {
    private let green = Color(red: 0.16, green: 0.82, blue: 0.36)
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
                    .rotationEffect(.degrees(piece.angle))
                    .offset(x: piece.x, y: piece.y)
            }

            Circle()
                .stroke(green.opacity(0.13), lineWidth: 13)
                .frame(width: 96, height: 96)
            Circle()
                .stroke(green.opacity(0.24), lineWidth: 8)
                .frame(width: 75, height: 75)
            Circle()
                .fill(green)
                .frame(width: 52, height: 52)
                .shadow(color: green.opacity(0.42), radius: 11, y: 2)
            Image(systemName: "checkmark")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
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
