import Foundation
import MapKit

#if os(macOS)
import AppKit
typealias PlacePhotoPlatformImage = NSImage
#else
import UIKit
typealias PlacePhotoPlatformImage = UIImage
#endif

enum PlacePhotoSource: String, Sendable {
    case openStreetMap
    case wikimediaCommons
}

enum PlacePhotoRole: Equatable, Sendable {
    case place
    case brandLogo
}

struct PlacePhoto: Sendable {
    let imageURL: URL
    let sourcePageURL: URL
    let source: PlacePhotoSource
    let role: PlacePhotoRole
    let attribution: String
}

enum PlacePhotoResolver {
    static func isEligible(category: String?) -> Bool {
        guard let category else { return false }
        let value = category.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !value.contains("parking"), !value.contains("parkride"),
              !value.contains("evcharger"), !value.contains("atm"), !value.contains("pharmacy") else { return false }
        let usefulCategories = [
            "attraction", "museum", "castle", "theatre", "theater", "gallery", "viewpoint",
            "monument", "artwork", "historic", "landmark", "church", "placeofworship",
            "artscentre", "culturalcentre", "amusement", "aquarium", "zoo",
            "restaurant", "cafe", "coffee", "fastfood",
            "foodcourt", "hotel", "motel", "hostel", "guesthouse", "shoppingcentre",
            "shoppingcenter", "departmentstore", "mall", "nationalpark", "garden", "park"
        ]
        return usefulCategories.contains(where: { value.contains($0) })
    }

    static func resolve(for details: PlaceDetails, identity: PlaceIdentity) async -> PlacePhoto? {
        guard isEligible(category: details.category) || isEligible(category: identity.category) else { return nil }
        let key = [identity.cacheKey, "place-photo", details.imageURL ?? "", details.imageAttribution ?? "",
                   details.imageLicense ?? "", details.wikimediaCommons ?? "", details.wikidataID ?? ""]
            .joined(separator: "|")
        let cached = await PlacePhotoCache.shared.lookup(key)
        if cached.found { return cached.photo }

        if let fileName = wikimediaFileName(details.imageURL) {
            if let photo = await commonsPhoto(fileName: fileName, role: .place) {
                await PlacePhotoCache.shared.store(photo, for: key)
                return photo
            }
        } else if let photo = taggedImage(from: details) {
            await PlacePhotoCache.shared.store(photo, for: key)
            return photo
        }

        let fileName: String?
        if let commonsName = wikimediaFileName(details.wikimediaCommons) {
            fileName = commonsName
        } else {
            fileName = await wikimediaFileName(for: details.wikidataID, propertyID: "P18")
        }
        if let fileName, let photo = await commonsPhoto(fileName: fileName, role: .place) {
            await PlacePhotoCache.shared.store(photo, for: key)
            return photo
        }

        await PlacePhotoCache.shared.store(nil, for: key)
        return nil
    }

    static func resolveBrandLogo(for details: PlaceDetails, identity: PlaceIdentity) async -> PlacePhoto? {
        let key = "\(identity.cacheKey)/brand-logo/\(details.brandWikidataID ?? "")"
        let cached = await PlacePhotoCache.shared.lookup(key)
        if cached.found { return cached.photo }
        guard let fileName = await wikimediaFileName(for: details.brandWikidataID, propertyID: "P154"),
              let photo = await commonsPhoto(fileName: fileName, role: .brandLogo) else {
            await PlacePhotoCache.shared.store(nil, for: key)
            return nil
        }
        await PlacePhotoCache.shared.store(photo, for: key)
        return photo
    }

    private static func taggedImage(from details: PlaceDetails) -> PlacePhoto? {
        guard let rawURL = details.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              var components = URLComponents(string: rawURL),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let attribution = details.imageAttribution?.trimmingCharacters(in: .whitespacesAndNewlines),
              !attribution.isEmpty else { return nil }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        guard let url = components.url else { return nil }
        let license = details.imageLicense?.trimmingCharacters(in: .whitespacesAndNewlines)
        let credit = [attribution, license].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return PlacePhoto(imageURL: url, sourcePageURL: url, source: .openStreetMap, role: .place,
                          attribution: credit)
    }

    private static func wikimediaFileName(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let url = URL(string: value), url.host?.lowercased() == "commons.wikimedia.org" {
            let path = url.path.removingPercentEncoding ?? url.path
            if let fileMarker = path.range(of: "/wiki/File:", options: .caseInsensitive) {
                value = String(path[fileMarker.upperBound...])
            } else if let fileMarker = path.range(of: "/wiki/Special:FilePath/", options: .caseInsensitive) {
                value = String(path[fileMarker.upperBound...])
            } else {
                return nil
            }
        }
        value = value.replacingOccurrences(of: "_", with: " ")
        if let colon = value.firstIndex(of: ":") {
            let namespace = value[..<colon].lowercased()
            guard namespace == "file" else { return nil }
            value = String(value[value.index(after: colon)...])
        }
        let fileName = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return fileName.isEmpty ? nil : fileName
    }

