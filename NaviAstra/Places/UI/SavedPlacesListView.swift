import SwiftUI

/// Keeps library layout independent of map state and presentation routing.
struct SavedPlacesListView: View {
    let places: [SavedPlace]
    let estimates: [String: PlaceRouteEstimate]
    let isCalculating: Bool
    let onSelect: (SavedPlace) -> Void
    let onEdit: (SavedPlace) -> Void
    let onTogglePin: (SavedPlace) -> Void
    let onRemove: (SavedPlace) -> Void
    let onSearch: () -> Void

    var body: some View {
        List {
            if places.isEmpty {
                ContentUnavailableView {
                    Label("Twoje miejsca pod ręką", systemImage: "heart")
                } description: {
                    Text("Zapisz Dom, Pracę i ulubione adresy, aby szybciej planować podróże.")
                } actions: {
                    Button("Wyszukaj miejsce", systemImage: "magnifyingglass", action: onSearch)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            section("Dom i praca", places: [PlaceKind.home, .work].compactMap { kind in
                places.first { $0.kind == kind }
            })
            section("Przypięte", places: places.filter { $0.kind == .favorite && $0.isPinned })
            section("Ulubione", places: places.filter { $0.kind == .favorite && !$0.isPinned })
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.plain)
        #endif
    }

    @ViewBuilder
    private func section(_ title: String, places: [SavedPlace]) -> some View {
        if !places.isEmpty {
            Section(title) {
                ForEach(places) { place in
                    SavedPlaceLibraryRow(
                        place: place,
                        estimate: estimates[place.id.uuidString],
                        isCalculating: isCalculating,
                        onSelect: { onSelect(place) },
                        onEdit: { onEdit(place) },
                        onTogglePin: { onTogglePin(place) },
                        onRemove: { onRemove(place) })
                }
            }
        }
    }
}

private struct SavedPlaceLibraryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let place: SavedPlace
    let estimate: PlaceRouteEstimate?
    let isCalculating: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onTogglePin: () -> Void
    let onRemove: () -> Void

    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
    }

    var body: some View {
        rowLayout {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: place.icon.symbol)
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(place.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(place.sourceContactIdentifier != nil
                             ? "Z Kontaktów · \(place.destination.address ?? place.kind.title)"
                             : (place.destination.address ?? place.kind.title))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        travelSummary
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 44, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Pokaż miejsce i zaplanuj trasę")

            HStack(spacing: 0) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Edytuj miejsce \(place.displayName)")
                Menu {
                    if place.kind == .favorite {
                        Button(place.isPinned ? "Odepnij od wyszukiwarki" : "Przypnij pod wyszukiwarką",
                               systemImage: place.isPinned ? "pin.slash" : "pin", action: onTogglePin)
                    }
                    Button("Usuń", systemImage: "trash", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Opcje miejsca \(place.displayName)")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder
    private var travelSummary: some View {
        if let estimate {
            Label("\(TravelDurationFormatter.string(minutes: estimate.minutes)) · \(distance(estimate.distanceMeters))",
                  systemImage: "arrow.triangle.turn.up.right.diamond")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text(isCalculating ? "Obliczanie trasy…" : "Trasa niedostępna")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func distance(_ meters: Double) -> String {
        guard meters.isFinite, meters >= 0 else { return "—" }
        if meters >= 1_000 {
            return (meters / 1_000).formatted(.number.precision(.fractionLength(1))
                .locale(PolishRegionalFormat.locale)) + " km"
        }
        return meters.formatted(.number.precision(.fractionLength(0))
            .locale(PolishRegionalFormat.locale)) + " m"
    }
}
