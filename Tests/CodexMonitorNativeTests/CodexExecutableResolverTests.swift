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

    func testFnmHomeTakesPriorityAndUsesInstallationSubpath() throws {
        let configuredHome = "/Users/test/custom-fnm"
        let defaultHome = "/Users/test/.local/share/fnm"
        let fileSystem = StubFileSystem(
            items: [
                "\(configuredHome)/node-versions/v18.20.0/installation/bin/codex": .regularFile(executable: true),
                "\(configuredHome)/node-versions/v20.9.0/installation/bin/codex": .regularFile(executable: true),
                "\(defaultHome)/node-versions/v21.0.0/installation/bin/codex": .regularFile(executable: true),
                "\(defaultHome)/aliases/default/bin/codex": .regularFile(executable: true)
            ],
            directories: [
                "\(configuredHome)/node-versions": ["v18.20.0", "v20.9.0"],
                "\(defaultHome)/node-versions": ["v21.0.0"]
            ]
        )
        let resolver = makeResolver(
            environment: ["FNM_DIR": configuredHome],
            fileSystem: fileSystem
        )

        XCTAssertEqual(try resolver.resolve().map(\.path), [
            "\(configuredHome)/node-versions/v20.9.0/installation/bin/codex",
            "\(configuredHome)/node-versions/v18.20.0/installation/bin/codex",
            "\(defaultHome)/aliases/default/bin/codex",
            "\(defaultHome)/node-versions/v21.0.0/installation/bin/codex"
        ])
        XCTAssertEqual(try resolver.resolve().map(\.source), [.fnm, .fnm, .fnm, .fnm])
    }

    func testVersionDirectorySortParsesEachPathOnce() {
        let paths = (0..<32).map { "/root/node/v\(20 + $0 % 4).\($0).\($0 % 10)" }

        var optimizedParses = 0
        let optimized = CodexExecutableResolver.sortedNewestVersionFirst(paths) { path in
            optimizedParses += 1
            return CodexExecutableResolver.versionComponents(of: path)
        }

        var baselineParses = 0
        let baseline = paths.sorted { lhs, rhs in
            baselineParses += 2
            return referenceIsNewer(lhs, rhs)
        }

        XCTAssertEqual(optimized, baseline)
        XCTAssertEqual(optimizedParses, paths.count)
        XCTAssertGreaterThan(baselineParses, optimizedParses)
    }

    func testVersionSortMatchesReferenceOrderingForMixedNames() {
        let paths = [
            "/root/v18.20.0", "/root/v18.2.0", "/root/v9.0.0", "/root/v1", "/root/latest",
            "/root/v1.2", "/root/v1.2.0", "/root/v20.11.0-rc.1", "/root/node-v17.3", "/root/",
            "/root/v0.0.0", "/root/v0.0.1", "/root/10", "/root/9", "/root/v10.0.0-nightly.9"
        ]

        let reference = paths.sorted(by: referenceIsNewer)
        let optimized = CodexExecutableResolver.sortedNewestVersionFirst(paths) {
            CodexExecutableResolver.versionComponents(of: $0)
        }

        XCTAssertEqual(optimized, reference)
        XCTAssertEqual(optimized.first, "/root/v20.11.0-rc.1")
        XCTAssertLessThan(
            reference.firstIndex(of: "/root/v1.2.0")!,
            reference.firstIndex(of: "/root/v1.2")!
        )
    }

    func testVersionComponentsParsingSkipsNonNumericAndOverflowingSegments() {
        XCTAssertEqual(CodexExecutableResolver.versionComponents(of: "/root/v20.11.0"), [20, 11, 0])
        XCTAssertEqual(CodexExecutableResolver.versionComponents(of: "/root/node-v18.2"), [18, 2])
        XCTAssertEqual(CodexExecutableResolver.versionComponents(of: "/root/v1.2.3-rc.4"), [1, 2, 3, 4])
        XCTAssertEqual(CodexExecutableResolver.versionComponents(of: "latest"), [])
        XCTAssertEqual(CodexExecutableResolver.versionComponents(of: ""), [])
        XCTAssertEqual(CodexExecutableResolver.versionComponents(of: "/root/v99999999999999999999"), [])
        XCTAssertEqual(
            CodexExecutableResolver.sortedNewestVersionFirst([], versionComponents: { _ in [] }),
            []
        )
    }

    private func referenceIsNewer(_ lhs: String, _ rhs: String) -> Bool {
        let lhsComponents = CodexExecutableResolver.versionComponents(of: lhs)
        let rhsComponents = CodexExecutableResolver.versionComponents(of: rhs)
        for (left, right) in zip(lhsComponents, rhsComponents) where left != right {
            return left > right
        }
        if lhsComponents.count != rhsComponents.count {
            return lhsComponents.count > rhsComponents.count
        }
        return lhs > rhs
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
