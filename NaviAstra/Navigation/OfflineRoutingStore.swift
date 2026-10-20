#if os(iOS)
import Foundation
import Network
import Observation
import OSLog

nonisolated struct OfflineRoutingDownload: Identifiable, Decodable, Sendable {
    let name: String
    let size: Int64
    let browserDownloadURL: URL
    let digest: String?
    var sha256: String? { digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil } }
    var id: URL { browserDownloadURL }
    var title: String {
        name.replacingOccurrences(of: "valhalla_tiles_", with: "").replacingOccurrences(of: ".tar", with: "")
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }
    enum CodingKeys: String, CodingKey {
        case name, size, digest
        case browserDownloadURL = "browser_download_url"
    }
}

private final class OfflineRoutingTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @MainActor @Sendable (Int64, Int64) -> Void
    init(report: @escaping @MainActor @Sendable (Int64, Int64) -> Void) { self.report = report }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in report(totalBytesWritten, totalBytesExpectedToWrite) }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {}
}

@MainActor @Observable
final class OfflineRoutingStore {
    static let shared = OfflineRoutingStore()
    private(set) var packs: [OfflineRoutingPack] = []
    private(set) var catalog: [OfflineRoutingDownload] = []
    private(set) var isLoadingCatalog = false
    private(set) var isInstalling = false
    private(set) var transferName = ""
    private(set) var downloadedBytes: Int64 = 0
    private(set) var expectedBytes: Int64 = 0
    private(set) var networkUnavailable = false
    private(set) var removingIDs: Set<UUID> = []
    var error: String?
    var activeID: UUID? {
        didSet { UserDefaults.standard.set(activeID?.uuidString, forKey: "offlineRouting.activePack") }
    }
    var preferOffline: Bool {
        didSet { UserDefaults.standard.set(preferOffline, forKey: "offlineRouting.preferLocal") }
    }
    var activePack: OfflineRoutingPack? { packs.first { $0.id == activeID && !removingIDs.contains($0.id) } }
    var progress: Double? { expectedBytes > 0 ? min(1, Double(downloadedBytes) / Double(expectedBytes)) : nil }
    @ObservationIgnored private var transferTask: Task<Void, Never>?
    @ObservationIgnored private var transferID: UUID?
    @ObservationIgnored private let monitor = NWPathMonitor()
    private let logger = Logger(subsystem: "Blackmaks.NaviAstras.pl", category: "OfflineRoutingStore")

