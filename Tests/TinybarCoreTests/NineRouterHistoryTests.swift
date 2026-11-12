import Foundation
import SQLite3
@testable import TinybarCore
import Testing

// Synthetic rows in the 9router usageHistory/providerConnections shapes verified 2026-11-02.
@Suite struct NineRouterHistoryTests {
    @Test func aggregatesAndPersistsCursor() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        try fixture.seed()
        let store = try UsageStore(path: fixture.root.appendingPathComponent("usage.sqlite"))
        #expect(try await store.ingestNineRouter(database: fixture.database) == 5)
        let daily = try await store.daily(since: "2000-01-01")
        #expect(daily.count == 4)
        let day = DayKey.string(for: try #require(ISO8601DateFormatter().date(from: "2026-01-02T12:00:00Z")))
        let combined = try #require(daily.first { $0.provider == .inferhub && $0.model == "cb/glm-5.3" && $0.day == day })
        #expect(combined.tokens == TokenCounts(input: 300, output: 30, cacheWrite: 10, cacheRead: 60))
        #expect(combined.project.isEmpty)
        #expect(daily.contains { $0.provider == .surplus }) // Inactive connections still count.
        #expect(daily.contains { $0.provider == .deepseek })
        #expect(try await store.ingestNineRouter(database: fixture.database) == 0)
        #expect(try await store.daily(since: "2000-01-01") == daily)
        let reopened = try UsageStore(path: fixture.root.appendingPathComponent("usage.sqlite"))
        #expect(try await reopened.ingestNineRouter(database: fixture.database) == 0)
        let saved = try SQLiteDB(path: fixture.root.appendingPathComponent("usage.sqlite").path)
        #expect(try saved.run("SELECT value FROM meta WHERE key = 'ninerouter_cursor'").first?.first?.text == "10")
        try fixture.sql("INSERT INTO usageHistory VALUES (11, '2026-01-03T12:00:00Z', 'custom', 'deepseek-v4.1-flash-1017', 'rins', 17, 3, '{}', 'success')")
        #expect(try await reopened.ingestNineRouter(database: fixture.database) == 1)
        #expect(try await reopened.daily(since: "2000-01-01").contains { $0.provider == .rins })
    }

    @Test func skipsInvalidRowsAndAdvancesOtherIDs() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        try fixture.seed()
        let reading = try #require(NineRouterHistory.read(database: fixture.database, after: 0))
        #expect(reading.newest == 10)
        #expect(reading.rows.count == 5)
        #expect(reading.skippedRows == 3) // Future time, malformed timestamp, malformed token JSON.
        #expect(try #require(NineRouterHistory.read(database: fixture.database, after: 10)).rows.isEmpty)
        let first = try #require(NineRouterHistory.read(database: fixture.database, after: 0, limit: 3))
        #expect(first.newest == 3)
        #expect(first.rows.count == 3)
        let second = try #require(NineRouterHistory.read(database: fixture.database, after: first.newest, limit: 3))
        #expect(second.newest == 6)
        #expect(second.rows.count == 2)
    }

    @Test func missingDatabaseIsHarmless() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try UsageStore(path: fixture.root.appendingPathComponent("usage.sqlite"))
        let missing = fixture.root.appendingPathComponent("missing.sqlite")
        #expect(try await store.ingestNineRouter(database: missing) == 0)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func readsWALWithoutChangingSource() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        try fixture.sql("PRAGMA journal_mode=WAL")
        try fixture.seed()
        try fixture.sql("BEGIN EXCLUSIVE")
        defer { try? fixture.sql("ROLLBACK") }
        let files = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
        let original = try files.map { try Data(contentsOf: $0) }
        #expect(try #require(NineRouterHistory.read(database: fixture.database, after: 0)).rows.count == 5)
        #expect(try files.map { try Data(contentsOf: $0) } == original)
        #expect(Set(try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)) == Set(files))
    }
    @Test func storeResumesBoundedBatches() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        try fixture.sql("""
            INSERT INTO providerConnections VALUES ('deepseek', 'deepseek', 0, '{}');
            WITH RECURSIVE ids(id) AS (SELECT 1 UNION ALL SELECT id + 1 FROM ids WHERE id < 5001)
            INSERT INTO usageHistory
            SELECT id, '2026-01-02T12:00:00Z', 'deepseek', 'deepseek-chat', 'deepseek', 1, 0, '{}', 'ok' FROM ids;
            """)
        let store = try UsageStore(path: fixture.root.appendingPathComponent("usage.sqlite"))
        #expect(try await store.ingestNineRouter(database: fixture.database) == 5000)
        #expect(try await store.ingestNineRouter(database: fixture.database) == 1)
        #expect(try await store.ingestNineRouter(database: fixture.database) == 0)
        let rows = try await store.daily(since: "2000-01-01")
        #expect(rows.reduce(Int64(0)) { $0 + $1.tokens.input } == 5001)
    }

}

