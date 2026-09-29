import SwiftUI

struct DestinationSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let navigationStore: NavigationStore
    @Bindable var searchStore: SearchStore
    let selectingRouteOrigin: Bool
    let places: [SavedPlace]
    let recentDestinations: [Destination]
    let recentSearches: [SearchHistoryEntry]
    let quickEstimates: [String: PlaceRouteEstimate]
    let pointSelectionHint: String
    let onRemoveFavorite: (Destination) -> Bool
    let onRenameFavorite: (Destination, String) -> Bool
    let onRefreshContactPlace: (String, Destination) -> Bool
    let onSavePlaceAs: (Destination, PlaceKind, String?) -> Bool
    let onSaveCurrentLocation: (PlaceKind) async -> Bool
    let onChooseOnMap: (PlaceKind) -> Void
    let onSelectTransitStop: (TransitStop) -> Void
    let onSelectTransitLine: (TransitLineSearchResult) -> Void
    let onSelectDestination: (Destination, Bool) -> Void

    @State private var savingKind: PlaceKind?
    @State private var savedPlaceNotice: String?
    @State private var saveAlertMessage = ""
    @State private var showSaveAlert = false
    @State private var contactsAccessStatus = ContactsAccessStatus.current()
    @State private var isRequestingContactsAccess = false
    @State private var speechInput = SearchSpeechInput()
    @FocusState private var isSearchFocused: Bool

    private var query: String {
        get { searchStore.query }
        nonmutating set { searchStore.query = newValue }
    }

    private var searchScope: DestinationSearchScope {
        get { searchStore.scope }
        nonmutating set { searchStore.scope = newValue }
    }

    private var results: [SearchResult] {
        get { searchStore.results }
        nonmutating set { searchStore.results = newValue }
    }

    private var transitResults: TransitSearchResults {
        get { searchStore.transitResults }
        nonmutating set { searchStore.transitResults = newValue }
    }

    private var isTransitSearching: Bool {
        get { searchStore.isTransitSearching }
        nonmutating set { searchStore.isTransitSearching = newValue }
    }

    private var searchError: SearchError? {
        get { searchStore.searchError }
        nonmutating set { searchStore.searchError = newValue }
    }

    private var didCompleteSearchWithNoResults: Bool {
        get { searchStore.didCompleteSearchWithNoResults }
        nonmutating set { searchStore.didCompleteSearchWithNoResults = newValue }
    }

    private var isSearching: Bool {
        get { searchStore.isSearching }
        nonmutating set { searchStore.isSearching = newValue }
    }

    private var searchArea: Coordinate? {
        get { searchStore.searchArea }
        nonmutating set { searchStore.searchArea = newValue }
    }

    private var alongRoute: Bool {
        get { searchStore.alongRoute }
        nonmutating set { searchStore.alongRoute = newValue }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var localMatches: [LocalSearchSuggestion] {
        let needle = normalized(trimmedQuery)
        guard !needle.isEmpty else { return [] }

        var matches: [LocalSearchSuggestion] = []
        for place in places where normalized(place.displayName).contains(needle) {
            append(place.navigationDestination, subtitle: place.kind.title, symbol: place.icon.symbol, to: &matches)
        }
        for destination in recentDestinations where normalized(destination.name).contains(needle) {
            append(destination, subtitle: selectingRouteOrigin ? "Ostatnie miejsce" : "Ostatni cel",
                   symbol: "clock.arrow.circlepath", to: &matches)
        }
        for item in recentSearches where normalized(item.destination.name).contains(needle) {
            append(item.destination, subtitle: "Ostatnie wyszukiwanie", symbol: "magnifyingglass", to: &matches)
        }
        return Array(matches.prefix(5))
    }

    private var visibleRemoteResults: [SearchResult] {
        // Contact destinations stay grouped separately from place results.
        results.filter { !$0.isContact }
    }

    private var visibleContactResults: [SearchResult] {
        results.filter(\.isContact)
    }

    private var contactResultActionTitle: String {
        if savingKind != nil { return "Zapisz" }
        if selectingRouteOrigin { return "Start" }
        if alongRoute || QueryClassifier().classify(query).alongRoute { return "Dodaj" }
        return "Trasa"
    }

    private var contactResultActionSymbol: String {
        if savingKind != nil { return "plus" }
        if selectingRouteOrigin { return "location" }
        if alongRoute || QueryClassifier().classify(query).alongRoute { return "plus" }
        return "arrow.turn.down.right"
    }

    private var contactResultActionHint: String {
        if let savingKind { return "Zapisz ten adres jako \(savingKind.title.lowercased())." }
        if selectingRouteOrigin { return "Użyj tego adresu jako punktu startowego." }
        if alongRoute || QueryClassifier().classify(query).alongRoute {
            return "Dodaj ten adres jako przystanek do trasy."
        }
        return "Wyznacz trasę do tego adresu kontaktu."
    }

    private var hasResultsForCurrentScope: Bool {
        switch searchScope {
        case .places:
            !results.isEmpty || !localMatches.isEmpty
        case .transit:
            !transitResults.stops.isEmpty || !transitResults.lines.isEmpty
        }
    }

    private var searchScopePicker: some View {
        Picker("Rodzaj wyszukiwania", selection: $searchStore.scope) {
            ForEach(DestinationSearchScope.allCases) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: searchScope) { _, _ in startSearch(query) }
    }

    private var searchAreaControls: some View {
        HStack {
            if let center = navigationStore.state.searchMapCenter {
                Button("Szukaj w tym obszarze") {
                    searchArea = center
                    startSearch(query)
                }
            }
            if searchArea != nil {
                Button("Blisko mnie") { searchArea = nil; startSearch(query) }
            }
            if navigationStore.state.status == .navigating && searchScope == .places {
                Toggle("Po trasie", isOn: $searchStore.alongRoute)
                    .onChange(of: alongRoute) { _, _ in startSearch(query) }
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var searchResultSections: some View {
        if trimmedQuery.isEmpty {
            if searchScope == .places {
                savedDestinations
            } else {
                ContentUnavailableView(
                    "Szukaj pociągu, stacji lub linii",
                    systemImage: "tram.fill",
                    description: Text("Wpisz numer pociągu lub linii albo nazwę stacji i przystanku w Polsce."))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
            }
        } else if searchScope == .places {
            matchingDestinations
            contactsResultsSection
            searchStatus
            remoteResults
        } else {
            transitResultsSection
            searchStatus
        }
    }

    private var searchResultsScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                searchResultSections
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private var searchMainContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            searchField
            if speechInput.isListening {
                Label("Słucham… Powiedz nazwę miejsca lub przystanku.", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            if let message = speechInput.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let savedPlaceNotice {
                Label(savedPlaceNotice, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            if !selectingRouteOrigin && searchScope == .places && trimmedQuery.isEmpty {
                quickPlacesSection
            }
            if !selectingRouteOrigin { searchScopePicker }
            searchAreaControls
            searchResultsScrollView
        }
        .padding(.horizontal, 17)
        .padding(.top, 14)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
    }

    private var searchNavigationTitle: String {
        if selectingRouteOrigin { return "Skąd zaczynasz?" }
        if let savingKind { return "Dodaj \(savingKind.title.lowercased())" }
        return "Szukaj"
    }

    private func prepareSearchPresentation() {
        contactsAccessStatus = ContactsAccessStatus.current()
        searchStore.resetForPresentation(selectingRouteOrigin: selectingRouteOrigin)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isSearchFocused = true
        }
    }

    private func handleLocationChange(previous: Coordinate?, current: Coordinate?) {
        // A query entered before the first GPS fix must be retried with that fix.
        if previous == nil, current != nil, searchArea == nil, !trimmedQuery.isEmpty {
            startSearch(query)
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase == .background {
            if speechInput.isStarting || speechInput.isListening {
                speechInput.stop(keepAudioSessionActive: navigationStore.state.status == .navigating)
            }
            return
        }
        guard phase == .active, !isRequestingContactsAccess else { return }
        let previousStatus = contactsAccessStatus
        contactsAccessStatus = ContactsAccessStatus.current()
        if previousStatus != contactsAccessStatus, !trimmedQuery.isEmpty {
            startSearch(query)
        }
    }

    private func cleanUpSearch() {
        speechInput.stop(keepAudioSessionActive: navigationStore.state.status == .navigating)
        searchStore.cancelSearches()
        let closingSearchID = searchStore.currentRequestID
        Task { @MainActor in
            await Task.yield()
            guard searchStore.isCurrentRequest(closingSearchID) else { return }
            navigationStore.state.searchResults = []
        }
    }

    var body: some View {
        NavigationStack {
            searchMainContent
                .navigationTitle(searchNavigationTitle)
                .alert("Nie udało się dodać miejsca", isPresented: $showSaveAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(saveAlertMessage)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Zamknij") { dismiss() }
                    }
                }
                .onAppear(perform: prepareSearchPresentation)
                .onChange(of: navigationStore.state.location?.coordinate) { previous, current in
                    handleLocationChange(previous: previous, current: current)
                }
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhaseChange(phase)
                }
                .onDisappear(perform: cleanUpSearch)
        }
    }

    private func startSearch(_ value: String, includeUUGFallback: Bool = false) {
        let requestID = searchStore.beginRequest()
        navigationStore.state.searchResults = []
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { isSearching = false; isTransitSearching = false; return }

        if searchScope == .transit {
            isTransitSearching = true
            let task = Task {
                do {
                    try await Task.sleep(for: .milliseconds(450))
                } catch {
                    return
                }
                guard !Task.isCancelled, searchStore.isCurrentRequest(requestID) else { return }
                let center = searchArea ?? navigationStore.state.location?.coordinate
                let matches = await searchStore.searchTransit(trimmed, near: center)
                guard !Task.isCancelled, searchStore.isCurrentRequest(requestID) else { return }
                transitResults = matches
                isTransitSearching = false
                didCompleteSearchWithNoResults = matches.stops.isEmpty && matches.lines.isEmpty
            }
            searchStore.setTransitSearchTask(task)
            return
        }

        isSearching = true
        let task = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, searchStore.isCurrentRequest(requestID) else { return }
                let state = navigationStore.state
                let context = await searchStore.searchContext(
                    navigation: state, places: places, recentSearches: recentSearches)
                let found = try await searchStore.searchPlaces(
                    trimmed, context: context, includeUUGFallback: includeUUGFallback,
                    routingServerAddress: UserDefaults.standard.string(forKey: "routingServer")
                        ?? "https://valhalla1.openstreetmap.de",
                    routeEstimator: { origin, destination, mode in
                        try await navigationStore.estimatedSearchRoute(from: origin, to: destination, mode: mode)
                    }) { partial in
                    guard !Task.isCancelled, searchStore.isCurrentRequest(requestID) else { return }
                    results = partial
                    navigationStore.state.searchResults = results
                }
                guard !Task.isCancelled, searchStore.isCurrentRequest(requestID) else { return }
                results = found
                navigationStore.state.searchResults = results
                isSearching = false
                didCompleteSearchWithNoResults = found.isEmpty
                var didRefreshSavedContact = false
                for result in found {
                    guard let contactReference = contactIdentifier(for: result),
                          places.contains(where: { $0.sourceContactIdentifier == contactReference }) else { continue }
                    if onRefreshContactPlace(contactReference, result.navigationDestination) {
                        didRefreshSavedContact = true
                    }
                }
                if didRefreshSavedContact {
                    savedPlaceNotice = "Zaktualizowano zapisany adres z Kontaktów."
                }
            } catch {
                guard !Task.isCancelled, searchStore.isCurrentRequest(requestID) else { return }
                isSearching = false
                searchError = SearchError.classify(error)
            }
        }
        searchStore.setPlaceSearchTask(task)
    }

    private var searchField: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.accentColor)
            TextField(searchScope == .places
                      ? (savingKind.map { "Adres lub miejsce dla \($0.title.lowercased())" }
                         ?? (selectingRouteOrigin ? "Adres, miejsce lub kontakt" : "Adres, miejsce, marka lub kontakt"))
                      : "Linia lub przystanek", text: $searchStore.query)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onChange(of: query) { _, value in startSearch(value) }
                .onSubmit { startSearch(query, includeUUGFallback: true) }

            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    searchError = nil
                    didCompleteSearchWithNoResults = false
                    isSearching = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Wyczyść wyszukiwanie")
            }

            Button(action: toggleSpeechInput) {
                Group {
                    if speechInput.isStarting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: speechInput.isListening ? "stop.fill" : "mic.fill")
                            .foregroundStyle(speechInput.isListening ? .red : .secondary)
                            .symbolEffect(.pulse, isActive: speechInput.isListening)
                    }
                }
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(speechInput.isListening || speechInput.isStarting
                                ? "Zatrzymaj wyszukiwanie głosowe" : "Wyszukaj głosowo")
            .accessibilityHint("Wypowiedz nazwę miejsca, adresu, linii lub przystanku.")
        }
        .font(.body)
        .padding(.horizontal, 15)
        .frame(height: 52)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }

    private func toggleSpeechInput() {
        isSearchFocused = false
        if speechInput.isListening || speechInput.isStarting {
            speechInput.stop(keepAudioSessionActive: navigationStore.state.status == .navigating)
        } else {
            speechInput.start(keepAudioSessionActive: navigationStore.state.status == .navigating) { transcript in
                query = transcript
            }
        }
    }

    private var quickPlacesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SZYBKIE MIEJSCA")
                    .font(.caption.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                addPlaceMenu
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach([PlaceKind.home, .work], id: \.self) { kind in
                        if let place = places.first(where: { $0.kind == kind }) {
                            quickPlaceCard(place)
                        } else {
                            Button {
                                beginAddressSave(as: kind)
                            } label: {
                                Label("Dodaj \(kind.title.lowercased())", systemImage: "plus")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 13)
                                    .frame(minHeight: 62)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 15))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }

                    ForEach(pinnedFavoritePlaces) { place in
                        quickPlaceCard(place)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

        }
    }

    private var pinnedFavoritePlaces: [SavedPlace] {
        var seen = Set<String>()
        return places.filter { place in
            guard place.kind == .favorite, place.isPinned else { return false }
            let coordinate = place.destination.coordinate
            let key = "\(coordinate.latitude),\(coordinate.longitude)"
            return seen.insert(key).inserted
        }.prefix(6).map { $0 }
    }

    private func quickPlaceCard(_ place: SavedPlace) -> some View {
        Button {
            handleDestination(place.navigationDestination, contactIdentifier: place.sourceContactIdentifier)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: place.icon.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let estimate = quickEstimates[place.id.uuidString] {
                        Text("\(estimate.minutes) min · \(formattedRouteDistance(estimate.distanceMeters))")
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(place.destination.address ?? place.kind.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: place.kind == .favorite ? 145 : 158, minHeight: 62, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.primary.opacity(0.045)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pokaż miejsce \(place.displayName)")
    }

    private var addPlaceMenu: some View {
        Menu {
            Menu("Wyszukaj adres", systemImage: "magnifyingglass") {
                ForEach([PlaceKind.home, .work, .favorite], id: \.self) { kind in
                    Button(kind.title, systemImage: kind.defaultIcon.symbol) { beginAddressSave(as: kind) }
                }
            }
            Menu("Moja lokalizacja", systemImage: "location.fill") {
                ForEach([PlaceKind.home, .work, .favorite], id: \.self) { kind in
                    Button(kind.title, systemImage: kind.defaultIcon.symbol) { saveCurrentLocation(as: kind) }
                }
            }
            Menu("Wybierz na mapie", systemImage: "mappin.and.ellipse") {
                ForEach([PlaceKind.home, .work, .favorite], id: \.self) { kind in
                    Button(kind.title, systemImage: kind.defaultIcon.symbol) {
                        onChooseOnMap(kind)
                        dismiss()
                    }
                }
            }
            Menu("Adres kontaktu", systemImage: "person.crop.circle") {
                ForEach([PlaceKind.home, .work, .favorite], id: \.self) { kind in
                    Button(kind.title, systemImage: kind.defaultIcon.symbol) { beginContactSave(as: kind) }
                }
            }
        } label: {
            Label("Dodaj", systemImage: "plus")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 11)
                .frame(minHeight: 34)
                .background(Color.accentColor.opacity(0.09), in: Capsule())
        }
        .accessibilityLabel("Dodaj zapisane miejsce")
    }

    private func beginAddressSave(as kind: PlaceKind) {
        savingKind = kind
        savedPlaceNotice = nil
        isSearchFocused = true
    }

    private func beginContactSave(as kind: PlaceKind) {
        beginAddressSave(as: kind)
        if contactsAccessStatus == .notDetermined {
            requestContactsAccess()
        } else if !contactsAccessStatus.canReadContacts {
            saveAlertMessage = "Włącz dostęp do Kontaktów w Ustawieniach, aby wyszukać zapisany adres."
            showSaveAlert = true
        }
    }

    private func saveCurrentLocation(as kind: PlaceKind) {
        Task {
            let saved = await onSaveCurrentLocation(kind)
            if saved {
                withAnimation(.easeInOut(duration: 0.18)) {
                    savedPlaceNotice = "Zapisano \(kind.title.lowercased()) z bieżącej lokalizacji."
                }
            } else {
                saveAlertMessage = "Bieżąca lokalizacja jest niedostępna. Spróbuj ponownie, gdy mapa ustali Twoją pozycję."
                showSaveAlert = true
            }
        }
    }

    private func formattedRouteDistance(_ meters: Double) -> String {
        let kilometers = NumberFormatter()
        kilometers.locale = Locale(identifier: "pl_PL")
        kilometers.minimumFractionDigits = 1
        kilometers.maximumFractionDigits = 1
        return "\(kilometers.string(from: NSNumber(value: meters / 1_000)) ?? "—") km"
    }

    @ViewBuilder
    private var contactsResultsSection: some View {
        if !visibleContactResults.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Kontakty")
                ForEach(visibleContactResults, id: \.placeIdentity.cacheKey) { result in
                    Button {
                        selectResult(result)
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 20))
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
                                    .lineLimit(2)
                                if let summary = result.travelSummary {
                                    Text(summary)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Label(contactResultActionTitle, systemImage: contactResultActionSymbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(contactResultActionHint)
                }
            }
        } else if !trimmedQuery.isEmpty && contactsAccessStatus != .authorized {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Kontakty")
                if contactsAccessStatus == .notDetermined {
                    Button(action: requestContactsAccess) {
                        Label("Szukaj w Kontaktach", systemImage: "person.crop.circle.badge.plus")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    Text("NaviAstra użyje zapisanych nazw i adresów, aby znaleźć cel nawigacji.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(contactsAccessStatus == .restricted
                         ? "Dostęp do Kontaktów jest ograniczony przez system."
                         : "Dostęp do Kontaktów jest wyłączony. Możesz go zmienić w Ustawieniach systemowych.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func requestContactsAccess() {
        Task {
            isRequestingContactsAccess = true
            let status = await ContactsSearchProvider().requestAccess()
            isRequestingContactsAccess = false
            contactsAccessStatus = status
            if contactsAccessStatus.canReadContacts {
                startSearch(query)
            }
        }
    }

    @ViewBuilder
    private var savedDestinations: some View {
        if !places.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Zapisane miejsca")
                ForEach(places.prefix(5)) { place in
                    destinationRow(place.navigationDestination,
                                   subtitle: place.destination.address ?? place.kind.title,
                                   symbol: place.icon.symbol)
                }
            }
        }

        if !recentDestinations.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Ostatnie")
                ForEach(recentDestinations) { destination in
                    destinationRow(destination,
                                   subtitle: selectingRouteOrigin ? "Ostatnie miejsce" : "Ostatni cel",
                                   symbol: "clock.arrow.circlepath")
                }
            }
        }

        if !recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Ostatnie wyszukiwania")
                ForEach(recentSearches.prefix(5)) { item in
                    destinationRow(item.destination,
                                   subtitle: item.searchedAt.formatted(date: .abbreviated, time: .shortened),
                                   symbol: "magnifyingglass")
                }
            }
        }

        if places.isEmpty && recentDestinations.isEmpty && recentSearches.isEmpty {
            ContentUnavailableView(selectingRouteOrigin ? "Wyszukaj punkt startowy" : "Wpisz cel podróży",
                                   systemImage: "magnifyingglass",
                                   description: Text(pointSelectionHint))
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
        }
    }

    @ViewBuilder
    private var matchingDestinations: some View {
        if !localMatches.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Zapisane i ostatnie")
                ForEach(localMatches) { suggestion in
                    destinationRow(suggestion.destination, subtitle: suggestion.subtitle, symbol: suggestion.symbol)
                }
            }
        }
    }

    @ViewBuilder
    private var searchStatus: some View {
        if isSearching {
            ProgressView(results.isEmpty ? "Wyszukiwanie miejsc…" : "Uzupełnianie wyników…")
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        } else if let searchError, results.isEmpty,
                  transitResults.stops.isEmpty, transitResults.lines.isEmpty, !isTransitSearching {
            VStack(spacing: 10) {
                Image(systemName: "mappin.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(searchError.localizedDescription)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if searchError.canRetry {
                    Button("Ponów wyszukiwanie") { startSearch(query) }
                        .buttonStyle(.bordered)
                } else {
                    Text("Możesz też zmienić obszar wyszukiwania.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
        } else if didCompleteSearchWithNoResults, !hasResultsForCurrentScope,
                  !isSearching, !isTransitSearching {
            VStack(spacing: 8) {
                Image(systemName: "mappin.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Nie znaleziono wyników dla „\(trimmedQuery)”")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Zmień nazwę miejsca albo wybierz inny obszar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
        }
    }

    @ViewBuilder
    private var remoteResults: some View {
        if !visibleRemoteResults.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Wyniki")
                ForEach(Array(visibleRemoteResults.enumerated()), id: \.element.placeIdentity.cacheKey) { index, result in
                    PlaceSearchResultRow(
                        result: result,
                        index: index + 1,
                        isSaved: places.contains { $0.kind == .favorite && $0.destination.coordinate == result.destination.coordinate },
                        onSave: {
                            onSavePlaceAs(result.navigationDestination, .favorite,
                                          contactIdentifier(for: result))
                        },
                        onRemove: { onRemoveFavorite(result.destination) },
                        onRename: { onRenameFavorite(result.destination, $0) },
                        onSelect: { selectResult(result) },
                        isNavigating: alongRoute || QueryClassifier().classify(query).alongRoute,
                        primaryActionTitle: alongRoute || QueryClassifier().classify(query).alongRoute ? "Dodaj przystanek" : "Wyznacz trasę")
                }
            }
        }
    }

    @ViewBuilder
    private var transitResultsSection: some View {
        if isTransitSearching || !transitResults.stops.isEmpty || !transitResults.lines.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("Transport publiczny")
                if isTransitSearching && transitResults.stops.isEmpty && transitResults.lines.isEmpty {
                    ProgressView("Szukam przystanków i lokalnych linii…").font(.caption).padding(.vertical, 5)
                }
                if !transitResults.lines.isEmpty {
                    Text("Linie").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 3)
                    ForEach(transitResults.lines) { line in
                        Button {
                            isSearchFocused = false
                            onSelectTransitLine(line)
                            dismiss()
                        } label: {
                            HStack(spacing: 11) {
                                Text(line.name).font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.white).frame(minWidth: 36, minHeight: 30)
                                    .background(mapTransitColor(line.colorHex), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.mode == "RAIL" ? "Pociąg" : line.mode == "TRAM" ? "Tramwaj" : "Autobus")
                                        .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    if !line.directions.isEmpty {
                                        Text(line.directions).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !transitResults.stops.isEmpty {
                    Text("Stacje i przystanki").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 3)
                    ForEach(transitResults.stops) { stop in
                        Button {
                            isSearchFocused = false
                            onSelectTransitStop(stop)
                            dismiss()
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: "tram.fill")
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                                    .frame(width: 34, height: 34)
                                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stop.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    if !stop.lines.isEmpty {
                                        Text(stop.lines.prefix(6).joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func selectResult(_ result: SearchResult) {
        searchStore.cancelPlaceSearch()
        isSearchFocused = false
        if let kind = savingKind {
            saveDestination(result.navigationDestination, as: kind,
                            contactIdentifier: contactIdentifier(for: result))
            return
        }
        let asStop = alongRoute || QueryClassifier().classify(query).alongRoute
        onSelectDestination(result.navigationDestination, asStop)
        if selectingRouteOrigin { return }
        if !asStop, QueryClassifier().classify(query).intent == .coordinates,
           navigationStore.state.destination?.id == result.destination.id {
            let destinationID = result.destination.id
            Task {
                guard let address = await GUGiKAddressProvider().reverseGeocode(result.destination.coordinate),
                      let current = navigationStore.state.destination,
                      current.id == destinationID else { return }
                navigationStore.state.destination = Destination(id: current.id, name: current.name,
                                                       coordinate: current.coordinate, address: address)
            }
            return
        }
        guard result.isAddress else { return }
        Task {
            let precise = await GUGiKAddressProvider().preciseDestination(for: result)
            if let precise,
               navigationStore.state.status == .destinationPreview || navigationStore.state.status == .routeCalculating ||
                navigationStore.state.status == .routePreview || navigationStore.state.status == .error,
               navigationStore.state.destination?.id == result.destination.id {
                navigationStore.selectDestination(precise)
                await navigationStore.planRoute()
            }
        }
    }

    private func destinationRow(_ destination: Destination, subtitle: String, symbol: String) -> some View {
        Button {
            isSearchFocused = false
            handleDestination(destination, contactIdentifier: nil)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(destination.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleDestination(_ destination: Destination, contactIdentifier: String?) {
        guard let kind = savingKind else {
            onSelectDestination(destination, false)
            return
        }
        saveDestination(destination, as: kind, contactIdentifier: contactIdentifier)
    }

    private func saveDestination(_ destination: Destination, as kind: PlaceKind,
                                 contactIdentifier: String?) {
        guard onSavePlaceAs(destination, kind, contactIdentifier) else {
            saveAlertMessage = "Miejsce nie zostało zapisane na urządzeniu. Spróbuj ponownie."
            showSaveAlert = true
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            savingKind = nil
            savedPlaceNotice = "Dodano do \(kind.title)."
        }
        query = ""
        results = []
        searchError = nil
        didCompleteSearchWithNoResults = false
        navigationStore.state.searchResults = []
        isSearchFocused = false
    }

    private func contactIdentifier(for result: SearchResult) -> String? {
        guard result.isContact, let providerID = result.providerID,
              providerID.hasPrefix("contact-") else { return nil }
        return providerID
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .padding(.top, 3)
    }

    private func append(_ destination: Destination, subtitle: String, symbol: String,
                        to suggestions: inout [LocalSearchSuggestion]) {
        guard !suggestions.contains(where: { $0.destination.coordinate == destination.coordinate }) else { return }
        suggestions.append(LocalSearchSuggestion(destination: destination, subtitle: subtitle, symbol: symbol))
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }


}

private struct LocalSearchSuggestion: Identifiable {
    let destination: Destination
    let subtitle: String
    let symbol: String
    var id: UUID { destination.id }
}
