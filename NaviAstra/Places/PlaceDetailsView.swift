import SwiftUI
import MapKit
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

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
    @State private var fuelPriceLookup: FuelPriceLookupResult?
    @State private var fuelPriceError: String?
    @State private var isLoadingFuelPrices = false
    @State private var placePhoto: PlacePhoto?
    @State private var placePhotoLoadFailed = false
    @State private var lookAroundPreview: PlaceLookAroundPreview?
    @State private var isLoadingPlacePhoto = false
    @State private var showLookAround = false
    private let provider = OpenStreetMapPlaceDetailsProvider()
    private let fuelPriceProvider: any FuelPriceProvider = FuelWideFuelPriceProvider.shared

    init(result: SearchResult, isSaved: Bool, onSave: @escaping () -> Bool,
         isNavigating: Bool = false, primaryActionTitle: String = "Wyznacz trasę",
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
        self.supplementalDetails = supplementalDetails
        _details = State(initialValue: PlaceDetails.partial(for: result))
        _isSaved = State(initialValue: isSaved)
        _savedName = State(initialValue: result.destination.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if showsPlacePhoto {
                placePhotoSection
            }

            HStack(alignment: .top, spacing: 10) {
                if result.isPOI && !showsPlacePhoto {
                    Image(systemName: photoSymbol(for: details?.category ?? result.category ?? ""))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
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
            }

            HStack(spacing: 9) {
                Button(action: onPlanRoute) {
                    Label(primaryActionTitle,
                          systemImage: isNavigating ? "plus" : "arrow.triangle.turn.up.right.diamond")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.borderedProminent)

                if let onRouteFromPlace, !isNavigating {
                    Menu {
                        Button("Trasa z tego miejsca", systemImage: "arrowshape.turn.up.left") {
                            onRouteFromPlace()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 40, height: 42)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Więcej opcji trasy")
                }

                Button(action: toggleSavedState) {
                    Image(systemName: isSaved ? "heart.fill" : "heart")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isSaved ? Color.red : Color.secondary)
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                        .scaleEffect(favoritePulseScale)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(isSaved ? "Usuń z Ulubionych" : "Dodaj do Ulubionych")
                .accessibilityHint(isSaved ? "Wymaga potwierdzenia" : "Zapisz to miejsce na później")
                .disabled(isSaved && onRemove == nil)
            }

            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }

            Divider()
            ForEach(supplementalDetails, id: \.self) { detail in
                Label(detail, systemImage: "info.circle")
                    .font(.subheadline)
            }
            if let details { detailsContent(details) }
            if isFuelStation { fuelPricesSection }

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
                Text("OpenStreetMap · pobrano \(loadedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let details {
                Text(details.source.title).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
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
        .sheet(isPresented: $showLookAround) {
            if let scene = lookAroundPreview?.scene {
                LookAroundPreview(initialScene: scene)
                    .frame(minWidth: 320, minHeight: 300)
            }
        }
#endif
        .task(id: "\(result.placeIdentity.cacheKey)/\(retry)") {
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
                loadError = "Nie udało się uzupełnić informacji. Dostępne dane pozostają widoczne."
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
        .task(id: fuelPriceTaskID) {
            isLoadingFuelPrices = false
            fuelPriceLookup = nil
            fuelPriceError = nil
            guard isFuelStation else { return }

            isLoadingFuelPrices = true
            defer {
                if !Task.isCancelled { isLoadingFuelPrices = false }
            }
            do {
                let lookup = try await fuelPriceProvider.prices(for: FuelStationLookup(identity: result.placeIdentity))
                guard !Task.isCancelled else { return }
                fuelPriceLookup = lookup
            } catch {
                guard !Task.isCancelled else { return }
                fuelPriceError = "Nie udało się pobrać cen paliw."
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

    @ViewBuilder
    private var placePhotoSection: some View {
        if let placePhoto, placePhoto.role == .brandLogo {
            brandLogoSection(placePhoto)
        } else {
            placePhotoHero
        }
    }

    private var placePhotoHero: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let lookAroundPreview, placePhoto == nil || placePhotoLoadFailed {
                        platformImage(lookAroundPreview.image)
                            .resizable()
                            .scaledToFill()
                    } else if let placePhoto {
                        AsyncImage(url: placePhoto.imageURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .empty:
                                photoLoadingPlaceholder
                            case .failure:
                                if placePhotoLoadFailed {
                                    photoPlaceholder
                                } else {
                                    photoLoadingPlaceholder.task(id: placePhoto.imageURL) {
                                        guard !Task.isCancelled else { return }
                                        placePhotoLoadFailed = true
                                        await loadLookAroundFallback()
                                    }
                                }
                            @unknown default:
                                photoPlaceholder
                            }
                        }
                    } else if let lookAroundPreview {
                        platformImage(lookAroundPreview.image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        photoPlaceholder
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 184)
                .clipped()

#if os(iOS)
                if lookAroundPreview != nil {
                    Button {
                        showLookAround = true
                    } label: {
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
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if lookAroundPreview != nil && (placePhoto == nil || placePhotoLoadFailed) {
                Label("Widok z Apple Look Around", systemImage: "viewfinder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let placePhoto, !placePhotoLoadFailed {
                photoCredit(placePhoto,
                            sourceTitle: placePhoto.source == .wikimediaCommons
                                ? "Wikimedia Commons"
                                : "Oryginalne zdjęcie")
            } else if lookAroundPreview != nil {
                Label("Widok z Apple Look Around", systemImage: "viewfinder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func brandLogoSection(_ photo: PlacePhoto) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: photo.imageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .empty:
                    ProgressView().controlSize(.small)
                case .failure:
                    Button { retry += 1 } label: {
                        Image(systemName: "tag.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ponów pobieranie logo")
                @unknown default:
                    Image(systemName: "tag.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 62, height: 62)
            .padding(8)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(details?.brand ?? result.brand ?? result.destination.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                photoCredit(photo, sourceTitle: "Logo · Wikimedia Commons")
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
    }

    private var photoPlaceholder: some View {
        let category = details?.category ?? result.category ?? ""
        let title = details?.brand ?? result.brand ?? result.destination.name
        return VStack(spacing: 8) {
            if isLoadingPlacePhoto {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: photoSymbol(for: category))
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Text(isLoadingPlacePhoto ? "Wyszukiwanie zdjęcia miejsca…" : "Zdjęcie niedostępne")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !isLoading && !isLoadingPlacePhoto {
                Button("Spróbuj ponownie", systemImage: "arrow.clockwise") { retry += 1 }
                    .font(.caption.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.045))
    }

    @ViewBuilder
    private func photoCredit(_ photo: PlacePhoto, sourceTitle: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Link(sourceTitle, destination: photo.sourcePageURL)
            Text("· \(photo.attribution)")
                .foregroundStyle(.secondary)
            if let licenseURL = photo.licenseURL {
                Link(photo.licenseName ?? "Licencja", destination: licenseURL)
            } else if let licenseName = photo.licenseName {
                Text("· \(licenseName)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .lineLimit(2)
    }

    private var photoLoadingPlaceholder: some View {
        ProgressView("Ładowanie zdjęcia…")
            .font(.caption)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.045))
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

    private var fuelPriceTaskID: String {
        "\(result.placeIdentity.cacheKey)/\(details?.category ?? result.category ?? "")/\(retry)"
    }

    private var isFuelStation: Bool {
        (details?.category ?? result.category)?.lowercased().split(separator: "=").last == "fuel"
    }

    private var fuelPricesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Średnie ceny paliw w Polsce", systemImage: "fuelpump.fill")
                .font(.subheadline.weight(.semibold))

            if isLoadingFuelPrices {
                ProgressView("Pobieranie cen…")
                    .font(.caption)
            } else if let fuelPriceError {
                Text(fuelPriceError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Spróbuj ponownie", systemImage: "arrow.clockwise") { retry += 1 }
                    .font(.caption.weight(.semibold))
            } else if let fuelPriceLookup {
                fuelPriceLookupContent(fuelPriceLookup)
            }

        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func fuelPriceLookupContent(_ lookup: FuelPriceLookupResult) -> some View {
        switch lookup {
        case .outsideCoverage:
            Text("Dane o cenach są dostępne dla Polski.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .prices(let report):
            FuelPriceReportContent(report: report)
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

        if let rawHours = details.openingHours, !rawHours.isEmpty, details.osmParking?.openingHours == nil {
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
        if let parking = details.parking, details.osmParking == nil {
            Label("Parking: \(parking)", systemImage: "parkingsign.circle").font(.subheadline)
        }
        if let parking = details.osmParking {
            parkingInformation(parking, details: details)
        }
        if let driveThrough = details.driveThrough {
            Label(driveThrough.lowercased() == "yes" ? "Drive-through" : "Drive-through: \(driveThrough)", systemImage: "car.side")
                .font(.subheadline)
        }
    }

    private func parkingInformation(_ parking: ParkingInformation, details: PlaceDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Warunki parkowania", systemImage: "parkingsign.circle.fill")
                .font(.subheadline.weight(.semibold))

            parkingRow("Opłaty", parking.tariff.status.title)
            if let freeMinutes = parking.tariff.freeMinutes {
                parkingRow("Bezpłatnie", "pierwsze \(durationText(minutes: freeMinutes))")
            }
            if let hourlyRate = parking.tariff.hourlyRate {
                parkingRow("Stawka godzinowa", parkingPriceText(hourlyRate))
            } else if let charge = parking.tariff.chargeDescription {
                parkingRow("Taryfa", charge)
            }
            if let firstHourRate = parking.tariff.firstHourRate {
                parkingRow("Pierwsza godzina", parkingPriceText(firstHourRate))
            }
            if let subsequentHourRate = parking.tariff.subsequentHourRate {
                parkingRow("Kolejna godzina", parkingPriceText(subsequentHourRate))
            }
            if let dailyRate = parking.tariff.dailyRate {
                parkingRow("Stawka dzienna", parkingPriceText(dailyRate))
            }
            if let feeCondition = parking.tariff.feeCondition {
                parkingRow("Warunkowa opłata", feeCondition)
            }
            if let conditionalCharge = parking.tariff.conditionalCharge {
                parkingRow("Warunkowa taryfa", conditionalCharge)
            }
            if let capacity = parking.capacity {
                parkingRow("Pojemność", "\(capacity) miejsc")
            }
            if let availableSpaces = parking.availableSpaces {
                parkingRow("Wolne miejsca", parking.capacity.map { "\(availableSpaces) / \($0)" } ?? "\(availableSpaces)")
            } else {
                parkingRow("Wolne miejsca", "brak danych na żywo")
            }
            if let maxStay = parking.maxStay {
                parkingRow("Maksymalny postój", parking.maxStayMinutes.map { durationText(minutes: $0) } ?? maxStay)
            }
            if let maxStay = parking.maxStayConditional {
                parkingRow("Warunkowy limit postoju", maxStay)
            }
            if let access = parking.access {
                parkingRow("Dostęp", parkingAccessTitle(access))
            }
            if let access = parking.accessConditional {
                parkingRow("Warunkowy dostęp", access)
            }
            if let parkingType = parking.parkingType {
                parkingRow("Rodzaj", parkingType.replacingOccurrences(of: "_", with: " "))
            }
            if let openingHours = parking.openingHours, !openingHours.isEmpty {
                openingHoursDisclosure(openingHours, details: details)
            }

            ForEach(parking.streetSides, id: \.side) { side in
                VStack(alignment: .leading, spacing: 4) {
                    Text(side.side.title + (side.parkingType.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? ""))
                        .font(.caption.weight(.semibold))
                    if let condition = side.parkingCondition { parkingRow("Zasada", condition) }
                    if let condition = side.parkingConditionConditional { parkingRow("Zasada warunkowa", condition) }
                    if let fee = side.fee { parkingRow("Opłaty", fee) }
                    if let charge = side.charge { parkingRow("Taryfa", charge) }
                    if let charge = side.chargeConditional { parkingRow("Warunkowa taryfa", charge) }
                    if let condition = side.feeCondition { parkingRow("Warunkowa opłata", condition) }
                    if let maxStay = side.maxStay { parkingRow("Maksymalny postój", maxStay) }
                    if let maxStay = side.maxStayConditional { parkingRow("Limit warunkowy", maxStay) }
                    if let access = side.access { parkingRow("Dostęp", parkingAccessTitle(access)) }
                    if let hours = side.openingHours { parkingRow("Godziny", hours) }
                    if let restriction = side.restriction { parkingRow("Ograniczenie", restriction) }
                    if let restriction = side.restrictionConditional { parkingRow("Ograniczenie warunkowe", restriction) }
                }
                .padding(.top, 3)
            }

            if parking.tariff.status == .unknown {
                Text("Brak informacji o opłacie w OSM nie oznacza, że parking jest bezpłatny.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(parking.dataSources.isEmpty
                 ? "Źródło taryfy: brak danych"
                 : "Źródło: " + parking.dataSources.map(\.title).joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func parkingRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func parkingPriceText(_ price: ParkingPrice) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let amount = formatter.string(from: NSDecimalNumber(decimal: price.amount)) ?? price.amount.description
        let currency = switch price.currencyCode?.uppercased() {
        case "PLN": "zł"
        case "EUR": "€"
        case "USD": "$"
        case "GBP": "£"
        case "CZK": "Kč"
        case let code?: code
        case nil: ""
        }
        let unit = price.unit == "day" ? "/ dzień" : price.unit == "hour" ? "/ godz." : ""
        return [amount, currency].filter { !$0.isEmpty }.joined(separator: " ") + unit
    }

    private func durationText(minutes: Int) -> String {
        if minutes % 1_440 == 0 {
            let days = minutes / 1_440
            return days == 1 ? "1 dzień" : "\(days) dni"
        }
        if minutes % 60 == 0 { return "\(minutes / 60) godz." }
        return "\(minutes) min"
    }

    private func parkingAccessTitle(_ value: String) -> String {
        switch value.lowercased() {
        case "yes", "public", "permissive": "publiczny"
        case "customers": "dla klientów"
        case "private": "prywatny"
        case "no": "brak dostępu publicznego"
        case "permit": "na zezwolenie"
        case "residents": "dla mieszkańców"
        default: value
        }
    }

    private func openingHoursDisclosure(_ rawHours: String, details: PlaceDetails) -> some View {
        DisclosureGroup("Godziny parkowania", isExpanded: $showHours) {
            if let rows = PlaceOpeningHours(rawValue: rawHours,
                                            coordinate: details.coordinate,
                                            countryCode: details.countryCode,
                                            timeZoneIdentifier: details.timeZoneIdentifier).weeklyRows {
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
                Text(rawHours).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Godziny mogą się różnić w święta.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.caption)
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
            imageURL != nil || wikimediaCommons != nil || wikidataID != nil || brandWikidataID != nil ||
            wheelchair != nil || parking != nil || osmParking != nil || driveThrough != nil
    }
}

private struct FuelPriceReportContent: View {
    let report: FuelPriceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                ForEach(report.prices) { price in
                    HStack(spacing: 5) {
                        Text(price.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 3)
                        Text("\(price.isEstimated ? "≈ " : "")\(price.amount.formatted(.number.precision(.fractionLength(2)))) zł/l")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }

            Text(report.notes)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("Aktualizacja: \(report.reportedAt)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if report.isStale {
                Label("Dostawca oznacza te dane jako nieaktualne.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Link(report.source,
                 destination: URL(string: "https://energy.ec.europa.eu/data-and-analysis/weekly-oil-bulletin_en")!)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Link("API FuelWide", destination: URL(string: "https://fuelwide.com/fuel-prices/poland")!)
                Link("Kurs EUR/PLN: NBP", destination: URL(string: "https://api.nbp.pl/api/exchangerates/rates/a/eur/?format=json")!)
            }
            .font(.caption2)
        }
    }
}

struct FuelPriceSummaryCard: View {
    @State private var report: FuelPriceReport?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Ceny paliw · średnia krajowa", systemImage: "fuelpump.fill")
                .font(.subheadline.weight(.semibold))

            if isLoading {
                ProgressView("Pobieranie aktualnych cen…")
                    .font(.caption)
            } else if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Spróbuj ponownie", systemImage: "arrow.clockwise") { retry += 1 }
                    .font(.caption.weight(.semibold))
            } else if let report {
                FuelPriceReportContent(report: report)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .task(id: retry) {
            isLoading = true
            loadError = nil
            defer {
                if !Task.isCancelled { isLoading = false }
            }
            do {
                report = try await FuelWideFuelPriceProvider.shared.pricesForPoland()
            } catch {
                guard !Task.isCancelled else { return }
                loadError = "Nie udało się pobrać cen paliw."
            }
        }
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
