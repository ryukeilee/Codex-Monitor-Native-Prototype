import XCTest
@testable import CodexMonitorNative

final class RealQuotaProviderTests: XCTestCase {
    func testParseRateLimitsPrefersCanonicalWeeklyBankAndKeepsFastestEntries() {
        let response: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": 5
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "usedPercent": 57.0,
                        "resetAt": "2026-06-19T14:10:00Z"
                    ],
                    "secondary": [
                        "usedPercent": 48.0,
                        "nextResetAt": "2026-06-20T10:00:00Z"
                    ]
                ],
                "codex_other": [
                    "primary": [
                        "usedPercent": 25.0,
                        "windowResetAt": "2026-06-19T13:00:00Z"
                    ]
                ],
                "bonus": [
                    "primary": [
                        "usedPercent": 10.0,
                        "resetsAt": "2026-06-21T10:00:00Z"
                    ]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.fiveHourQuotaPercent, 43)
        XCTAssertEqual(snapshot?.weeklyQuotaPercent, 52)
        XCTAssertEqual(snapshot?.resetAvailableCount, 5)
        XCTAssertEqual(
            snapshot?.resetCreditRawFields,
            [ResetCreditRawField(path: "rateLimitResetCredits.availableCount", value: "5")]
        )
        XCTAssertTrue(snapshot?.resetCreditTimeEntries.isEmpty ?? false)
        XCTAssertEqual(snapshot?.resetBanks.map(\.id), [
            "codex.primary",
            "codex.secondary",
            "bonus.primary"
        ])
    }

    func testParseRateLimitsDoesNotPromoteNormalBankResetTimeIntoResetCredits() {
        let response: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": 5
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "usedPercent": 57.0,
                        "resetAt": "2026-06-19T14:10:00Z"
                    ]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.resetAvailableCount, 5)
        XCTAssertTrue(snapshot?.resetCreditTimeEntries.isEmpty ?? false)
        XCTAssertEqual(snapshot?.resetBanks.first?.resolvedResetFieldName, "resetAt")
    }

    func testParseRateLimitsUsesOnlyResetCreditFieldsForCreditTimes() {
        let response: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": 5,
                "restoresAt": [
                    1_718_000_600,
                    1_718_004_200
                ],
                "expiresAt": [
                    1_718_007_800
                ],
                "windowStartAt": 1_717_900_000
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "usedPercent": 57.0,
                        "resetAt": "2026-06-19T14:10:00Z"
                    ]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.resetCreditTimeEntries.map(\.label), ["恢复时间", "恢复时间", "到期时间"])
        XCTAssertEqual(snapshot?.resetCreditTimeEntries.map(\.sourcePath), [
            "rateLimitResetCredits.restoresAt[0]",
            "rateLimitResetCredits.restoresAt[1]",
            "rateLimitResetCredits.expiresAt[0]"
        ])
    }

    func testParseRateLimitsUsesFallbackWeeklyBankWhenSecondaryMissing() {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "usedPercent": 57.0,
                        "resetAt": "2026-06-19T14:10:00Z"
                    ]
                ],
                "codex_other": [
                    "primary": [
                        "usedPercent": 25.0,
                        "windowResetAt": "2026-06-19T13:00:00Z"
                    ]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.weeklyQuotaPercent, 75)
        XCTAssertEqual(snapshot?.resetBanks.map(\.id), [
            "codex_other.primary",
            "codex.primary"
        ])
    }

    func testParseRateLimitsKeepsUnknownResetBankRawFields() {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "usedPercent": 61.0
                    ],
                    "secondary": [
                        "usedPercent": 35.0,
                        "nextResetAt": NSNull()
                    ]
                ]
            ]
        ]

        let snapshot = RealQuotaProvider.parseRateLimits(response: response)

        XCTAssertEqual(snapshot?.resetBanks.count, 2)
        XCTAssertNil(snapshot?.resetBanks.first?.resetAt)
        XCTAssertEqual(snapshot?.resetBanks.first?.rawResetFields, [])
        XCTAssertEqual(
            snapshot?.resetBanks.last?.rawResetFields,
            [ResetBankRawField(name: "nextResetAt", value: "<null>")]
        )
    }
}
