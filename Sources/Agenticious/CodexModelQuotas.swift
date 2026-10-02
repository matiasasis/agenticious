import Foundation
import CoreFoundation

struct CodexModelQuota: Identifiable, Equatable {
    let id: String
    let available: Bool
    let availableAt: Date?

    var name: String {
        ModelCatalog.models(for: .codex).first { $0.id == id }?.name ?? id
    }

    var status: String { available ? "Available" : "Limit reached" }
}

struct CodexModelQuotaReading: Equatable {
    let quotas: [CodexModelQuota]
    let checkedAt: Date
}

enum CodexModelQuotaReader {
    static var authURL: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("auth.json")
    }

    // The app-server's rateLimits response omits model_usage, so read its underlying usage endpoint.
    static func read(authURL: URL = authURL,
                     fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) async -> CodexModelQuotaReading? {
        guard let request = request(authURL: authURL) else { return nil }
        do {
            let (data, response) = try await fetch(request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  let quotas = parse(data) else { return nil }
            return CodexModelQuotaReading(quotas: quotas, checkedAt: Date())
        } catch { return nil }
    }

    private static func request(authURL: URL) -> URLRequest? {
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              let account = tokens["account_id"] as? String, !account.isEmpty else { return nil }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        return request
    }

    static func parse(_ data: Data) -> [CodexModelQuota]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let raw = object["model_usage"] as? [String: [String: Any]] else {
            return object["model_usage"] == nil || object["model_usage"] is NSNull ? [] : nil
        }
        return raw.sorted { $0.key < $1.key }.compactMap { id, usage in
            guard let value = usage["available"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            let available = value.boolValue
            return CodexModelQuota(id: id, available: available, availableAt: date(usage["available_at"]))
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let value = value as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
