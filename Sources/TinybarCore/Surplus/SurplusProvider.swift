import Foundation

/// Surplus credit balance. Keys live in 9router under the `surplus` node; Tinybar only reads them.
/// Source: `GET /v1/payments/balance` with `Authorization: Bearer inf_...`. All money figures are
/// integer microdollar strings (`"4329891"` = $4.329891); `credit_balance_usdc` is the spendable one.
public struct SurplusProvider: UsageProvider {
    public let id = ProviderID.surplus
    private let session: URLSession

    public init(session: URLSession = .tinybar) {
        self.session = session
    }

    public func isConfigured() -> Bool { SurplusUsageAPI.storedKey() != nil }

    public func fetch() async throws -> ProviderSnapshot {
        guard let key = SurplusUsageAPI.storedKey() else { throw ProviderError.notConfigured }
        return try await SurplusUsageAPI.fetch(apiKey: key, session: session)
    }
}

enum SurplusUsageAPI {
    static let baseURL = URL(string: "https://api.surplusintelligence.ai")!

    // MARK: Wire types

    struct Balance: Decodable {
        /// Combined spendable figure: fiat credit plus deposited USDC, in microdollars.
        var creditBalance: String?
        var accountStatus: String?

        enum CodingKeys: String, CodingKey {
            case creditBalance = "credit_balance_usdc"
            case accountStatus = "account_status"
        }
    }

    // MARK: Fetch

    static func storedKey(db: URL = NineRouterKeys.database) -> String? {
        NineRouterKeys.apiKey(.node("surplus"), db: db)
    }

    static func fetch(apiKey: String, session: URLSession) async throws -> ProviderSnapshot {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/payments/balance"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tinybar", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await HTTP.send(request, session: session, providerName: "Surplus")
        let balance: Balance
        do {
            balance = try JSONDecoder().decode(Balance.self, from: data)
        } catch {
            throw ProviderError.unexpected("Unexpected Surplus balance response")
        }
        return snapshot(from: balance)
    }

    // MARK: Mapping

    /// Microdollar strings (optionally scientific notation) to dollars.
    static func dollars(_ micro: String?) -> Double? {
        guard let micro, let value = Double(micro), value.isFinite else { return nil }
        return value / 1_000_000
    }

    static func snapshot(from balance: Balance, now: Date = Date()) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .surplus,
            plan: balance.accountStatus.map { $0 == "active" ? "Active" : $0.capitalized },
            windows: [],
            credits: Credits(hasCredits: true, unlimited: false, balance: dollars(balance.creditBalance)),
            source: .cli,
            fetchedAt: now)
    }
}
