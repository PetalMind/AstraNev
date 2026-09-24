import SwiftUI

struct PlaceDetailsView: View {
    let result: SearchResult
    let onSave: () -> Bool
    let onPlanRoute: () -> Void
    let isNavigating: Bool
    let primaryActionTitle: String

    @State private var details: PlaceDetails?
    @State private var isSaved: Bool
    @State private var saveError: String?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var retry = 0
    @State private var showHours = false
    @State private var loadedAt: Date?
    private let provider = OpenStreetMapPlaceDetailsProvider()

    init(result: SearchResult, isSaved: Bool, onSave: @escaping () -> Bool,
         isNavigating: Bool = false, primaryActionTitle: String = "Wyznacz trasę",
         onPlanRoute: @escaping () -> Void) {
        self.result = result
        self.onSave = onSave
        self.onPlanRoute = onPlanRoute
        self.isNavigating = isNavigating
        self.primaryActionTitle = primaryActionTitle
        _details = State(initialValue: PlaceDetails.partial(for: result))
        _isSaved = State(initialValue: isSaved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 5) {
                Text(details?.name ?? result.destination.name)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                if let travelSummary {
                    Label(travelSummary, systemImage: "location")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 9) {
                Button(action: onPlanRoute) {
                    Label(primaryActionTitle,
                          systemImage: isNavigating ? "plus" : "arrow.triangle.turn.up.right.diamond")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    if onSave() {
                        isSaved = true
                        saveError = nil
                    } else {
                        saveError = "Nie udało się zapisać miejsca na urządzeniu."
                    }
                } label: {
                    Label(isSaved ? "Zapisano" : "Zapisz", systemImage: isSaved ? "star.fill" : "star")
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 42)
                }
                .buttonStyle(.bordered)
                .disabled(isSaved)
            }

            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }

            Divider()
            if let details { detailsContent(details) }

            if isLoading {
                ProgressView("Uzupełnianie informacji…")
                    .font(.caption)
            } else if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loadError).font(.caption).foregroundStyle(.secondary)
                    Button("Spróbuj ponownie", systemImage: "arrow.clockwise") { retry += 1 }
                        .font(.caption.weight(.semibold))
                }
            } else if result.isPOI, details?.hasAdditionalInformation != true {
                Text("Brak dodatkowych informacji o tym miejscu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let loadedAt {
                Text("OpenStreetMap · pobrano \(loadedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let details {
                Text(details.source.title).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .task(id: "\(result.placeIdentity.cacheKey)/\(retry)") {
            details = PlaceDetails.partial(for: result)
            loadedAt = nil
            loadError = nil
            guard result.isPOI else { return }
            isLoading = true
            defer { isLoading = false }
            if let cached = await provider.cachedDetails(for: result.placeIdentity) {
                guard !Task.isCancelled else { return }
                details = details?.merging(cached) ?? cached
                loadedAt = cached.fetchedAt
            }
            do {
                if let loaded = try await provider.details(for: result.placeIdentity) {
                    guard !Task.isCancelled else { return }
                    details = details?.merging(loaded) ?? loaded
                    loadedAt = loaded.fetchedAt
                }
            } catch {
                guard !Task.isCancelled else { return }
                loadError = "Nie udało się uzupełnić informacji. Dostępne dane pozostają widoczne."
            }
        }
    }

    private var travelSummary: String? {
        result.travelSummary
    }

    @ViewBuilder
    private func detailsContent(_ details: PlaceDetails) -> some View {
        if let category = details.category {
            Label(categoryTitle(category), systemImage: "tag")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let brand = details.brand ?? details.operatorName, brand != details.name {
            Label(brand, systemImage: "building.2")
                .font(.caption)
        }

        if let address = details.address, !address.isEmpty {
            Label(address, systemImage: "mappin.and.ellipse")
                .font(.subheadline)
                .textSelection(.enabled)
        }

        if let rawHours = details.openingHours, !rawHours.isEmpty {
            openingHours(rawHours, details: details)
        }

        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { contactLinks(details) }
            VStack(alignment: .leading, spacing: 12) { contactLinks(details) }
        }
        .font(.subheadline.weight(.medium))

        if let wheelchair = details.wheelchair {
            Label(wheelchairTitle(wheelchair), systemImage: "figure.roll")
                .font(.subheadline)
        }
        if let parking = details.parking {
            Label("Parking: \(parking)", systemImage: "parkingsign.circle").font(.subheadline)
        }
        if let driveThrough = details.driveThrough {
            Label(driveThrough.lowercased() == "yes" ? "Drive-through" : "Drive-through: \(driveThrough)", systemImage: "car.side")
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private func contactLinks(_ details: PlaceDetails) -> some View {
        if let phone = details.phone, let url = details.phoneURL {
            Link(destination: url) { Label(phone, systemImage: "phone") }
        }
        if let website = details.websiteURL {
            Link(destination: website) { Label("Strona", systemImage: "globe") }
        }
    }

    @ViewBuilder
    private func openingHours(_ rawHours: String, details: PlaceDetails) -> some View {
        let hours = details.openingHoursInfo
        VStack(alignment: .leading, spacing: 5) {
            if let status = hours?.statusText() {
                Label(status, systemImage: status.hasPrefix("Otwarte") ? "clock.fill" : "clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.hasPrefix("Otwarte") ? Color.green : Color.secondary)
            }
            DisclosureGroup("Godziny otwarcia", isExpanded: $showHours) {
                if let rows = hours?.weeklyRows {
                    ForEach(Array(rows.enumerated()), id: \.offset) { item in
                        HStack {
                            Text(item.element.0).frame(width: 46, alignment: .leading)
                            Text(item.element.1)
                            Spacer(minLength: 0)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(rawHours)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Godziny mogą się różnić w święta.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }

    private func categoryTitle(_ category: String) -> String {
        let labels = [
            "supermarket": "Supermarket", "convenience": "Sklep spożywczy", "bakery": "Piekarnia",
            "restaurant": "Restauracja", "fast_food": "Fast food", "cafe": "Kawiarnia",
            "fuel": "Stacja paliw", "parking": "Parking", "charging_station": "Ładowarka EV",
            "pharmacy": "Apteka", "bank": "Bank", "hotel": "Hotel", "park": "Park"
        ]
        return labels[category] ?? category.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func wheelchairTitle(_ value: String) -> String {
        switch value.lowercased() {
        case "yes", "designated": "Dostęp dla wózków"
        case "limited": "Ograniczony dostęp dla wózków"
        case "no": "Brak dostępu dla wózków"
        default: "Dostępność: \(value)"
        }
    }
}

private extension PlaceDetails {
    var hasAdditionalInformation: Bool {
        address != nil || openingHours != nil || phone != nil || website != nil ||
            wheelchair != nil || parking != nil || driveThrough != nil
    }
}

struct PlaceSearchResultRow: View {
    let result: SearchResult
    let index: Int
    let isSaved: Bool
    let onSave: () -> Bool
    let onSelect: () -> Void
    var isNavigating = false
    var primaryActionTitle = "Wyznacz trasę"

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 13) {
                    Text("\(index)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.destination.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(result.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let summary = result.travelSummary {
                            Text(summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Ukryj szczegóły miejsca" : "Pokaż szczegóły miejsca")

            if isExpanded {
                PlaceDetailsView(result: result, isSaved: isSaved, onSave: onSave,
                                 isNavigating: isNavigating, primaryActionTitle: primaryActionTitle, onPlanRoute: onSelect)
                    .id(result.placeIdentity.cacheKey)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
