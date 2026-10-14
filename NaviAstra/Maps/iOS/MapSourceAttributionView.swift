#if os(iOS)
import SwiftUI
import UIKit

/// Mobile attribution remains one tap from the map; all visible controls are Polish.
struct MapSourceAttributionView: View {
    var onClose: () -> Void
    var body: some View {
        NavigationStack {
            List {
                Section("Zdjęcia satelitarne i lotnicze") {
                    SatelliteMapCredits()
                }
                if MapTilerEnvironmentStyle.configuredURL != nil {
                    Section("Szczegóły otoczenia") {
                        Link(destination: URL(string: "https://www.maptiler.com/copyright/")!) {
                            Image("MapTilerLogo")
                                .resizable().scaledToFit().frame(width: 134, height: 40)
                                .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("MapTiler · prawa autorskie")
                        }
                        Link("© MapTiler", destination: URL(string: "https://www.maptiler.com/copyright/")!)
                    }
                }
                Section("Dane mapowe") {
                    Link("© autorzy OpenStreetMap · licencja ODbL",
                         destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    Link("OpenFreeMap · mapa bazowa", destination: URL(string: "https://openfreemap.org")!)
                    Link("OpenMapTiles · schemat danych", destination: URL(string: "https://openmaptiles.org")!)
                }
                Section("Silnik mapy") {
                    Link("MapLibre · licencja BSD", destination: URL(string: "https://maplibre.org")!)
                }
            }
            .navigationTitle("Źródła mapy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Zamknij", action: onClose) } }
        }
        .environment(\.locale, Locale(identifier: "pl_PL"))
    }

    @MainActor
    static func present(from map: UIView) {
        var responder: UIResponder? = map
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let owner = responder as? UIViewController else { return }
        let controller = UIHostingController(rootView: MapSourceAttributionView(onClose: {}))
        controller.rootView = MapSourceAttributionView(onClose: { [weak controller] in controller?.dismiss(animated: true) })
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.detents = [.medium(), .large()]
        owner.present(controller, animated: true)
    }
}

/// Shared by the map's attribution button and Settings.
struct SatelliteMapCredits: View {
    var body: some View {
        Link("GUGiK · ortofotomapa Polski", destination: SatelliteMapStyle.gugikURL)
        Link(SatelliteMapStyle.eoxCredit, destination: SatelliteMapStyle.eoxURL)
        Link("EOX::Maps · serwis zdjęć", destination: SatelliteMapStyle.eoxMapsURL)
        Link("Sentinel‑2 2016 · licencja CC BY 4.0", destination: SatelliteMapStyle.eoxLicenseURL)
        Text(SatelliteMapStyle.description)
            .font(.footnote).foregroundStyle(Color.naviTextSecondary)
    }
}
#endif
