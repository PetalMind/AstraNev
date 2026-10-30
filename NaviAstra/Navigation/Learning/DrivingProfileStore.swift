import Foundation
import SQLite3

nonisolated struct PendingDrivingTrip: Codable, Sendable, Identifiable {
    let id: UUID
    let destinationName: String
    let destination: Coordinate
    let startedAt: Date
    let duration: TimeInterval
    let context: DrivingPreferenceContext
    let trace: [TripTracePoint]
    let proposedCoordinates: [Coordinate]
    let costing: String
    var confirmed: Bool
    var allowAutomaticDeviations: Bool
    var offeredVariants: [DrivingOfferedVariant] = []
    var selectedVariantID: String? = nil
    var selectedAgainstAlternative = false
    var proposedVariantID: String? = nil
}

nonisolated struct DrivingProfileSnapshot: Codable, Sendable {
    var settings = DrivingLearningSettings()
    var trips: [LearnedDrivingTrip] = []
    var pending: [PendingDrivingTrip] = []
    var ignoredTripIDs: Set<UUID> = []
    var ignoredRoadIDs: Set<String> = []
    var ignoredShortcutIDs: Set<String> = []
    var ignoredApproachIDs: Set<UUID> = []
    var evidence: [PreferenceEvidence] = []
    var schemaVersion = 3
    // One-time recovery of observations rejected by the old all-or-nothing GPS rule.
    // Fresh and explicitly reset profiles must not import old history.
    var historyRecoveryVersion = 1
}

extension DrivingProfileSnapshot {
    nonisolated enum CodingKeys: String, CodingKey {
        case settings, trips, pending, ignoredTripIDs, ignoredRoadIDs, ignoredShortcutIDs, ignoredApproachIDs, evidence, schemaVersion, historyRecoveryVersion
    }

    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        settings = try values.decodeIfPresent(DrivingLearningSettings.self, forKey: .settings) ?? .init()
        trips = try values.decodeIfPresent([LearnedDrivingTrip].self, forKey: .trips) ?? []
        pending = try values.decodeIfPresent([PendingDrivingTrip].self, forKey: .pending) ?? []
        ignoredTripIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .ignoredTripIDs) ?? []
        ignoredRoadIDs = try values.decodeIfPresent(Set<String>.self, forKey: .ignoredRoadIDs) ?? []
        ignoredShortcutIDs = try values.decodeIfPresent(Set<String>.self, forKey: .ignoredShortcutIDs) ?? []
        ignoredApproachIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .ignoredApproachIDs) ?? []
        evidence = try values.decodeIfPresent([PreferenceEvidence].self, forKey: .evidence) ?? []
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        historyRecoveryVersion = try values.decodeIfPresent(Int.self, forKey: .historyRecoveryVersion) ?? 0
    }
}

/// One atomic SQLite transaction commits history and settings together. GPS is
/// retained in a bounded pending queue; learned observations store road edges or
/// explicitly marked local geometry when no offline graph is installed.
struct DrivingProfileStore {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DrivingLearning/NavigationLearning.sqlite")
    }

    func load() throws -> DrivingProfileSnapshot {
        try withDatabase { db in
            var snapshot = DrivingProfileSnapshot()
            try rows(db, sql: "SELECT payload FROM learning_state WHERE id = 1") { data in
                snapshot = try JSONDecoder().decode(DrivingProfileSnapshot.self, from: data)
            }
            try rows(db, sql: "SELECT payload FROM trip_history ORDER BY started_at DESC LIMIT 300") { data in
                snapshot.trips.append(try JSONDecoder().decode(LearnedDrivingTrip.self, from: data))
            }
            try rows(db, sql: "SELECT payload FROM preference_evidence ORDER BY timestamp, id") { data in
                snapshot.evidence.append(try JSONDecoder().decode(PreferenceEvidence.self, from: data))
            }
            return snapshot
        }
    }

    func save(_ snapshot: DrivingProfileSnapshot) throws {
        try withDatabase { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try execute(db, "DELETE FROM trip_history")
                for trip in snapshot.trips {
                    try insert(db, sql: "INSERT INTO trip_history(id, started_at, payload) VALUES (?, ?, ?)",
                        id: trip.id.uuidString, date: trip.startedAt.timeIntervalSince1970,
                        data: JSONEncoder().encode(trip))
                }
                var state = snapshot
                state.trips = []
                state.evidence = []
                try execute(db, "DELETE FROM preference_evidence")
                for item in snapshot.evidence {
                    try insert(db, sql: "INSERT INTO preference_evidence(id, timestamp, payload) VALUES (?, ?, ?)",
                        id: item.id.uuidString, date: item.timestamp.timeIntervalSince1970, data: JSONEncoder().encode(item))
                }
                try insert(db, sql: "INSERT OR REPLACE INTO learning_state(id, started_at, payload) VALUES (?, ?, ?)",
                           id: "1", date: Date().timeIntervalSince1970, data: JSONEncoder().encode(state))
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    private func withDatabase<T>(_ work: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw DrivingLearningFailure.storage
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)
        try execute(db, "PRAGMA secure_delete = ON")
        try execute(db, "CREATE TABLE IF NOT EXISTS trip_history(id TEXT PRIMARY KEY, started_at REAL NOT NULL, payload BLOB NOT NULL)")
        try execute(db, "CREATE TABLE IF NOT EXISTS learning_state(id INTEGER PRIMARY KEY, started_at REAL NOT NULL, payload BLOB NOT NULL)")
        try execute(db, "CREATE TABLE IF NOT EXISTS preference_evidence(id TEXT PRIMARY KEY, timestamp REAL NOT NULL, payload BLOB NOT NULL)")
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                             ofItemAtPath: url.path)
        #endif
        return try work(db)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DrivingLearningFailure.storage }
    }

    func databaseBytes() -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber else { return nil }
            total += size.int64Value
        }
        return total
    }

    private func insert(_ db: OpaquePointer, sql: String, id: String, date: Double, data: Data) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DrivingLearningFailure.storage
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, id, -1, transient) == SQLITE_OK,
              sqlite3_bind_double(statement, 2, date) == SQLITE_OK else { throw DrivingLearningFailure.storage }
        let bound = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), transient)
        }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw DrivingLearningFailure.storage }
    }

    private func rows(_ db: OpaquePointer, sql: String, consume: (Data) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DrivingLearningFailure.storage
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
                throw DrivingLearningFailure.storage
            }
            try consume(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        }
    }
}