    private static func wikimediaFileName(for wikidataID: String?, propertyID: String) async -> String? {
        guard let wikidataID, wikidataID.range(of: #"^Q[1-9][0-9]*$"#, options: .regularExpression) != nil,
              var components = URLComponents(string: "https://www.wikidata.org/w/api.php") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "wbgetentities"),
            URLQueryItem(name: "ids", value: wikidataID),
            URLQueryItem(name: "props", value: "claims"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url,
              let data = await fetch(url, accept: "application/json"),
              let reply = try? JSONDecoder().decode(WikidataEntitiesReply.self, from: data),
              let claims = reply.entities[wikidataID]?.claims[propertyID],
              let value = claims.first?.mainSnak.dataValue?.value else { return nil }
        return value
    }

    private static func commonsPhoto(fileName: String, role: PlacePhotoRole) async -> PlacePhoto? {
        guard var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "titles", value: "File:\(fileName)"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "800"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2")
        ]
        guard let url = components.url,
              let data = await fetch(url, accept: "application/json"),
              let reply = try? JSONDecoder().decode(CommonsImageReply.self, from: data),
              let imageInfo = reply.query.pages.first?.imageInfo?.first,
              let imageURL = imageInfo.thumbURL ?? imageInfo.url,
              let pageURL = imageInfo.descriptionURL else { return nil }

        let metadata = imageInfo.extMetadata ?? [:]
        let author = (metadata["Artist"]?.value ?? metadata["Author"]?.value).map(plainText)
        guard let license = metadata["LicenseShortName"]?.value.map(plainText), !license.isEmpty else { return nil }
        let attribution = [author, Optional(license)].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: " · ")

        let fallbackAttribution = role == .brandLogo
            ? "Logo z Wikimedia Commons"
            : "Zdjęcie z Wikimedia Commons"
        return PlacePhoto(imageURL: imageURL, sourcePageURL: pageURL, source: .wikimediaCommons, role: role,
                          attribution: attribution.isEmpty ? fallbackAttribution : attribution)
    }

    private static func fetch(_ url: URL, accept: String) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("NaviAstra/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return data
    }

    private static func plainText(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
struct PlaceLookAroundPreview {
    let scene: MKLookAroundScene
    let image: PlacePhotoPlatformImage
}

@MainActor
enum PlaceLookAroundProvider {
    static func preview(at coordinate: Coordinate) async -> PlaceLookAroundPreview? {
        await withCheckedContinuation { continuation in
            let request = MKLookAroundSceneRequest(coordinate: coordinate.cl)
            request.getSceneWithCompletionHandler { scene, _ in
                guard let scene else {
                    continuation.resume(returning: nil)
                    return
                }

                let options = MKLookAroundSnapshotter.Options()
                options.size = CGSize(width: 1200, height: 675)
                let snapshotter = MKLookAroundSnapshotter(scene: scene, options: options)
                snapshotter.getSnapshotWithCompletionHandler { snapshot, _ in
                    guard let snapshot else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: PlaceLookAroundPreview(scene: scene, image: snapshot.image))
                }
            }
        }
    }
}

private actor PlacePhotoCache {
    static let shared = PlacePhotoCache()

    private struct Entry {
        let photo: PlacePhoto?
        let expiresAt: Date
    }

    private var values: [String: Entry] = [:]

    func lookup(_ key: String) -> (found: Bool, photo: PlacePhoto?) {
        guard let entry = values[key], entry.expiresAt > Date() else {
            values.removeValue(forKey: key)
            return (false, nil)
        }
        return (true, entry.photo)
    }

    func store(_ photo: PlacePhoto?, for key: String) {
        let lifetime: TimeInterval = photo == nil ? 24 * 60 * 60 : 7 * 24 * 60 * 60
        values[key] = Entry(photo: photo, expiresAt: Date().addingTimeInterval(lifetime))
    }
}

private struct WikidataEntitiesReply: Decodable {
    let entities: [String: WikidataEntity]
}

private struct WikidataEntity: Decodable {
    let claims: [String: [WikidataClaim]]
}

private struct WikidataClaim: Decodable {
    let mainSnak: WikidataMainSnak

    enum CodingKeys: String, CodingKey {
        case mainSnak = "mainsnak"
    }
}

private struct WikidataMainSnak: Decodable {
    let dataValue: WikidataDataValue?

    enum CodingKeys: String, CodingKey {
        case dataValue = "datavalue"
    }
}

private struct WikidataDataValue: Decodable {
    let value: String?
}

private struct CommonsImageReply: Decodable {
    let query: CommonsQuery
}

private struct CommonsQuery: Decodable {
    let pages: [CommonsPage]
}

private struct CommonsPage: Decodable {
    let imageInfo: [CommonsImageInfo]?

    enum CodingKeys: String, CodingKey {
        case imageInfo = "imageinfo"
    }
}

private struct CommonsImageInfo: Decodable {
    let url: URL?
    let thumbURL: URL?
    let descriptionURL: URL?
    let extMetadata: [String: CommonsMetadataValue]?

    enum CodingKeys: String, CodingKey {
        case url
        case thumbURL = "thumburl"
        case descriptionURL = "descriptionurl"
        case extMetadata = "extmetadata"
    }
}

private struct CommonsMetadataValue: Decodable {
    let value: String?
}
