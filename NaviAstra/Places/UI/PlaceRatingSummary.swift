import SwiftUI

struct PlaceRatingSummary: View {
    let identity: PlaceIdentity
    let resolvedOSMID: String?
    @State private var rating: PlaceRating?
    @State private var isLoading = true
    @State private var failed = false
    @State private var retry = 0

    private var refreshKey: String {
        identity.cacheKey + "/" + identity.name + "/" + (resolvedOSMID ?? "") + "/\(retry)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isLoading {
                ProgressView("Pobieranie ocen…").font(.caption)
            } else if failed {
                Text("Oceny są chwilowo niedostępne.")
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
                Button("Ponów pobieranie ocen", systemImage: "arrow.clockwise") { retry += 1 }
                    .font(.caption)
            } else if let rating {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { stars(rating); ratingLabel(rating) }
                    VStack(alignment: .leading, spacing: 4) { stars(rating); ratingLabel(rating) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Ocena \(rating.stars.formatted(.number.precision(.fractionLength(1)))) na 5, liczba ocen: \(rating.count). Źródło: Mangrove.")
            } else {
                Label("Brak ocen w Mangrove", systemImage: "star")
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
            }
            HStack(spacing: 8) {
                Link("Mangrove Reviews", destination: URL(string: "https://mangrove.reviews/")!)
                if let rating {
                    Link(rating.includesShareAlike ? "CC BY-SA 4.0" : "CC BY 4.0",
                         destination: URL(string: rating.includesShareAlike
                            ? "https://creativecommons.org/licenses/by-sa/4.0/"
                            : "https://creativecommons.org/licenses/by/4.0/")!)
                }
            }
            .font(.caption2)
        }
        .task(id: refreshKey) {
            rating = nil
            failed = false
            isLoading = true
            do {
                let value = try await MangrovePlaceRatingProvider.shared.rating(
                    for: identity, resolvedOSMID: resolvedOSMID, forceRefresh: retry > 0)
                guard !Task.isCancelled else { return }
                rating = value
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                isLoading = false
            }
        }
    }

    private func stars(_ rating: PlaceRating) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<5) { index in
                let fraction = min(1, max(0, rating.stars - Double(index)))
                Image(systemName: "star")
                    .foregroundStyle(Color.naviTextSecondary)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Image(systemName: "star.fill")
                                .foregroundStyle(Color(naviHex: NaviAstraColorPalette.warning))
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: geometry.size.width * fraction)
                                }
                        }
                    }
            }
        }
        .font(.caption)
    }

    private func ratingLabel(_ rating: PlaceRating) -> some View {
        Text("\(rating.stars.formatted(.number.precision(.fractionLength(1)))) / 5 · Liczba ocen: \(rating.count)")
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.naviTextSecondary)
    }
}
