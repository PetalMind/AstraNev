#if os(iOS)
import SwiftUI

struct IOSPlannedTripWorkspace: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: IOSPlannedTripDraft
    let service: TripPlanningService
    let places: [SavedPlace]
    let recentPlaces: [Destination]
    let mapSettings: MapSettings
    let onRecordPlace: (Destination) -> Void
    let onSaved: (PlannedTrip) -> Void
    private enum Pane: String { case editor, search, map, calendar }
    @State private var pane: Pane = .editor
    @State private var detent: NavigationBottomSheetDetent = .medium
    @State private var dragging = false
    @State private var panelHeight: CGFloat = 440
    @State private var previewRevision = 0
    @State private var mapStops: [TransitStop] = []
    @State private var mapStopsTask: Task<Void, Never>?
    @State private var viewportGeneration = 0
    @State private var expandedOptions = false
    @State private var showsDiscardConfirmation = false

    init(seed: PlannedTrip?, preparedDraft: IOSPlannedTripDraft? = nil, service: TripPlanningService, places: [SavedPlace], recentPlaces: [Destination],
         currentOrigin: Destination?, initialCenter: Coordinate?, preferences: RoutingPreferences,
         mapSettings: MapSettings, onRecordPlace: @escaping (Destination) -> Void,
         onSaved: @escaping (PlannedTrip) -> Void) {
        self.service = service; self.places = places; self.recentPlaces = recentPlaces
        self.mapSettings = mapSettings; self.onRecordPlace = onRecordPlace; self.onSaved = onSaved
        _draft = State(initialValue: preparedDraft ?? IOSPlannedTripDraft(seed: seed, currentOrigin: currentOrigin,
            initialCenter: initialCenter, preferences: preferences))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                MapLibreView(scene: scene(in: geometry)).ignoresSafeArea()
                if pane == .editor {
                    editorPanel(maximumHeight: max(250, geometry.size.height - 74))
                        .frame(maxWidth: 560)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                    header.frame(maxWidth: 560).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if pane == .map {
                    mapSelection(in: geometry)
                } else if pane == .search {
                    IOSTripPlaceSearch(draft: draft, places: places, recentPlaces: recentPlaces,
                        onBack: { pane = .editor }, onMap: beginMapSelection, onSelect: choose)
                        .background(Color(.systemGroupedBackground)).frame(maxHeight: .infinity)
                } else {
                    IOSTripCalendarSelection(onBack: { pane = .editor }) { event in
                        draft.title = event.title; draft.targetDate = event.date
                        if draft.mode != .parkRide { draft.timing = .arrival }
                        if let coordinate = event.coordinate {
                            choose(Destination(name: event.title, coordinate: coordinate, address: event.location), role: .destination)
                        } else {
                            draft.selectedRole = .destination; draft.searchQuery = event.location; pane = .search
                        }
                    }
                    .background(Color(.systemGroupedBackground)).frame(maxHeight: .infinity)
                }
            }
        }
        .environment(\.locale, PolishRegionalFormat.locale)
        .task(id: draft.previewKey + pane.rawValue + String(previewRevision)) {
            guard pane == .editor, !draft.saving, draft.savedTrip == nil else { return }
            if !draft.hasPreview { await draft.calculatePreview() }
        }
        .onChange(of: draft.mapState.searchMapCenter) { _, center in
            if pane == .map, let center { draft.updateMapCandidate(center) }
        }
        .onDisappear { draft.cancel(); mapStopsTask?.cancel() }
        .confirmationDialog("Odrzucić niezapisany szkic podróży?", isPresented: $showsDiscardConfirmation) {
            Button("Odrzuć szkic", role: .destructive) { dismiss() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { if draft.savedTrip != nil || !draft.hasChanges { dismiss() } else { showsDiscardConfirmation = true } } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                    .modifier(NavigationGlassSurface(radius: 22, interactive: true))
            }.accessibilityLabel("Zamknij planowanie").disabled(draft.saving)
            Text("Zaplanuj podróż").font(.headline)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .modifier(NavigationGlassSurface(radius: 22))
            Spacer(minLength: 0)
            if draft.mapState.route != nil {
                Button { draft.session.mapCameraController.showRouteOverview(); detent = .peek } label: {
                    Image(systemName: "map").frame(width: 44, height: 44)
                        .modifier(NavigationGlassSurface(radius: 22, interactive: true))
                }.accessibilityLabel("Pokaż całą trasę")
            }
        }.padding(.horizontal, 16).padding(.top, 8)
    }

    private func editorPanel(maximumHeight: CGFloat) -> some View {
        NavigationBottomSheet(detent: $detent, maximumHeight: maximumHeight, accessibilityLabel: "Planowanie podróży",
            appearance: .discovery, isDragging: $dragging, mediumHeightFraction: 0.65,
            minimumPeekHeight: 150, minimumMediumHeight: 400, dragHandleHeight: 44, resizesFromContent: false) { level, _ in
                VStack(alignment: .leading, spacing: 16) {
                    if let saved = draft.savedTrip {
                        savedSummary(saved)
                    } else if level == .peek {
                        Text(draft.destination?.name ?? "Wybierz cel podróży").font(.title3.weight(.semibold))
                        resultSummary
                    } else {
                        transportPicker
                        pointsCard
                        timingCard
                        previewCard
                        DisclosureGroup("Przypomnienia i pozostałe ustawienia", isExpanded: $expandedOptions) {
                            additionalOptions.padding(.top, 12)
                        }.font(.subheadline.weight(.semibold))
                        if let message = draft.message { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
                .disabled(draft.saving)
            } footer: { _, _ in
                saveFooter
            }
    }

    private var transportPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(TransportMode.allCases) { mode in
                    Button { draft.mode = mode; draft.preferredRoute = [] } label: {
                        Label(mode.title, systemImage: mode.symbol).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .background(draft.mode == mode ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04), in: Capsule())
                    }.buttonStyle(.plain).foregroundStyle(draft.mode == mode ? Color.accentColor : Color.primary)
                        .accessibilityAddTraits(draft.mode == mode ? .isSelected : [])
                }
            }
        }.scrollIndicators(.hidden)
    }

    private var pointsCard: some View {
        VStack(spacing: 0) {
            pointRow(role: .origin, destination: draft.origin, symbol: "a.circle.fill", label: "Start")
            ForEach(Array(draft.waypoints.enumerated()), id: \.element.id) { index, stop in
                HStack(spacing: 0) {
                    pointRow(role: .replaceWaypoint(stop.id), destination: stop, symbol: "\(index + 1).circle.fill", label: "Punkt pośredni")
                    Menu {
                        Button("Przesuń wyżej", systemImage: "arrow.up") { moveStop(index, offset: -1) }.disabled(index == 0)
                        Button("Przesuń niżej", systemImage: "arrow.down") { moveStop(index, offset: 1) }.disabled(index == draft.waypoints.count - 1)
                        Button("Zmień miejsce", systemImage: "pencil") { search(.replaceWaypoint(stop.id)) }
                        Button("Usuń punkt", systemImage: "trash", role: .destructive) { draft.waypoints.remove(at: index); draft.preferredRoute = [] }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("Opcje punktu \(index + 1): \(stop.name)")
                }
            }
            pointRow(role: .destination, destination: draft.destination, symbol: "flag.fill", label: "Cel")
            Divider().padding(.horizontal, 12)
            HStack {
                Button("Dodaj punkt", systemImage: "plus") { search(.waypoint) }
                    .disabled(!draft.allowsWaypoints || draft.waypoints.count >= 8)
                Spacer()
                Button { let origin = draft.origin; draft.origin = draft.destination; draft.destination = origin; draft.preferredRoute = [] } label: {
                    Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44)
                }.accessibilityLabel("Zamień start z celem")
            }.font(.subheadline.weight(.semibold)).padding(.horizontal, 12)
            if !draft.allowsWaypoints, !draft.waypoints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Wybrany transport nie obsługuje punktów pośrednich. Zachowaliśmy je w szkicu.").font(.footnote)
                    Button("Usuń punkty pośrednie", role: .destructive) { draft.waypoints = []; draft.stopMinutes = 0 }
                }.padding(12)
            }
        }.modifier(NavigationGlassSurface(radius: 20, interactive: true))
    }

    private func pointRow(role: IOSTripPointRole, destination: Destination?, symbol: String, label: String) -> some View {
        Button { search(role) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Text(destination?.name ?? "Wpisz adres lub wybierz na mapie").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if let address = destination?.address { Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(12).frame(minHeight: 62).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var timingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Termin podróży", selection: $draft.timing) {
                Text("Wyjazd").tag(PlannedTrip.Timing.departure)
                Text("Przyjazd do").tag(PlannedTrip.Timing.arrival)
            }.pickerStyle(.segmented)
            DatePicker("Data i godzina", selection: $draft.targetDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, draft.timeZone)
                .onChange(of: draft.targetDate) { _, value in
                    if value != draft.normalizedTargetDate { draft.targetDate = draft.normalizedTargetDate }
                }
            if draft.timing == .arrival {
                Stepper("Bufor przed przyjazdem: \(draft.bufferMinutes) min", value: $draft.bufferMinutes, in: 0...180, step: 5)
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder private var resultSummary: some View {
        if draft.calculating {
            ProgressView("Obliczam trasę…").font(.subheadline)
        } else if let estimate = draft.estimate {
            if let next = draft.plan?.occurrences(after: Date()).first, next != draft.normalizedTargetDate {
                Text("Najbliższa podróż: \(PolishRegionalFormat.dateTime(next, dateStyle: .complete, timeStyle: .omitted, timeZone: draft.timeZone))").font(.footnote).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Wyjazd około").font(.caption).foregroundStyle(.secondary)
                    Text(PolishRegionalFormat.time(estimate.departure, timeZone: draft.timeZone)).font(.title2.weight(.bold))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Przyjazd około").font(.caption).foregroundStyle(.secondary)
                    Text(PolishRegionalFormat.time(estimate.arrival, timeZone: draft.timeZone)).font(.title2.weight(.semibold))
                }
            }
            if estimate.departure < Date() { Text("Zalecana godzina wyjazdu już minęła. Zmień termin lub bufor.").font(.footnote).foregroundStyle(.orange) }
        } else if let validation = draft.validationMessage { Text(validation).font(.subheadline).foregroundStyle(.secondary) }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            resultSummary
            if draft.hasPreview {
                Text(draft.mapState.routeOptions.count > 1 ? "Wybierz przebieg trasy" : "Wyznaczona trasa").font(.subheadline.weight(.semibold))
                ForEach(Array(draft.mapState.routeOptions.enumerated()), id: \.element.id) { index, route in
                    Button { draft.select(route) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: draft.mapState.route?.id == route.id ? "checkmark.circle.fill" : "circle")
                            Text("Wariant \(index + 1)").font(.subheadline.weight(.semibold))
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(TravelDurationFormatter.string(minutes: Int(ceil(route.expectedTravelTime / 60))))
                                Text(String(format: "%.1f km", locale: PolishRegionalFormat.locale, route.distance / 1_000)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(12).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(draft.mapState.route?.id == route.id ? Color.accentColor : Color.primary)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                }
                if let date = draft.previewCalculatedAt { Text("Obliczono \(PolishRegionalFormat.dateTime(date, timeZone: draft.timeZone))").font(.footnote).foregroundStyle(.secondary) }
                Text("Podgląd dla wybranego terminu. Przed rozpoczęciem podróży trasa jest obliczana ponownie.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let message = draft.routeMessage {
                Text(message).font(.footnote).foregroundStyle(.orange)
                Button("Przelicz ponownie", systemImage: "arrow.clockwise") { draft.invalidatePreview(); previewRevision += 1 }
            }
        }
    }

    private var additionalOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Nazwa podróży (opcjonalnie)", text: $draft.title).textFieldStyle(.roundedBorder)
            Button("Wybierz wydarzenie z kalendarza", systemImage: "calendar") { draft.cancelCalculation(); pane = .calendar }
            Picker("Powtarzaj", selection: $draft.repeatRule) { ForEach(PlannedTrip.RepeatRule.allCases) { Text($0.title).tag($0) } }
            if draft.repeatRule == .custom {
                HStack(spacing: 4) {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                        Button {
                            if draft.weekdays.contains(day) { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                        } label: {
                            Text(String(PolishRegionalFormat.weekday(day).prefix(2))).font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(draft.weekdays.contains(day) ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04), in: Capsule())
                        }.buttonStyle(.plain).accessibilityLabel(PolishRegionalFormat.weekday(day))
                            .accessibilityAddTraits(draft.weekdays.contains(day) ? .isSelected : [])
                    }
                }
            }
            if !draft.waypoints.isEmpty { Stepper("Łączny czas postojów: \(draft.stopMinutes) min", value: $draft.stopMinutes, in: 0...360, step: 5) }
            Text("Przypomnienia").font(.subheadline.weight(.semibold))
            ForEach([1_440, 60, 15, 0], id: \.self) { minutes in
                Toggle(minutes == 1_440 ? "Dzień wcześniej" : minutes == 0 ? "W chwili wyjazdu" : "\(minutes) min przed wyjazdem", isOn: Binding(
                    get: { draft.reminders.contains(minutes) }, set: { if $0 { draft.reminders.insert(minutes) } else { draft.reminders.remove(minutes) } }))
            }
            if draft.mode == .car {
                Picker("Preferencja trasy", selection: $draft.preferences.advanced.routePreference) {
                    ForEach(RoutePreference.allCases) { Text($0.title).tag($0) }
                }.onChange(of: draft.preferences.advanced.routePreference) { _, _ in draft.preferredRoute = []; draft.preferences.advanced.shortest = draft.preferences.advanced.routePreference == .shortest }
                Toggle("Unikaj opłat", isOn: $draft.preferences.avoidTolls)
                Toggle("Unikaj autostrad", isOn: $draft.preferences.avoidHighways)
            }
            if draft.mode != .transit && draft.mode != .parkRide {
                Toggle("Unikaj promów", isOn: $draft.preferences.avoidFerries)
                Toggle("Unikaj dróg nieutwardzonych", isOn: $draft.preferences.avoidUnpaved)
            }
            Text("Przypomnienia korzystają z ostatniego przeliczenia. Odświeżanie w tle zależy od systemu.").font(.footnote).foregroundStyle(.secondary)
        }.font(.subheadline)
    }

    private var saveFooter: some View {
        VStack(spacing: 8) {
            if draft.savedTrip != nil {
                Button { dismiss() } label: { Text("Gotowe").font(.headline).frame(maxWidth: .infinity, minHeight: 46) }.buttonStyle(.borderedProminent)
            } else {
                if draft.calculating { Text("Obliczam trasę…").font(.caption).foregroundStyle(.secondary) }
                else if let estimate = draft.estimate {
                    Text("Wyjazd około \(PolishRegionalFormat.time(estimate.departure, timeZone: draft.timeZone)) · \(TravelDurationFormatter.string(minutes: Int(ceil(estimate.travelSeconds / 60))))")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Button { Task { if await draft.save(to: service, withoutRoute: false), let trip = draft.savedTrip { onSaved(trip) } } } label: {
                    HStack { if draft.saving { ProgressView().tint(.white) }; Text(draft.saving ? "Zapisuję…" : "Zapisz plan").font(.headline) }
                        .frame(maxWidth: .infinity, minHeight: 46)
                }.buttonStyle(.borderedProminent).disabled(draft.saving || !draft.hasPreview || draft.validationMessage != nil)
                if !draft.hasPreview && draft.validationMessage == nil {
                    Button("Zapisz bez wyliczenia trasy") {
                        Task { if await draft.save(to: service, withoutRoute: true), let trip = draft.savedTrip { onSaved(trip) } }
                    }.font(.footnote).disabled(draft.saving)
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func savedSummary(_ trip: PlannedTrip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Plan zapisany", systemImage: "checkmark.circle.fill").font(.title3.weight(.semibold)).foregroundStyle(.green)
            Text("\(trip.origin.name) → \(trip.destination.name)").font(.headline)
            Text(PolishRegionalFormat.dateTime(trip.targetDate, timeZone: draft.timeZone))
            if trip.estimate == nil { Text("Godzina wyjazdu nie została obliczona. Plan zapisano; trasę możesz przeliczyć w szczegółach podróży.").foregroundStyle(.orange) }
            if let message = service.reminderMessage { Text(IOSTripUserMessage.reminders(message)).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func search(_ role: IOSTripPointRole) { draft.selectedRole = role; draft.searchQuery = ""; draft.message = nil; draft.cancelCalculation(); pane = .search }
    private func choose(_ destination: Destination, role: IOSTripPointRole) {
        guard draft.choose(destination, for: role) else { return }
        onRecordPlace(destination); draft.mapState.routeOriginMapSelectionActive = false; pane = .editor
    }
    private func beginMapSelection() {
        draft.resetMapSelection(); draft.cancelCalculation(); draft.mapState.routeOriginMapSelectionActive = true
        if let place = draft.point(for: draft.selectedRole) { draft.selectMapPlace(place) }
        else if let center = draft.mapState.searchMapCenter ?? draft.origin?.coordinate ?? draft.currentOrigin?.coordinate { draft.updateMapCandidate(center); draft.focus(center) }
        pane = .map
    }
    private func moveStop(_ index: Int, offset: Int) {
        guard draft.waypoints.indices.contains(index + offset) else { return }
        draft.waypoints.swapAt(index, index + offset); draft.preferredRoute = []
    }
}

extension IOSPlannedTripWorkspace {
    private func scene(in geometry: GeometryProxy) -> MapScene {
        var settings = mapSettings
        settings.overlays.transit = draft.mode == .transit || draft.mode == .parkRide
        let commands = MapSceneCommands(
            onSearchSelect: { destination in
                guard pane == .map else { return }
                draft.selectMapPlace(destination)
            },
            onPlaceSelect: { results in
                guard pane == .map, let result = results.first else { return }
                draft.selectMapPlace(result.navigationDestination)
            },
            onTransitStopSelect: { stop in
                guard pane == .map else { return }
                draft.selectMapPlace(Destination(name: stop.name, coordinate: stop.coordinate, address: stop.address))
            },
            onTransitVehicleSelect: { _ in }, onParkedCarSelect: {},
            onRouteSelect: { id in
                guard pane == .editor, !draft.saving, draft.savedTrip == nil, draft.hasPreview,
                      let route = draft.mapState.routeOptions.first(where: { $0.id == id }) else { return }
                draft.select(route)
            },
            onCyclingPathsStatus: { _ in }, onRoadPOIStatus: { _ in },
            onTransitViewportChange: { viewport in
                guard draft.mode == .transit || draft.mode == .parkRide else { return }
                viewportGeneration += 1; let generation = viewportGeneration
                mapStopsTask?.cancel()
                mapStopsTask = Task {
                    let stops = await draft.session.transitDataProvider.mapStops(in: viewport)
                    guard !Task.isCancelled, generation == viewportGeneration else { return }
                    mapStops = stops
                }
            },
            onMapPan: {
                DispatchQueue.main.async {
                    if pane == .editor { detent = .peek }
                    else if pane == .map { draft.mapGestureStarted() }
                }
            },
            onLongPress: { coordinate in
                guard pane == .map else { return }
                draft.mapGestureStarted(); draft.focus(coordinate); draft.updateMapCandidate(coordinate)
            })
        return MapScene(navigationState: draft.mapState, energyPolicy: draft.session.energyPolicyEngine.currentPolicy,
            transit: MapSceneTransitData(vehicles: [], stops: mapStops, selectedStopID: nil, selectedRouteID: nil,
                selectedTripID: nil, selectedTripStopIDs: [], activeStopID: nil, alightingStopID: nil,
                lineCoordinates: [], lineColor: nil),
            parkedCar: nil, settings: settings, isSearchPresented: pane == .search,
            routePreviewExpanded: pane == .editor && detent == .expanded, isBottomSheetDragging: dragging,
            viewportPadding: pane == .map ? CameraPadding(top: 0, left: 0, bottom: 0, right: 0)
                : CameraPadding(top: 72, left: 24, bottom: Double(panelHeight + 12), right: 24), commands: commands, precisePointSelection: pane == .map)
    }

    private func mapSelection(in geometry: GeometryProxy) -> some View {
        ZStack {
            Image(systemName: "mappin.and.ellipse").font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.accentColor).shadow(color: .black.opacity(0.2), radius: 4)
                .position(x: geometry.size.width / 2,
                    y: geometry.size.height / 2 + (geometry.safeAreaInsets.bottom - geometry.safeAreaInsets.top) / 2 - 18)
                .allowsHitTesting(false)
            VStack {
                HStack {
                    Button {
                        draft.mapState.routeOriginMapSelectionActive = false; pane = .search
                    } label: { Label("Wstecz", systemImage: "chevron.left").padding(12) }
                    .modifier(NavigationGlassSurface(radius: 22, interactive: true))
                    Spacer()
                    Text(draft.selectedRole.title).font(.headline).padding(12)
                        .modifier(NavigationGlassSurface(radius: 22))
                }
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    Text(draft.mapCandidate?.address ?? draft.mapCandidate?.name ?? "Przesuń mapę pod pinezkę")
                        .font(.headline).lineLimit(3)
                    if draft.geocoding { ProgressView("Odczytuję adres…").font(.footnote) }
                    Text("Przesuń mapę, dotknij miejsca lub przytrzymaj wybrany punkt.").font(.footnote).foregroundStyle(.secondary)
                    if let message = draft.message { Text(message).font(.footnote).foregroundStyle(.red) }
                    Button {
                        if let candidate = draft.mapCandidate { choose(candidate, role: draft.selectedRole) }
                    } label: { Text(draft.selectedRole.confirmation).font(.headline).frame(maxWidth: .infinity, minHeight: 46) }
                    .buttonStyle(.borderedProminent).disabled(draft.mapCandidate == nil)
                }.padding(16).modifier(NavigationStableSurface(radius: 22))
            }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
    }
}
#endif
