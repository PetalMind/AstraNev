import Foundation
import Testing
@testable import NaviAstra

/// End-to-end durability regressions; these cover process loss and partial writes.
@MainActor
struct HistoryPersistenceCriticalTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-critical-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func trip(start: Date = Date().addingTimeInterval(-120), arrived: Bool = true) -> TripRecord {
        TripRecord(destination: Destination(name: "Cel", coordinate: Coordinate(latitude: 52, longitude: 21)),
            startedAt: start, endedAt: start.addingTimeInterval(60), distanceMeters: 500,
            movingSeconds: 50, rerouteCount: 0, arrived: arrived, transportMode: .car,
            measuredStoppedSeconds: 10, terminationReason: arrived ? .completed : .userStopped)
    }

    @Test func corruptArchiveRemainsUnchangedWhileNewJourneysStayDurable() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = url.appendingPathComponent("trips.json")
        let original = Data("unreadable-history".utf8)
        try original.write(to: archive)
        let store = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        let finished = trip()
        #expect(!store.addTrip(finished))
        #expect(try Data(contentsOf: archive) == original)
        #expect(store.trips.map(\.id) == [finished.id])
        let reloaded = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        #expect(reloaded.trips.map(\.id) == [finished.id])
        #expect(try Data(contentsOf: archive) == original)
        #expect(reloaded.errorMessage != nil)
    }

    @Test func partialRecoveryPreservesOriginalBeforeAcceptingAnotherJourney() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let valid = trip()
        let goodJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
        var invalidMeasurements = try #require(goodJSON as? [String: Any])
        invalidMeasurements["id"] = UUID().uuidString
        invalidMeasurements["distanceMeters"] = -1
        let original = try JSONSerialization.data(withJSONObject: [goodJSON, ["id": UUID().uuidString], invalidMeasurements])
        try original.write(to: url.appendingPathComponent("trips.json"))
        let store = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        #expect(store.trips.map(\.id) == [valid.id])
        let next = trip()
        #expect(store.addTrip(next))
        let backups = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("trips-recovery-") }
        #expect(try backups.contains { try Data(contentsOf: $0) == original })
        let reloaded = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        #expect(Set(reloaded.trips.map(\.id)) == [valid.id, next.id])
    }

    @Test func activeCheckpointRecoversOnceAndUnreadableCheckpointIsPreserved() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        var checkpoint = trip(arrived: false)
        checkpoint.terminationReason = nil
        #expect(store.saveActiveTrip(checkpoint))
        let firstLaunch = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        let recovered = try #require(firstLaunch.trips.first)
        #expect(recovered.id == checkpoint.id)
        #expect(recovered.endedAt == checkpoint.endedAt)
        #expect(recovered.terminationReason == .interruptedRecovered)
        #expect(!recovered.arrived)
        #expect(LocalDataStore(directory: url, removeLearningTrip: { _ in true }).trips.count == 1)

        let unreadable = Data("unreadable-checkpoint".utf8)
        try unreadable.write(to: url.appendingPathComponent("active-trip.json"))
        let nextLaunch = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        #expect(nextLaunch.saveActiveTrip(trip(arrived: false)))
        let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        #expect(try files.filter { $0.lastPathComponent.hasPrefix("history-journal-recovery-") }
            .contains { try Data(contentsOf: $0) == unreadable })
    }

    @Test func failedFinalSaveThenNewSessionDoesNotLoseOrReclassifyCompletedJourney() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        let first = trip()
        var checkpoint = first
        checkpoint.arrived = false
        checkpoint.terminationReason = nil
        #expect(store.saveActiveTrip(checkpoint))
        // A directory at the archive path creates a real atomic-write failure.
        let archive = url.appendingPathComponent("trips.json")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        #expect(!store.addTrip(first))
        let second = trip(start: first.endedAt.addingTimeInterval(60), arrived: false)
        #expect(store.saveActiveTrip(second))
        try FileManager.default.removeItem(at: archive)
        let reloaded = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        #expect(reloaded.trips.count == 2)
        let completed = try #require(reloaded.trips.first { $0.id == first.id })
        #expect(completed.arrived)
        #expect(completed.terminationReason == .completed)
        #expect(reloaded.trips.first { $0.id == second.id }?.terminationReason == .interruptedRecovered)
    }

    @Test func deletionIntentSurvivesLearningFailureAndRetriesAfterRelaunch() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        var allowLearningRemoval = false
        var attempts: [UUID] = []
        let remove: (UUID) -> Bool = { id in attempts.append(id); return allowLearningRemoval }
        let store = LocalDataStore(directory: url, removeLearningTrip: remove)
        let finished = trip()
        #expect(store.addTrip(finished))
        let revision = store.historyRevision
        #expect(store.removeTrip(finished.id))
        #expect(store.trips.isEmpty)
        #expect(store.historyRevision > revision)
        let tombstonesURL = url.appendingPathComponent("trip-deletions.json")
        #expect(try JSONDecoder().decode(Set<UUID>.self, from: Data(contentsOf: tombstonesURL)) == [finished.id])
        let reloaded = LocalDataStore(directory: url, removeLearningTrip: remove)
        #expect(reloaded.trips.isEmpty)
        allowLearningRemoval = true
        reloaded.retryPendingHistoryWrites()
        #expect(attempts.filter { $0 == finished.id }.count >= 3)
        #expect(try JSONDecoder().decode(Set<UUID>.self, from: Data(contentsOf: tombstonesURL)).isEmpty)
        #expect(LocalDataStore(directory: url, removeLearningTrip: remove).trips.isEmpty)
    }

    @Test func activeCleanupFailureNeverReclassifiesAlreadyCommittedJourney() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        let completed = trip()
        var checkpoint = completed
        checkpoint.arrived = false
        checkpoint.terminationReason = nil
        #expect(store.saveActiveTrip(checkpoint))
        let activeURL = url.appendingPathComponent("active-trip.json")
        try FileManager.default.removeItem(at: activeURL)
        try FileManager.default.createDirectory(at: activeURL, withIntermediateDirectories: true)
        try Data("block".utf8).write(to: activeURL.appendingPathComponent("child"))
        #expect(!store.addTrip(completed))
        #expect(store.trips.first?.arrived == true)
        try FileManager.default.removeItem(at: activeURL)
        let next = trip(start: completed.endedAt.addingTimeInterval(60), arrived: false)
        #expect(store.saveActiveTrip(next))
        store.retryPendingHistoryWrites()
        let reloaded = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        #expect(reloaded.trips.first { $0.id == completed.id }?.terminationReason == .completed)
        #expect(reloaded.trips.first { $0.id == completed.id }?.arrived == true)
        #expect(reloaded.trips.first { $0.id == next.id }?.terminationReason == .interruptedRecovered)
    }

    @Test func unreadableDeletionJournalCannotOverwritePreviousActiveCheckpoint() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let initial = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        let first = trip(arrived: false)
        #expect(initial.saveActiveTrip(first))
        let activeURL = url.appendingPathComponent("active-trip.json")
        let savedCheckpoint = try Data(contentsOf: activeURL)
        let deletionsURL = url.appendingPathComponent("trip-deletions.json")
        let unreadable = Data("unreadable-deletions".utf8)
        try unreadable.write(to: deletionsURL)
        let blocked = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        let second = trip(start: first.endedAt.addingTimeInterval(60), arrived: false)
        #expect(blocked.saveActiveTrip(second))
        #expect(try Data(contentsOf: activeURL) == savedCheckpoint)
        #expect(try Data(contentsOf: deletionsURL) == unreadable)
        // Once the deletion journal is recovered, both isolated checkpoints are safe.
        try JSONEncoder().encode(Set<UUID>()).write(to: deletionsURL)
        let recovered = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        #expect(Set(recovered.trips.map(\.id)) == [first.id, second.id])
        #expect(recovered.trips.allSatisfy { $0.terminationReason == .interruptedRecovered })
    }

    @Test func expiringLegacyGeometryPreservesFuelDistanceAcrossFillBoundary() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date().addingTimeInterval(-366 * 86_400)
        let origin = Coordinate(latitude: 52, longitude: 21)
        let end = Coordinate(latitude: 52.0009, longitude: 21)
        var old = trip(start: start)
        old.endedAt = start.addingTimeInterval(20)
        old.distanceMeters = origin.distance(to: end)
        old.movingSeconds = 20
        old.measuredStoppedSeconds = nil
        old.trace = [
            TripTracePoint(coordinate: origin, timestamp: start, speedKph: 20, startsSegment: true),
            TripTracePoint(coordinate: end, timestamp: old.endedAt, speedKph: 20, startsSegment: false)
        ]
        let from = start.addingTimeInterval(10)
        let to = old.endedAt.addingTimeInterval(10)
        let before = try #require(EnergyCalculator.recordedKilometers(old, from: from, to: to))
        let store = LocalDataStore(directory: url, removeLearningTrip: { _ in true })
        #expect(store.addTrip(old))
        let retained = try #require(store.trips.first)
        #expect(retained.trace.isEmpty)
        #expect(retained.traceUnavailableReason == .retention)
        #expect(retained.distanceSamples.count == 1)
        let after = try #require(EnergyCalculator.recordedKilometers(retained, from: from, to: to))
        #expect(abs(before - after) < 0.000001)
        let reloaded = try #require(LocalDataStore(directory: url, removeLearningTrip: { _ in true }).trips.first)
        #expect(reloaded.distanceSamples.count == 1)
    }
}
