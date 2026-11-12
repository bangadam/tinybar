import Foundation
import SQLite3

/// Keys kept in 9router's local database (`~/.9router/db/data.sqlite`). 9router stores each
/// provider connection as a row in `providerConnections`, with the secret inside the JSON `data`
/// column. This helper only reads; it never writes beside 9router's database.
enum NineRouterKeys: Sendable {
    static var database: URL { Paths.home.appendingPathComponent(".9router/db/data.sqlite", isDirectory: false) }

    enum Kind: Sendable {
        /// A connection whose `providerSpecificData.nodeName` equals the name 9router shows.
        case node(String)
        /// A first-party connection stored under its own provider slug.
        case provider(String)
    }

    static func apiKey(_ kind: Kind, db: URL = database) -> String? {
        let sql: String
        switch kind {
        case let .node(name):
            sql = "SELECT data FROM providerConnections WHERE CASE WHEN json_valid(data) THEN json_extract(data, '$.providerSpecificData.nodeName') END = ? AND isActive = 1 LIMIT 1"
            return read(sql, bind: name, db: db)
        case let .provider(slug):
            sql = "SELECT data FROM providerConnections WHERE provider = ? AND isActive = 1 LIMIT 1"
            return read(sql, bind: slug, db: db)
        }
    }

    private static func read(_ sql: String, bind: String, db: URL) -> String? {
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        return CredentialDatabase.read(db) { handle in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, bind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            let raw = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
            guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let key = json["apiKey"] as? String, !key.isEmpty
            else { return nil }
            return key
        }
    }
}
