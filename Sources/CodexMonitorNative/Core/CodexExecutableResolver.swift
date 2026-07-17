import Foundation

struct CodexExecutableResolver: Sendable {
    struct Candidate: Sendable, Equatable {
        let path: String
        let source: Source
    }

    enum Source: Sendable, Equatable {
        case explicitOverride
        case codexBin
        case codexExecutable
        case path
        case homebrewAppleSilicon
        case homebrewIntel
        case npmConfigPrefix
        case pnpmHome
        case voltaHome
        case npmGlobal
        case npmPackages
        case localBin
        case bun
        case asdf
        case mise
        case voltaDefault
        case pnpmDefault
        case nvm
        case fnm
        case applications
        case userApplications
    }

    enum ResolutionFailure: Error, Sendable, Equatable {
        case noCandidatesFound
        case candidatesNotRunnable
    }

    struct FileSystem: Sendable {
        enum Item: Sendable, Equatable {
            case missing
            case directory
            case regularFile(executable: Bool)
            case other
        }

        let itemAtPath: @Sendable (String) -> Item
        let canonicalPath: @Sendable (String) -> String
        let directoryContents: @Sendable (String) -> [String]

        static let live = FileSystem(
            itemAtPath: { path in
                let fileManager = FileManager.default
                var isDirectory = ObjCBool(false)
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                    return .missing
                }
                guard !isDirectory.boolValue else {
                    return .directory
                }
                guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                      attributes[.type] as? FileAttributeType == .typeRegular else {
                    return .other
                }
                return .regularFile(executable: fileManager.isExecutableFile(atPath: path))
            },
            canonicalPath: { path in
                URL(fileURLWithPath: path)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                    .path
            },
            directoryContents: { path in
                (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            }
        )
    }

    private struct ProposedCandidate: Sendable {
        let path: String
        let source: Source
        let isExplicitConfiguration: Bool
    }

    private let explicitOverride: String?
    private let environment: @Sendable () -> [String: String]
    private let homeDirectory: @Sendable () -> String
    private let fileSystem: FileSystem

    init(
        explicitOverride: String? = nil,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        homeDirectory: @escaping @Sendable () -> String = { FileManager.default.homeDirectoryForCurrentUser.path },
        fileSystem: FileSystem = .live
    ) {
        self.explicitOverride = explicitOverride
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileSystem = fileSystem
    }

    /// Discovers runnable `codex` executables in priority order.
    ///
    /// The environment and version-manager directories are queried for every invocation so
    /// an interactive shell upgrade can be used without restarting the app.
    func resolve() throws -> [Candidate] {
        let proposedCandidates = makeProposedCandidates(
            environment: environment(),
            homeDirectory: homeDirectory()
        )
        var runnableCandidates: [Candidate] = []
        var canonicalPaths = Set<String>()
        var foundUnrunnableCandidate = false

        for proposed in proposedCandidates {
            guard isAbsolutePath(proposed.path) else {
                foundUnrunnableCandidate = foundUnrunnableCandidate || proposed.isExplicitConfiguration
                continue
            }

            let canonicalPath = fileSystem.canonicalPath(proposed.path)
            guard isAbsolutePath(canonicalPath) else {
                foundUnrunnableCandidate = foundUnrunnableCandidate || proposed.isExplicitConfiguration
                continue
            }

            switch fileSystem.itemAtPath(canonicalPath) {
            case .regularFile(executable: true):
                if canonicalPaths.insert(canonicalPath).inserted {
                    runnableCandidates.append(Candidate(path: canonicalPath, source: proposed.source))
                }
            case .missing:
                continue
            case .directory, .regularFile(executable: false), .other:
                foundUnrunnableCandidate = true
            }
        }

        guard !runnableCandidates.isEmpty else {
            throw foundUnrunnableCandidate
                ? ResolutionFailure.candidatesNotRunnable
                : ResolutionFailure.noCandidatesFound
        }
        return runnableCandidates
    }

    private func makeProposedCandidates(
        environment: [String: String],
        homeDirectory: String
    ) -> [ProposedCandidate] {
        var candidates: [ProposedCandidate] = []

        func append(_ path: String?, source: Source, explicit: Bool = false) {
            guard let path, !path.isEmpty else { return }
            candidates.append(ProposedCandidate(path: path, source: source, isExplicitConfiguration: explicit))
        }

        append(explicitOverride, source: .explicitOverride, explicit: true)
        append(environment["CODEX_BIN"], source: .codexBin, explicit: true)
        append(environment["CODEX_EXECUTABLE"], source: .codexExecutable, explicit: true)

        for directory in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let path = String(directory)
            guard isAbsolutePath(path) else { continue }
            append(executablePath(in: path), source: .path)
        }

