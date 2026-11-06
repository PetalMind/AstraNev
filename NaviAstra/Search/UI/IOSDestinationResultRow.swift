#if os(iOS)
import SwiftUI

/// The whole result selects a place. Details are a separate, explicitly labelled action.
struct IOSDestinationResultRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    let result: SearchResult
    let query: String
    let isSaved: Bool
    let actionTitle: String
    let isStop: Bool
    let onSelect: () -> Void
    let onExpand: () -> Void
    let onSave: () -> Bool
    let onRemove: () -> Bool
    let onRename: (String) -> Bool
    var onEstimate: (() -> Void)? = nil
    var recoveryMessage: String? = nil

    @State private var expanded = false
    @State private var hours: OpeningHoursPresentation?
    @State private var arrivalHours: OpeningHoursPresentation?
    @State private var hoursDetails: PlaceDetails?
    @State private var hoursDetailsPlaceKey: String?
    @State private var hoursDetailsRevision = 0
    @State private var isLoadingHours = false

    private var symbol: String {
        if result.isContact { return "person.crop.circle" }
        if isSaved { return "heart.fill" }
        return result.isPOI ? "mappin.and.ellipse" : "building.2"
    }

    private var highlightedName: AttributedString {
        var title = AttributedString(result.destination.name)
        let words = query.split(whereSeparator: { $0.isWhitespace })
        for word in words where word.count > 1 {
            if let range = title.range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive],
                                       locale: Locale(identifier: "pl_PL")) {
                title[range].foregroundColor = .accentColor
            }
        }
        return title
    }

    private var address: String {
        if result.isContact { return result.subtitle }
        if let address = result.destination.address, !address.isEmpty { return address }
        let street = [result.street, result.houseNumber].compactMap { $0 }.joined(separator: " ")
        let parts = [street.isEmpty ? nil : street, result.city].compactMap { $0 }
        return parts.isEmpty ? (result.isPOI ? "Miejsce na mapie" : "Adres lub miejscowość")
            : parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Button(action: onSelect) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 40, height: 40)
                            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(highlightedName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(address)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            if let summary = result.travelSummary {
                                HStack(spacing: 6) {
                                    if result.travelEstimateStatus == .calculating {
                                        ProgressView().controlSize(.mini).accessibilityHidden(true)
                                    }
                                    Text(summary)
                                        .font(.caption.weight(.medium).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let hours, let status = hours.statusText {
                                Text(status)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(hours.isOpen == false ? Color.orange : Color.secondary)
                            } else if isLoadingHours {
                                Text("Sprawdzam godziny otwarcia…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if arrivalHours?.isOpen == false {
                                Label("Przy dojeździe: zamknięte", systemImage: "clock.badge.exclamationmark")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(actionTitle)

                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded.toggle() }
                    if expanded { onExpand() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .accessibilityLabel("\(expanded ? "Ukryj szczegóły" : "Szczegóły miejsca"): \(result.destination.name)")
                .accessibilityValue(expanded ? "Rozwinięte" : "Zwinięte")
            }
            if result.needsTravelEstimate, result.travelEstimateStatus != .calculating {
                VStack(alignment: .leading, spacing: 4) {
                    if let recoveryMessage {
                        Text(recoveryMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Button(action: onEstimate ?? onSelect) {
                        Label(onEstimate == nil ? actionTitle : "Sprawdź dojazd",
                              systemImage: "arrow.triangle.turn.up.right.diamond")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHint(onEstimate == nil ? actionTitle : "Oblicz czas i odległość dla tego miejsca")
                }
                .padding(.leading, 52)
                .padding(.trailing, 12)
                .padding(.bottom, 8)
            }
            if expanded {
                Divider().padding(.bottom, 12)
                PlaceDetailsView(result: result, isSaved: isSaved, onSave: onSave,
                                 isNavigating: isStop, primaryActionTitle: actionTitle,
                                 onRemove: onRemove, onRename: onRename,
                                 onOpeningHoursUpdate: receiveHoursDetails, onPlanRoute: onSelect)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .iosCardSurface(radius: 18)
        .task(id: hoursDataKey) {
            isLoadingHours = false
            guard scenePhase == .active, result.isPOI, !result.isContact else { return }
            // ETA changes only reevaluate arrival status; they must not cancel
            // and restart a website request for the same visible place.
            let placeKey = result.placeIdentity.cacheKey
            if hoursDetailsPlaceKey != placeKey {
                hoursDetails = nil
                hours = nil
                arrivalHours = nil
            }
            let initialRevision = hoursDetailsRevision
            guard let cached = await PlaceSearchOpeningHours.seed(result), !Task.isCancelled,
                  hoursDetailsRevision == initialRevision else { return }
            let seed = PlaceSearchOpeningHours.reconcilingSeed(cached, with: hoursDetails)
            receiveHoursDetails(seed)
            if seed.openingHours == nil {
                isLoadingHours = true
                let seedRevision = hoursDetailsRevision
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard hoursDetailsRevision == seedRevision else { return }
                let enriched = await PlaceSearchOpeningHours.enrich(seed, result: result)
                guard !Task.isCancelled, hoursDetailsRevision == seedRevision else { return }
                receiveHoursDetails(enriched)
            }
        }
        .task(id: hoursPresentationKey) {
            guard scenePhase == .active, let hoursDetails else { return }
            while !Task.isCancelled {
                let fresh = PlaceSearchOpeningHours.removingExpiredHours(from: hoursDetails)
                let presentation = await PlaceSearchOpeningHours.presentations(fresh, travelTime: result.travelTime)
                guard !Task.isCancelled else { return }
                hours = presentation.now
                arrivalHours = presentation.arrival
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private func receiveHoursDetails(_ details: PlaceDetails) {
        hoursDetailsRevision += 1
        hoursDetailsPlaceKey = result.placeIdentity.cacheKey
        hoursDetails = details
        isLoadingHours = false
    }

    private var hoursDataKey: String {
        [result.placeIdentity.cacheKey, result.openingHours ?? "", result.website ?? "",
         result.destination.address ?? "", result.street ?? "", result.houseNumber ?? "",
         result.city ?? "", String(describing: scenePhase)].joined(separator: "|")
    }

    private var hoursPresentationKey: String {
        [hoursDataKey, String(hoursDetailsRevision), hoursDetails?.openingHours ?? "", hoursDetails?.timeZoneIdentifier ?? "",
         hoursDetails?.countryCode ?? "", String(describing: hoursDetails?.fetchedAt),
         String(describing: hoursDetails?.websiteHoursCheckedAt), String(describing: result.travelTime)]
            .joined(separator: "|")
    }
}
#endif
