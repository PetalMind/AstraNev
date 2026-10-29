#if os(iOS)
import Foundation
import MapLibre
import Observation
import UIKit

/// The renderer and offline regions must use exactly the same style URL.
enum MapResourceConfiguration {
    static let url = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
}

struct OfflineMapRegion: Identifiable {
    let id: String
    let name: String
    let center: Coordinate
    let radiusKilometers: Double
    let maximumZoom: Double
    let bounds: OfflineMapBounds
    let state: MLNOfflinePackState
    let downloadedResources: UInt64
    let expectedResources: UInt64
    let exactResourceCount: Bool
    let bytes: UInt64
    let error: String?

    var progress: Double? {
        guard exactResourceCount, expectedResources > 0 else { return nil }
        return min(1, Double(downloadedResources) / Double(expectedResources))
    }
    var status: String {
        if error != nil { return "Pobieranie przerwane" }
        switch state {
        case .complete: return "Gotowa do użycia offline"
        case .active: return "Pobieranie"
        case .inactive: return "Wstrzymana"
        case .unknown: return "Odczytywanie stanu"
        default: return "Niedostępna"
        }
    }
}

private struct OfflineMapMetadata: Codable {
    let id: String
    let name: String
    let center: Coordinate
    let radiusKilometers: Double
    let maximumZoom: Double
    // Optional for backwards compatibility with previously downloaded square regions.
    var bounds: OfflineMapBounds? = nil
}

@MainActor @Observable
final class OfflineMapStore {
    static let shared = OfflineMapStore()
    private(set) var regions: [OfflineMapRegion] = []
    private(set) var isCreating = false
    private(set) var isLoading = true
    private(set) var deletingIDs: Set<String> = []
    var error: String?

    @ObservationIgnored private let storage: MLNOfflineStorage = {
        MapTileNetwork.prepare()
        return MLNOfflineStorage.shared
    }()
    @ObservationIgnored private var packsByID: [String: MLNOfflinePack] = [:]
    @ObservationIgnored private var removingPacks: [ObjectIdentifier: MLNOfflinePack] = [:]
    @ObservationIgnored private var packErrors: [String: String] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var packsObservation: NSKeyValueObservation?

    private init() {
        packsObservation = storage.observe(\.packs, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .MLNOfflinePackProgressChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .MLNOfflinePackError, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let pack = notification.object as? MLNOfflinePack,
                      let id = self.packsByID.first(where: { $0.value === pack })?.key,
                      !self.deletingIDs.contains(id) else { return }
                let message = (notification.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError)?
                    .localizedDescription ?? "Nie udało się pobrać zasobów mapy."
                self.packErrors[id] = message
                pack.suspend()
                self.refresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for pack in self.packsByID.values where pack.state == .active { pack.suspend() }
                self.refresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .MLNOfflinePackMaximumMapboxTilesReached, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.error = "Osiągnięto limit pobierania kafli. Wybierz mniejszy obszar lub usuń niepotrzebną mapę."
                for (id, pack) in self.packsByID where !self.deletingIDs.contains(id) {
                    pack.suspend()
                }
                self.refresh()
            }
        })
    }

    func refresh() {
        guard let packs = storage.packs else { return }
        isLoading = false
        let currentIdentities = Set(packs.map(ObjectIdentifier.init))
        removingPacks = removingPacks.filter { currentIdentities.contains($0.key) }
        var currentPacks: [String: MLNOfflinePack] = [:]
        regions = packs.compactMap { pack in
            // Removed SDK packs must never be messaged: their getters raise Objective-C exceptions.
            guard removingPacks[ObjectIdentifier(pack)] == nil,
                  let metadata = try? JSONDecoder().decode(OfflineMapMetadata.self, from: pack.context) else { return nil }
            currentPacks[metadata.id] = pack
            let progress = pack.progress
            let needsProgress = packsByID[metadata.id] == nil && pack.state == .unknown
            if needsProgress { pack.requestProgress() }
            return OfflineMapRegion(id: metadata.id, name: metadata.name, center: metadata.center,
                radiusKilometers: metadata.radiusKilometers, maximumZoom: metadata.maximumZoom,
                bounds: metadata.bounds ?? OfflineMapBounds.around(metadata.center, radiusKilometers: metadata.radiusKilometers),
                state: pack.state, downloadedResources: progress.countOfResourcesCompleted,
                expectedResources: progress.countOfResourcesExpected,
                exactResourceCount: progress.maximumResourcesExpected != UInt64.max
                    && progress.maximumResourcesExpected == progress.countOfResourcesExpected,
                bytes: progress.countOfBytesCompleted, error: packErrors[metadata.id])
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        packsByID = currentPacks
    }

    func download(name: String, center: Coordinate, radiusKilometers: Double, maximumZoom: Double) {
        download(name: name, bounds: .around(center, radiusKilometers: radiusKilometers), maximumZoom: maximumZoom)
    }

    func download(name: String, bounds: OfflineMapBounds, maximumZoom: Double) {
        guard !isCreating else { return }
        guard bounds.isValid, maximumZoom.isFinite, (12...16).contains(maximumZoom) else {
            error = "Wybierz obszar między 85°S a 85°N, który nie przecina południka 180°."
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = OfflineMapMetadata(id: UUID().uuidString,
            name: trimmedName.isEmpty ? "Pobrany obszar" : trimmedName, center: bounds.center,
            radiusKilometers: max(bounds.widthKilometers, bounds.heightKilometers) / 2,
            maximumZoom: maximumZoom, bounds: bounds)
        do {
            let data = try JSONEncoder().encode(metadata)
            let region = MLNTilePyramidOfflineRegion(styleURL: MapResourceConfiguration.url,
                bounds: bounds.mapLibreBounds, fromZoomLevel: 0, toZoomLevel: maximumZoom)
            isCreating = true
            error = nil
            storage.addPack(for: region, withContext: data) { [weak self] pack, failure in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isCreating = false
                    if let failure { self.error = failure.localizedDescription }
                    else if let pack { pack.resume() }
                    else { self.error = "Nie udało się utworzyć obszaru offline." }
                    self.refresh()
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func toggleDownload(_ id: String) {
        guard !deletingIDs.contains(id), let pack = packsByID[id] else { return }
        packErrors[id] = nil
        if pack.state == .active { pack.suspend() }
        else if pack.state == .inactive { pack.resume() }
        refresh()
        pack.requestProgress()
    }

    func remove(_ id: String) {
        guard !deletingIDs.contains(id), let pack = packsByID.removeValue(forKey: id) else { return }
        deletingIDs.insert(id)
        let identity = ObjectIdentifier(pack)
        removingPacks[identity] = pack
        pack.suspend()
        storage.removePack(pack) { [weak self] failure in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deletingIDs.remove(id)
                if let failure {
                    self.error = failure.localizedDescription
                    // The SDK invalidates the old object even when deletion fails.
                    for validPack in self.packsByID.values { validPack.suspend() }
                    self.packsByID.removeAll()
                    self.storage.reloadPacks()
                } else {
                    self.packErrors[id] = nil
                    self.regions.removeAll { $0.id == id }
                }
                self.refresh()
            }
        }
    }
}
#endif
