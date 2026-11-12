import Foundation
import SQLite3
@testable import TinybarCore
import Testing

// Shapes verified against the live endpoints: Surplus /v1/payments/balance, InferHub /api/me,
// DeepSeek /user/balance and Rins /v1/models (2026-11-12), using keys from 9router's database.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

@Suite struct CreditProviderTests {
    @Test func surplus() throws {
        let balance = try decode(SurplusUsageAPI.Balance.self, """
        {"credit_balance_usdc":"4329891","fiat_available_usdc":"-28","usdc_available_usdc":"4329919",
         "account_status":"active"}
        """)
        let snapshot = SurplusUsageAPI.snapshot(from: balance)
        #expect(snapshot.provider == .surplus)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.credits?.hasCredits == true)
        let dollars = try #require(snapshot.credits?.balance)
        #expect(abs(dollars - 4.329891) < 1e-6)
    }

    @Test func surplusScientific() throws {
        // Surplus quoted an allowance-sized figure in scientific notation; only the spendable
        // credit balance matters, and it must parse the same way.
        let snapshot = SurplusUsageAPI.snapshot(from: try decode(SurplusUsageAPI.Balance.self, """
        {"credit_balance_usdc":"1.157920892373162e+06","account_status":"active"}
        """))
        let dollars = try #require(snapshot.credits?.balance)
        #expect(abs(dollars - 1.157920892373162) < 1e-9)
    }

    @Test func surplusMissing() throws {
        let snapshot = SurplusUsageAPI.snapshot(from: try decode(SurplusUsageAPI.Balance.self, "{}"))
        #expect(snapshot.credits?.hasCredits == true)
        #expect(snapshot.credits?.balance == nil)
    }

    @Test func inferhub() throws {
        let me = try decode(InferHubUsageAPI.Me.self, """
        {"id":"603b8961-3e4e-4827-bcbe-b11c23f61684","email":"dafanamikaze@gmail.com",
         "displayName":"bangadam","status":"active",
         "balances":{"consumer_balance":"1.166345","fiat_pendings":"10.778803"}}
        """)
        let snapshot = InferHubUsageAPI.snapshot(from: me)
        #expect(snapshot.provider == .inferhub)
        #expect(snapshot.windows.isEmpty)
        let dollars = try #require(snapshot.credits?.balance)
        #expect(abs(dollars - 1.166345) < 1e-9)
        #expect(snapshot.plan == "bangadam")
    }

    @Test func deepseekPrefersUSD() throws {
        let balance = try decode(DeepSeekUsageAPI.Balance.self, """
        {"is_available":true,"balance_infos":[
         {"currency":"USD","total_balance":"17.27","granted_balance":"0.00","topped_up_balance":"17.27"},
         {"currency":"CNY","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}]}
        """)
        let snapshot = DeepSeekUsageAPI.snapshot(from: balance)
        #expect(snapshot.provider == .deepseek)
        #expect(snapshot.windows.isEmpty)
        let dollars = try #require(snapshot.credits?.balance)
        #expect(abs(dollars - 17.27) < 1e-9)
    }

    @Test func deepseekFallsBackToCNY() throws {
        let balance = try decode(DeepSeekUsageAPI.Balance.self, """
        {"is_available":true,"balance_infos":[
         {"currency":"CNY","total_balance":"5.50","granted_balance":"0.00","topped_up_balance":"5.50"}]}
        """)
        let dollars = try #require(DeepSeekUsageAPI.snapshot(from: balance).credits?.balance)
        #expect(abs(dollars - 5.5) < 1e-9)
    }

    /// Rins has no balance endpoint; the key's model list is its report.
    @Test func rinsNamesTheKeysModel() throws {
        let models = try decode(RinsUsageAPI.Models.self, """
        {"object":"list","data":[{"id":"deepseek-v4.1-flash-1017","object":"model"}]}
        """)
        let snapshot = RinsUsageAPI.snapshot(from: models)
        #expect(snapshot.provider == .rins)
        #expect(snapshot.plan == "deepseek-v4.1-flash-1017")
        #expect(snapshot.windows.isEmpty && snapshot.credits == nil)
    }