    private init() {
        activeID = UserDefaults.standard.string(forKey: "offlineRouting.activePack").flatMap(UUID.init(uuidString:))
        preferOffline = UserDefaults.standard.bool(forKey: "offlineRouting.preferLocal")
        refresh()
        if activePack == nil { preferOffline = false }
        Task {
            do { try await OfflineRoutingEngine.shared.discardInterruptedInstallations() }
            catch {
                logger.error("Nie udało się usunąć przerwanych instalacji: \(error.localizedDescription, privacy: .private)")
                self.error = "Nie udało się uporządkować niedokończonej instalacji danych drogowych."
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let unavailable = path.status == .unsatisfied
            Task { @MainActor [weak self] in self?.networkUnavailable = unavailable }
        }
        monitor.start(queue: DispatchQueue(label: "NaviAstra.OfflineRouting.Network"))
    }

    func refresh() {
        let root = OfflineRoutingEngine.root
        guard FileManager.default.fileExists(atPath: root.path) else { packs = []; return }
        do {
            packs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .compactMap { directory in
                    guard let pack = try? JSONDecoder().decode(OfflineRoutingPack.self,
                        from: Data(contentsOf: directory.appendingPathComponent("metadata.json"))),
                        directory.lastPathComponent == pack.id.uuidString,
                        FileManager.default.fileExists(atPath: directory.appendingPathComponent("tiles.tar").path) else { return nil }
                    return pack
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            logger.error("Nie udało się odczytać paczek offline: \(error.localizedDescription, privacy: .private)")
            self.error = "Nie udało się odczytać zapisanych paczek danych drogowych."
        }
    }

    func loadCatalog() async {
        guard !isLoadingCatalog else { return }
        isLoadingCatalog = true
        error = nil
        defer { isLoadingCatalog = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/librescoot/valhalla-tiles/releases/latest")!)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            struct Release: Decodable { let assets: [OfflineRoutingDownload] }
            catalog = try JSONDecoder().decode(Release.self, from: data).assets.filter {
                $0.name.hasPrefix("valhalla_tiles_") && $0.name.hasSuffix(".tar")
                    && $0.size > 0 && $0.browserDownloadURL.scheme == "https" && $0.browserDownloadURL.host == "github.com"
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch is CancellationError {}
        catch {
            logger.error("Nie udało się wczytać katalogu paczek: \(error.localizedDescription, privacy: .private)")
            self.error = "Nie udało się wczytać katalogu paczek. Sprawdź połączenie i spróbuj ponownie."
        }
    }

    func download(url: URL, name: String, motorVehiclesOnly: Bool, expectedSHA256: String? = nil) {
        guard !isInstalling, url.scheme == "https", url.host != nil else { return }
        beginTransfer(name: name)
        let token = transferID
        let delegate = OfflineRoutingTransfer { [weak self] bytes, expected in
            guard let self, self.transferID == token else { return }
            self.downloadedBytes = bytes
            self.expectedBytes = expected
        }
        transferTask = Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 120
                let (file, response) = try await URLSession.shared.download(for: request, delegate: delegate)
                defer { try? FileManager.default.removeItem(at: file) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let pack = try await OfflineRoutingEngine.shared.install(file: file, name: name,
                    motorVehiclesOnly: motorVehiclesOnly, expectedSHA256: expectedSHA256)
                refresh()
                activeID = pack.id
            } catch is CancellationError {}
            catch {
                logger.error("Nie udało się pobrać paczki danych drogowych: \(error.localizedDescription, privacy: .private)")
                if !Task.isCancelled { self.error = "Nie udało się pobrać danych drogowych. Sprawdź połączenie i dostępne miejsce, a następnie spróbuj ponownie." }
            }
            finishTransfer()
        }
    }

    func importArchive(_ file: URL, motorVehiclesOnly: Bool) {
        guard !isInstalling else { return }
        beginTransfer(name: file.deletingPathExtension().lastPathComponent)
        transferTask = Task {
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() }; finishTransfer() }
            do {
                let pack = try await OfflineRoutingEngine.shared.install(file: file,
                    name: file.deletingPathExtension().lastPathComponent, motorVehiclesOnly: motorVehiclesOnly)
                refresh()
                activeID = pack.id
            } catch is CancellationError {}
            catch {
                logger.error("Nie udało się zaimportować paczki: \(error.localizedDescription, privacy: .private)")
                self.error = "Nie udało się zaimportować paczki. Sprawdź, czy to poprawne archiwum Valhalla, i spróbuj ponownie."
            }
        }
    }

    func cancelTransfer() { transferTask?.cancel() }

    func remove(_ pack: OfflineRoutingPack) {
        guard !removingIDs.contains(pack.id) else { return }
        removingIDs.insert(pack.id)
        if activeID == pack.id { activeID = nil; preferOffline = false }
        Task {
            do {
                try await OfflineRoutingEngine.shared.remove(pack.id)
                refresh()
            } catch {
                logger.error("Nie udało się usunąć paczki offline: \(error.localizedDescription, privacy: .private)")
                self.error = "Nie udało się usunąć paczki danych drogowych."
            }
            removingIDs.remove(pack.id)
        }
    }

    private func beginTransfer(name: String) {
        error = nil
        isInstalling = true
        transferName = name
        downloadedBytes = 0
        expectedBytes = 0
        transferID = UUID()
    }
    private func finishTransfer() {
        isInstalling = false
        transferTask = nil
        transferID = nil
    }
}
#endif
