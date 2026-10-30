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

    @State private var expanded = false
    @State private var hours: OpeningHoursPresentation?
    @State private var arrivalHours: OpeningHoursPresentation?

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
                                Text(summary)
                                    .font(.caption.weight(.medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if let hours, let status = hours.statusText {
                                Text(status)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(hours.isOpen == false ? Color.orange : Color.secondary)
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
            if expanded {
                Divider().padding(.bottom, 12)
                PlaceDetailsView(result: result, isSaved: isSaved, onSave: onSave,
                                 isNavigating: isStop, primaryActionTitle: actionTitle,
                                 onRemove: onRemove, onRename: onRename, onPlanRoute: onSelect)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .iosCardSurface(radius: 18)
        .task(id: "\(result.id)|\(result.openingHours ?? "")|\(String(describing: result.travelTime))|\(scenePhase)") {
            guard scenePhase == .active else { return }
            // Use known/cached hours here; network enrichment belongs to the detail view.
            while !Task.isCancelled {
                if let details = await PlaceSearchOpeningHours.seed(result) {
                    let presentation = await PlaceSearchOpeningHours.presentations(details, travelTime: result.travelTime)
                    guard !Task.isCancelled else { return }
                    hours = presentation.now
                    arrivalHours = presentation.arrival
                }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}
#endif
