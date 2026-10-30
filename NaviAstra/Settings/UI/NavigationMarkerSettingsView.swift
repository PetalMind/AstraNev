import SwiftUI

struct NavigationMarkerSettingsView: View {
    @Bindable var store: MapStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var modelColumnWidth = 96.0
    @State private var selectedTransport: NavigationPositionIcon = .car
    @State private var nightPreview = false
    @State private var tiltedPreview = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                preview
                VStack(alignment: .leading, spacing: 12) {
                    Text("Wygląd").font(.headline)
                    Picker("Rodzaj znacznika", selection: $store.transportPositionIconsEnabled) {
                        Text("Model").tag(true)
                        Text("Strzałka").tag(false)
                    }
                    .modifier(MarkerAdaptivePickerStyle())
                }
                if store.transportPositionIconsEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Personalizujesz").font(.headline)
                        Picker("Wygląd dla sposobu podróży", selection: $selectedTransport) {
                            Text("Auto").tag(NavigationPositionIcon.car)
                            Text("Rower").tag(NavigationPositionIcon.bicycle)
                            Text("Pieszo").tag(NavigationPositionIcon.pedestrian)
                        }
                        .modifier(MarkerAdaptivePickerStyle())
                        Text("Zmiana tutaj dotyczy wyglądu znacznika.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    modelPicker
                }
                paintPicker
                VStack(alignment: .leading, spacing: 12) {
                    Text("Wielkość").font(.headline)
                    Picker("Wielkość znacznika", selection: $store.markerAppearance.size) {
                        ForEach(NavigationMarkerSize.allCases) { Text($0.title).tag($0) }
                    }
                    .modifier(MarkerAdaptivePickerStyle())
                }
                Label {
                    Text("W komunikacji publicznej znacznik dopasowuje się do aktualnego etapu. Podczas dojścia i oczekiwania pokazuje pieszego.")
                } icon: {
                    Image(systemName: "tram.fill")
                }
                .font(.footnote).foregroundStyle(.secondary)
                Text("Kierunek podkreśla delikatna poświata wychodząca spod modelu. Przerywany obrys oznacza słabszą lub nieaktualną lokalizację. W podglądzie trasy znacznik pozostaje w Twojej rzeczywistej pozycji.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("Twój znacznik")
        .onAppear { nightPreview = colorScheme == .dark }
    }