private final class HistoryFixture {
    let root: URL
    let database: URL
    private var handle: OpaquePointer?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = root.appendingPathComponent("data.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open(database.path, &handle) == SQLITE_OK else { throw ProviderError.unexpected("Fixture database failed") }
        try sql("""
            CREATE TABLE providerConnections(id TEXT, provider TEXT, isActive INTEGER, data TEXT);
            CREATE TABLE usageHistory(id INTEGER PRIMARY KEY, timestamp TEXT, provider TEXT, model TEXT,
                connectionId TEXT, promptTokens INTEGER, completionTokens INTEGER, tokens TEXT, status TEXT);
            """)
    }

    func remove() {
        sqlite3_close(handle)
        handle = nil
        try? FileManager.default.removeItem(at: root)
    }

    func sql(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw ProviderError.unexpected("Fixture SQL failed: \(String(cString: sqlite3_errmsg(handle)))")
        }
    }

    func seed() throws {
        try sql("""
            INSERT INTO providerConnections VALUES
            ('infer', 'custom', 1, '{"providerSpecificData":{"nodeName":"inferhub"}}'),
            ('infer-an', 'custom', 1, '{"providerSpecificData":{"nodeName":"inferhub-an"}}'),
            ('surplus', 'custom', 0, '{"providerSpecificData":{"nodeName":"surplus"}}'),
            ('deepseek', 'deepseek', 1, '{}'),
            ('rins', 'custom', 1, '{"providerSpecificData":{"nodeName":"rins"}}');
            INSERT INTO usageHistory VALUES
            (1, '2026-01-02T12:00:00Z', 'custom', 'cb/glm-5.3', 'infer', 100, 10, '{"cached_tokens":20,"cache_creation_input_tokens":10}', 'ok'),
            (2, '2026-01-02T12:00:00.000Z', 'custom', 'cb/glm-5.3', 'infer-an', 200, 20, '{"cached_tokens":40}', 'success'),
            (3, '2026-01-01T12:00:00Z', 'custom', 'other', 'infer', 50, 5, '{}', 'ok'),
            (4, '2026-01-02T12:00:00Z', 'custom', 'glm-5', 'surplus', 60, 6, '{}', 'ok'),
            (5, '2026-01-02T12:00:00Z', 'deepseek', 'deepseek-chat', 'deepseek', 70, 7, '{}', 'ok'),
            (6, '2099-01-01T12:00:00Z', 'deepseek', 'future', 'deepseek', 999, 0, '{}', 'ok'),
            (7, 'bad timestamp', 'deepseek', 'bad', 'deepseek', 999, 0, '{}', 'ok'),
            (8, '2026-01-02T12:00:00Z', 'deepseek', 'bad', 'deepseek', 999, 0, 'not json', 'ok'),
            (9, '2026-01-02T12:00:00Z', 'deepseek', 'failed', 'deepseek', 999, 0, '{}', 'error'),
            (10, '2026-01-02T12:00:00Z', 'codex', 'gpt-6', 'unmapped', 999, 0, '{}', 'ok');
            """)
    }
}
