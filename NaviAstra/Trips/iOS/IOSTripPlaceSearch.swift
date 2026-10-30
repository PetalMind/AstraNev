#if os(iOS)
import SwiftUI

struct IOSTripPlaceSearch: View {
    @Bindable var draft: IOSPlannedTripDraft
    let places: [SavedPlace]
    let recentPlaces: [Destination]
    let onBack: () -> Void
    let onMap: () -> Void
    let onSelect: (Destination, IOSTripPointRole) -> Void
    @FocusState private var focused: Bool
    @State private var scope: IOSTripPlaceSearchModel.Scope = .places
    @State private var model = IOSTripPlaceSearchModel()
    @State private var submittedRevision = 0
    private var query: String { draft.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var request: IOSTripPlaceSearchModel.Request {
        .init(query: query, scope: scope, revision: submittedRevision)
    }
    private var resultsAreCurrent: Bool { model.resultsRequest == request }
    private var recentSuggestions: [Destination] {
        var suggestions: [Destination] = []
        for place in recentPlaces {
            guard !places.contains(where: { IOSTripPlaceSearchModel.samePlace($0.navigationDestination, place) }),
                  !suggestions.contains(where: { IOSTripPlaceSearchModel.samePlace($0, place) }) else { continue }
            suggestions.append(place)
            if suggestions.count == 10 { break }
        }
        return suggestions
    }

    var body: some View {
        let localMatches = scope == .places
            ? IOSTripPlaceSearchModel.localMatches(query: query, destinations: places.map(\.navigationDestination) + recentPlaces)
            : []
        let remoteResults = model.results.filter { result in
            !localMatches.contains(where: { IOSTripPlaceSearchModel.samePlace($0, result.destination) })
        }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button { focused = false; model.cancel(); onBack() } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.accessibilityLabel("Wróć do szkicu")
                    Text(draft.selectedRole.title).font(.title2.weight(.semibold))
                    Spacer()
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(scope == .places ? "Wpisz adres lub nazwę miejsca" : "Wpisz nazwę przystanku", text: $draft.searchQuery)
                        .focused($focused).submitLabel(.search).autocorrectionDisabled()
                        .accessibilityLabel(scope == .places ? "Adres lub nazwa miejsca" : "Nazwa przystanku")
                        .onSubmit { submitSearch() }
                    if !draft.searchQuery.isEmpty {
                        Button { draft.searchQuery = ""; focused = true } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                            .accessibilityLabel("Wyczyść adres")
                    }
                }.padding(.horizontal, 14).frame(minHeight: 52).iosCardSurface(radius: 16)
                Button { focused = false; model.cancel(); onMap() } label: {
                    Label("Wybierz na mapie", systemImage: "mappin.and.ellipse").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                }.buttonStyle(.bordered)
                if draft.mode == .transit {
                    Picker("Wyszukaj", selection: $scope) {
                        ForEach(IOSTripPlaceSearchModel.Scope.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let message = draft.message { Text(message).foregroundStyle(.red).font(.subheadline) }
                    if query.isEmpty {
                        if let current = draft.currentOrigin {
                            sectionTitle("Bieżące miejsce")
                            locationRow(current, symbol: "location.fill", subtitle: "Zapisz ten punkt jako miejsce podróży")
                        }
                        if !places.isEmpty {
                            sectionTitle("Zapisane miejsca")
                            ForEach(places) { place in locationRow(place.navigationDestination, symbol: place.icon.symbol, subtitle: place.destination.address ?? place.kind.title) }
                        }
                        if !recentSuggestions.isEmpty {
                            sectionTitle("Ostatnie miejsca")
                            ForEach(recentSuggestions) { place in
                                locationRow(place, symbol: "clock.arrow.circlepath", subtitle: place.address)
                            }
                        }
                        if places.isEmpty && recentPlaces.isEmpty && draft.currentOrigin == nil {
                            Text("Wpisz miejscowość i adres albo wybierz punkt na mapie. Lokalizacja GPS nie jest potrzebna do zapisania wybranego miejsca.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else if scope == .places {
                        if !localMatches.isEmpty {
                            sectionTitle("Zapisane i ostatnie miejsca")
                            ForEach(localMatches) { place in locationRow(place, symbol: "star", subtitle: place.address) }
                        }
                        if query.count >= 2 { resultsHeading }
                        ForEach(remoteResults, id: \.id) { result in
                            locationRow(result.navigationDestination, symbol: result.isPOI ? "mappin" : "building.2",
                                subtitle: result.destination.address ?? [result.street, result.houseNumber, result.city].compactMap { $0 }.joined(separator: " "))
                                .disabled(!resultsAreCurrent)
                                .opacity(resultsAreCurrent ? 1 : 0.55)
                        }
                    } else {
                        if query.count >= 2 { resultsHeading }
                        ForEach(model.stops) { stop in
                            locationRow(Destination(name: stop.name, coordinate: stop.coordinate, address: stop.address),
                                symbol: "tram.fill", subtitle: stop.address)
                                .disabled(!resultsAreCurrent)
                                .opacity(resultsAreCurrent ? 1 : 0.55)
                        }
                    }
                    if let errorMessage = model.errorMessage {
                        Text(errorMessage).font(.subheadline).foregroundStyle(.red)
                        Button("Spróbuj ponownie", systemImage: "arrow.clockwise", action: submitSearch)
                            .buttonStyle(.bordered).controlSize(.large)
                    } else if model.completed && !model.loading && model.results.isEmpty && model.stops.isEmpty && localMatches.isEmpty {
                        ContentUnavailableView {
                            Label("Nie znaleziono miejsca", systemImage: "mappin.slash")
                        } description: {
                            Text("Dopisz miejscowość lub numer budynku albo wybierz punkt na mapie.")
                        }
                    } else if !query.isEmpty && query.count < 2 && localMatches.isEmpty {
                        Text("Wpisz co najmniej dwa znaki.").font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(16)
            }.scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: IOSLayout.readableWidth).frame(maxWidth: .infinity)
        .environment(\.locale, PolishRegionalFormat.locale)
        .onAppear { focused = true }
        .onDisappear { model.cancel() }
        .task(id: request) {
            let context = SearchContext(origin: draft.origin?.coordinate ?? draft.currentOrigin?.coordinate,
                area: draft.mapState.searchMapCenter, route: draft.mapState.route?.coordinates ?? [],
                mode: draft.mode, preferences: draft.preferences,
                localDestinations: places.map(\.navigationDestination) + recentPlaces)
            await model.search(request, context: context,
                transitSearchCenter: draft.origin?.coordinate ?? draft.mapState.searchMapCenter,
                transitProvider: draft.session.transitDataProvider)
        }
    }

    private func submitSearch() {
        focused = false
        submittedRevision += 1
    }

    private var resultsHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                sectionTitle(scope == .places ? "Wyniki wyszukiwania" : "Stacje i przystanki")
                Spacer(minLength: 0)
                ProgressView()
                    .controlSize(.small)
                    .opacity(model.loading ? 1 : 0)
                    .accessibilityHidden(true)
            }
            Text(resultsStatus)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var resultsStatus: String {
        if model.loading {
            if model.results.isEmpty && model.stops.isEmpty { return "Szukam miejsc…" }
            return resultsAreCurrent ? "Uzupełniam wyniki…" : "Aktualizuję wyniki…"
        }
        return "Wybierz miejsce, aby dodać je do planu."
    }

    private func sectionTitle(_ title: String) -> some View { Text(title).font(.headline).accessibilityAddTraits(.isHeader) }
    private func locationRow(_ place: Destination, symbol: String, subtitle: String?) -> some View {
        Button { focused = false; model.cancel(); onSelect(place, draft.selectedRole) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
            }.padding(12).frame(minHeight: 60).contentShape(Rectangle())
        }.buttonStyle(.plain).iosCardSurface(radius: 16)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Użyj tego miejsca w planie podróży")
    }

}
#endif
