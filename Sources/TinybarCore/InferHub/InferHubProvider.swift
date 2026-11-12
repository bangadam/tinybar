import Foundation

/// InferHub account balance. Keys live in 9router under the `inferhub` node; Tinybar only reads them.
/// Source: `GET /api/me` with `Authorization: Bearer sk-airo-...`, whose `balances.consumer_balance`
/// is spendable USDC as a decimal string.
public struct InferHubProvider: UsageProvider {
    public let id = ProviderID.inferhub
    private let session: URLSession

    public init(session: URLSession = .tinybar) {
        self.session = session
    }

    public func isConfigured() -> Bool { InferHubUsageAPI.storedKey() != nil }

    public func fetch() async throws -> ProviderSnapshot {
        guard let key = InferHubUsageAPI.storedKey() else { throw ProviderError.notConfigured }
        return try await InferHubUsageAPI.fetch(apiKey: key, session: session)
    }
}

enum InferHubUsageAPI {
    static let baseURL = URL(string: "https://inferhub.dev")!

    // MARK: Wire types

    struct Me: Decodable {
        var email: String?
        var displayName: String?
        var balances: Balances?
    }

    struct Balances: Decodable {
        var consumerBalance: String?

        enum CodingKeys: String, CodingKey {
            case consumerBalance = "consumer_balance"
        }
    }

    // MARK: Fetch

    static func storedKey(db: URL = NineRouterKeys.database) -> String? {
        NineRouterKeys.apiKey(.node("inferhub"), db: db)
    }

    static func fetch(apiKey: String, session: URLSession) async throws -> ProviderSnapshot {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/me"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tinybar", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await HTTP.send(request, session: session, providerName: "InferHub")
        let me: Me
        do {
            me = try JSONDecoder().decode(Me.self, from: data)
        } catch {
            throw ProviderError.unexpected("Unexpected InferHub balance response")
        }
        return snapshot(from: me)
    }

    // MARK: Mapping

    static func snapshot(from me: Me, now: Date = Date()) -> ProviderSnapshot {
        let balance = me.balances?.consumerBalance.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
        return ProviderSnapshot(
            provider: .inferhub,
            plan: me.displayName ?? me.email,
            windows: [],
            credits: Credits(hasCredits: true, unlimited: false, balance: balance),
            source: .cli,
            fetchedAt: now)
    }
}
