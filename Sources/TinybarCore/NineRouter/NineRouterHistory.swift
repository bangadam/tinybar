import Foundation

/// Local proxy history, read without touching 9router's database or WAL.
enum NineRouterHistory {
    struct Row: Sendable {
        var provider: ProviderID
        var record: UsageRecord
    }

    struct Reading: Sendable {
        var rows: [Row]
        var newest: Int64
        var skippedRows: Int
    }

    static func read(database: URL, after seen: Int64, limit: Int = 5_000, now: Date = Date()) -> Reading? {
        CredentialDatabase.read(database) { handle in
            // Limit raw IDs, not matched providers: excluded nodes and failed requests advance too.
            guard let columns = SQLiteDB.rows(handle, """
                SELECT h.id, h.timestamp, h.provider, h.model, h.promptTokens, h.completionTokens,
                       h.tokens, h.status, c.data
                FROM usageHistory h LEFT JOIN providerConnections c ON c.id = h.connectionId
                WHERE h.id > ? ORDER BY h.id LIMIT ?
                """, [.int(seen), .int(Int64(max(1, limit)))]) else { return nil }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            var reading = Reading(rows: [], newest: seen, skippedRows: 0)
            for c in columns {
                reading.newest = max(reading.newest, c[0].int)
                guard c[7].text == "ok" || c[7].text == "success" else { continue }
                let data = c[8].text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                let specific = data?["providerSpecificData"] as? [String: Any]
                let node = specific?["nodeName"] as? String ?? c[2].text ?? ""
                let provider: ProviderID
                switch node.lowercased() {
                case "inferhub", "inferhub-an": provider = .inferhub
                case "surplus": provider = .surplus
                case "deepseek": provider = .deepseek
                case "rins": provider = .rins
                default: continue
                }
                guard let text = c[1].text,
                      let date = fractional.date(from: text) ?? plain.date(from: text), date <= now,
                      let model = c[3].text, !model.isEmpty,
                      let tokenText = c[6].text,
                      let tokens = try? JSONSerialization.jsonObject(with: Data(tokenText.utf8)) as? [String: Any]
                else { reading.skippedRows += 1; continue }
                let input = c[4].int
                let output = c[5].int
                let cached = (tokens["cached_tokens"] as? NSNumber)?.int64Value ?? 0
                let write = (tokens["cache_creation_input_tokens"] as? NSNumber)?.int64Value ?? 0
                guard [input, output, cached, write].allSatisfy({ $0 >= 0 && $0 <= 1 << 40 }) else {
                    reading.skippedRows += 1
                    continue
                }
                reading.rows.append(Row(provider: provider, record: UsageRecord(
                    timestamp: date, model: model, cwd: nil,
                    tokens: TokenCounts(input: input, output: output, cacheWrite: write, cacheRead: cached))))
            }
            return reading
        }
    }
}
