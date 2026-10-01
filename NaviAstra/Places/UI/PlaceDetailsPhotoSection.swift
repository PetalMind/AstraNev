import SwiftUI

struct PlaceDetailsPhotoSection: View {
    let photo: PlacePhoto?
    let imagePhase: AsyncImagePhase?
    let lookAroundImage: Image?
    let placePhotoLoadFailed: Bool
    let isLoadingPlacePhoto: Bool
    let isLoadingDetails: Bool
    let category: String
    let brandName: String
    let photoHeight: CGFloat
    let onRetry: () -> Void
    let onOpenLookAround: () -> Void
    let onPlacePhotoLoadFailure: () async -> Void

    var body: some View {
        if let photo, photo.role == .brandLogo {
            brandLogoSection(photo)
        } else {
            placePhotoHero
        }
    }

    private var placePhotoHero: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let lookAroundImage, photo == nil || placePhotoLoadFailed {
                            lookAroundImage
                                .resizable()
                                .scaledToFill()
                        } else if let photo, let imagePhase {
                            switch imagePhase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                case .empty:
                                    photoLoadingPlaceholder
                                case .failure:
                                    if placePhotoLoadFailed {
                                        photoPlaceholder
                                    } else {
                                        photoLoadingPlaceholder.task(id: photo.imageURL) {
                                            guard !Task.isCancelled else { return }
                                            await onPlacePhotoLoadFailure()
                                        }
                                    }
                                @unknown default:
                                    photoPlaceholder
                            }
                        } else if let lookAroundImage {
                            lookAroundImage
                                .resizable()
                                .scaledToFill()
                        } else {
                            photoPlaceholder
                        }
                    }
                    .frame(width: geometry.size.width, height: photoHeight)
                    .clipped()

#if os(iOS)
                    if lookAroundImage != nil {
                        Button(action: onOpenLookAround) {
                            Label("Rozejrzyj się", systemImage: "viewfinder")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                    }
#endif
                }
                .frame(width: geometry.size.width, height: photoHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .frame(height: photoHeight)

            if lookAroundImage != nil && (photo == nil || placePhotoLoadFailed) {
                Label("Widok z Apple Look Around", systemImage: "viewfinder")
                    .font(.caption2)
                    .foregroundStyle(Color.naviTextSecondary)
            } else if let photo, !placePhotoLoadFailed {
                PlaceDetailsPhotoCredit(
                    photo: photo,
                    sourceTitle: photo.source == .wikimediaCommons ? "Wikimedia Commons" : "Oryginalne zdjęcie")
            } else if lookAroundImage != nil {
                Label("Widok z Apple Look Around", systemImage: "viewfinder")
                    .font(.caption2)
                    .foregroundStyle(Color.naviTextSecondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func brandLogoSection(_ photo: PlacePhoto) -> some View {
        HStack(spacing: 12) {
            Group {
                if let imagePhase {
                    switch imagePhase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .empty:
                        ProgressView().controlSize(.small)
                    case .failure:
                        retryLogoButton
                    @unknown default:
                        logoPlaceholder
                    }
                } else {
                    logoPlaceholder
                }
            }
            .frame(width: 62, height: 62)
            .padding(8)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(brandName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                PlaceDetailsPhotoCredit(photo: photo, sourceTitle: "Logo · Wikimedia Commons")
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
    }

    private var retryLogoButton: some View {
        Button(action: onRetry) {
            Image(systemName: "tag.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ponów pobieranie logo")
    }

    private var logoPlaceholder: some View {
        Image(systemName: "tag.fill")
            .font(.title2)
            .foregroundStyle(Color.accentColor)
    }

    private var photoPlaceholder: some View {
        VStack(spacing: 8) {
            if isLoadingPlacePhoto {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: photoSymbol(for: category))
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(brandName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Text(isLoadingPlacePhoto ? "Wyszukiwanie zdjęcia miejsca…" : "Zdjęcie niedostępne")
                .font(.caption)
                .foregroundStyle(Color.naviTextSecondary)
            if !isLoadingDetails && !isLoadingPlacePhoto {
                Button("Spróbuj ponownie", systemImage: "arrow.clockwise", action: onRetry)
                    .font(.caption.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.045))
    }

    private var photoLoadingPlaceholder: some View {
        ProgressView("Ładowanie zdjęcia…")
            .font(.caption)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.045))
    }

    private func photoSymbol(for category: String) -> String {
        let value = category.lowercased()
        if value.contains("fuel") || value.contains("gas_station") { return "fuelpump.fill" }
        if value.contains("parking") { return "parkingsign.circle.fill" }
        if value.contains("charging") || value.contains("ev_charger") { return "bolt.car.fill" }
        if value.contains("pharmacy") { return "cross.case.fill" }
        if value.contains("atm") || value.contains("bank") { return "banknote.fill" }
        if value.contains("shop") || value.contains("supermarket") { return "cart.fill" }
        if value.contains("museum") || value.contains("historic") || value.contains("castle") { return "building.columns.fill" }
        if value.contains("theatre") || value.contains("theater") || value.contains("cinema") { return "theatermasks.fill" }
        if value.contains("hotel") || value.contains("hostel") { return "bed.double.fill" }
        if value.contains("restaurant") || value.contains("cafe") || value.contains("food") { return "fork.knife" }
        if value.contains("park") || value.contains("garden") { return "tree.fill" }
        if value.contains("viewpoint") || value.contains("attraction") { return "binoculars.fill" }
        return "photo"
    }
}

private struct PlaceDetailsPhotoCredit: View {
    let photo: PlacePhoto
    let sourceTitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Link(sourceTitle, destination: photo.sourcePageURL)
            Text("· \(photo.attribution)")
                .foregroundStyle(Color.naviTextSecondary)
            if let licenseURL = photo.licenseURL {
                Link(photo.licenseName ?? "Licencja", destination: licenseURL)
            } else if let licenseName = photo.licenseName {
                Text("· \(licenseName)")
                    .foregroundStyle(Color.naviTextSecondary)
            }
        }
        .font(.caption2)
        .lineLimit(2)
    }
}
