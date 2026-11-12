import Foundation

/// Rins AI Gateway (OpenAI-compatible) key status. Keys live in 9router under the `rins` node;
/// Tinybar only reads them. Rins publishes no balance endpoint, so `GET /v1/models` is the report:
/// a key is bound to one plan and one model, and the list names the model it may call.
public struct RinsProvider: UsageProvider {
    public let id = ProviderID.rins
    private let session: URLSession

    public init(session: URLSession = .tinybar) {
        self.session = session
    }

    public func isConfigured() -> Bool { RinsUsageAPI.storedKey() != nil }

    public func fetch() async throws -> ProviderSnapshot {
        guard let key = RinsUsageAPI.storedKey() else { throw ProviderError.notConfigured }
        return try await RinsUsageAPI.fetch(apiKey: key, session: session)
    }
}

enum RinsUsageAPI {
    static let baseURL = URL(string: "https://api.rinsdev.cloud")!

    // MARK: Wire types

    struct Models: Decodable {
        var data: [Model]?

        struct Model: Decodable {
            var id: String?
        }
    }

    // MARK: Fetch

    static func storedKey(db: URL = NineRouterKeys.database) -> String? {
        NineRouterKeys.apiKey(.node("rins"), db: db)
    }

    static func fetch(apiKey: String, session: URLSession) async throws -> ProviderSnapshot {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/models"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tinybar", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await HTTP.send(request, session: session, providerName: "Rins")
        let models: Models
        do {
            models = try JSONDecoder().decode(Models.self, from: data)
        } catch {
            throw ProviderError.unexpected("Unexpected Rins models response")
        }
        return snapshot(from: models)
    }

    // MARK: Mapping

    /// One key, one model: the list holds only what this key's plan may call.
    static func snapshot(from models: Models, now: Date = Date()) -> ProviderSnapshot {
        let names = (models.data ?? []).compactMap(\.id).filter { !$0.isEmpty }
        return ProviderSnapshot(
            provider: .rins,
            plan: names.first,
            windows: [],
            source: .cli,
            fetchedAt: now)
    }
}
