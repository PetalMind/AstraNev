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

    @State private var details: PlaceDetails?
    @State private var isSaved: Bool
    @State private var saveError: String?
    @State private var showSavedConfirmation = false
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
    @State private var placePhotoLoadFailed = false
    @State private var lookAroundPreview: PlaceLookAroundPreview?
    @State private var isLoadingPlacePhoto = false
    @State private var showLookAround = false
    private let provider = OpenStreetMapPlaceDetailsProvider()

    init(result: SearchResult, isSaved: Bool, onSave: @escaping () -> Bool,
         isNavigating: Bool = false, primaryActionTitle: String = "Wyznacz trasę",
         presentation: PlaceDetailsPresentation = .full,
         embeddedInBottomSheet: Bool = false,
         showsPrimaryAction: Bool = true,
         supplementalDetails: [String] = [],
         onRouteFromPlace: (() -> Void)? = nil,
         onRemove: (() -> Bool)? = nil,
         onRename: ((String) -> Bool)? = nil,
         onPlanRoute: @escaping () -> Void) {
        self.result = result
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
        self.supplementalDetails = supplementalDetails
        _details = State(initialValue: PlaceDetails.partial(for: result))
        _isSaved = State(initialValue: isSaved)
        _savedName = State(initialValue: result.destination.name)
    }

    private var placeDetailsContent: some View {
        VStack(alignment: .leading, spacing: presentation == .compact ? 12 : 11) {
            if presentation != .compact && showsPlacePhoto {
                placePhotoSection
            }

            PlaceDetailsHeroSummary(
                title: details?.name ?? result.destination.name,
                symbol: photoSymbol(for: details?.category ?? result.category ?? ""),
            showsPOIIcon: result.isPOI && !showsPlacePhoto,
            travelSummary: travelSummary)

            if presentation == .medium {
                compactDetailsSummary(includeCategory: false)
            }

            placeDetailsActionBar

            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }

            if presentation == .compact {
                compactDetailsSummary()
            } else if presentation == .full {
                Divider()
                if !supplementalDetails.isEmpty || details?.hasAdditionalInformation == true {
                    Text("Szczegóły miejsca")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(supplementalDetails, id: \.self) { detail in
                    Label(detail, systemImage: "info.circle")
                        .font(.subheadline)
                }
                if let details {
                    PlaceDetailsAttributesSection(details: details, showHours: $showHours)
                }

                if isLoading {
                    ProgressView("Uzupełnianie informacji…")
                        .font(.caption)
                } else if let loadError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(loadError).font(.caption).foregroundStyle(.secondary)
                        Button("Spróbuj ponownie", systemImage: "arrow.clockwise") { retry += 1 }
                            .font(.caption.weight(.semibold))
                    }
                } else if result.isPOI, details?.hasAdditionalInformation != true, supplementalDetails.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Brak dodatkowych informacji o tym miejscu.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Sprawdź ponownie", systemImage: "arrow.clockwise") { retry += 1 }
                            .font(.caption.weight(.semibold))
                    }
                }

                if let loadedAt {
                    let sourceTitle = details?.source.title ?? "OpenStreetMap"
                    Text("\(sourceTitle) · pobrano \(loadedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let details {
                    Text(details.source.title).font(.caption2).foregroundStyle(.secondary)
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
            isSaved: isSaved,
            favoritePulseScale: favoritePulseScale,
            canRemoveSavedPlace: onRemove != nil,
            showsPrimaryAction: showsPrimaryAction,
            onPlanRoute: onPlanRoute,
            onRouteFromPlace: onRouteFromPlace,
            onToggleSavedState: toggleSavedState)
    }

    @ViewBuilder
    private func compactDetailsSummary(includeCategory: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if includeCategory, let category = details?.category ?? result.category {
                Label(category.replacingOccurrences(of: "_", with: " ").capitalized,
                      systemImage: "tag")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let address = details?.address ?? result.destination.address, !address.isEmpty {
                Label(address, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            if let details {
                PlaceDetailsCompactAttributesSection(details: details, showHours: $showHours)
            }
            if isLoading {
                ProgressView("Uzupełnianie informacji…")
                    .font(.caption)
            } else if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if result.isPOI, details?.hasAdditionalInformation != true,
                      (details?.address ?? result.destination.address) == nil {
                Text("Brak dodatkowych informacji o tym miejscu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        placeDetailsContent
        .confirmationDialog("Dodano do Ulubionych", isPresented: $showSavedConfirmation,
                            titleVisibility: .visible) {
            if onRename != nil {
                Button("Zmień nazwę") { showRenamePrompt = true }
            }
            Button("Gotowe", role: .cancel) { }
        } message: {
            Text(result.destination.name)
        }
        .confirmationDialog("Usunąć z Ulubionych?", isPresented: $showRemoveConfirmation,
                            titleVisibility: .visible) {
            Button("Usuń", role: .destructive) {
                if onRemove?() == true { isSaved = false }
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
        .task(id: detailsRefreshKey) {
            await loadPlaceDetails()
        }
    }

    @MainActor
    private func loadPlaceDetails() async {
        details = PlaceDetails.partial(for: result)
        placePhoto = nil
        placePhotoLoadFailed = false
        lookAroundPreview = nil
        isLoadingPlacePhoto = false
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
            if let loaded = try await provider.details(for: result.placeIdentity, forceRefresh: retry > 0) {
                guard !Task.isCancelled else { return }
                details = details?.merging(loaded) ?? loaded
                loadedAt = loaded.fetchedAt
            }
        } catch {
            guard !Task.isCancelled else { return }
            if details?.hasAdditionalInformation != true {
                loadError = "Nie udało się uzupełnić informacji. Dostępne dane pozostają widoczne."
            }
        }
        if let current = details,
           current.timeZoneIdentifier == nil,
           let timeZoneIdentifier = await PlaceTimeZoneResolver.identifier(for: result.destination.coordinate) {
            guard !Task.isCancelled else { return }
            var updated = current
            updated.timeZoneIdentifier = timeZoneIdentifier
            details = updated
        }
        if let current = details,
           !isNavigating {
            if PlacePhotoResolver.isEligible(category: current.category)
                || PlacePhotoResolver.isEligible(category: result.category) {
                await loadPlacePhoto(for: current, forceRefresh: retry > 0)
            } else {
                await loadBrandLogo(for: current, forceRefresh: retry > 0)
            }
        }
    }

    private func toggleSavedState() {
        if isSaved {
            showRemoveConfirmation = true
            return
        }
        guard onSave() else {
            saveError = "Nie udało się zapisać miejsca na urządzeniu."
            return
        }
        isSaved = true
        saveError = nil
        showSavedConfirmation = true
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
        !isNavigating && (PlacePhotoResolver.isEligible(category: details?.category)
                          || PlacePhotoResolver.isEligible(category: result.category)
                          || placePhoto?.role == .brandLogo)
    }

    private var detailsRefreshKey: String {
        let placeKey = result.placeIdentity.cacheKey
        let retryAttempt = String(retry)
        return placeKey + "/" + retryAttempt
    }

    @ViewBuilder
    private var placePhotoSection: some View {
        if let placePhoto {
            AsyncImage(url: placePhoto.imageURL) { imagePhase in
                placePhotoPresentation(imagePhase: imagePhase)
            }
        } else {
            placePhotoPresentation(imagePhase: nil)
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
            photoHeight: presentation == .medium ? 96 : 184,
            onRetry: { retry += 1 },
            onOpenLookAround: { showLookAround = true },
            onPlacePhotoLoadFailure: {
                placePhotoLoadFailed = true
                await loadLookAroundFallback()
            })
    }

    private func loadPlacePhoto(for details: PlaceDetails, forceRefresh: Bool) async {
        isLoadingPlacePhoto = true
        defer {
            if !Task.isCancelled { isLoadingPlacePhoto = false }
        }
        let resolvedPhoto = await PlacePhotoResolver.resolve(for: details, identity: result.placeIdentity,
                                                             forceRefresh: forceRefresh)
        guard !Task.isCancelled else { return }
        placePhoto = resolvedPhoto
        if resolvedPhoto == nil {
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

    private func loadBrandLogo(for details: PlaceDetails, forceRefresh: Bool) async {
        isLoadingPlacePhoto = true
        defer {
            if !Task.isCancelled { isLoadingPlacePhoto = false }
        }
        let brandLogo = await PlacePhotoResolver.resolveBrandLogo(for: details, identity: result.placeIdentity,
                                                                   forceRefresh: forceRefresh)
        guard !Task.isCancelled else { return }
        placePhoto = brandLogo
    }

    private func loadLookAroundFallback(forceRefresh: Bool = false) async {
        guard lookAroundPreview == nil, !Task.isCancelled,
              PlacePhotoResolver.isEligible(category: details?.category)
                || PlacePhotoResolver.isEligible(category: result.category) else { return }
        let preview = await PlaceLookAroundProvider.preview(at: result.destination.coordinate)
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

    private var allSupplementalDetails: [String] {
        expandedDetails ?? supplementalDetails
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                            .foregroundStyle(.primary)
                        if showsSourceSubtitle {
                            Text(result.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let primaryMetaLine {
                            Text(primaryMetaLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let summary = result.travelSummary {
                            Text(summary)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ForEach(supplementalDetails, id: \.self) { detail in
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

            if isExpanded {
                PlaceDetailsView(result: result, isSaved: isSaved, onSave: onSave,
                                 isNavigating: isNavigating, primaryActionTitle: primaryActionTitle,
                                 supplementalDetails: allSupplementalDetails,
                                 onRemove: onRemove, onRename: onRename,
                                 onPlanRoute: onSelect)
                    .id(result.placeIdentity.cacheKey)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
