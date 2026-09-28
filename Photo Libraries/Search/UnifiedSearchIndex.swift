import Foundation
import SQLite3

nonisolated enum UnifiedSearchIndexError: LocalizedError, Sendable {
    case applicationSupportUnavailable
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Application Support is unavailable for the search index."
        case .sqlite(let message):
            "Search index error: \(message)"
        }
    }
}

actor UnifiedSearchIndex {
    private nonisolated static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private var database: OpaquePointer?

    init() throws {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw UnifiedSearchIndexError.applicationSupportUnavailable
        }
        let directory = applicationSupport
            .appendingPathComponent("Photo Libraries", isDirectory: true)
            .appendingPathComponent("Search Index", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("search.sqlite3", isDirectory: false)
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Could not open search.sqlite3."
            sqlite3_close(database)
            database = nil
            throw UnifiedSearchIndexError.sqlite(message)
        }
        guard let database else {
            throw UnifiedSearchIndexError.sqlite("Database is closed.")
        }
        try Self.execute("PRAGMA journal_mode=WAL", on: database)
        try Self.execute("PRAGMA synchronous=NORMAL", on: database)
        let schemaVersion = try Self.scalarInt("PRAGMA user_version", on: database)
        if schemaVersion != 1 {
            // This database is a disposable derivative of public PhotoKit and
            // app-owned manifests. Rebuild it instead of risking a partial
            // migration when the search schema changes.
            try Self.execute("DROP TABLE IF EXISTS search_documents_fts", on: database)
            try Self.execute("DROP TABLE IF EXISTS search_documents", on: database)
        }
        try Self.execute("""
            CREATE TABLE IF NOT EXISTS search_documents (
                id TEXT PRIMARY KEY NOT NULL,
                library_id TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                library_name TEXT NOT NULL,
                source TEXT NOT NULL,
                filename TEXT NOT NULL,
                display_name TEXT NOT NULL,
                caption TEXT NOT NULL,
                keywords TEXT NOT NULL,
                raw_location TEXT NOT NULL,
                place_name TEXT NOT NULL,
                city TEXT NOT NULL,
                country TEXT NOT NULL,
                formatted_address TEXT NOT NULL,
                capture_date REAL,
                date_description TEXT NOT NULL,
                favorite INTEGER NOT NULL,
                pixel_width INTEGER NOT NULL,
                pixel_height INTEGER NOT NULL,
                media_type TEXT NOT NULL,
                latitude REAL,
                longitude REAL,
                normalized_text TEXT NOT NULL,
                library_search TEXT NOT NULL,
                city_search TEXT NOT NULL,
                country_search TEXT NOT NULL,
                place_search TEXT NOT NULL
            )
            """, on: database)
        try Self.execute("PRAGMA user_version=1", on: database)
        try Self.execute(
            "CREATE INDEX IF NOT EXISTS search_documents_library ON search_documents(library_id)",
            on: database
        )
        try Self.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS search_documents_fts USING fts5(
                document_id UNINDEXED,
                normalized_text,
                tokenize='unicode61 remove_diacritics 2'
            )
            """, on: database)
    }

    deinit {
        sqlite3_close(database)
    }

    /// Reconcile a fresh catalog with the on-disk search data. Return the
    /// documents with previously resolved places restored for the UI.
    func replaceLibrary(
        _ documents: [UnifiedSearchDocument], libraryID: LibraryID
    ) throws -> [UnifiedSearchDocument] {
        var indexedDocuments: [UnifiedSearchDocument] = []
        indexedDocuments.reserveCapacity(documents.count)
        try transaction {
            var existingByID = try existingDocuments(for: libraryID)
            for var document in documents {
                let existing = existingByID.removeValue(forKey: document.id)
                if let existing, existing.coordinate == document.coordinate {
                    document.place = existing.place
                }
                if existing.map({ !sameSearchContent($0, document) }) ?? true {
                    try upsertWithoutTransaction(document)
                }
                indexedDocuments.append(document)
            }
            for identifier in existingByID.keys {
                try deleteDocument(identifier)
            }
        }
        return indexedDocuments
    }

    func upsert(_ document: UnifiedSearchDocument) throws {
        try transaction {
            try upsertWithoutTransaction(document)
        }
    }

    func removeLibrary(_ libraryID: LibraryID) throws {
        try transaction {
            try deleteLibrary(libraryID)
        }
    }

    func updatePlace(documentID: String, place: SearchPlace) throws {
        guard var document = try document(id: documentID) else { return }
        document.place = place
        try upsert(document)
    }

    func search(_ query: ParsedSearchQuery) throws -> [UnifiedSearchDocument] {
        guard !query.isEmpty else { return [] }
        var sql = "SELECT d.* FROM search_documents d"
        var conditions: [String] = []
        var bindings: [SQLiteBinding] = []

        if !query.freeText.isEmpty {
            sql += " JOIN search_documents_fts f ON f.document_id = d.id"
            conditions.append("f.normalized_text MATCH ?")
            bindings.append(.text(ftsQuery(query.freeText)))
        }
        if let favorite = query.favorite {
            conditions.append("d.favorite = ?")
            bindings.append(.integer(favorite ? 1 : 0))
        }
        append(query.width, column: "d.pixel_width", conditions: &conditions, bindings: &bindings)
        append(query.height, column: "d.pixel_height", conditions: &conditions, bindings: &bindings)
        if let width = query.exactWidth {
            conditions.append("d.pixel_width = ?")
            bindings.append(.integer(Int64(width)))
        }
        if let height = query.exactHeight {
            conditions.append("d.pixel_height = ?")
            bindings.append(.integer(Int64(height)))
        }
        appendLike(query.mediaType, column: "d.media_type", conditions: &conditions, bindings: &bindings)
        appendLike(query.library, column: "d.library_search", conditions: &conditions, bindings: &bindings)
        appendLike(query.city, column: "d.city_search", conditions: &conditions, bindings: &bindings)
        appendLike(query.country, column: "d.country_search", conditions: &conditions, bindings: &bindings)
        if let place = query.place {
            conditions.append("(d.place_search LIKE ? OR d.raw_location LIKE ?)")
            let pattern = "%\(place)%"
            bindings.append(contentsOf: [.text(pattern), .text(pattern)])
        }
        if let start = query.dateStart {
            conditions.append("d.capture_date >= ?")
            bindings.append(.double(start.timeIntervalSince1970))
        }
        if let end = query.dateEnd {
            conditions.append("d.capture_date < ?")
            bindings.append(.double(end.timeIntervalSince1970))
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY d.capture_date DESC, d.library_name, d.filename"

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var results: [UnifiedSearchDocument] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(document(from: statement))
        }
        try checkLastStep(statement)
        return results
    }
}

private extension UnifiedSearchIndex {
    enum SQLiteBinding {
        case text(String)
        case integer(Int64)
        case double(Double)
    }

    func execute(_ sql: String) throws {
        guard let database else { throw UnifiedSearchIndexError.sqlite("Database is closed.") }
        try Self.execute(sql, on: database)
    }

    nonisolated static func execute(_ sql: String, on database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw UnifiedSearchIndexError.sqlite(message)
        }
    }

    nonisolated static func scalarInt(_ sql: String, on database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw UnifiedSearchIndexError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UnifiedSearchIndexError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try operation()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw UnifiedSearchIndexError.sqlite("Database is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw UnifiedSearchIndexError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                result = sqlite3_bind_double(statement, index, value)
            }
            guard result == SQLITE_OK else {
                throw UnifiedSearchIndexError.sqlite(errorMessage)
            }
        }
    }

    var errorMessage: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed."
    }

    func checkLastStep(_ statement: OpaquePointer) throws {
        let result = sqlite3_errcode(database)
        guard result == SQLITE_OK || result == SQLITE_DONE || result == SQLITE_ROW else {
            throw UnifiedSearchIndexError.sqlite(errorMessage)
        }
    }

    func deleteLibrary(_ libraryID: LibraryID) throws {
        let select = try prepare("SELECT id FROM search_documents WHERE library_id = ?")
        defer { sqlite3_finalize(select) }
        try bind([.text(libraryID.rawValue.uuidString)], to: select)
        var identifiers: [String] = []
        while sqlite3_step(select) == SQLITE_ROW {
            identifiers.append(text(select, column: 0))
        }
        for identifier in identifiers {
            try deleteFTS(identifier)
        }
        let delete = try prepare("DELETE FROM search_documents WHERE library_id = ?")
        defer { sqlite3_finalize(delete) }
        try bind([.text(libraryID.rawValue.uuidString)], to: delete)
        guard sqlite3_step(delete) == SQLITE_DONE else {
            throw UnifiedSearchIndexError.sqlite(errorMessage)
        }
    }

    func existingDocuments(for libraryID: LibraryID) throws -> [String: UnifiedSearchDocument] {
        let statement = try prepare("SELECT * FROM search_documents WHERE library_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.text(libraryID.rawValue.uuidString)], to: statement)
        var documents: [String: UnifiedSearchDocument] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let item = document(from: statement)
            documents[item.id] = item
        }
        try checkLastStep(statement)
        return documents
    }

    func sameSearchContent(
        _ left: UnifiedSearchDocument, _ right: UnifiedSearchDocument
    ) -> Bool {
        let sameDate: Bool
        switch (left.captureDate, right.captureDate) {
        case (nil, nil): sameDate = true
        case (let first?, let second?):
            sameDate = abs(first.timeIntervalSince1970 - second.timeIntervalSince1970) < 0.001
        default: sameDate = false
        }
        return left.id == right.id
            && left.libraryID == right.libraryID
            && left.assetID == right.assetID
            && left.libraryName == right.libraryName
            && left.source == right.source
            && left.filename == right.filename
            && left.displayName == right.displayName
            && left.caption == right.caption
            && left.keywords == right.keywords
            && left.rawLocation == right.rawLocation
            && left.place == right.place
            && sameDate
            && left.dateDescription == right.dateDescription
            && left.isFavorite == right.isFavorite
            && left.pixelWidth == right.pixelWidth
            && left.pixelHeight == right.pixelHeight
            && left.mediaType == right.mediaType
            && left.coordinate == right.coordinate
    }

    func deleteDocument(_ identifier: String) throws {
        try deleteFTS(identifier)
        let statement = try prepare("DELETE FROM search_documents WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.text(identifier)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw UnifiedSearchIndexError.sqlite(errorMessage)
        }
    }

    func upsertWithoutTransaction(_ document: UnifiedSearchDocument) throws {
        let sql = """
            INSERT INTO search_documents (
                id, library_id, asset_id, library_name, source, filename,
                display_name, caption, keywords, raw_location, place_name,
                city, country, formatted_address, capture_date,
                date_description, favorite, pixel_width, pixel_height,
                media_type, latitude, longitude, normalized_text,
                library_search, city_search, country_search, place_search
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                library_id=excluded.library_id, asset_id=excluded.asset_id,
                library_name=excluded.library_name, source=excluded.source,
                filename=excluded.filename, display_name=excluded.display_name,
                caption=excluded.caption, keywords=excluded.keywords,
                raw_location=excluded.raw_location,
                place_name=excluded.place_name, city=excluded.city,
                country=excluded.country,
                formatted_address=excluded.formatted_address,
                capture_date=excluded.capture_date,
                date_description=excluded.date_description,
                favorite=excluded.favorite, pixel_width=excluded.pixel_width,
                pixel_height=excluded.pixel_height, media_type=excluded.media_type,
                latitude=excluded.latitude, longitude=excluded.longitude,
                normalized_text=excluded.normalized_text,
                library_search=excluded.library_search,
                city_search=excluded.city_search,
                country_search=excluded.country_search,
                place_search=excluded.place_search
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let place = document.place
        let bindings: [SQLiteBinding?] = [
            .text(document.id), .text(document.libraryID.rawValue.uuidString),
            .text(document.assetID), .text(document.libraryName),
            .text(document.source.rawValue), .text(document.filename),
            .text(document.displayName), .text(document.caption),
            .text(document.keywords.joined(separator: "\u{001F}")),
            .text(document.rawLocation), .text(place?.name ?? ""),
            .text(place?.city ?? ""), .text(place?.country ?? ""),
            .text(place?.formattedAddress ?? ""),
            document.captureDate.map { .double($0.timeIntervalSince1970) },
            .text(document.dateDescription), .integer(document.isFavorite ? 1 : 0),
            .integer(Int64(document.pixelWidth)), .integer(Int64(document.pixelHeight)),
            .text(document.mediaType), document.coordinate.map { .double($0.latitude) },
            document.coordinate.map { .double($0.longitude) },
            .text(document.normalizedSearchText),
            .text(SearchTextNormalizer.normalize(document.libraryName)),
            .text(SearchTextNormalizer.normalize(place?.city ?? "")),
            .text(SearchTextNormalizer.normalize(place?.country ?? "")),
            .text(SearchTextNormalizer.normalize(place?.searchableText ?? document.rawLocation))
        ]
        try bindNullable(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw UnifiedSearchIndexError.sqlite(errorMessage)
        }
        try deleteFTS(document.id)
        let fts = try prepare(
            "INSERT INTO search_documents_fts(document_id, normalized_text) VALUES (?,?)"
        )
        defer { sqlite3_finalize(fts) }
        try bind([.text(document.id), .text(document.normalizedSearchText)], to: fts)
        guard sqlite3_step(fts) == SQLITE_DONE else {
            throw UnifiedSearchIndexError.sqlite(errorMessage)
        }
    }

    func deleteFTS(_ documentID: String) throws {
        let statement = try prepare("DELETE FROM search_documents_fts WHERE document_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.text(documentID)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw UnifiedSearchIndexError.sqlite(errorMessage)
        }
    }

    func bindNullable(_ bindings: [SQLiteBinding?], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            if let binding {
                try bindOne(binding, index: Int32(offset + 1), to: statement)
            } else if sqlite3_bind_null(statement, Int32(offset + 1)) != SQLITE_OK {
                throw UnifiedSearchIndexError.sqlite(errorMessage)
            }
        }
    }

    func bindOne(_ binding: SQLiteBinding, index: Int32, to statement: OpaquePointer) throws {
        let result: Int32
        switch binding {
        case .text(let value):
            result = sqlite3_bind_text(statement, index, value, -1, Self.transient)
        case .integer(let value):
            result = sqlite3_bind_int64(statement, index, value)
        case .double(let value):
            result = sqlite3_bind_double(statement, index, value)
        }
        guard result == SQLITE_OK else { throw UnifiedSearchIndexError.sqlite(errorMessage) }
    }

    func document(id: String) throws -> UnifiedSearchDocument? {
        let statement = try prepare("SELECT * FROM search_documents WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.text(id)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return document(from: statement)
    }

    func document(from statement: OpaquePointer) -> UnifiedSearchDocument {
        let libraryID = LibraryID(rawValue: UUID(uuidString: text(statement, column: 1)) ?? UUID())
        let placeName = text(statement, column: 10)
        let city = text(statement, column: 11)
        let country = text(statement, column: 12)
        let address = text(statement, column: 13)
        let place = [placeName, city, country, address].allSatisfy(\.isEmpty)
            ? nil
            : SearchPlace(name: placeName, city: city, country: country, formattedAddress: address)
        let captureDate = sqlite3_column_type(statement, 14) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 14))
        let coordinate: SearchCoordinate?
        if sqlite3_column_type(statement, 20) == SQLITE_NULL ||
            sqlite3_column_type(statement, 21) == SQLITE_NULL {
            coordinate = nil
        } else {
            coordinate = SearchCoordinate(
                latitude: sqlite3_column_double(statement, 20),
                longitude: sqlite3_column_double(statement, 21)
            )
        }
        return UnifiedSearchDocument(
            id: text(statement, column: 0),
            libraryID: libraryID,
            assetID: text(statement, column: 2),
            libraryName: text(statement, column: 3),
            source: UnifiedSearchSource(rawValue: text(statement, column: 4)) ?? .registeredLibrary,
            filename: text(statement, column: 5),
            displayName: text(statement, column: 6),
            caption: text(statement, column: 7),
            keywords: text(statement, column: 8).split(separator: "\u{001F}").map(String.init),
            rawLocation: text(statement, column: 9),
            place: place,
            captureDate: captureDate,
            dateDescription: text(statement, column: 15),
            isFavorite: sqlite3_column_int(statement, 16) != 0,
            pixelWidth: Int(sqlite3_column_int64(statement, 17)),
            pixelHeight: Int(sqlite3_column_int64(statement, 18)),
            mediaType: text(statement, column: 19),
            coordinate: coordinate
        )
    }

    func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    func ftsQuery(_ freeText: String) -> String {
        freeText.split(separator: " ").map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " AND ")
    }

    func append(
        _ constraint: NumericSearchConstraint?,
        column: String,
        conditions: inout [String],
        bindings: inout [SQLiteBinding]
    ) {
        guard let constraint else { return }
        conditions.append("\(column) \(constraint.comparison.rawValue) ?")
        bindings.append(.integer(Int64(constraint.value)))
    }

    func appendLike(
        _ value: String?,
        column: String,
        conditions: inout [String],
        bindings: inout [SQLiteBinding]
    ) {
        guard let value else { return }
        conditions.append("\(column) LIKE ?")
        bindings.append(.text("%\(value)%"))
    }
}
