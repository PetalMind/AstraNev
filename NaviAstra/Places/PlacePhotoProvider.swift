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
    let licenseName: String?
    let licenseURL: URL?
}

enum PlacePhotoResolver {
    static func isEligible(category: String?) -> Bool {
        guard let category else { return false }
        let value = category.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !value.contains("parking"), !value.contains("parkride"),
              !value.contains("evcharger"), !value.contains("atm"), !value.contains("pharmacy") else { return false }
        let usefulCategories = [
            "attraction", "museum", "castle", "theatre", "theater", "gallery", "viewpoint",
            "monument", "memorial", "ruins", "archaeologicalsite", "heritagesite", "artwork",
            "historic", "landmark", "church", "placeofworship",
            "artscentre", "culturalcentre", "amusement", "aquarium", "zoo",
            "restaurant", "cafe", "coffee", "fastfood",
            "foodcourt", "hotel", "motel", "hostel", "guesthouse", "shoppingcentre",
            "shoppingcenter", "departmentstore", "mall", "nationalpark", "garden", "park"
        ]
        return usefulCategories.contains(where: { value.contains($0) })
    }

    static func resolve(for details: PlaceDetails, identity: PlaceIdentity,
                        forceRefresh: Bool = false) async -> PlacePhoto? {
        guard isEligible(category: details.category) || isEligible(category: identity.category) else { return nil }
        let key = [identity.cacheKey, "place-photo", details.imageURL ?? "", details.imageAttribution ?? "",
                   details.imageLicense ?? "", details.wikimediaCommons ?? "", details.wikidataID ?? ""]
            .joined(separator: "|")
        if !forceRefresh {
            let cached = await PlacePhotoCache.shared.lookup(key)
            if cached.found { return cached.photo }
        }

        if let fileName = wikimediaFileName(details.imageURL) {
            if let photo = await commonsPhoto(fileName: fileName, role: .place) {
                await PlacePhotoCache.shared.store(photo, for: key)
                return photo
            }
        } else if let photo = taggedImage(from: details) {
            await PlacePhotoCache.shared.store(photo, for: key)
            return photo
        }

        if let commonsName = wikimediaFileName(details.wikimediaCommons) {
            if let photo = await commonsPhoto(fileName: commonsName, role: .place) {
                await PlacePhotoCache.shared.store(photo, for: key)
                return photo
            }
        }

        for fileName in await wikimediaFileNames(for: details.wikidataID, propertyID: "P18") {
            if let photo = await commonsPhoto(fileName: fileName, role: .place) {
                await PlacePhotoCache.shared.store(photo, for: key)
                return photo
            }
        }

        await PlacePhotoCache.shared.store(nil, for: key)
        return nil
    }

    static func resolveBrandLogo(for details: PlaceDetails, identity: PlaceIdentity,
                                 forceRefresh: Bool = false) async -> PlacePhoto? {
        let key = "\(identity.cacheKey)/brand-logo/\(details.brandWikidataID ?? "")"
        if !forceRefresh {
            let cached = await PlacePhotoCache.shared.lookup(key)
            if cached.found { return cached.photo }
        }
        for fileName in await wikimediaFileNames(for: details.brandWikidataID, propertyID: "P154") {
            if let photo = await commonsPhoto(fileName: fileName, role: .brandLogo) {
                await PlacePhotoCache.shared.store(photo, for: key)
                return photo
            }
        }
        await PlacePhotoCache.shared.store(nil, for: key)
        return nil
    }

