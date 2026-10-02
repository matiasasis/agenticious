import XCTest
@testable import Agenticious

final class CodexModelQuotasTests: XCTestCase {
    func testAvailableAndBlockedModelsRemainSeparateFromAccountUsage() throws {
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":81}},"model_usage":{"gpt-6-astra":{"available":false,"available_at":"2026-10-03T12:00:00Z","credits_would_enable":true},"gpt-6-sol":{"available":true,"available_at":null}}}"#.utf8)
        let quotas = try XCTUnwrap(CodexModelQuotaReader.parse(data))
        XCTAssertEqual(quotas.map(\.id), ["gpt-6-astra", "gpt-6-sol"])
        XCTAssertEqual(quotas.map(\.status), ["Limit reached", "Available"])
        XCTAssertEqual(quotas[0].availableAt, ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z"))
        XCTAssertNil(quotas[1].availableAt)
    }

    func testMissingModelDataDoesNotInventAQuotaAndMalformedResponsesAreRejected() {
        for json in ["{}", #"{"model_usage":null}"#, #"{"model_usage":{}}"#] {
            XCTAssertEqual(CodexModelQuotaReader.parse(Data(json.utf8)), [])
        }
        XCTAssertNil(CodexModelQuotaReader.parse(Data("broken".utf8)))
        XCTAssertNil(CodexModelQuotaReader.parse(Data(#"{"model_usage":[]}"#.utf8)))
        let unknown = Data(#"{"model_usage":{"unknown":{"available_at":123}}}"#.utf8)
        XCTAssertEqual(CodexModelQuotaReader.parse(unknown), [])
        XCTAssertEqual(CodexModelQuotaReader.parse(Data(#"{"model_usage":{"unknown":{"available":1}}}"#.utf8)), [])
        for reset in ["true", #""unknown""#] {
            let malformedDate = Data(#"{"model_usage":{"gpt-6-astra":{"available":false,"available_at":\#(reset)}}}"#.utf8)
            let quotas = CodexModelQuotaReader.parse(malformedDate)
            XCTAssertEqual(quotas?.count, 1)
            XCTAssertNil(quotas?.first?.availableAt)
        }
    }

    @MainActor
    func testFailedRefreshPreservesTheLastStatusAsStaleAndAnEmptySuccessClearsIt() {
        let monitor = UsageMonitor()
        let reading = CodexModelQuotaReading(quotas: [CodexModelQuota(id: "gpt-6-astra", available: false, availableAt: nil)], checkedAt: Date())
        monitor.recordCodexModelQuotas(reading)
        XCTAssertFalse(monitor.codexModelQuotasStale)
        monitor.recordCodexModelQuotas(nil)
        XCTAssertEqual(monitor.codexModelQuotas, reading)
        XCTAssertTrue(monitor.codexModelQuotasStale)
        monitor.recordCodexModelQuotas(CodexModelQuotaReading(quotas: [], checkedAt: Date()))
        XCTAssertEqual(monitor.codexModelQuotas?.quotas, [])
        XCTAssertFalse(monitor.codexModelQuotasStale)
    }

    func testLiveRequestUsesExistingSignInAndRejectsHTTPFailures() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"tokens":{"access_token":"test-token","account_id":"test-account"}}"#.utf8).write(to: url)
        let reading = await CodexModelQuotaReader.read(authURL: url) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "test-account")
            XCTAssertEqual(request.timeoutInterval, 10)
            return (Data(#"{"model_usage":{"gpt-6-astra":{"available":true}}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(reading?.quotas.first?.status, "Available")
        let failed = await CodexModelQuotaReader.read(authURL: url) { request in
            (Data(#"{"model_usage":{"gpt-6-astra":{"available":true}}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertNil(failed)
        let offline = await CodexModelQuotaReader.read(authURL: url) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertNil(offline)
    }

    func testMissingCredentialsNeverSendARequest() async {
        let missing = URL(fileURLWithPath: "/tmp/\(UUID()).json")
        let reading = await CodexModelQuotaReader.read(authURL: missing) { _ in
            XCTFail("Missing credentials should not trigger a request")
            throw URLError(.userAuthenticationRequired)
        }
        XCTAssertNil(reading)
    }
}
