import SwiftUI

struct PlaceDetailsHeroSummary: View {
    let title: String
    let symbol: String
    let showsPOIIcon: Bool
    let travelSummary: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsPOIIcon {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                if let travelSummary {
                    Label(travelSummary, systemImage: "location")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PlaceDetailsActionBar: View {
    let primaryActionTitle: String
    let isNavigating: Bool
    let isSaved: Bool
    let favoritePulseScale: CGFloat
    let canRemoveSavedPlace: Bool
    let showsPrimaryAction: Bool
    let onPlanRoute: () -> Void
    let onRouteFromPlace: (() -> Void)?
    let onToggleSavedState: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            if showsPrimaryAction {
                Button(action: onPlanRoute) {
                    Label(primaryActionTitle,
                          systemImage: isNavigating ? "plus" : "arrow.triangle.turn.up.right.diamond")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }

            if let onRouteFromPlace, !isNavigating {
                Button(action: onRouteFromPlace) {
                    Label("Stąd", systemImage: "arrowshape.turn.up.left")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Wyznacz trasę z tego miejsca")
            }

            Button(action: onToggleSavedState) {
                Image(systemName: isSaved ? "heart.fill" : "heart")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSaved ? Color.red : Color.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .scaleEffect(favoritePulseScale)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isSaved ? "Usuń z Ulubionych" : "Dodaj do Ulubionych")
            .accessibilityHint(isSaved ? "Wymaga potwierdzenia" : "Zapisz to miejsce na później")
            .disabled(isSaved && !canRemoveSavedPlace)
        }
    }
}