    private static func taggedImage(from details: PlaceDetails) -> PlacePhoto? {
        guard let rawURL = details.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              var components = URLComponents(string: rawURL),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let attribution = details.imageAttribution?.trimmingCharacters(in: .whitespacesAndNewlines),
              !attribution.isEmpty else { return nil }
        let rawLicense = details.imageLicense?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawLicense, !rawLicense.isEmpty, !allowsImageReuse(rawLicense) { return nil }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        guard let url = components.url else { return nil }
        let declaredLicense = rawLicense?.isEmpty == false ? rawLicense : nil
        let licenseURL = declaredLicense.flatMap(secureURL)
        let licenseName: String?
        if let declaredLicense, licenseURL == nil {
            licenseName = declaredLicense
        } else if declaredLicense == nil {
            licenseName = "Licencja niepodana"
        } else {
            licenseName = nil
        }
        return PlacePhoto(imageURL: url, sourcePageURL: url, source: .openStreetMap, role: .place,
                          attribution: attribution, licenseName: licenseName, licenseURL: licenseURL)
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

    private static func wikimediaFileNames(for rawWikidataIDs: String?, propertyID: String) async -> [String] {
        var fileNames: [String] = []
        for wikidataID in wikidataIdentifiers(from: rawWikidataIDs).prefix(3) {
            guard var components = URLComponents(string: "https://www.wikidata.org/w/api.php") else { continue }
            components.queryItems = [
                URLQueryItem(name: "action", value: "wbgetentities"),
                URLQueryItem(name: "ids", value: wikidataID),
                URLQueryItem(name: "props", value: "claims"),
                URLQueryItem(name: "format", value: "json")
            ]
            guard let url = components.url,
                  let data = await fetch(url, accept: "application/json"),
                  let reply = try? JSONDecoder().decode(WikidataEntitiesReply.self, from: data),
                  let claims = reply.entities[wikidataID]?.claims[propertyID] else { continue }
            let preferred = claims.filter { $0.rank == "preferred" }
            let normal = claims.filter { $0.rank == nil || $0.rank == "normal" }
            for claim in preferred + normal {
                guard let value = claim.mainSnak.dataValue?.value,
                      let fileName = wikimediaFileName(value),
                      !fileNames.contains(fileName) else { continue }
                fileNames.append(fileName)
            }
        }
        return fileNames
    }

    private static func wikidataIdentifiers(from value: String?) -> [String] {
        guard let value, let regex = try? NSRegularExpression(pattern: #"\bQ[1-9][0-9]*\b"#) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var identifiers: [String] = []
        for match in regex.matches(in: value, range: range) {
            guard let range = Range(match.range, in: value) else { continue }
            let identifier = String(value[range])
            if !identifiers.contains(identifier) { identifiers.append(identifier) }
        }
        return identifiers
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
        let license = metadata["LicenseShortName"]?.value.map {
            plainText($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let license, !license.isEmpty else { return nil }
        let author = ["Artist", "Author", "Credit"].compactMap { key in
            metadata[key]?.value.map { plainText($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }.first { !$0.isEmpty }
        let licenseAllowsUncreditedUse = license.localizedCaseInsensitiveContains("CC0")
            || license.localizedCaseInsensitiveContains("public domain")
        let attribution: String
        if let author, !author.isEmpty {
            attribution = author
        } else if licenseAllowsUncreditedUse {
            attribution = role == .brandLogo ? "Logo z Wikimedia Commons" : "Zdjęcie z Wikimedia Commons"
        } else {
            return nil
        }
        let licenseURL = metadata["LicenseUrl"]?.value.map(plainText).flatMap(secureURL)
        return PlacePhoto(imageURL: imageURL, sourcePageURL: pageURL, source: .wikimediaCommons, role: role,
                          attribution: attribution, licenseName: license,
                          licenseURL: licenseURL)
    }

    private static func secureURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host != nil else { return nil }
        return components.url
    }

    private static func allowsImageReuse(_ rawLicense: String) -> Bool {
        let value = rawLicense.lowercased().filter { $0.isLetter || $0.isNumber }
        let restrictedTerms = [
            "noncommercial", "noderivatives", "ccbync", "ccbynd", "ccbysanc", "ccbysand",
            "licensesbync", "licensesbynd", "licensesbysanc", "licensesbysand"
        ]
        guard !restrictedTerms.contains(where: { value.contains($0) }) else { return false }
        if value.contains("cc0") || value.contains("publicdomain") { return true }
        return value.contains("ccby") || value.contains("creativecommonsattribution")
            || value.contains("creativecommonsorglicensesby")
    }

    private static let userAgent = "NaviAstra/1.0 (https://github.com/PetalMind/AstraNev)"

    private static func fetch(_ url: URL, accept: String) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return data
    }

    private static func plainText(_ html: String) -> String {
        let decoded = html
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return decoded
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
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
        guard coordinate.latitude.isFinite, (-90...90).contains(coordinate.latitude),
              coordinate.longitude.isFinite, (-180...180).contains(coordinate.longitude) else { return nil }

        do {
            let request = MKLookAroundSceneRequest(coordinate: coordinate.cl)
            guard let scene = try await request.scene else { return nil }
            try Task.checkCancellation()

            let options = MKLookAroundSnapshotter.Options()
            options.size = CGSize(width: 1200, height: 675)
            let snapshotter = MKLookAroundSnapshotter(scene: scene, options: options)
            let snapshot = try await snapshotter.snapshot
            return PlaceLookAroundPreview(scene: scene, image: snapshot.image)
        } catch {
            return nil
        }
    }
}

private actor PlacePhotoCache {
    static let shared = PlacePhotoCache()
    private let maximumEntries = 256

    private struct Entry {
        let photo: PlacePhoto?
        let expiresAt: Date
        var lastAccessedAt: Date
    }

    private var values: [String: Entry] = [:]

    func lookup(_ key: String) -> (found: Bool, photo: PlacePhoto?) {
        guard var entry = values[key], entry.expiresAt > Date() else {
            values.removeValue(forKey: key)
            return (false, nil)
        }
        entry.lastAccessedAt = Date()
        values[key] = entry
        return (true, entry.photo)
    }

    func store(_ photo: PlacePhoto?, for key: String) {
        let now = Date()
        let lifetime: TimeInterval = photo == nil ? 5 * 60 : 7 * 24 * 60 * 60
        values[key] = Entry(photo: photo, expiresAt: now.addingTimeInterval(lifetime), lastAccessedAt: now)

        let expiredKeys = values.compactMap { $0.value.expiresAt <= now ? $0.key : nil }
        for expiredKey in expiredKeys { values.removeValue(forKey: expiredKey) }
        guard values.count > maximumEntries else { return }
        let overflow = values.count - maximumEntries
        let leastRecentlyUsedKeys = values.sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
            .prefix(overflow)
            .map(\.key)
        for leastRecentlyUsedKey in leastRecentlyUsedKeys { values.removeValue(forKey: leastRecentlyUsedKey) }
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
    let rank: String?

    enum CodingKeys: String, CodingKey {
        case mainSnak = "mainsnak"
        case rank
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
