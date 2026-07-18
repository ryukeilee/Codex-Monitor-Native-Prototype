import AppKit
import CryptoKit
import Foundation
import Security

struct AppInstallationVersion: Codable, Equatable, Sendable {
    let marketingVersion: String
    let buildVersion: String

    func isNotOlder(than other: AppInstallationVersion) -> Bool {
        let marketingComparison = Self.compare(marketingVersion, other.marketingVersion)
        if marketingComparison != .orderedSame {
            return marketingComparison == .orderedDescending
        }
        return Self.compare(buildVersion, other.buildVersion) != .orderedAscending
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(
            rhs,
            options: [.caseInsensitive, .numeric],
            range: nil,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

enum AppInstallationSignatureKind: String, Codable, Equatable, Sendable {
    case adHoc
    case certificateBacked
}

struct AppInstallationSigningAnchor {
    static func digest(
        designatedRequirement: String?,
        teamIdentifier: String?,
        signingIdentifier: String,
        isAdHoc: Bool
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("signing-kind\0".utf8))
        hasher.update(data: Data((isAdHoc ? "ad-hoc" : "certificate-backed").utf8))
        if !isAdHoc, let designatedRequirement {
            hasher.update(data: Data("designated-requirement\0".utf8))
            hasher.update(data: Data(designatedRequirement.utf8))
        }
        hasher.update(data: Data("team-identifier\0".utf8))
        hasher.update(data: Data((teamIdentifier ?? "").utf8))
        hasher.update(data: Data("signing-identifier\0".utf8))
        hasher.update(data: Data(signingIdentifier.utf8))
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct AppInstallationIdentity: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let bundlePath: String
    let bundleIdentifier: String
    let codeIdentityDigest: String
    let signingAnchorDigest: String?
    let signatureKind: AppInstallationSignatureKind?
    let version: AppInstallationVersion?

    init(
        bundlePath: String,
        bundleIdentifier: String,
        codeIdentityDigest: String,
        signingAnchorDigest: String? = nil,
        signatureKind: AppInstallationSignatureKind? = nil,
        version: AppInstallationVersion? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.codeIdentityDigest = codeIdentityDigest
        self.signingAnchorDigest = signingAnchorDigest
        self.signatureKind = signatureKind
        self.version = version
    }

    var bundleURL: URL {
        URL(fileURLWithPath: bundlePath, isDirectory: true)
    }

    var isDevelopmentArtifact: Bool {
        let components = bundleURL.pathComponents
        return bundleURL.pathExtension.lowercased() != "app"
            || components.contains("dist")
            || components.contains(".build")
            || components.contains("DerivedData")
    }

    var hasCertificateBackedSignature: Bool {
        signatureKind == .certificateBacked
    }
}

protocol AppInstallationIdentityProviding {
    func identity(for bundleURL: URL) -> AppInstallationIdentity?
}

struct SystemAppInstallationIdentityProvider: AppInstallationIdentityProviding {
    // CodeDirectory's CS_ADHOC bit is not surfaced by the Swift Security overlay.
    private static let adHocSignatureFlag: UInt32 = 0x00000002

    private struct SigningIdentity {
        let anchorDigest: String
        let kind: AppInstallationSignatureKind
    }

    func identity(for bundleURL: URL) -> AppInstallationIdentity? {
        let canonicalBundleURL = bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let bundle = Bundle(url: canonicalBundleURL),
              let bundleIdentifier = bundle.bundleIdentifier,
              let executableURL = bundle.executableURL,
              let executableData = try? Data(contentsOf: executableURL, options: .mappedIfSafe),
              let infoPlistData = try? Data(
                contentsOf: canonicalBundleURL.appendingPathComponent("Contents/Info.plist"),
                options: .mappedIfSafe
              ) else {
            return nil
        }
        let version = installationVersion(from: infoPlistData)

        var hasher = SHA256()
        hasher.update(data: Data("executable\0".utf8))
        hasher.update(data: executableData)
        hasher.update(data: Data("info-plist\0".utf8))
        hasher.update(data: infoPlistData)

        let codeResourcesURL = canonicalBundleURL
            .appendingPathComponent("Contents/_CodeSignature/CodeResources")
        hasher.update(data: Data("code-resources\0".utf8))
        if let codeResourcesData = try? Data(contentsOf: codeResourcesURL, options: .mappedIfSafe) {
            hasher.update(data: codeResourcesData)
        } else {
            hasher.update(data: Data("missing".utf8))
        }

        let digest = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        let signingIdentity = signingIdentity(for: canonicalBundleURL)
        return AppInstallationIdentity(
            bundlePath: canonicalBundleURL.path,
            bundleIdentifier: bundleIdentifier,
            codeIdentityDigest: digest,
            signingAnchorDigest: signingIdentity?.anchorDigest,
            signatureKind: signingIdentity?.kind,
            version: version
        )
    }

    private func installationVersion(from infoPlistData: Data) -> AppInstallationVersion? {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: infoPlistData,
            options: [],
            format: nil
        ),
              let infoPlist = propertyList as? [String: Any],
              let marketingVersion = infoPlist["CFBundleShortVersionString"] as? String,
              !marketingVersion.isEmpty,
              let buildVersion = infoPlist["CFBundleVersion"] as? String,
              !buildVersion.isEmpty else {
            return nil
        }
        return AppInstallationVersion(
            marketingVersion: marketingVersion,
            buildVersion: buildVersion
        )
    }

    private func signingIdentity(for bundleURL: URL) -> SigningIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil) == errSecSuccess else {
            return nil
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let information = signingInformation as? [String: Any],
              let signingIdentifier = information[kSecCodeInfoIdentifier as String] as? String,
              let signingFlags = information[kSecCodeInfoFlags as String] as? NSNumber,
              !signingIdentifier.isEmpty else {
            return nil
        }
        let isAdHoc = signingFlags.uint32Value & Self.adHocSignatureFlag != 0
        var designatedRequirement: String?
        if !isAdHoc {
            guard let requirementValue = information[kSecCodeInfoDesignatedRequirement as String]
            else {
                return nil
            }
            let requirementReference = requirementValue as CFTypeRef
            guard CFGetTypeID(requirementReference) == SecRequirementGetTypeID() else {
                return nil
            }
            let requirement = requirementValue as! SecRequirement
            var requirementString: CFString?
            guard SecRequirementCopyString(
                requirement,
                SecCSFlags(),
                &requirementString
            ) == errSecSuccess,
                  let requirementString else {
                return nil
            }
            let requirementText = requirementString as String
            guard !requirementText.localizedCaseInsensitiveContains("cdhash") else {
                return nil
            }
            designatedRequirement = requirementText
        }
        return SigningIdentity(
            anchorDigest: AppInstallationSigningAnchor.digest(
                designatedRequirement: designatedRequirement,
                teamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String,
                signingIdentifier: signingIdentifier,
                isAdHoc: isAdHoc
            ),
            kind: isAdHoc ? .adHoc : .certificateBacked
        )
    }
}

@MainActor
final class AppInstallationAuthority {
    enum Resolution: Equatable {
        case useCurrent(
            identity: AppInstallationIdentity?,
            shouldPersist: Bool,
            allowsAutomaticLoginItemReconciliation: Bool
        )
        case redirect(AppInstallationIdentity)
        case reject(String)
    }

