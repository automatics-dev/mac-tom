import Foundation
import SQLite3

final class StorageManager: @unchecked Sendable {

    // MARK: - Properties

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.meettom.storage", qos: .userInitiated)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let dbDirectory: URL
    let recordingsDirectory: URL

    // MARK: - Init

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        dbDirectory = home.appendingPathComponent(".tom/data/db", isDirectory: true)
        recordingsDirectory = home.appendingPathComponent(".tom/data/recordings", isDirectory: true)

        try? FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

        let dbPath = dbDirectory.appendingPathComponent("tom.db").path
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            fatalError("StorageManager: unable to open database at \(dbPath)")
        }

        createTables()
        migrateSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func createTables() {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS meeting_groups (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                icon TEXT NOT NULL DEFAULT '📁'
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                date TEXT NOT NULL,
                duration REAL NOT NULL DEFAULT 0,
                recording_path TEXT,
                transcript TEXT,
                summary TEXT,
                action_items TEXT,
                topics TEXT,
                state TEXT NOT NULL DEFAULT 'recording',
                group_id TEXT,
                kind TEXT NOT NULL DEFAULT 'meeting',
                speaker_aliases TEXT,
                title_is_custom INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (group_id) REFERENCES meeting_groups(id)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS transcript_segments (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                speaker TEXT NOT NULL,
                text TEXT NOT NULL,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS embeddings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meeting_id TEXT NOT NULL,
                chunk_text TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                start_time REAL,
                end_time REAL,
                embedding BLOB NOT NULL,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS annotations (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL,
                idx INTEGER NOT NULL,
                is_marker INTEGER NOT NULL DEFAULT 0,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                marks TEXT NOT NULL,
                screenshot_path TEXT NOT NULL,
                crop_path TEXT,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id)
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_transcript_segments_meeting_id ON transcript_segments(meeting_id);",
            "CREATE INDEX IF NOT EXISTS idx_annotations_meeting_id ON annotations(meeting_id);",
            "CREATE INDEX IF NOT EXISTS idx_embeddings_meeting_id ON embeddings(meeting_id);"
        ]

        queue.sync {
            for sql in statements {
                var errMsg: UnsafeMutablePointer<CChar>?
                if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                    let msg = errMsg.map { String(cString: $0) } ?? "unknown"
                    sqlite3_free(errMsg)
                    print("StorageManager: table creation error — \(msg)")
                }
            }
        }
    }

    private func migrateSchema() {
        queue.sync {
            let existing = columnNames(table: "meetings")
            let migrations: [(column: String, sql: String)] = [
                ("group_id",        "ALTER TABLE meetings ADD COLUMN group_id TEXT;"),
                ("kind",            "ALTER TABLE meetings ADD COLUMN kind TEXT NOT NULL DEFAULT 'meeting';"),
                ("speaker_aliases", "ALTER TABLE meetings ADD COLUMN speaker_aliases TEXT;"),
                ("title_is_custom", "ALTER TABLE meetings ADD COLUMN title_is_custom INTEGER NOT NULL DEFAULT 0;"),
            ]
            // transcript_segments: word-level timings as JSON (karaoke sync).
            let segmentColumns = columnNames(table: "transcript_segments")
            let segmentMigrations: [(column: String, sql: String)] = [
                ("words", "ALTER TABLE transcript_segments ADD COLUMN words TEXT;"),
            ]
            for (column, sql) in segmentMigrations where !segmentColumns.contains(column) {
                var errMsg: UnsafeMutablePointer<CChar>?
                if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                    let msg = errMsg.map { String(cString: $0) } ?? "unknown"
                    sqlite3_free(errMsg)
                    print("StorageManager: segment migration error — \(msg)")
                }
            }
            for (column, sql) in migrations where !existing.contains(column) {
                var errMsg: UnsafeMutablePointer<CChar>?
                if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                    let msg = errMsg.map { String(cString: $0) } ?? "unknown"
                    sqlite3_free(errMsg)
                    print("StorageManager: migration error — \(msg)")
                }
            }
        }
    }

    private func columnNames(table: String) -> Set<String> {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 1) {
                names.insert(String(cString: cstr))
            }
        }
        return names
    }

    // MARK: - Group CRUD

    func createGroup(name: String, icon: String = "folder") throws -> MeetingGroup {
        let group = MeetingGroup(name: name, icon: icon)
        try queue.sync {
            let sql = "INSERT INTO meeting_groups (id, name, icon) VALUES (?, ?, ?);"
            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            try exec(sql) { stmt in
                sqlite3_bind_text(stmt, 1, group.id.uuidString, -1, TRANSIENT)
                sqlite3_bind_text(stmt, 2, name, -1, TRANSIENT)
                sqlite3_bind_text(stmt, 3, icon, -1, TRANSIENT)
            }
        }
        return group
    }

    func fetchAllGroups() throws -> [MeetingGroup] {
        try queue.sync {
            let sql = "SELECT id, name, icon FROM meeting_groups ORDER BY name;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            var groups: [MeetingGroup] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idStr = columnText(stmt!, 0), let id = UUID(uuidString: idStr) else { continue }
                let name = columnText(stmt!, 1) ?? ""
                let icon = columnText(stmt!, 2) ?? "📁"
                groups.append(MeetingGroup(id: id, name: name, icon: icon))
            }
            return groups
        }
    }

    func updateGroup(_ group: MeetingGroup) throws {
        try queue.sync {
            let sql = "UPDATE meeting_groups SET name = ?, icon = ? WHERE id = ?;"
            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            try exec(sql) { stmt in
                sqlite3_bind_text(stmt, 1, group.name, -1, TRANSIENT)
                sqlite3_bind_text(stmt, 2, group.icon, -1, TRANSIENT)
                sqlite3_bind_text(stmt, 3, group.id.uuidString, -1, TRANSIENT)
            }
        }
    }

    func deleteGroup(id: UUID) throws {
        try queue.sync {
            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            // Unset group_id on meetings in this group
            try exec("UPDATE meetings SET group_id = NULL WHERE group_id = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, TRANSIENT)
            }
            try exec("DELETE FROM meeting_groups WHERE id = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, TRANSIENT)
            }
        }
    }

    func meetingCount(groupId: UUID?) throws -> Int {
        try queue.sync {
            let sql: String
            if groupId != nil {
                sql = "SELECT COUNT(*) FROM meetings WHERE group_id = ?;"
            } else {
                sql = "SELECT COUNT(*) FROM meetings;"
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            if let groupId {
                let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(stmt, 1, groupId.uuidString, -1, TRANSIENT)
            }

            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    // MARK: - Helpers

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func exec(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        bind?(stmt!)
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE else {
            throw StorageError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    // MARK: - Meeting CRUD

    func createMeeting(title: String, groupId: UUID? = nil, kind: MeetingKind = .meeting) throws -> Meeting {
        let meeting = Meeting(title: title, groupId: groupId, kind: kind)
        try queue.sync {
            let sql = """
                INSERT INTO meetings (id, title, date, duration, recording_path, transcript, summary, state, group_id, kind, speaker_aliases)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            try exec(sql) { stmt in
                sqlite3_bind_text(stmt, 1, meeting.id.uuidString, -1, TRANSIENT)
                sqlite3_bind_text(stmt, 2, title, -1, TRANSIENT)
                sqlite3_bind_text(stmt, 3, Self.dateFormatter.string(from: meeting.date), -1, TRANSIENT)
                sqlite3_bind_double(stmt, 4, meeting.duration)
                sqlite3_bind_text(stmt, 5, meeting.recordingPath, -1, TRANSIENT)
                sqlite3_bind_null(stmt, 6) // transcript
                sqlite3_bind_null(stmt, 7) // summary
                sqlite3_bind_text(stmt, 8, meeting.state.rawValue, -1, TRANSIENT)
                if let gid = groupId { sqlite3_bind_text(stmt, 9, gid.uuidString, -1, TRANSIENT) } else { sqlite3_bind_null(stmt, 9) }
                sqlite3_bind_text(stmt, 10, kind.rawValue, -1, TRANSIENT)
                sqlite3_bind_null(stmt, 11)  // speaker_aliases
            }
        }
        return meeting
    }

    func updateMeeting(_ meeting: Meeting) throws {
        try queue.sync {
            let sql = """
                UPDATE meetings
                SET title = ?, date = ?, duration = ?, recording_path = ?, transcript = ?,
                    summary = ?, state = ?, group_id = ?, kind = ?, speaker_aliases = ?,
                    title_is_custom = ?
                WHERE id = ?;
            """
            try exec(sql) { stmt in
                let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(stmt, 1, meeting.title, -1, TRANSIENT)
                sqlite3_bind_text(stmt, 2, Self.dateFormatter.string(from: meeting.date), -1, TRANSIENT)
                sqlite3_bind_double(stmt, 3, meeting.duration)
                sqlite3_bind_text(stmt, 4, meeting.recordingPath, -1, TRANSIENT)
                if let t = meeting.transcript { sqlite3_bind_text(stmt, 5, t, -1, TRANSIENT) } else { sqlite3_bind_null(stmt, 5) }
                if let s = meeting.summary { sqlite3_bind_text(stmt, 6, s, -1, TRANSIENT) } else { sqlite3_bind_null(stmt, 6) }
                sqlite3_bind_text(stmt, 7, meeting.state.rawValue, -1, TRANSIENT)
                if let gid = meeting.groupId { sqlite3_bind_text(stmt, 8, gid.uuidString, -1, TRANSIENT) } else { sqlite3_bind_null(stmt, 8) }
                sqlite3_bind_text(stmt, 9, meeting.kind.rawValue, -1, TRANSIENT)
                if !meeting.speakerAliases.isEmpty,
                   let json = try? JSONEncoder().encode(meeting.speakerAliases),
                   let str = String(data: json, encoding: .utf8) {
                    sqlite3_bind_text(stmt, 10, str, -1, TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 10)
                }
                sqlite3_bind_int(stmt, 11, meeting.titleIsCustom ? 1 : 0)
                sqlite3_bind_text(stmt, 12, meeting.id.uuidString, -1, TRANSIENT)
            }
        }
    }

    func fetchAllMeetings() throws -> [Meeting] {
        try queue.sync {
            let sql = "SELECT id, title, date, duration, recording_path, transcript, summary, state, group_id, kind, speaker_aliases, title_is_custom FROM meetings ORDER BY date DESC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            var meetings: [Meeting] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let meeting = try parseMeetingRow(stmt!) {
                    meetings.append(meeting)
                }
            }
            return meetings
        }
    }

    func fetchMeeting(id: UUID) throws -> Meeting? {
        try queue.sync {
            let sql = "SELECT id, title, date, duration, recording_path, transcript, summary, state, group_id, kind, speaker_aliases, title_is_custom FROM meetings WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, TRANSIENT)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return try parseMeetingRow(stmt!)
        }
    }

    func deleteMeeting(id: UUID) throws {
        try queue.sync {
            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            // Delete related data first
            try exec("DELETE FROM transcript_segments WHERE meeting_id = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, TRANSIENT)
            }
            try exec("DELETE FROM embeddings WHERE meeting_id = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, TRANSIENT)
            }
            try exec("DELETE FROM annotations WHERE meeting_id = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, TRANSIENT)
            }
            try exec("DELETE FROM meetings WHERE id = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, TRANSIENT)
            }
        }
    }

    /// Backward-compatible method used by AppState.loadMeetings().
    func loadMeetings() -> [Meeting] {
        (try? fetchAllMeetings()) ?? []
    }

    // MARK: - Transcript Segments

    /// Replaces all transcript segments for a meeting. Deletes existing rows
    /// for `meetingId` first, then inserts the new segments. This makes
    /// retranscribe a true full replacement — without the delete, fresh UUIDs
    /// on each rerun caused old rows to accumulate alongside new ones.
    func saveTranscriptSegments(_ segments: [TranscriptSegment], meetingId: UUID) throws {
        try queue.sync {
            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            try exec("DELETE FROM transcript_segments WHERE meeting_id = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, meetingId.uuidString, -1, TRANSIENT)
            }
            let sql = """
                INSERT INTO transcript_segments (id, meeting_id, start_time, end_time, speaker, text, words)
                VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            for segment in segments {
                let wordsJSON: String? = segment.words.flatMap { words in
                    (try? JSONEncoder().encode(words)).flatMap { String(data: $0, encoding: .utf8) }
                }
                try exec(sql) { stmt in
                    sqlite3_bind_text(stmt, 1, segment.id.uuidString, -1, TRANSIENT)
                    sqlite3_bind_text(stmt, 2, meetingId.uuidString, -1, TRANSIENT)
                    sqlite3_bind_double(stmt, 3, segment.startTime)
                    sqlite3_bind_double(stmt, 4, segment.endTime)
                    sqlite3_bind_text(stmt, 5, segment.speaker, -1, TRANSIENT)
                    sqlite3_bind_text(stmt, 6, segment.text, -1, TRANSIENT)
                    if let wordsJSON {
                        sqlite3_bind_text(stmt, 7, wordsJSON, -1, TRANSIENT)
                    } else {
                        sqlite3_bind_null(stmt, 7)
                    }
                }
            }
        }
    }

    func fetchTranscriptSegments(meetingId: UUID) throws -> [TranscriptSegment] {
        try queue.sync {
            let sql = "SELECT id, start_time, end_time, speaker, text, words FROM transcript_segments WHERE meeting_id = ? ORDER BY start_time;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, meetingId.uuidString, -1, TRANSIENT)

            var segments: [TranscriptSegment] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idStr = columnText(stmt!, 0), let id = UUID(uuidString: idStr) else { continue }
                let startTime = sqlite3_column_double(stmt, 1)
                let endTime = sqlite3_column_double(stmt, 2)
                let speaker = columnText(stmt!, 3) ?? ""
                let text = strippingWhisperTokens(columnText(stmt!, 4) ?? "")
                let words: [WordStamp]? = columnText(stmt!, 5)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode([WordStamp].self, from: $0) }
                segments.append(TranscriptSegment(id: id, startTime: startTime, endTime: endTime, speaker: speaker, text: text, words: words))
            }
            return segments
        }
    }

    // MARK: - Annotations (Learning sessions)

    func saveAnnotation(_ annotation: Annotation) throws {
        let marksJSON = String(data: try encoder.encode(annotation.marks), encoding: .utf8) ?? "[]"
        try queue.sync {
            let sql = """
                INSERT OR REPLACE INTO annotations
                (id, meeting_id, idx, is_marker, start_time, end_time, marks, screenshot_path, crop_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            try exec(sql) { stmt in
                sqlite3_bind_text(stmt, 1, annotation.id.uuidString, -1, TRANSIENT)
                sqlite3_bind_text(stmt, 2, annotation.meetingId.uuidString, -1, TRANSIENT)
                sqlite3_bind_int(stmt, 3, Int32(annotation.index))
                sqlite3_bind_int(stmt, 4, annotation.isMarker ? 1 : 0)
                sqlite3_bind_double(stmt, 5, annotation.startTime)
                sqlite3_bind_double(stmt, 6, annotation.endTime)
                sqlite3_bind_text(stmt, 7, marksJSON, -1, TRANSIENT)
                sqlite3_bind_text(stmt, 8, annotation.screenshotPath, -1, TRANSIENT)
                if let crop = annotation.cropPath {
                    sqlite3_bind_text(stmt, 9, crop, -1, TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 9)
                }
            }
        }
    }

    func fetchAnnotations(meetingId: UUID) throws -> [Annotation] {
        try queue.sync {
            let sql = """
                SELECT id, idx, is_marker, start_time, end_time, marks, screenshot_path, crop_path
                FROM annotations WHERE meeting_id = ? ORDER BY start_time;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, meetingId.uuidString, -1, TRANSIENT)

            var annotations: [Annotation] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idStr = columnText(stmt!, 0), let id = UUID(uuidString: idStr) else { continue }
                let marks = columnText(stmt!, 5)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? decoder.decode([AnnotationMark].self, from: $0) } ?? []
                annotations.append(Annotation(
                    id: id,
                    meetingId: meetingId,
                    index: Int(sqlite3_column_int(stmt, 1)),
                    isMarker: sqlite3_column_int(stmt, 2) != 0,
                    startTime: sqlite3_column_double(stmt, 3),
                    endTime: sqlite3_column_double(stmt, 4),
                    marks: marks,
                    screenshotPath: columnText(stmt!, 6) ?? "",
                    cropPath: columnText(stmt!, 7)
                ))
            }
            return annotations
        }
    }

    // MARK: - Embeddings

    /// Deletes every embedding row for a meeting. Call before re-embedding to
    /// avoid stale chunks from previous transcripts polluting search.
    func deleteEmbeddings(meetingId: UUID) throws {
        try queue.sync {
            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            try exec("DELETE FROM embeddings WHERE meeting_id = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, meetingId.uuidString, -1, TRANSIENT)
            }
        }
    }

    func saveEmbedding(meetingId: UUID, chunkText: String, chunkIndex: Int, startTime: Double?, endTime: Double?, embedding: [Float]) throws {
        try queue.sync {
            let sql = """
                INSERT INTO embeddings (meeting_id, chunk_text, chunk_index, start_time, end_time, embedding)
                VALUES (?, ?, ?, ?, ?, ?);
            """
            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            try exec(sql) { stmt in
                sqlite3_bind_text(stmt, 1, meetingId.uuidString, -1, TRANSIENT)
                sqlite3_bind_text(stmt, 2, chunkText, -1, TRANSIENT)
                sqlite3_bind_int(stmt, 3, Int32(chunkIndex))
                if let s = startTime { sqlite3_bind_double(stmt, 4, s) } else { sqlite3_bind_null(stmt, 4) }
                if let e = endTime { sqlite3_bind_double(stmt, 5, e) } else { sqlite3_bind_null(stmt, 5) }
                // Store raw float bytes
                _ = embedding.withUnsafeBufferPointer { buf in
                    sqlite3_bind_blob(stmt, 6, buf.baseAddress, Int32(buf.count * MemoryLayout<Float>.size), TRANSIENT)
                }
            }
        }
    }

    /// Brute-force cosine search over all stored chunks. When `meetingIds` is
    /// non-nil, only chunks from those meetings are considered — this scopes RAG
    /// to the selected sidebar group (nil = "All Meetings" = search everything).
    /// An empty set therefore returns no results, which is the correct answer for
    /// an empty group.
    func searchSimilar(queryEmbedding: [Float], limit: Int, meetingIds: Set<UUID>? = nil) throws -> [(chunkText: String, meetingId: UUID, distance: Float)] {
        try queue.sync {
            let sql = "SELECT meeting_id, chunk_text, embedding FROM embeddings;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StorageError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            var results: [(chunkText: String, meetingId: UUID, distance: Float)] = []
            var rowsSeen = 0
            var rowsKept = 0
            var rowsFiltered = 0
            var seenMeetingIds = Set<UUID>()

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let meetingIdStr = columnText(stmt!, 0),
                      let meetingId = UUID(uuidString: meetingIdStr),
                      let chunkText = columnText(stmt!, 1) else { continue }

                rowsSeen += 1
                seenMeetingIds.insert(meetingId)

                if let meetingIds, !meetingIds.contains(meetingId) {
                    rowsFiltered += 1
                    continue
                }
                rowsKept += 1

                let blobPtr = sqlite3_column_blob(stmt, 2)
                let blobSize = Int(sqlite3_column_bytes(stmt, 2))
                let floatCount = blobSize / MemoryLayout<Float>.size

                guard let blobPtr, floatCount == queryEmbedding.count else { continue }

                let embeddingPtr = blobPtr.assumingMemoryBound(to: Float.self)
                let distance = simdCosineDistance(queryEmbedding, UnsafeBufferPointer(start: embeddingPtr, count: floatCount))
                results.append((chunkText: chunkText, meetingId: meetingId, distance: distance))
            }

            results.sort { $0.distance < $1.distance }

            let scopeDesc: String
            if let meetingIds {
                let overlap = meetingIds.intersection(seenMeetingIds).count
                scopeDesc = "scoped to \(meetingIds.count) meeting(s), \(overlap) of which have embeddings"
            } else {
                scopeDesc = "all meetings"
            }
            tomLog("searchSimilar: \(scopeDesc); embeddings table holds \(rowsSeen) chunks across \(seenMeetingIds.count) meeting(s); kept \(rowsKept), filtered out \(rowsFiltered); returning \(min(results.count, limit))")

            return Array(results.prefix(limit))
        }
    }

    // MARK: - Row Parsing

    private func parseMeetingRow(_ stmt: OpaquePointer) throws -> Meeting? {
        guard let idStr = columnText(stmt, 0), let id = UUID(uuidString: idStr) else { return nil }
        let title = columnText(stmt, 1) ?? ""
        let dateStr = columnText(stmt, 2) ?? ""
        let date = Self.dateFormatter.date(from: dateStr) ?? Date()
        let duration = sqlite3_column_double(stmt, 3)
        let recordingPath = columnText(stmt, 4) ?? ""
        let transcript = columnText(stmt, 5).map(strippingWhisperTokens)
        let summary = columnText(stmt, 6)

        let stateStr = columnText(stmt, 7) ?? "recording"
        let state = MeetingState(rawValue: stateStr) ?? .recording
        let groupId: UUID? = columnText(stmt, 8).flatMap { UUID(uuidString: $0) }
        let kindStr = columnText(stmt, 9) ?? "meeting"
        let kind = MeetingKind(rawValue: kindStr) ?? .meeting

        var speakerAliases: [String: String] = [:]
        if let json = columnText(stmt, 10), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            speakerAliases = decoded
        }
        let titleIsCustom = sqlite3_column_int(stmt, 11) != 0

        return Meeting(
            id: id,
            title: title,
            date: date,
            duration: duration,
            recordingPath: recordingPath,
            transcript: transcript,
            summary: summary,
            state: state,
            groupId: groupId,
            kind: kind,
            speakerAliases: speakerAliases,
            titleIsCustom: titleIsCustom
        )
    }
}

// MARK: - Whisper Token Cleanup

/// Strips Whisper's structural and timestamp control tokens from text loaded
/// out of the transcript columns. New transcriptions clean tokens at write
/// time, but meetings recorded before that fix shipped have raw tokens
/// persisted in the DB. Cleaning at read time means existing rows render
/// cleanly without a destructive SQL migration. Runs on every read but the
/// regex is cheap and transcripts are bounded.
func strippingWhisperTokens(_ text: String) -> String {
    let withoutTokens = text.replacingOccurrences(
        of: #"<\|[^|<>]*\|>"#,
        with: " ",
        options: .regularExpression
    )
    let collapsed = withoutTokens.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    )
    return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Errors

enum StorageError: LocalizedError {
    case prepareFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .prepareFailed(let msg): return "SQLite prepare failed: \(msg)"
        case .stepFailed(let msg): return "SQLite step failed: \(msg)"
        }
    }
}
