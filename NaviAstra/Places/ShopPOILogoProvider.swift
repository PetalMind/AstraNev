import Foundation
import Observation
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Only the brand attached to a resolved OSM shop is used. Names never guess a brand.
@MainActor
@Observable
final class ShopPOILogoStore {
    static let shared = ShopPOILogoStore()

    struct Credit: Codable, Identifiable {
        var id: String { sourcePageURL.absoluteString }
        let name: String
        let sourcePageURL: URL
        let attribution: String
        let licenseName: String?
        let licenseURL: URL?
    }

    private(set) var credits: [Credit]
    @ObservationIgnored private var downloadedImages: [URL: PlacePhotoPlatformImage] = [:]
    @ObservationIgnored private var activeLoads = 0
    @ObservationIgnored private var images: [String: (PlacePhotoPlatformImage?, Date)] = [:]
    @ObservationIgnored private var requests: [String: Task<PlacePhotoPlatformImage?, Never>] = [:]
    private static let creditsKey = "shopPOILogoCredits"

    private init() {
        credits = UserDefaults.standard.data(forKey: Self.creditsKey)
            .flatMap { try? JSONDecoder().decode([Credit].self, from: $0) } ?? []
    }

    func image(for identity: PlaceIdentity) async -> PlacePhotoPlatformImage? {
        let key = identity.cacheKey
        if let cached = images[key], cached.1 > Date() { return cached.0 }
        if let pending = requests[key] { return await pending.value }
        guard requests.count < 8 else { return nil }
        let task = Task {
            while self.activeLoads >= 2 {
                try? await Task.sleep(for: .milliseconds(200))
            }
            self.activeLoads += 1
            defer { self.activeLoads -= 1 }
            return await self.load(identity)
        }
        requests[key] = task
        let image = await task.value
        requests[key] = nil
        if images.count >= 256, let oldest = images.min(by: { $0.value.1 < $1.value.1 })?.key {
            images.removeValue(forKey: oldest)
        }
        images[key] = (image, Date().addingTimeInterval(image == nil ? 300 : 86_400))
        return image
    }

    private func load(_ identity: PlaceIdentity) async -> PlacePhotoPlatformImage? {
        let provider = OpenStreetMapPlaceDetailsProvider()
        guard let details = try? await provider.details(for: identity),
              PlacePOIMapMarkerKind(category: details.category) == .shopping,
              let photo = await PlacePhotoResolver.resolveBrandLogo(wikidataID: details.brandWikidataID) else { return nil }
        if let cached = downloadedImages[photo.imageURL] { return cached }
        var request = URLRequest(url: photo.imageURL)
        request.timeoutInterval = 8
        request.setValue("NaviAstra (https://github.com/PetalMind/AstraNev)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              data.count <= 5_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        #if os(macOS)
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        #else
        let image = UIImage(cgImage: thumbnail)
        #endif
        if downloadedImages.count >= 64 { downloadedImages.removeAll(keepingCapacity: true) }
        downloadedImages[photo.imageURL] = image
        let credit = Credit(name: details.brand ?? details.name, sourcePageURL: photo.sourcePageURL,
                            attribution: photo.attribution, licenseName: photo.licenseName,
                            licenseURL: photo.licenseURL)
        if !credits.contains(where: { $0.id == credit.id }) {
            credits.append(credit)
            credits.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if let encoded = try? JSONEncoder().encode(credits) {
                UserDefaults.standard.set(encoded, forKey: Self.creditsKey)
            }
        }
        return image
    }
}

/// One serial queue per map, debounced after camera changes. Failed lookups have a short TTL.
@MainActor
final class ShopPOILogoLoader {
    private(set) var images: [String: PlacePhotoPlatformImage] = [:]
    private var identities: [PlaceIdentity] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var refreshedAt = Date.distantPast

    func update(_ places: [PlaceIdentity], enabled: Bool, onChange: @escaping @MainActor () -> Void) {
        var seen = Set<String>()
        let desired = enabled ? Array(places.filter { seen.insert($0.cacheKey).inserted }.prefix(48)) : []
        guard desired.map(\.cacheKey) != identities.map(\.cacheKey) || Date().timeIntervalSince(refreshedAt) >= 300 else { return }
        refreshedAt = Date()
        identities = desired
        task?.cancel()
        generation = UUID()
        let currentGeneration = generation
        let keys = Set(desired.map(\.cacheKey))
        images = images.filter { keys.contains($0.key) }
        onChange()
        guard !desired.isEmpty else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            for identity in desired {
                guard !Task.isCancelled else { return }
                let image = await ShopPOILogoStore.shared.image(for: identity)
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                if let image {
                    self.images[identity.cacheKey] = image
                    onChange()
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        identities = []
        images = [:]
        generation = UUID()
    }
}