        append("/opt/homebrew/bin/codex", source: .homebrewAppleSilicon)
        append("/usr/local/bin/codex", source: .homebrewIntel)

        if let npmPrefix = environment["NPM_CONFIG_PREFIX"], isAbsolutePath(npmPrefix) {
            append(executablePath(in: pathJoining(npmPrefix, "bin")), source: .npmConfigPrefix, explicit: true)
        }
        if let pnpmHome = environment["PNPM_HOME"], isAbsolutePath(pnpmHome) {
            append(executablePath(in: pnpmHome), source: .pnpmHome, explicit: true)
        }
        if let voltaHome = environment["VOLTA_HOME"], isAbsolutePath(voltaHome) {
            append(executablePath(in: pathJoining(voltaHome, "bin")), source: .voltaHome, explicit: true)
        }

        append(executablePath(in: pathJoining(homeDirectory, ".npm-global/bin")), source: .npmGlobal)
        append(executablePath(in: pathJoining(homeDirectory, ".npm-packages/bin")), source: .npmPackages)
        append(executablePath(in: pathJoining(homeDirectory, ".local/bin")), source: .localBin)
        append(executablePath(in: pathJoining(homeDirectory, ".bun/bin")), source: .bun)
        append(executablePath(in: pathJoining(homeDirectory, ".asdf/shims")), source: .asdf)
        append(executablePath(in: pathJoining(homeDirectory, ".local/share/mise/shims")), source: .mise)
        append(executablePath(in: pathJoining(homeDirectory, ".volta/bin")), source: .voltaDefault)
        append(executablePath(in: pathJoining(homeDirectory, "Library/pnpm")), source: .pnpmDefault)

        appendVersionManagerCandidates(
            root: pathJoining(homeDirectory, ".nvm/versions/node"),
            source: .nvm,
            executableSubpath: "bin",
            into: &candidates
        )

        var fnmHomes = [
            pathJoining(homeDirectory, ".local/share/fnm"),
            pathJoining(homeDirectory, ".fnm")
        ]
        if let fnmDirectory = environment["FNM_DIR"], isAbsolutePath(fnmDirectory) {
            fnmHomes.insert(fnmDirectory, at: 0)
        }
        for fnmHome in fnmHomes {
            append(
                executablePath(in: pathJoining(fnmHome, "aliases/default/bin")),
                source: .fnm
            )
            appendVersionManagerCandidates(
                root: pathJoining(fnmHome, "node-versions"),
                source: .fnm,
                executableSubpath: "installation/bin",
                into: &candidates
            )
        }

        for applicationsDirectory in ["/Applications", pathJoining(homeDirectory, "Applications")] {
            let source: Source = applicationsDirectory == "/Applications" ? .applications : .userApplications
            for application in ["Codex.app", "ChatGPT.app"] {
                append(
                    pathJoining(applicationsDirectory, "\(application)/Contents/Resources/codex"),
                    source: source
                )
                append(
                    pathJoining(applicationsDirectory, "\(application)/Contents/MacOS/codex"),
                    source: source
                )
            }
        }

        return candidates
    }

    private func appendVersionManagerCandidates(
        root: String,
        source: Source,
        executableSubpath: String,
        into candidates: inout [ProposedCandidate]
    ) {
        let versions = fileSystem.directoryContents(root)
            .map { directoryPath($0, relativeTo: root) }
            .sorted(by: isNewerVersionDirectory)

        for version in versions {
            let executableDirectory = executableSubpath
                .split(separator: "/")
                .reduce(version) { pathJoining($0, String($1)) }
            candidates.append(
                ProposedCandidate(
                    path: executablePath(in: executableDirectory),
                    source: source,
                    isExplicitConfiguration: false
                )
            )
        }
    }

    private func executablePath(in directory: String) -> String {
        URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("codex")
            .path
    }

    private func pathJoining(_ path: String, _ component: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(component)
            .path
    }

    private func directoryPath(_ entry: String, relativeTo root: String) -> String {
        isAbsolutePath(entry) ? entry : pathJoining(root, entry)
    }

    private func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/")
    }

    private func isNewerVersionDirectory(_ lhs: String, _ rhs: String) -> Bool {
        let lhsComponents = versionComponents(of: lhs)
        let rhsComponents = versionComponents(of: rhs)
        for (left, right) in zip(lhsComponents, rhsComponents) where left != right {
            return left > right
        }
        if lhsComponents.count != rhsComponents.count {
            return lhsComponents.count > rhsComponents.count
        }
        return lhs > rhs
    }

    private func versionComponents(of path: String) -> [Int] {
        path
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }
}
