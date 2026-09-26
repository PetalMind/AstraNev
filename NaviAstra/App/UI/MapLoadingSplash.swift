import SwiftUI

struct MapLoadingSplash: View {
    private let accent = Color(red: 0.36, green: 0.91, blue: 0.82)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.075, blue: 0.13), Color(red: 0.012, green: 0.025, blue: 0.055)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            Circle()
                .fill(accent.opacity(0.13))
                .frame(width: 300, height: 300)
                .blur(radius: 90)
                .offset(x: 70, y: -110)

            VStack(spacing: 25) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 92, height: 92)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 29, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 29, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: accent.opacity(0.2), radius: 24, y: 8)

                VStack(spacing: 8) {
                    Text("NAVI ASTRA")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .tracking(3.5)
                        .foregroundStyle(.white)

                    Text("Przygotowujemy mapę…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.66))
                }

                ProgressView()
                    .tint(accent)
                    .scaleEffect(1.08)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }
}