    static let developmentLaunchArgument = "--codex-monitor-allow-development-instance"

    private let defaults: UserDefaults
    private let preferenceKey: String
    private let currentBundleURL: URL
    private let identityProvider: AppInstallationIdentityProviding
    private let arguments: [String]
    private let registeredApplicationURLProvider: @MainActor (String) -> URL?
    private let expectedBundleIdentifier: String

    private enum StoredPreferredIdentity {
        case missing
        case valid(AppInstallationIdentity)
        case invalid
    }

    init(
        defaults: UserDefaults = .standard,
        preferenceKey: String = "codex.monitor.native.preferredInstallation.v1",
        currentBundleURL: URL = Bundle.main.bundleURL,
        identityProvider: AppInstallationIdentityProviding = SystemAppInstallationIdentityProvider(),
        arguments: [String] = ProcessInfo.processInfo.arguments,
        expectedBundleIdentifier: String = "com.ryukeilee.CodexMonitorNativePrototype",
        registeredApplicationURLProvider: @escaping @MainActor (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    ) {
        self.defaults = defaults
        self.preferenceKey = preferenceKey
        self.currentBundleURL = currentBundleURL
        self.identityProvider = identityProvider
        self.arguments = arguments
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.registeredApplicationURLProvider = registeredApplicationURLProvider
    }

    func resolveCurrentInstallation() -> Resolution {
        guard currentBundleURL.pathExtension.lowercased() == "app" else {
            return .useCurrent(
                identity: nil,
                shouldPersist: false,
                allowsAutomaticLoginItemReconciliation: false
            )
        }
        guard let currentIdentity = identityProvider.identity(for: currentBundleURL) else {
            return .reject("无法验证当前 App 安装身份")
        }
        guard currentIdentity.bundleIdentifier == expectedBundleIdentifier else {
            return .reject("当前 App Bundle ID 与预期不一致")
        }
        guard currentIdentity.signingAnchorDigest != nil else {
            return .reject("当前 App 代码签名无效")
        }
        guard currentIdentity.version != nil else {
            return .reject("当前 App 版本信息无效")
        }

        if currentIdentity.isDevelopmentArtifact,
           arguments.contains(Self.developmentLaunchArgument) {
            return .useCurrent(
                identity: currentIdentity,
                shouldPersist: false,
                allowsAutomaticLoginItemReconciliation: false
            )
        }

        let storedIdentity = storedPreferredIdentity()
        if case .invalid = storedIdentity {
            return .reject("已保存的 App 安装身份无效")
        }
        if case .valid(let preferredIdentity) = storedIdentity,
           preferredIdentity.bundleIdentifier != expectedBundleIdentifier {
            return .reject("已保存的 App Bundle ID 与预期不一致")
        }
        guard case .valid(let preferredIdentity) = storedIdentity else {
            if let preferredCandidate = bestDiscoveredInstallationCandidate(
                for: currentIdentity
            ) {
                return .redirect(preferredCandidate)
            }
            return .useCurrent(
                identity: currentIdentity,
                shouldPersist: !currentIdentity.isDevelopmentArtifact,
                allowsAutomaticLoginItemReconciliation: !currentIdentity.isDevelopmentArtifact
            )
        }

        if canonicalBundlePath(preferredIdentity) == canonicalBundlePath(currentIdentity) {
            guard storedSigningAnchorAllowsReplacement(
                preferredIdentity,
                installedIdentity: currentIdentity
            ) else {
                return .reject("当前 App 签名身份与已记录安装不一致")
            }
            guard storedVersionAllowsReplacement(
                preferredIdentity,
                installedIdentity: currentIdentity
            ) else {
                return .reject("当前 App 版本低于已记录安装")
            }
            return .useCurrent(
                identity: currentIdentity,
                shouldPersist: preferredIdentity != currentIdentity,
                allowsAutomaticLoginItemReconciliation: true
            )
        }

        let preferredURL = preferredIdentity.bundleURL
        if let installedPreferredIdentity = identityProvider.identity(for: preferredURL) {
            guard installedPreferredIdentity.bundleIdentifier == preferredIdentity.bundleIdentifier else {
                return .reject("首选 App Bundle ID 已改变")
            }
            guard storedSigningAnchorAllowsReplacement(
                preferredIdentity,
                installedIdentity: installedPreferredIdentity
            ) else {
                return .reject("首选 App 签名身份已改变")
            }
            guard storedVersionAllowsReplacement(
                preferredIdentity,
                installedIdentity: installedPreferredIdentity
            ) else {
                return .reject("首选 App 版本低于已记录安装")
            }
            guard currentIdentity.signingAnchorDigest != nil,
                  currentIdentity.signingAnchorDigest == installedPreferredIdentity.signingAnchorDigest else {
                return .reject("当前 App 与首选 App 签名身份不一致")
            }
            if canRedirect(
                from: currentIdentity,
                to: installedPreferredIdentity,
                hasRecordedPathAuthority: true
            ) {
                return .redirect(installedPreferredIdentity)
            }
            if !currentIdentity.hasCertificateBackedSignature
                || !installedPreferredIdentity.hasCertificateBackedSignature {
                return .reject("未记录的 ad-hoc App 不能替换现有首选安装")
            }
        }

        guard storedSigningAnchorAllowsReplacement(
            preferredIdentity,
            installedIdentity: currentIdentity
        ) else {
            return .reject("移动后的 App 签名身份与已记录安装不一致")
        }
        guard storedVersionAllowsReplacement(
            preferredIdentity,
            installedIdentity: currentIdentity
        ) else {
            return .reject("移动后的 App 版本低于已记录安装")
        }

        if currentIdentity.isDevelopmentArtifact {
            return .useCurrent(
                identity: currentIdentity,
                shouldPersist: false,
                allowsAutomaticLoginItemReconciliation: false
            )
        }

        return .useCurrent(
            identity: currentIdentity,
            shouldPersist: true,
            allowsAutomaticLoginItemReconciliation: true
        )
    }

    func persistPreferredInstallation(_ identity: AppInstallationIdentity) {
        guard !identity.isDevelopmentArtifact,
              let data = try? JSONEncoder().encode(identity) else {
            return
        }
        defaults.set(data, forKey: preferenceKey)
    }

    func revalidateRedirectTarget(_ expectedIdentity: AppInstallationIdentity) -> Bool {
        identityProvider.identity(for: expectedIdentity.bundleURL) == expectedIdentity
    }

    func isRecordedPreferredInstallation(_ expectedIdentity: AppInstallationIdentity) -> Bool {
        guard case .valid(let storedIdentity) = storedPreferredIdentity(),
              canonicalBundlePath(storedIdentity) == canonicalBundlePath(expectedIdentity),
              storedIdentity.bundleIdentifier == expectedBundleIdentifier,
              expectedIdentity.bundleIdentifier == expectedBundleIdentifier,
              storedSigningAnchorAllowsReplacement(
                  storedIdentity,
                  installedIdentity: expectedIdentity
              ),
              storedVersionAllowsReplacement(
                  storedIdentity,
                  installedIdentity: expectedIdentity
              ) else {
            return false
        }
        return revalidateRedirectTarget(expectedIdentity)
    }

    func isValidMovedSuccessor(
        _ expectedIdentity: AppInstallationIdentity,
        replacing currentIdentity: AppInstallationIdentity
    ) -> Bool {
        guard case .valid(let storedIdentity) = storedPreferredIdentity(),
              storedIdentity.bundleIdentifier == expectedBundleIdentifier,
              canonicalBundlePath(storedIdentity) == canonicalBundlePath(currentIdentity),
              expectedIdentity.bundleIdentifier == expectedBundleIdentifier,
              canonicalBundlePath(expectedIdentity) != canonicalBundlePath(currentIdentity),
              identityProvider.identity(for: storedIdentity.bundleURL) == nil,
              currentIdentity.signingAnchorDigest != nil,
              currentIdentity.signingAnchorDigest == expectedIdentity.signingAnchorDigest,
              storedSigningAnchorAllowsReplacement(
                  storedIdentity,
                  installedIdentity: expectedIdentity
              ),
              storedVersionAllowsReplacement(
                  storedIdentity,
                  installedIdentity: expectedIdentity
              ),
              let currentVersion = currentIdentity.version,
              let expectedVersion = expectedIdentity.version,
              expectedVersion.isNotOlder(than: currentVersion),
              (currentIdentity.hasCertificateBackedSignature
                  && expectedIdentity.hasCertificateBackedSignature)
                  || currentIdentity.codeIdentityDigest == expectedIdentity.codeIdentityDigest else {
            return false
        }
        return revalidateRedirectTarget(expectedIdentity)
    }

    func shouldCurrentInstallationReplaceLegacyOwner(
        currentIdentity: AppInstallationIdentity,
        ownerIdentity: AppInstallationIdentity,
        ownerIdentityWasCapturedAtClaim: Bool = true
    ) -> Bool {
        guard !currentIdentity.isDevelopmentArtifact,
              currentIdentity.bundleIdentifier == expectedBundleIdentifier,
              ownerIdentity.bundleIdentifier == expectedBundleIdentifier,
              let currentAnchor = currentIdentity.signingAnchorDigest,
              let ownerAnchor = ownerIdentity.signingAnchorDigest,
              currentAnchor == ownerAnchor,
              let currentVersion = currentIdentity.version,
              let ownerVersion = ownerIdentity.version,
              currentVersion.isNotOlder(than: ownerVersion) else {
            return false
        }

        let hasStrongSignerContinuity = currentIdentity.hasCertificateBackedSignature
            && ownerIdentity.hasCertificateBackedSignature
        let hasExactCodeContinuity = currentIdentity.codeIdentityDigest
            == ownerIdentity.codeIdentityDigest

        switch storedPreferredIdentity() {
        case .invalid:
            return false

        case .missing:
            if !ownerIdentityWasCapturedAtClaim,
               currentIdentity.bundlePath == ownerIdentity.bundlePath {
                // An earliest-v1 owner did not capture its loaded code
                // identity. After an in-place cover install the filesystem now
                // describes the claimant, while the missing handoff capability
                // proves the live owner is the stale implementation.
                return true
            }
            let isStrictlyNewer = !ownerVersion.isNotOlder(than: currentVersion)
            let hasHigherRank = installationRank(currentIdentity) > installationRank(ownerIdentity)
            return (hasStrongSignerContinuity && (isStrictlyNewer || hasHigherRank))
                || (hasExactCodeContinuity && hasHigherRank)

        case .valid(let preferredIdentity):
            guard preferredIdentity.bundleIdentifier == expectedBundleIdentifier else {
                return false
            }
            if canonicalBundlePath(preferredIdentity) == canonicalBundlePath(currentIdentity) {
                guard storedSigningAnchorAllowsReplacement(
                    preferredIdentity,
                    installedIdentity: currentIdentity
                ), storedVersionAllowsReplacement(
                    preferredIdentity,
                    installedIdentity: currentIdentity
                ) else {
                    return false
                }
                return ownerIdentity.bundlePath != currentIdentity.bundlePath
                    || preferredIdentity.codeIdentityDigest != currentIdentity.codeIdentityDigest
            }

            guard let installedPreferred = identityProvider.identity(
                for: preferredIdentity.bundleURL
            ) else {
                // The recorded bundle was truly moved or removed. The current
                // regular installation must still preserve the stored signer
                // and non-downgrade boundary before it can succeed the owner.
                return storedSigningAnchorAllowsReplacement(
                    preferredIdentity,
                    installedIdentity: currentIdentity
                ) && storedVersionAllowsReplacement(
                    preferredIdentity,
                    installedIdentity: currentIdentity
                )
            }
            guard storedSigningAnchorAllowsReplacement(
                preferredIdentity,
                installedIdentity: installedPreferred
            ), storedVersionAllowsReplacement(
                preferredIdentity,
                installedIdentity: installedPreferred
            ) else {
                return false
            }
            let isStrictlyNewer = !ownerVersion.isNotOlder(than: currentVersion)
            return hasStrongSignerContinuity && isStrictlyNewer
        }
    }

    private func storedPreferredIdentity() -> StoredPreferredIdentity {
        guard defaults.object(forKey: preferenceKey) != nil else {
            return .missing
        }
        guard let data = defaults.data(forKey: preferenceKey),
              let identity = try? JSONDecoder().decode(AppInstallationIdentity.self, from: data),
              identity.schemaVersion == AppInstallationIdentity.currentSchemaVersion else {
            return .invalid
        }
        return .valid(identity)
    }

    private func installationRank(_ identity: AppInstallationIdentity) -> Int {
        if identity.isDevelopmentArtifact {
            return 0
        }
        let components = identity.bundleURL.pathComponents
        if components.starts(with: ["/", "Applications"]) {
            return 3
        }
        if components.count >= 4,
           components[0] == "/",
           components[1] == "Users",
           components[3] == "Applications" {
            return 2
        }
        return 1
    }

    private func canRedirect(
        from current: AppInstallationIdentity,
        to candidate: AppInstallationIdentity,
        hasRecordedPathAuthority: Bool
    ) -> Bool {
        guard let currentSigningAnchor = current.signingAnchorDigest,
              let candidateSigningAnchor = candidate.signingAnchorDigest,
              currentSigningAnchor == candidateSigningAnchor,
              let currentVersion = current.version,
              let candidateVersion = candidate.version else {
            return false
        }
        guard candidateVersion.isNotOlder(than: currentVersion) else {
            return false
        }
        if !hasRecordedPathAuthority,
           !current.hasCertificateBackedSignature || !candidate.hasCertificateBackedSignature {
            // An ad-hoc identifier is not a cryptographic publisher identity.
            // Without a recorded path decision, only an exact copied build can
            // move to a higher-ranked location automatically.
            return current.codeIdentityDigest == candidate.codeIdentityDigest
        }
        return true
    }

    private func storedSigningAnchorAllowsReplacement(
        _ storedIdentity: AppInstallationIdentity,
        installedIdentity: AppInstallationIdentity
    ) -> Bool {
        guard let storedAnchor = storedIdentity.signingAnchorDigest else {
            // Early schema-v1 records had no signer boundary. They can migrate
            // only while the exact recorded code identity is still present.
            return storedIdentity.codeIdentityDigest == installedIdentity.codeIdentityDigest
        }
        return storedAnchor == installedIdentity.signingAnchorDigest
    }

    private func storedVersionAllowsReplacement(
        _ storedIdentity: AppInstallationIdentity,
        installedIdentity: AppInstallationIdentity
    ) -> Bool {
        guard let storedVersion = storedIdentity.version else {
            // A missing non-downgrade boundary is safe to upgrade only when the
            // code identity has not changed since the legacy record was written.
            return storedIdentity.codeIdentityDigest == installedIdentity.codeIdentityDigest
        }
        guard let installedVersion = installedIdentity.version else {
            return false
        }
        return installedVersion.isNotOlder(than: storedVersion)
    }

    private func canonicalBundlePath(_ identity: AppInstallationIdentity) -> String {
        identity.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func bestDiscoveredInstallationCandidate(
        for currentIdentity: AppInstallationIdentity
    ) -> AppInstallationIdentity? {
        let appName = currentIdentity.bundleURL.lastPathComponent
        var candidateURLs = [
            URL(fileURLWithPath: "/Applications", isDirectory: true)
                .appendingPathComponent(appName, isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(appName, isDirectory: true)
        ]
        if let registeredURL = registeredApplicationURLProvider(currentIdentity.bundleIdentifier) {
            candidateURLs.append(registeredURL)
        }

        let currentRank = installationRank(currentIdentity)
        var seenPaths = Set<String>()
        return candidateURLs.compactMap { candidateURL -> AppInstallationIdentity? in
            let canonicalURL = candidateURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard canonicalURL.path != currentIdentity.bundlePath,
                  seenPaths.insert(canonicalURL.path).inserted,
                  let candidate = identityProvider.identity(for: canonicalURL),
                  candidate.bundleIdentifier == currentIdentity.bundleIdentifier,
                  canRedirect(
                    from: currentIdentity,
                    to: candidate,
                    hasRecordedPathAuthority: false
                  ),
                  installationRank(candidate) > currentRank else {
                return nil
            }
            return candidate
        }
        .max { installationRank($0) < installationRank($1) }
    }
}
