import SwiftUI
import MapKit
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

enum PlaceDetailsPresentation: Equatable {
    case compact
    case medium
    case full
}

struct PlaceDetailsView: View {
    let result: SearchResult
    private let isFavoriteFromParent: Bool
    let onSave: () -> Bool
    let onRemove: (() -> Bool)?
    let onRename: ((String) -> Bool)?
    let onPlanRoute: () -> Void
    let onRouteFromPlace: (() -> Void)?
    let isNavigating: Bool
    let primaryActionTitle: String
    let supplementalDetails: [String]
    let presentation: PlaceDetailsPresentation
    let embeddedInBottomSheet: Bool
    let showsPrimaryAction: Bool
    let onExpandDetails: (() -> Void)?

    @State private var details: PlaceDetails?
    @State private var isSaved: Bool
    @State private var favoriteFeedback: FavoriteFeedback?
    @State private var saveError: String?
    @State private var showRemoveConfirmation = false
    @State private var showRenamePrompt = false
    @State private var savedName = ""
    @State private var favoritePulseScale: CGFloat = 1
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var retry = 0
    @State private var showHours = false
    @State private var loadedAt: Date?
    @State private var placePhoto: PlacePhoto?
    @State private var loadedPhotoImage: Image?
    @State private var loadedPhotoURL: URL?
    @State private var placePhotos: [PlacePhoto] = []
    @State private var placePhotoLoadFailed = false
    @State private var lookAroundPreview: PlaceLookAroundPreview?
    @State private var isLoadingPlacePhoto = false
    @State private var showLookAround = false
    @State private var failedPhotoURLs: Set<URL> = []
    @State private var hasAppleDetails = false
    private let provider = OpenStreetMapPlaceDetailsProvider()

    init(result: SearchResult, isSaved: Bool, onSave: @escaping () -> Bool,
         isNavigating: Bool = false, primaryActionTitle: String = "Wyznacz trasę",
         presentation: PlaceDetailsPresentation = .full,
         embeddedInBottomSheet: Bool = false,
         showsPrimaryAction: Bool = true,
         onExpandDetails: (() -> Void)? = nil,
         supplementalDetails: [String] = [],
         onRouteFromPlace: (() -> Void)? = nil,
         onRemove: (() -> Bool)? = nil,
         onRename: ((String) -> Bool)? = nil,
         onPlanRoute: @escaping () -> Void) {
        self.result = result
        self.isFavoriteFromParent = isSaved
        self.onSave = onSave
        self.onPlanRoute = onPlanRoute
        self.onRouteFromPlace = onRouteFromPlace
        self.onRemove = onRemove
        self.onRename = onRename
        self.isNavigating = isNavigating
        self.primaryActionTitle = primaryActionTitle
        self.presentation = presentation
        self.embeddedInBottomSheet = embeddedInBottomSheet
        self.showsPrimaryAction = showsPrimaryAction
        self.onExpandDetails = onExpandDetails
        self.supplementalDetails = supplementalDetails
        _details = State(initialValue: PlaceDetails.partial(for: result))
        _isSaved = State(initialValue: isSaved)
        _savedName = State(initialValue: result.destination.name)
        _isLoading = State(initialValue: result.isPOI)
    }

