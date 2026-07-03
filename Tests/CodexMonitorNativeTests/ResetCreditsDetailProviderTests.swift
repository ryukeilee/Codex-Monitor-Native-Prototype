import XCTest
@testable import CodexMonitorNative

final class ResetCreditsDetailProviderTests: XCTestCase {
    func testFetchDetailsUsesAccessTokenWithoutAccountID() async throws {
        let authFileURL = try makeTemporaryAuthFile(contents: #"{"tokens":{"access_token":"test-access-token"}}"#)
        let requestStore = CapturedRequestStore()
        let provider = ResetCreditsDetailProvider(authFileURL: authFileURL) { request in
            await requestStore.save(request)
            return (
                Self.payloadData(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        let payload = try await provider.fetchDetails()
        let capturedRequest = await requestStore.request

        XCTAssertEqual(payload.availableCount, 1)
        XCTAssertEqual(payload.availableCredits.first?.expiresAt, makeDate("2026-06-19T18:00:00Z"))
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "ChatGPT-Account-ID"))
    }

    func testFetchDetailsSetsAccountIDHeaderWhenPresent() async throws {
        let authFileURL = try makeTemporaryAuthFile(contents: #"{"tokens":{"access_token":"test-access-token","account_id":"account-123"}}"#)
        let requestStore = CapturedRequestStore()
        let provider = ResetCreditsDetailProvider(authFileURL: authFileURL) { request in
            await requestStore.save(request)
            return (
                Self.payloadData(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        _ = try await provider.fetchDetails()
        let capturedRequest = await requestStore.request

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "account-123")
    }

    func testParsePayloadSortsAvailableCreditsByEarliestExpiry() throws {
        let payload = try ResetCreditsDetailProvider.parsePayload(from: [
            "available_count": 2,
            "credits": [
                [
                    "id": "credit-late",
                    "status": "available",
                    "granted_at": "2026-06-19T12:00:00Z",
                    "expires_at": "2026-06-20T12:00:00Z"
                ],
                [
                    "id": "credit-early",
                    "status": "available",
                    "granted_at": "2026-06-19T10:00:00Z",
                    "expires_at": "2026-06-19T18:00:00Z"
                ]
            ]
        ])

        XCTAssertEqual(payload.availableCount, 2)
        XCTAssertEqual(payload.availableCredits.count, 2)
        XCTAssertEqual(
            payload.availableCredits.compactMap(\.expiresAt),
            [makeDate("2026-06-19T18:00:00Z"), makeDate("2026-06-20T12:00:00Z")]
        )
    }

    func testParsePayloadFiltersNonAvailableCreditsFromMainDisplay() throws {
        let payload = try ResetCreditsDetailProvider.parsePayload(from: [
            "available_count": 1,
            "credits": [
                [
                    "id": "credit-available",
                    "status": "available",
                    "granted_at": "2026-06-19T12:00:00Z",
                    "expires_at": "2026-06-20T12:00:00Z"
                ],
                [
                    "id": "credit-redeemed",
                    "status": "redeemed",
                    "granted_at": "2026-06-18T12:00:00Z",
                    "expires_at": "2026-06-19T12:00:00Z"
                ],
                [
                    "id": "credit-expired",
                    "status": "expired",
                    "granted_at": "2026-06-17T12:00:00Z",
                    "expires_at": "2026-06-18T12:00:00Z"
                ]
            ]
        ])

        XCTAssertEqual(payload.availableCredits.count, 1)
        XCTAssertEqual(payload.availableCredits.first?.status, "available")
        XCTAssertEqual(
            payload.statusSummary,
            [
                ResetCreditStatusSummary(status: "available", count: 1),
                ResetCreditStatusSummary(status: "expired", count: 1),
                ResetCreditStatusSummary(status: "redeemed", count: 1)
            ]
        )
    }

    func testParsePayloadThrowsWhenCreditsFieldMissing() {
        XCTAssertThrowsError(
            try ResetCreditsDetailProvider.parsePayload(from: [
                "available_count": 1
            ])
        ) { error in
            XCTAssertEqual(error as? ResetCreditsDetailError, .missingCreditsField)
        }
    }

    func testParsePayloadThrowsWhenNoAvailableCredits() {
        XCTAssertThrowsError(
            try ResetCreditsDetailProvider.parsePayload(from: [
                "available_count": 1,
                "credits": [
                    [
                        "status": "expired",
                        "expires_at": "2026-06-18T12:00:00Z"
                    ]
                ]
            ])
        ) { error in
            XCTAssertEqual(error as? ResetCreditsDetailError, .noAvailableCredits)
        }
    }

    func testParsePayloadThrowsWhenAvailableCreditIsMissingExpiresAt() {
        XCTAssertThrowsError(
            try ResetCreditsDetailProvider.parsePayload(from: [
                "available_count": 1,
                "credits": [
                    [
                        "status": "available",
                        "granted_at": "2026-06-19T12:00:00Z"
                    ]
                ]
            ])
        ) { error in
            XCTAssertEqual(error as? ResetCreditsDetailError, .missingExpiresAt)
        }
    }

    func testErrorDescriptionsStaySanitized() {
        XCTAssertEqual(ResetCreditsDetailError.authFileMissing.errorDescription, "auth 文件不存在")
        XCTAssertEqual(ResetCreditsDetailError.tokensMissing.errorDescription, "tokens 缺失")
        XCTAssertEqual(ResetCreditsDetailError.invalidJSON.errorDescription, "返回非 JSON")
        XCTAssertEqual(ResetCreditsDetailError.unexpectedStatusCode(401).errorDescription, "HTTP 状态码 401")
    }

    private func makeDate(_ iso8601: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso8601)!
    }

    private func makeTemporaryAuthFile(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorNativeTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let fileURL = directory.appendingPathComponent("auth.json")
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    private static func payloadData() -> Data {
        Data(
            """
            {
              "available_count": 1,
              "credits": [
                {
                  "status": "available",
                  "granted_at": "2026-06-19T10:00:00Z",
                  "expires_at": "2026-06-19T18:00:00Z"
                }
              ]
            }
            """.utf8
        )
    }
}

private actor CapturedRequestStore {
    private(set) var request: URLRequest?

    func save(_ request: URLRequest) {
        self.request = request
    }
}
