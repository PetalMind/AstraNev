import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var naviastraGPX: UTType { UTType(importedAs: "com.topografix.gpx", conformingTo: .xml) }
}

nonisolated final class GPXTraceParser: NSObject, XMLParserDelegate {
    private var segments: [[Coordinate]] = []
    private var count = 0
    private var failure: Error?
    private var rootSeen = false

    static func read(_ data: Data) throws -> [[Coordinate]] {
        guard data.count <= 10_000_000 else { throw ValhallaFeatureError.message("Plik GPX może mieć maksymalnie 10 MB.") }
        let delegate = GPXTraceParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else {
            throw delegate.failure ?? ValhallaFeatureError.message("Nie udało się odczytać pliku GPX.")
        }
        let parts = delegate.segments.filter { $0.count >= 2 }
        guard !parts.isEmpty, parts.count <= 20 else {
            throw ValhallaFeatureError.message("GPX musi zawierać od 1 do 20 części śladu lub trasy, z co najmniej dwoma punktami w każdej.")
        }
        return parts
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if !rootSeen {
            rootSeen = true
            guard elementName == "gpx" else {
                failure = ValhallaFeatureError.message("Wybrany plik nie jest dokumentem GPX.")
                parser.abortParsing(); return
            }
        }
        if elementName == "trkseg" || elementName == "rte" { segments.append([]) }
        guard elementName == "trkpt" || elementName == "rtept" else { return }
        guard let lat = attributeDict["lat"].flatMap(Double.init),
              let lon = attributeDict["lon"].flatMap(Double.init) else {
            failure = ValhallaFeatureError.message("Plik zawiera nieprawidłowe współrzędne."); parser.abortParsing(); return
        }
        let coordinate = Coordinate(latitude: lat, longitude: lon)
        count += 1
        guard coordinate.isValidValhallaCoordinate, count <= 100_000 else {
            failure = ValhallaFeatureError.message("Nieprawidłowe współrzędne lub więcej niż 100 000 punktów GPX.")
            parser.abortParsing(); return
        }
        if segments.isEmpty { segments.append([]) }
        segments[segments.count - 1].append(coordinate)
    }
}

struct MatchedTraceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.naviastraGPX, .xml] }
    var data: Data
    init(routes: [NavigationRoute]) {
        let segments = routes.map { route in
            "<trkseg>" + route.coordinates.map {
                "<trkpt lat=\"\($0.latitude)\" lon=\"\($0.longitude)\"/>"
            }.joined() + "</trkseg>"
        }.joined()
        data = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"NaviAstra\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>Dopasowany ślad</name>\(segments)</trk></gpx>".utf8)
    }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