    private var placeDetailsContent: some View {
        VStack(alignment: .leading, spacing: presentation == .compact ? 12 : 16) {
            HStack(alignment: .top, spacing: 12) {
                PlaceDetailsHeroSummary(
                    title: details?.name ?? result.destination.name,
                    symbol: photoSymbol(for: details?.category ?? result.category ?? ""),
                    showsPOIIcon: result.isPOI,
                    categoryTitle: (details?.category ?? result.category).map(PlaceCategoryPresentation.title),
                    travelSummary: travelSummary)

                PlaceDetailsFavoriteButton(
                    isSaved: isSaved, pulseScale: favoritePulseScale,
                    canRemove: onRemove != nil, onToggle: toggleSavedState)
            }

            // The same essentials stay above photos in every presentation.
            compactDetailsSummary()
            detailsLoadStatus

            if showsPrimaryAction || (onRouteFromPlace != nil && !isNavigating) {
                placeDetailsActionBar
            }

            if favoriteFeedback != nil {
                FavoriteFeedbackOverlay(feedback: $favoriteFeedback)
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(Color(naviHex: NaviAstraColorPalette.danger))
            }

            if presentation != .compact, let details,
               details.phoneURL != nil || details.websiteURL != nil {
                PlaceDetailsQuickContact(details: details, showsPhoneNumber: presentation == .full)
            }

            if presentation == .medium, let onExpandDetails {
                Button(action: onExpandDetails) {
                    HStack {
                        Text("Wszystkie szczegóły")
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityHint("Rozwiń panel, aby zobaczyć pełne informacje o miejscu")
            }

            if presentation != .compact, result.isPOI,
               PaliwoMapaFuelPriceProvider.isFuelStation(category: details?.category ?? result.category) {
                PlaceFuelPricesSection(identity: fuelPriceIdentity)
            }

            if presentation == .full {
                ForEach(supplementalDetails, id: \.self) { detail in
                    Label(detail, systemImage: "info.circle")
                        .font(.subheadline)
                }
                if let details {
                    PlaceDetailsAttributesSection(details: details, showHours: $showHours)
                }

                if showsPlacePhoto {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(placePhoto?.role == .brandLogo ? "Marka" : "Zdjęcia i okolica")
                            .font(.headline.weight(.semibold))
                        placePhotoSection
                    }
                }
            }

            if presentation == .full {
                if let loadedAt {
                    let sourceTitle = details?.source.title ?? "OpenStreetMap"
                    let sources = hasAppleDetails && details?.source != .mapKit ? "Apple Maps + " + sourceTitle : sourceTitle
                    Text("\(sources) · pobrano \(loadedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(Color.naviTextSecondary)
                } else if let details {
                    Text(details.source.title).font(.caption2).foregroundStyle(Color.naviTextSecondary)
                }
            }
        }
        .padding(embeddedInBottomSheet ? 0 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(embeddedInBottomSheet ? Color.clear : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    private var placeDetailsActionBar: some View {
        PlaceDetailsActionBar(
            primaryActionTitle: primaryActionTitle,
            isNavigating: isNavigating,
            showsPrimaryAction: showsPrimaryAction,
            onPlanRoute: onPlanRoute,
            onRouteFromPlace: onRouteFromPlace)
    }

    private var fuelPriceIdentity: PlaceIdentity {
        var identity = result.placeIdentity
        identity.brand = details?.brand ?? identity.brand
        identity.operatorName = details?.operatorName ?? identity.operatorName
        identity.countryCode = details?.countryCode ?? identity.countryCode
        return identity
    }

    private func compactDetailsSummary() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let address = details?.address ?? result.destination.address, !address.isEmpty {
                Label(address, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(Color.naviTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if result.isPOI, let details {
                PlaceDetailsCompactAttributesSection(details: details, isLoading: isLoading,
                                                     showHours: $showHours)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var detailsLoadStatus: some View {
        if isLoading {
            ProgressView("Uzupełnianie informacji…")
                .font(.caption)
        } else if let loadError {
            VStack(alignment: .leading, spacing: 8) {
                Text(loadError).font(.caption).foregroundStyle(Color.naviTextSecondary)
                Button("Spróbuj ponownie", systemImage: "arrow.clockwise") { retry += 1 }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
            }
        } else if result.isPOI, details?.hasAdditionalInformation != true, supplementalDetails.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Brak dodatkowych informacji o tym miejscu.")
                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
                Button("Sprawdź ponownie", systemImage: "arrow.clockwise") { retry += 1 }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
    }

    var body: some View {
        placeDetailsContent
        .confirmationDialog("Usunąć z Ulubionych?", isPresented: $showRemoveConfirmation,
                            titleVisibility: .visible) {
            Button("Usuń", role: .destructive) {
                if onRemove?() == true {
                    isSaved = false
                } else {
                    saveError = "Nie udało się usunąć miejsca z Ulubionych."
                }
            }
            Button("Anuluj", role: .cancel) { }
        } message: {
            Text(result.destination.name)
        }
        .alert("Zmień nazwę", isPresented: $showRenamePrompt) {
            TextField("Nazwa miejsca", text: $savedName)
            Button("Zapisz") {
                if onRename?(savedName) != true {
                    saveError = "Nie udało się zmienić nazwy miejsca."
                }
            }
            Button("Anuluj", role: .cancel) { }
        }
#if os(iOS)
        .lookAroundViewer(isPresented: $showLookAround,
                          initialScene: lookAroundPreview?.scene)
#endif
        .background {
            // Keep image loading alive without reserving space in the place card.
            if !isNavigating, let photo = placePhoto {
                AsyncImage(url: photo.imageURL) { phase in
                    Color.clear
                        .frame(width: 0, height: 0)
                        .task(id: photo.imageURL.absoluteString + imagePhaseKey(phase)) {
                            guard !Task.isCancelled else { return }
                            switch phase {
                            case .success(let image):
                                loadedPhotoImage = image
                                loadedPhotoURL = photo.imageURL
                            case .failure:
                                loadedPhotoImage = nil
                                loadedPhotoURL = nil
                                if photo.role == .brandLogo {
                                    placePhoto = nil
                                } else {
                                    await handlePlacePhotoFailure()
                                }
                            default:
                                break
                            }
                        }
                }
                .id(detailsRefreshKey + photo.imageURL.absoluteString)
                .frame(width: 0, height: 0)
                .clipped()
            }
        }
        .task(id: detailsRefreshKey) {
            await loadPlaceDetails()
        }
        .task(id: photoRefreshKey) {
            placePhoto = nil
            loadedPhotoImage = nil
            loadedPhotoURL = nil
            placePhotos = []
            failedPhotoURLs = []
            placePhotoLoadFailed = false
            lookAroundPreview = nil
            isLoadingPlacePhoto = false
            guard result.isPOI, !isNavigating, let current = details else { return }
            await loadPlacePhoto(for: current, forceRefresh: retry > 0)
        }
        .task(id: timeZoneRefreshKey) {
            guard result.isPOI, details?.timeZoneIdentifier == nil else { return }
            let key = result.placeIdentity.cacheKey
            let identifier = await PlaceTimeZoneResolver.identifier(for: result.destination.coordinate)
            guard !Task.isCancelled, key == result.placeIdentity.cacheKey,
                  let identifier else { return }
            details?.timeZoneIdentifier = identifier
        }
        .onChange(of: isFavoriteFromParent) { _, newValue in
            isSaved = newValue
        }
    }

    @MainActor
    private func loadPlaceDetails() async {
        details = PlaceDetails.partial(for: result)
        loadedAt = nil
        hasAppleDetails = false
        loadError = nil
        guard result.isPOI else { return }
        isLoading = true
        async let appleDetails = try? MapKitPlaceDetailsProvider().details(for: result.placeIdentity)
        defer { if !Task.isCancelled { isLoading = false } }
        if let cached = await provider.cachedDetails(for: result.placeIdentity) {
            guard !Task.isCancelled else { return }
            details = details?.merging(cached) ?? cached
            loadedAt = cached.fetchedAt
        }
        do {
            async let refreshedDetails = provider.details(for: result.placeIdentity, forceRefresh: retry > 0)
            let native = await appleDetails
            guard !Task.isCancelled else { return }
            if let native {
                details = details.map { native.merging($0) } ?? native
                hasAppleDetails = true
            }
            if let loaded = try await refreshedDetails {
                guard !Task.isCancelled else { return }
                // A fresh response replaces stale fields; removed hours/contact data must disappear.
                let timeZone = details?.timeZoneIdentifier
                if let native {
                    details = native.merging(loaded)
                } else if result.placeProvider == .mapKit {
                    details = PlaceDetails.partial(for: result)?.merging(loaded) ?? loaded
                } else {
                    details = loaded
                }
                if details?.timeZoneIdentifier == nil { details?.timeZoneIdentifier = timeZone }
                loadedAt = loaded.fetchedAt
            } else {
                // An identified object that disappeared must not keep displaying its old cached hours.
                details = native ?? PlaceDetails.partial(for: result)
                loadedAt = native?.fetchedAt
            }
        } catch {
            guard !Task.isCancelled else { return }
            loadError = "Nie udało się odświeżyć informacji. Pokazujemy dostępne dane; mogą być nieaktualne."
        }
    }

    private func toggleSavedState() {
        if isSaved {
            showRemoveConfirmation = true
            return
        }
        guard onSave() else {
            saveError = nil
            favoriteFeedback = FavoriteFeedback(message: "Nie udało się zapisać miejsca",
                                                symbol: "exclamationmark.triangle.fill")
            return
        }
        isSaved = true
        saveError = nil
        favoriteFeedback = FavoriteFeedback(
            message: "Dodano do Ulubionych",
            detail: "Przypięto do szybkich skrótów",
            undoAction: onRemove.map { remove in
                {
                    if remove() {
                        isSaved = false
                        saveError = nil
                        favoriteFeedback = FavoriteFeedback(message: "Cofnięto dodanie")
                    } else {
                        favoriteFeedback = FavoriteFeedback(message: "Nie udało się cofnąć zapisu",
                                                             symbol: "exclamationmark.triangle.fill")
                    }
                }
            },
            secondaryAction: onRename.map { _ in
                { showRenamePrompt = true; savedName = result.destination.name }
            })
        withAnimation(.spring(response: 0.15, dampingFraction: 0.52)) {
            favoritePulseScale = 1.18
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.spring(response: 0.19, dampingFraction: 0.8)) {
                favoritePulseScale = 1
            }
        }
#if os(iOS)
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.prepare()
        haptic.impactOccurred()
#endif
    }

    private var showsPlacePhoto: Bool {
        guard !isNavigating else { return false }
        return lookAroundPreview != nil ||
            (loadedPhotoImage != nil && loadedPhotoURL == placePhoto?.imageURL)
    }

    private func imagePhaseKey(_ phase: AsyncImagePhase) -> String {
        switch phase {
        case .empty: "/loading"
        case .success: "/loaded"
        case .failure: "/failed"
        @unknown default: "/unknown"
        }
    }

    private func handlePlacePhotoFailure() async {
        if let url = placePhoto?.imageURL { failedPhotoURLs.insert(url) }
        if let next = placePhotos.first(where: { !failedPhotoURLs.contains($0.imageURL) }) {
            placePhoto = next
            placePhotoLoadFailed = false
        } else {
            placePhotoLoadFailed = true
            await loadLookAroundFallback()
        }
    }

    private var detailsRefreshKey: String {
        let placeKey = result.placeIdentity.cacheKey
        let retryAttempt = String(retry)
        return placeKey + "/" + retryAttempt
    }

    private var photoRefreshKey: String {
        [detailsRefreshKey, String(isNavigating), details?.category ?? "", result.category ?? "", details?.imageURL ?? "",
         details?.imageAttribution ?? "", details?.imageLicense ?? "",
         details?.wikimediaCommons ?? "", details?.wikidataID ?? "",
         details?.brandWikidataID ?? ""].joined(separator: "|")
    }

    private var timeZoneRefreshKey: String {
        detailsRefreshKey + "/" + (details?.timeZoneIdentifier ?? "unknown")
    }

    private var placePhotoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = loadedPhotoImage, loadedPhotoURL == placePhoto?.imageURL {
                placePhotoPresentation(imagePhase: .success(image))
            } else if lookAroundPreview != nil {
                placePhotoPresentation(imagePhase: nil)
            }
            if placePhotos.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(placePhotos, id: \.imageURL) { photo in
                            Button {
                                placePhoto = photo
                                placePhotoLoadFailed = false
                            } label: {
                                AsyncImage(url: photo.imageURL) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                    } else {
                                        Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                                .frame(width: 76, height: 58)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(placePhoto?.imageURL == photo.imageURL ? Color.accentColor : Color.clear, lineWidth: 2)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Pokaż zdjęcie miejsca: \(photo.attribution)")
                            .accessibilityAddTraits(placePhoto?.imageURL == photo.imageURL ? .isSelected : [])
                        }
                    }
                    .padding(2)
                }
            }
        }
    }

    private func placePhotoPresentation(imagePhase: AsyncImagePhase?) -> some View {
        PlaceDetailsPhotoSection(
            photo: placePhoto,
            imagePhase: imagePhase,
            lookAroundImage: lookAroundPreview.map { platformImage($0.image) },
            placePhotoLoadFailed: placePhotoLoadFailed,
            isLoadingPlacePhoto: isLoadingPlacePhoto,
            isLoadingDetails: isLoading,
            category: details?.category ?? result.category ?? "",
            brandName: details?.brand ?? result.brand ?? result.destination.name,
            photoHeight: 220,
            onRetry: { retry += 1 },
            onOpenLookAround: { showLookAround = true },
            onPlacePhotoLoadFailure: { await handlePlacePhotoFailure() })
    }

    private func loadPlacePhoto(for details: PlaceDetails, forceRefresh: Bool) async {
        isLoadingPlacePhoto = true
        defer {
            if !Task.isCancelled { isLoadingPlacePhoto = false }
        }
        let photos = await PlacePhotoResolver.gallery(for: details, identity: result.placeIdentity,
                                                      forceRefresh: forceRefresh)
        guard !Task.isCancelled else { return }
        placePhotos = photos
        placePhoto = photos.first
        if photos.isEmpty {
            await loadLookAroundFallback(forceRefresh: forceRefresh)
        }
        guard !Task.isCancelled else { return }
        if placePhoto == nil && lookAroundPreview == nil {
            let brandLogo = await PlacePhotoResolver.resolveBrandLogo(for: details, identity: result.placeIdentity,
                                                                       forceRefresh: forceRefresh)
            guard !Task.isCancelled else { return }
            placePhoto = brandLogo
        }
    }

    private func loadLookAroundFallback(forceRefresh: Bool = false) async {
        guard lookAroundPreview == nil, !Task.isCancelled else { return }
        let eligible = PlacePhotoResolver.isEligible(category: details?.category)
            || PlacePhotoResolver.isEligible(category: result.category)
        let preview: PlaceLookAroundPreview?
        if eligible {
            preview = await PlaceLookAroundProvider.preview(at: result.destination.coordinate)
        } else {
            preview = nil
        }
        guard !Task.isCancelled else { return }
        lookAroundPreview = preview
        guard preview == nil,
              let details,
              let brandLogo = await PlacePhotoResolver.resolveBrandLogo(for: details,
                                                                         identity: result.placeIdentity,
                                                                         forceRefresh: forceRefresh),
              !Task.isCancelled else { return }
        placePhoto = brandLogo
        placePhotoLoadFailed = false
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

    private func platformImage(_ image: PlacePhotoPlatformImage) -> Image {
#if os(macOS)
        Image(nsImage: image)
#else
        Image(uiImage: image)
#endif
    }

    private var travelSummary: String? {
        result.travelSummary
    }
}

private extension PlaceDetails {
    var hasAdditionalInformation: Bool {
        address != nil || openingHours != nil || phone != nil || website != nil ||
            imageURL != nil || wikimediaCommons != nil || wikidataID != nil || brandWikidataID != nil ||
            wheelchair != nil || parking != nil || osmParking != nil || driveThrough != nil
            || internetAccess != nil || takeaway != nil || delivery != nil || outdoorSeating != nil
    }
}

struct PlaceSearchResultRow: View {
    let result: SearchResult
    let index: Int
    let isSaved: Bool
    let onSave: () -> Bool
    var onRemove: (() -> Bool)? = nil
    var onRename: ((String) -> Bool)? = nil
    let onSelect: () -> Void
    var isNavigating = false
    var primaryActionTitle = "Wyznacz trasę"
    var supplementalDetails: [String] = []
    var expandedDetails: [String]? = nil

    @State private var isExpanded = false
    var showsSourceSubtitle = true
    var primaryMetaLine: String? = nil
    var onExpand: (() -> Void)? = nil
    var showsQuickRouteAction = false

    @State private var savedOverride: Bool? = nil
    @State private var favoriteFeedback: FavoriteFeedback? = nil
    @State private var showRemoveFavoriteConfirmation = false
    @State private var showRenamePrompt = false
    @State private var savedName = ""

    private var showsAsSaved: Bool { savedOverride ?? isSaved }

    private var allSupplementalDetails: [String] {
        expandedDetails ?? supplementalDetails
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Button {
                    let expands = !isExpanded
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded = expands }
                    if expands { onExpand?() }
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
                                .foregroundStyle(Color.naviTextPrimary)
                            if showsSourceSubtitle {
                                Text(result.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(Color.naviTextSecondary)
                            }
                            if let primaryMetaLine {
                                Text(primaryMetaLine)
                                    .font(.caption)
                                    .foregroundStyle(Color.naviTextSecondary)
                                    .lineLimit(1)
                            }
                            if let summary = result.travelSummary {
                                Text(summary)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.naviTextSecondary)
                                    .lineLimit(1)
                            }
                            ForEach(supplementalDetails, id: \.self) { detail in
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(Color.naviTextSecondary)
                                    .lineLimit(1)
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

                if showsQuickRouteAction {
                    Button(action: onSelect) {
                        Image(systemName: isNavigating ? "plus" : "arrow.turn.up.right")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(primaryActionTitle): \(result.destination.name)")
                    .accessibilityHint("Wyznacza trasę bez rozwijania szczegółów miejsca")
                }

                if !isExpanded {
                    Button(action: toggleFavorite) {
                        Image(systemName: showsAsSaved ? "heart.fill" : "heart")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(showsAsSaved ? Color.accentColor : Color.naviTextSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsAsSaved ? "Usuń z Ulubionych" : "Dodaj do Ulubionych")
                    .accessibilityHint(showsAsSaved ? "Wymaga potwierdzenia" : "Zapisz to miejsce na później")
                    .disabled(showsAsSaved && onRemove == nil)
                }
            }

            if favoriteFeedback != nil {
                FavoriteFeedbackOverlay(feedback: $favoriteFeedback)
            }

            if isExpanded {
                PlaceDetailsView(result: result, isSaved: showsAsSaved, onSave: onSave,
                                 isNavigating: isNavigating, primaryActionTitle: primaryActionTitle,
                                 supplementalDetails: allSupplementalDetails,
                                 onRemove: onRemove, onRename: onRename,
                                 onPlanRoute: onSelect)
                    .id(result.placeIdentity.cacheKey)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .confirmationDialog("Usunąć z Ulubionych?", isPresented: $showRemoveFavoriteConfirmation,
                            titleVisibility: .visible) {
            Button("Usuń", role: .destructive) {
                if onRemove?() == true {
                    savedOverride = false
                    favoriteFeedback = FavoriteFeedback(message: "Usunięto z Ulubionych")
                } else {
                    favoriteFeedback = FavoriteFeedback(message: "Nie udało się usunąć miejsca",
                                                        symbol: "exclamationmark.triangle.fill")
                }
            }
            Button("Anuluj", role: .cancel) { }
        } message: {
            Text(result.destination.name)
        }
        .alert("Zmień nazwę", isPresented: $showRenamePrompt) {
            TextField("Nazwa miejsca", text: $savedName)
            Button("Zapisz") {
                if onRename?(savedName) != true {
                    favoriteFeedback = FavoriteFeedback(message: "Nie udało się zmienić nazwy miejsca")
                }
            }
            Button("Anuluj", role: .cancel) { }
        }
        .onChange(of: isSaved) { _, _ in
            savedOverride = nil
        }
    }

    private func toggleFavorite() {
        if showsAsSaved {
            showRemoveFavoriteConfirmation = true
            return
        }
        guard onSave() else {
            favoriteFeedback = FavoriteFeedback(message: "Nie udało się zapisać miejsca",
                                                symbol: "exclamationmark.triangle.fill")
            return
        }
        savedOverride = true
        favoriteFeedback = FavoriteFeedback(
            message: "Dodano do Ulubionych",
            detail: "Przypięto do szybkich skrótów",
            undoAction: onRemove.map { remove in
                {
                    if remove() {
                        savedOverride = false
                        favoriteFeedback = FavoriteFeedback(message: "Cofnięto dodanie")
                    } else {
                        favoriteFeedback = FavoriteFeedback(message: "Nie udało się cofnąć zapisu",
                                                             symbol: "exclamationmark.triangle.fill")
                    }
                }
            },
            secondaryAction: onRename.map { _ in
                { savedName = result.destination.name; showRenamePrompt = true }
            })
    }
}

struct FavoriteFeedback: Identifiable {
    let id = UUID()
    let message: String
    var symbol: String = "checkmark.circle.fill"
    var detail: String? = nil
    var undoAction: (() -> Void)? = nil
    var secondaryAction: (() -> Void)? = nil
}

struct FavoriteFeedbackOverlay: View {
    @Binding var feedback: FavoriteFeedback?

    var body: some View {
        if let feedback {
            HStack(spacing: 10) {
                Image(systemName: feedback.symbol)
                    .foregroundStyle(Color(naviHex: feedback.symbol == "exclamationmark.triangle.fill"
                        ? NaviAstraColorPalette.warning : NaviAstraColorPalette.danger))
                VStack(alignment: .leading, spacing: 2) {
                    Text(feedback.message)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.naviTextPrimary)
                    if let detail = feedback.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Color.naviTextSecondary)
                    }
                }

                Spacer(minLength: 4)

                if let undoAction = feedback.undoAction {
                    Button("Cofnij") {
                        dismissThen(undoAction)
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }

                if let secondaryAction = feedback.secondaryAction {
                    Button("Zmień") {
                        dismissThen(secondaryAction)
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(20)
            .accessibilityElement(children: .contain)
            .task(id: feedback.id) {
                let feedbackID = feedback.id
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, self.feedback?.id == feedbackID else { return }
                withAnimation(.easeOut(duration: 0.18)) { self.feedback = nil }
            }
        }
    }

    private func dismissThen(_ action: () -> Void) {
        withAnimation(.easeOut(duration: 0.15)) { feedback = nil }
        action()
    }
}
