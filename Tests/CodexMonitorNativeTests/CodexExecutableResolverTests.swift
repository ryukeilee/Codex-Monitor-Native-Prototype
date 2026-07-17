import XCTest
@testable import CodexMonitorNative

final class CodexExecutableResolverTests: XCTestCase {
    func testOverrideAndEnvironmentCandidatesTakePriority() throws {
        let fileSystem = StubFileSystem(
            items: [
                "/override/codex": .regularFile(executable: true),
                "/bin/codex": .regularFile(executable: true),
                "/executable/codex": .regularFile(executable: true)
            ]
        )
        let resolver = makeResolver(
            override: "/override/codex",
            environment: [
                "CODEX_BIN": "/bin/codex",
                "CODEX_EXECUTABLE": "/executable/codex"
            ],
            fileSystem: fileSystem
        )

        let candidates = try resolver.resolve()

        XCTAssertEqual(candidates.map(\.path), ["/override/codex", "/bin/codex", "/executable/codex"])
        XCTAssertEqual(candidates.map(\.source), [.explicitOverride, .codexBin, .codexExecutable])
    }

    func testInvalidCodexBinDoesNotPreventCodexExecutableFallback() throws {
        let fileSystem = StubFileSystem(items: [
            "/working/codex": .regularFile(executable: true)
        ])
        let resolver = makeResolver(
            environment: [
                "CODEX_BIN": "/not-runnable/codex",
                "CODEX_EXECUTABLE": "/working/codex"
            ],
            fileSystem: fileSystem
        )

        XCTAssertEqual(try resolver.resolve(), [
            .init(path: "/working/codex", source: .codexExecutable)
        ])
    }

    func testEmptyGUIPathStillFindsHomebrew() throws {
        let fileSystem = StubFileSystem(items: [
            "/opt/homebrew/bin/codex": .regularFile(executable: true)
        ])
        let resolver = makeResolver(environment: ["PATH": ""], fileSystem: fileSystem)

        XCTAssertEqual(try resolver.resolve(), [
            .init(path: "/opt/homebrew/bin/codex", source: .homebrewAppleSilicon)
        ])
    }

    func testPathFindsNpmInstalledCodex() throws {
        let fileSystem = StubFileSystem(items: [
            "/npm/bin/codex": .regularFile(executable: true)
        ])
        let resolver = makeResolver(environment: ["PATH": "/npm/bin"], fileSystem: fileSystem)

        XCTAssertEqual(try resolver.resolve(), [
            .init(path: "/npm/bin/codex", source: .path)
        ])
    }

    func testPathEntryNamedCodexIsStillTreatedAsDirectory() throws {
        let path = "/tools/codex/codex"
        let fileSystem = StubFileSystem(items: [
            path: .regularFile(executable: true)
        ])
        let resolver = makeResolver(environment: ["PATH": "/tools/codex"], fileSystem: fileSystem)

        XCTAssertEqual(try resolver.resolve(), [
            .init(path: path, source: .path)
        ])
    }

    func testEmptyGUIPathFindsUserNpmGlobalCodex() throws {
        let path = "/Users/test/.npm-global/bin/codex"
        let fileSystem = StubFileSystem(items: [
            path: .regularFile(executable: true)
        ])
        let resolver = makeResolver(environment: ["PATH": ""], fileSystem: fileSystem)

        XCTAssertEqual(try resolver.resolve(), [
            .init(path: path, source: .npmGlobal)
        ])
    }

    func testNvmDirectoriesUseNewestFirstAndAreReenumeratedPerCall() throws {
        let nvmRoot = "/Users/test/.nvm/versions/node"
        let fileSystem = StubFileSystem(
            items: [
                "\(nvmRoot)/v20.11.0/bin/codex": .regularFile(executable: true),
                "\(nvmRoot)/v22.2.0/bin/codex": .regularFile(executable: true),
                "\(nvmRoot)/v23.0.0/bin/codex": .regularFile(executable: true)
            ],
            directories: [nvmRoot: ["v20.11.0", "v22.2.0"]]
        )
        let resolver = makeResolver(fileSystem: fileSystem)

        XCTAssertEqual(try resolver.resolve().map(\.path), [
            "\(nvmRoot)/v22.2.0/bin/codex",
            "\(nvmRoot)/v20.11.0/bin/codex"
        ])

        fileSystem.directories[nvmRoot] = ["v23.0.0"]

        XCTAssertEqual(try resolver.resolve().map(\.path), [
            "\(nvmRoot)/v23.0.0/bin/codex"
        ])
    }

