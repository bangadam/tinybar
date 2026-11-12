import Foundation

/// DeepSeek API balance. Keys live in 9router under the first-party `deepseek` connection;
/// Tinybar only reads them. Source: `GET /user/balance` with `Authorization: Bearer <key>`.
/// Prefers the USD row of `balance_infos`, falling back to CNY.
public struct DeepSeekProvider: UsageProvider {
    public let id = ProviderID.deepseek
    private let session: URLSession

    public init(session: URLSession = .tinybar) {
        self.session = session
    }

    public func isConfigured() -> Bool { DeepSeekUsageAPI.storedKey() != nil }

    public func fetch() async throws -> ProviderSnapshot {
        guard let key = DeepSeekUsageAPI.storedKey() else { throw ProviderError.notConfigured }
        return try await DeepSeekUsageAPI.fetch(apiKey: key, session: session)
    }
}

enum DeepSeekUsageAPI {
    static let baseURL = URL(string: "https://api.deepseek.com")!

    // MARK: Wire types

    struct Balance: Decodable {
        var isAvailable: Bool?
        var rows: [Row]?

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case rows = "balance_infos"
        }

        struct Row: Decodable {
            var currency: String?
            var totalBalance: String?

            enum CodingKeys: String, CodingKey {
                case currency
                case totalBalance = "total_balance"
            }
        }
    }

    // MARK: Fetch

    static func storedKey(db: URL = NineRouterKeys.database) -> String? {
        NineRouterKeys.apiKey(.provider("deepseek"), db: db)
    }

    static func fetch(apiKey: String, session: URLSession) async throws -> ProviderSnapshot {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("user/balance"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tinybar", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await HTTP.send(request, session: session, providerName: "DeepSeek")
        let balance: Balance
        do {
            balance = try JSONDecoder().decode(Balance.self, from: data)
        } catch {
            throw ProviderError.unexpected("Unexpected DeepSeek balance response")
        }
        return snapshot(from: balance)
    }

    // MARK: Mapping

    static func snapshot(from balance: Balance, now: Date = Date()) -> ProviderSnapshot {
        func amount(currency: String) -> Double? {
            balance.rows?.first { $0.currency?.uppercased() == currency }
                .flatMap(\.totalBalance).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
        }
        let money = amount(currency: "USD") ?? amount(currency: "CNY")
        return ProviderSnapshot(
            provider: .deepseek,
            plan: balance.isAvailable == true ? "Available" : nil,
            windows: [],
            credits: Credits(hasCredits: true, unlimited: false, balance: money),
            source: .cli,
            fetchedAt: now)
    }
}