    @Test func rinsWithNoModelHasNoPlan() throws {
        let models = try decode(RinsUsageAPI.Models.self, #"{"object":"list","data":[]}"#)
        #expect(RinsUsageAPI.snapshot(from: models).plan == nil)
    }

    @Test func missingDatabaseHasNoStoredKeys() {
        let db = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(SurplusUsageAPI.storedKey(db: db) == nil)
        #expect(InferHubUsageAPI.storedKey(db: db) == nil)
        #expect(DeepSeekUsageAPI.storedKey(db: db) == nil)
        #expect(RinsUsageAPI.storedKey(db: db) == nil)
        #expect(!FileManager.default.fileExists(atPath: db.path))
    }

    @Test func storedKeysIgnoreInactiveMissingAndMalformedConnections() throws {
        try withCreditDatabase { db, handle in
            try creditSQL(handle, """
            INSERT INTO providerConnections VALUES ('broken', 1, 'not json');
            INSERT INTO providerConnections VALUES ('deepseek', 0, '{"apiKey":"inactive"}');
            INSERT INTO providerConnections VALUES ('custom', 0, '{"apiKey":"inactive","providerSpecificData":{"nodeName":"surplus"}}');
            INSERT INTO providerConnections VALUES ('custom', 1, '{"providerSpecificData":{"nodeName":"inferhub"}}');
            """)
            #expect(SurplusUsageAPI.storedKey(db: db) == nil)
            #expect(InferHubUsageAPI.storedKey(db: db) == nil)
            #expect(DeepSeekUsageAPI.storedKey(db: db) == nil)
            try creditSQL(handle, """
            INSERT INTO providerConnections VALUES ('custom', 1, '{"apiKey":"surplus-key","providerSpecificData":{"nodeName":"surplus"}}');
            INSERT INTO providerConnections VALUES ('deepseek', 1, '{"apiKey":"deepseek-key"}');
            """)
            #expect(SurplusUsageAPI.storedKey(db: db) == "surplus-key")
            #expect(DeepSeekUsageAPI.storedKey(db: db) == "deepseek-key")
        }
    }

    @Test func storedKeysReadLockedWALWithoutChangingDatabase() throws {
        try withCreditDatabase { db, handle in
            try creditSQL(handle, "PRAGMA journal_mode=WAL; PRAGMA wal_checkpoint(TRUNCATE)")
            try creditSQL(handle, "INSERT INTO providerConnections VALUES ('custom', 1, '{\"apiKey\":\"wal-key\",\"providerSpecificData\":{\"nodeName\":\"inferhub\"}}')")
            try creditSQL(handle, "BEGIN EXCLUSIVE")
            defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }
            let root = db.deletingLastPathComponent()
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let original = try files.map { try Data(contentsOf: $0) }
            #expect(InferHubUsageAPI.storedKey(db: db) == "wal-key")
            #expect(try files.map { try Data(contentsOf: $0) } == original)
            #expect(Set(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) == Set(files))
        }
    }

    @Test(arguments: ["not-a-number", "NaN", "Infinity", "1e999"])
    func nonNumericBalancesAreUnknown(value: String) throws {
        #expect(SurplusUsageAPI.dollars(value) == nil)
        let me = try decode(InferHubUsageAPI.Me.self, "{\"balances\":{\"consumer_balance\":\"\(value)\"}}")
        #expect(InferHubUsageAPI.snapshot(from: me).credits?.balance == nil)
        let balance = try decode(DeepSeekUsageAPI.Balance.self, "{\"balance_infos\":[{\"currency\":\"USD\",\"total_balance\":\"\(value)\"}]}")
        #expect(DeepSeekUsageAPI.snapshot(from: balance).credits?.balance == nil)
    }

    @Test(arguments: ["surplus", "inferhub", "deepseek"])
    func malformedBalanceThrowsUnexpected(provider: String) async {
        await #expect(throws: ProviderError.unexpected("Unexpected \(creditProviderName(provider)) balance response")) {
            try await fetchCredit(provider, key: "malformed")
        }
    }

    @Test func malformedModelsThrowUnexpected() async {
        await #expect(throws: ProviderError.unexpected("Unexpected Rins models response")) {
            try await fetchCredit("rins", key: "malformed")
        }
    }

    @Test(arguments: ["surplus", "inferhub", "deepseek", "rins"], [401, 403, 429])
    func mapsHTTPFailures(provider: String, status: Int) async {
        let error: ProviderError = status == 429 ? .rateLimited(retryAfter: 120) : .loginExpired
        await #expect(throws: error) { try await fetchCredit(provider, key: String(status)) }
    }
}

private func creditProviderName(_ provider: String) -> String {
    switch provider {
    case "surplus": "Surplus"
    case "inferhub": "InferHub"
    default: "DeepSeek"
    }
}

private func fetchCredit(_ provider: String, key: String) async throws -> ProviderSnapshot {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CreditResponseFixture.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    switch provider {
    case "surplus": return try await SurplusUsageAPI.fetch(apiKey: key, session: session)
    case "inferhub": return try await InferHubUsageAPI.fetch(apiKey: key, session: session)
    case "rins": return try await RinsUsageAPI.fetch(apiKey: key, session: session)
    default: return try await DeepSeekUsageAPI.fetch(apiKey: key, session: session)
    }
}

private final class CreditResponseFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let status = request.value(forHTTPHeaderField: "Authorization").flatMap { Int($0.dropFirst(7)) } ?? 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "120"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("not json".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func creditSQL(_ handle: OpaquePointer, _ sql: String) throws {
    let code = sqlite3_exec(handle, sql, nil, nil, nil)
    #expect(code == SQLITE_OK)
    guard code == SQLITE_OK else { throw ProviderError.unexpected("Fixture SQL failed") }
}

private func withCreditDatabase(_ body: (URL, OpaquePointer) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = root.appendingPathComponent("data.sqlite")
    var writer: OpaquePointer?
    let code = sqlite3_open(db.path, &writer)
    defer { sqlite3_close(writer) }
    #expect(code == SQLITE_OK)
    let handle = try #require(writer)
    try creditSQL(handle, "CREATE TABLE providerConnections(provider TEXT, isActive INTEGER, data TEXT)")
    try body(db, handle)
}