    func testMissingCandidatesAndNonRunnableConfiguredCandidatesHaveDifferentFailures() {
        let missingResolver = makeResolver(
            environment: ["CODEX_BIN": "/missing/codex"],
            fileSystem: StubFileSystem()
        )
        XCTAssertThrowsError(try missingResolver.resolve()) { error in
            XCTAssertEqual(error as? CodexExecutableResolver.ResolutionFailure, .noCandidatesFound)
        }

        let nonRunnableResolver = makeResolver(
            environment: ["CODEX_BIN": "/not-executable/codex"],
            fileSystem: StubFileSystem(items: [
                "/not-executable/codex": .regularFile(executable: false)
            ])
        )
        XCTAssertThrowsError(try nonRunnableResolver.resolve()) { error in
            XCTAssertEqual(error as? CodexExecutableResolver.ResolutionFailure, .candidatesNotRunnable)
        }
    }

    func testRejectsDirectoriesRelativeEntriesAndEmptyPathComponents() {
        let resolver = makeResolver(
            environment: [
                "CODEX_BIN": "relative/codex",
                "CODEX_EXECUTABLE": "/directory",
                "PATH": ":relative/bin::"
            ],
            fileSystem: StubFileSystem(items: ["/directory": .directory])
        )

        XCTAssertThrowsError(try resolver.resolve()) { error in
            XCTAssertEqual(error as? CodexExecutableResolver.ResolutionFailure, .candidatesNotRunnable)
        }
    }

    func testSymlinkCandidatesAreCanonicalizedAndDeduplicated() throws {
        let fileSystem = StubFileSystem(
            items: ["/real/codex": .regularFile(executable: true)],
            canonicalPaths: [
                "/alias/codex": "/real/codex",
                "/real/codex": "/real/codex"
            ]
        )
        let resolver = makeResolver(
            environment: [
                "CODEX_BIN": "/alias/codex",
                "CODEX_EXECUTABLE": "/real/codex"
            ],
            fileSystem: fileSystem
        )

        XCTAssertEqual(try resolver.resolve(), [
            .init(path: "/real/codex", source: .codexBin)
        ])
    }

    func testFindsCodexInUserChatGPTBundle() throws {
        let path = "/Users/test/Applications/ChatGPT.app/Contents/MacOS/codex"
        let fileSystem = StubFileSystem(items: [path: .regularFile(executable: true)])
        let resolver = makeResolver(fileSystem: fileSystem)

        XCTAssertEqual(try resolver.resolve(), [
            .init(path: path, source: .userApplications)
        ])
    }

    private func makeResolver(
        override: String? = nil,
        environment: [String: String] = [:],
        homeDirectory: String = "/Users/test",
        fileSystem: StubFileSystem
    ) -> CodexExecutableResolver {
        CodexExecutableResolver(
            explicitOverride: override,
            environment: { environment },
            homeDirectory: { homeDirectory },
            fileSystem: .init(
                itemAtPath: { fileSystem.items[$0] ?? .missing },
                canonicalPath: { fileSystem.canonicalPaths[$0] ?? $0 },
                directoryContents: { fileSystem.directories[$0] ?? [] }
            )
        )
    }
}

private final class StubFileSystem: @unchecked Sendable {
    var items: [String: CodexExecutableResolver.FileSystem.Item]
    var canonicalPaths: [String: String]
    var directories: [String: [String]]

    init(
        items: [String: CodexExecutableResolver.FileSystem.Item] = [:],
        canonicalPaths: [String: String] = [:],
        directories: [String: [String]] = [:]
    ) {
        self.items = items
        self.canonicalPaths = canonicalPaths
        self.directories = directories
    }
}