    private var preview: some View {
        VStack(spacing: 14) {
            ZStack {
                MarkerPreviewMap(night: nightPreview)
                NavigationMarkerPreview(presentation: presentation())
                    .frame(width: 64 * store.markerAppearance.size.scale,
                           height: 64 * store.markerAppearance.size.scale)
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Podgląd wyglądu: \(store.transportPositionIconsEnabled ? selectedModel.title : "Strzałka"), \(selectedPaint.title)")
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
            layout {
                Picker("Oświetlenie podglądu", selection: $nightPreview) {
                    Text("Dzień").tag(false)
                    Text("Noc").tag(true)
                }
                Picker("Perspektywa podglądu", selection: $tiltedPreview) {
                    Text("2D").tag(false)
                    Text("3D").tag(true)
                }
            }
            .modifier(MarkerAdaptivePickerStyle())
            Text("Podgląd wyglądu na przykładowej mapie")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        #if os(iOS)
        .iosCardSurface(radius: 24)
        #else
        .modifier(NavigationGlassSurface(radius: 26))
        #endif
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: modelColumnWidth))], spacing: 10) {
                ForEach(models) { model in
                    Button {
                        if selectedTransport == .car { store.markerAppearance.car = model }
                        if selectedTransport == .bicycle { store.markerAppearance.bicycle = model }
                    } label: {
                        VStack(spacing: 4) {
                            NavigationMarkerPreview(presentation: presentation(model: model))
                                .frame(width: 64, height: 64)
                                .allowsHitTesting(false)
                            Text(model.title).font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Image(systemName: selectedModel == model ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedModel == model ? Color.accentColor : Color.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.primary.opacity(selectedModel == model ? 0.08 : 0.035),
                                    in: RoundedRectangle(cornerRadius: 18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(selectedModel == model ? Color.accentColor : Color.clear, lineWidth: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.title)
                    .accessibilityAddTraits(selectedModel == model ? [.isSelected] : [])
                }
            }
            if selectedTransport == .car {
                Text("Modele samochodów są dostępne bez internetu.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("Modele: Kenney Car Kit · licencja CC0",
                     destination: URL(string: "https://kenney.nl/assets/car-kit")!)
                    .font(.footnote)
            }
        }
    }

    private var paintPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(store.transportPositionIconsEnabled ? "Kolor" : "Kolor strzałki").font(.headline)
                Spacer()
                Text(selectedPaint.title).font(.subheadline).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                ForEach(NavigationMarkerPaint.allCases) { paint in
                    Button { setPaint(paint) } label: {
                        Circle().fill(Color(naviHex: paint.hex))
                            .frame(width: 38, height: 38)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
                            .overlay {
                                if selectedPaint == paint {
                                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(paint == .pearl || paint == .silver ? Color.black : Color.white)
                                }
                            }
                            .frame(width: 48, height: 48)
                            .overlay(Circle().strokeBorder(selectedPaint == paint ? Color.accentColor : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(paint.title)
                    .accessibilityAddTraits(selectedPaint == paint ? [.isSelected] : [])
                }
            }
        }
    }

    private var models: [NavigationMarkerModel] {
        switch selectedTransport {
        case .car: NavigationMarkerModel.cars
        case .bicycle: NavigationMarkerModel.bicycles
        default: [.pedestrian]
        }
    }
    private var selectedModel: NavigationMarkerModel { store.markerAppearance.model(for: selectedTransport) }
    private var selectedPaint: NavigationMarkerPaint {
        store.transportPositionIconsEnabled
            ? store.markerAppearance.paint(for: selectedTransport)
            : store.markerAppearance.arrowPaint
    }
    private func setPaint(_ paint: NavigationMarkerPaint) {
        if !store.transportPositionIconsEnabled {
            store.markerAppearance.arrowPaint = paint
            return
        }
        switch selectedTransport {
        case .car: store.markerAppearance.carPaint = paint
        case .bicycle: store.markerAppearance.bicyclePaint = paint
        default: store.markerAppearance.pedestrianPaint = paint
        }
    }
    private func presentation(model: NavigationMarkerModel? = nil) -> NavigationMarkerPresentation {
        var value = NavigationMarkerPresentation()
        value.model = store.transportPositionIconsEnabled ? model ?? selectedModel : nil
        value.paint = selectedPaint
        value.bearing = 24
        value.direction = 24
        value.pitch = tiltedPreview ? 45 : 0
        value.night = nightPreview
        value.increasedContrast = contrast == .increased
        value.scale = model == nil ? store.markerAppearance.size.scale : 1
        return value
    }
}

private struct MarkerAdaptivePickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if dynamicTypeSize.isAccessibilitySize {
            content.pickerStyle(.menu)
        } else {
            content.pickerStyle(.segmented)
        }
        #else
        content.pickerStyle(.segmented)
        #endif
    }
}

/// Explicitly illustrative, local preview; no synthetic GPS or map-provider data.
private struct MarkerPreviewMap: View {
    var night: Bool
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(naviHex: night ? 0x171C24 : 0xF3F2EF)))
            for row in 0..<3 {
                for column in 0..<5 {
                    let rect = CGRect(x: Double(column) * 82 - 25, y: Double(row) * 72 - 22,
                                      width: 56, height: 46)
                    context.fill(Path(roundedRect: rect, cornerRadius: 6),
                                 with: .color(Color(naviHex: night ? 0x272F39 : 0xE4E2DE)))
                }
            }
            var cross = Path()
            cross.move(to: CGPoint(x: 0, y: size.height * 0.72))
            cross.addLine(to: CGPoint(x: size.width, y: size.height * 0.72))
            context.stroke(cross, with: .color(Color(naviHex: night ? 0x36414D : 0xFFFFFF)),
                           style: StrokeStyle(lineWidth: 18))
            var road = Path()
            road.move(to: CGPoint(x: size.width * 0.32, y: size.height + 20))
            road.addLine(to: CGPoint(x: size.width * 0.66, y: -20))
            context.stroke(road, with: .color(Color(naviHex: night ? 0x465565 : 0xFFFFFF)),
                           style: StrokeStyle(lineWidth: 28))
            context.stroke(road, with: .color(Color(naviHex: night ? 0x5AA2FF : 0x1E5FE0)),
                           style: StrokeStyle(lineWidth: 7, lineCap: .round))
        }
    }
}
