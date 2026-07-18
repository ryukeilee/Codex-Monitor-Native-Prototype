import XCTest
@testable import CodexMonitorNative

@MainActor
final class AppInstallationAuthorityTests: XCTestCase {
    func testFirstInstalledAppBecomesPreferredOnlyAfterOwnerCommitsIt() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let current = fixture.identity(path: "/Applications/CodexMonitorNative.app", digest: "new")
        fixture.provider.identities[current.bundlePath] = current
        let authority = fixture.authority(currentURL: current.bundleURL)

        let resolution = authority.resolveCurrentInstallation()

        XCTAssertEqual(
            resolution,
            .useCurrent(
                identity: current,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )
        XCTAssertNil(try fixture.storedIdentity())

        authority.persistPreferredInstallation(current)
        XCTAssertEqual(try fixture.storedIdentity(), current)
    }

    func testFirstRunOldCopyRedirectsToHigherRankedLaunchServicesInstallation() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let installed = fixture.identity(path: "/Applications/CodexMonitorNative.app", digest: "installed")
        let oldCopy = fixture.identity(path: "/Users/test/Downloads/CodexMonitorNative.app", digest: "old")
        fixture.provider.identities[installed.bundlePath] = installed
        fixture.provider.identities[oldCopy.bundlePath] = oldCopy
        fixture.registeredApplicationURL = installed.bundleURL

        let resolution = fixture.authority(currentURL: oldCopy.bundleURL).resolveCurrentInstallation()

        XCTAssertEqual(resolution, .redirect(installed))
    }

    func testFirstRunOlderCopyRedirectsToHigherRankedNewerInstallation() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let installed = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "installed",
            marketingVersion: "2.0"
        )
        let oldCopy = fixture.identity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "old",
            marketingVersion: "1.9"
        )
        fixture.provider.identities[installed.bundlePath] = installed
        fixture.provider.identities[oldCopy.bundlePath] = oldCopy

        let resolution = fixture.authority(currentURL: oldCopy.bundleURL).resolveCurrentInstallation()

        XCTAssertEqual(resolution, .redirect(installed))
    }

    func testFirstRunNewerDownloadsCopyDoesNotRedirectToOlderApplicationsCopy() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let installed = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "installed-old",
            marketingVersion: "1.9"
        )
        let downloaded = fixture.identity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "downloaded-new",
            marketingVersion: "2.0"
        )
        fixture.provider.identities[installed.bundlePath] = installed
        fixture.provider.identities[downloaded.bundlePath] = downloaded
        fixture.registeredApplicationURL = installed.bundleURL

        let resolution = fixture.authority(currentURL: downloaded.bundleURL).resolveCurrentInstallation()

        XCTAssertEqual(
            resolution,
            .useCurrent(
                identity: downloaded,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )
    }

    func testFirstRunHigherRankedCandidateWithDifferentSigningAnchorIsIgnored() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let installed = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "installed",
            signingAnchor: "other-signer"
        )
        let downloaded = fixture.identity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "downloaded"
        )
        fixture.provider.identities[installed.bundlePath] = installed
        fixture.provider.identities[downloaded.bundlePath] = downloaded

        let resolution = fixture.authority(currentURL: downloaded.bundleURL).resolveCurrentInstallation()

        XCTAssertEqual(
            resolution,
            .useCurrent(
                identity: downloaded,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )
    }

    func testFirstRunApplicationsCopyIsNotDisplacedByLowerRankedLaunchServicesEntry() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let installed = fixture.identity(path: "/Applications/CodexMonitorNative.app", digest: "installed")
        let oldCopy = fixture.identity(path: "/Users/test/Downloads/CodexMonitorNative.app", digest: "old")
        fixture.provider.identities[installed.bundlePath] = installed
        fixture.provider.identities[oldCopy.bundlePath] = oldCopy
        fixture.registeredApplicationURL = oldCopy.bundleURL

        let resolution = fixture.authority(currentURL: installed.bundleURL).resolveCurrentInstallation()

        XCTAssertEqual(
            resolution,
            .useCurrent(
                identity: installed,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )
    }

    func testCoverInstallOrResignAtSamePathAdoptsNewExecutableIdentity() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let old = fixture.identity(path: "/Applications/CodexMonitorNative.app", digest: "old")
        let current = fixture.identity(path: old.bundlePath, digest: "new")
        try fixture.store(old)
        fixture.provider.identities[current.bundlePath] = current

        let resolution = fixture.authority(currentURL: current.bundleURL).resolveCurrentInstallation()

        XCTAssertEqual(
            resolution,
            .useCurrent(
                identity: current,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )
    }

    func testSamePathReplacementWithDifferentSigningAnchorFailsClosed() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let recorded = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "recorded",
            signingAnchor: "recorded-signer"
        )
        let replacement = fixture.identity(
            path: recorded.bundlePath,
            digest: "replacement",
            signingAnchor: "other-signer"
        )
        try fixture.store(recorded)
        fixture.provider.identities[replacement.bundlePath] = replacement

        XCTAssertEqual(
            fixture.authority(currentURL: replacement.bundleURL)
                .resolveCurrentInstallation(),
            .reject("当前 App 签名身份与已记录安装不一致")
        )
    }

    func testSamePathDowngradeFailsClosed() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let recorded = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "recorded-new",
            marketingVersion: "2.0"
        )
        let downgraded = fixture.identity(
            path: recorded.bundlePath,
            digest: "downgraded",
            marketingVersion: "1.9"
        )
        try fixture.store(recorded)
        fixture.provider.identities[downgraded.bundlePath] = downgraded

        XCTAssertEqual(
            fixture.authority(currentURL: downgraded.bundleURL)
                .resolveCurrentInstallation(),
            .reject("当前 App 版本低于已记录安装")
        )
    }

    func testLegacyIdentityWithoutSigningAnchorRequiresExactCodeContinuity() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let path = "/Applications/CodexMonitorNative.app"
        let legacy = AppInstallationIdentity(
            bundlePath: path,
            bundleIdentifier: "com.ryukeilee.CodexMonitorNativePrototype",
            codeIdentityDigest: "legacy-code",
            signingAnchorDigest: nil,
            signatureKind: nil,
            version: AppInstallationVersion(marketingVersion: "1.0", buildVersion: "1")
        )
        try fixture.store(legacy)

        let differentCode = fixture.identity(path: path, digest: "replacement-code")
        fixture.provider.identities[path] = differentCode
        XCTAssertEqual(
            fixture.authority(currentURL: differentCode.bundleURL).resolveCurrentInstallation(),
            .reject("当前 App 签名身份与已记录安装不一致")
        )

        let exactCode = fixture.identity(path: path, digest: legacy.codeIdentityDigest)
        fixture.provider.identities[path] = exactCode
        XCTAssertEqual(
            fixture.authority(currentURL: exactCode.bundleURL).resolveCurrentInstallation(),
            .useCurrent(
                identity: exactCode,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )
    }

    func testLegacyIdentityWithoutVersionRequiresExactCodeContinuity() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let path = "/Applications/CodexMonitorNative.app"
        let legacy = AppInstallationIdentity(
            bundlePath: path,
            bundleIdentifier: "com.ryukeilee.CodexMonitorNativePrototype",
            codeIdentityDigest: "legacy-code",
            signingAnchorDigest: "trusted-signing-anchor",
            signatureKind: .certificateBacked,
            version: nil
        )
        try fixture.store(legacy)

        let differentCode = fixture.identity(path: path, digest: "replacement-code")
        fixture.provider.identities[path] = differentCode
        XCTAssertEqual(
            fixture.authority(currentURL: differentCode.bundleURL).resolveCurrentInstallation(),
            .reject("当前 App 版本低于已记录安装")
        )

        let exactCode = fixture.identity(path: path, digest: legacy.codeIdentityDigest)
        fixture.provider.identities[path] = exactCode
        XCTAssertEqual(
            fixture.authority(currentURL: exactCode.bundleURL).resolveCurrentInstallation(),
            .useCurrent(
                identity: exactCode,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )
    }

    func testCanonicalEquivalentStoredPathUsesCurrentInstallationInsteadOfRedirecting() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let current = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "current"
        )
        let aliasedRecord = AppInstallationIdentity(
            bundlePath: "/Applications/../Applications/CodexMonitorNative.app",
            bundleIdentifier: current.bundleIdentifier,
            codeIdentityDigest: current.codeIdentityDigest,
            signingAnchorDigest: current.signingAnchorDigest,
            signatureKind: current.signatureKind,
            version: current.version
        )
        try fixture.store(aliasedRecord)
        fixture.provider.identities[current.bundlePath] = current

        XCTAssertEqual(
            fixture.authority(currentURL: current.bundleURL).resolveCurrentInstallation(),
            .useCurrent(
                identity: current,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )
    }

    func testUnrecordedAdHocCandidateRequiresExactCodeIdentity() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let installed = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "independent-build",
            signatureKind: .adHoc
        )
        let downloaded = fixture.identity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "current-build",
            signatureKind: .adHoc
        )
        fixture.provider.identities[installed.bundlePath] = installed
        fixture.provider.identities[downloaded.bundlePath] = downloaded

        XCTAssertEqual(
            fixture.authority(currentURL: downloaded.bundleURL)
                .resolveCurrentInstallation(),
            .useCurrent(
                identity: downloaded,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )

        let copiedBuild = fixture.identity(
            path: installed.bundlePath,
            digest: downloaded.codeIdentityDigest,
            signatureKind: .adHoc
        )
        fixture.provider.identities[copiedBuild.bundlePath] = copiedBuild
        XCTAssertEqual(
            fixture.authority(currentURL: downloaded.bundleURL)
                .resolveCurrentInstallation(),
            .redirect(copiedBuild)
        )
    }

    func testMovedAppAdoptsCurrentPathWhenRecordedPathNoLongerContainsAnApp() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let old = fixture.identity(path: "/Applications/CodexMonitorNative.app", digest: "same")
        let moved = fixture.identity(path: "/Users/test/Applications/CodexMonitorNative.app", digest: "same")
        try fixture.store(old)
        fixture.provider.identities[moved.bundlePath] = moved

        let resolution = fixture.authority(currentURL: moved.bundleURL).resolveCurrentInstallation()

        XCTAssertEqual(
            resolution,
            .useCurrent(
                identity: moved,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )
    }

    func testMovedAppMustKeepStoredSignerAndVersion() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let recorded = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "recorded",
            signingAnchor: "recorded-signer",
            marketingVersion: "2.0"
        )
        try fixture.store(recorded)

        let wrongSigner = fixture.identity(
            path: "/Users/test/Applications/CodexMonitorNative.app",
            digest: "moved",
            signingAnchor: "other-signer",
            marketingVersion: "2.0"
        )
        fixture.provider.identities[wrongSigner.bundlePath] = wrongSigner
        XCTAssertEqual(
            fixture.authority(currentURL: wrongSigner.bundleURL)
                .resolveCurrentInstallation(),
            .reject("移动后的 App 签名身份与已记录安装不一致")
        )

        let downgraded = fixture.identity(
            path: wrongSigner.bundlePath,
            digest: "moved-old",
            signingAnchor: "recorded-signer",
            marketingVersion: "1.9"
        )
        fixture.provider.identities[downgraded.bundlePath] = downgraded
        XCTAssertEqual(
            fixture.authority(currentURL: downgraded.bundleURL)
                .resolveCurrentInstallation(),
            .reject("移动后的 App 版本低于已记录安装")
        )
    }

    func testMovedLegacyIdentityWithoutSignerOrVersionRequiresExactCodeContinuity() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let legacy = AppInstallationIdentity(
            bundlePath: "/Applications/CodexMonitorNative.app",
            bundleIdentifier: "com.ryukeilee.CodexMonitorNativePrototype",
            codeIdentityDigest: "legacy-code",
            signingAnchorDigest: nil,
            signatureKind: nil,
            version: nil
        )
        try fixture.store(legacy)
        let movedPath = "/Users/test/Applications/CodexMonitorNative.app"

        let differentCode = fixture.identity(path: movedPath, digest: "replacement-code")
        fixture.provider.identities[movedPath] = differentCode
        XCTAssertEqual(
            fixture.authority(currentURL: differentCode.bundleURL).resolveCurrentInstallation(),
            .reject("移动后的 App 签名身份与已记录安装不一致")
        )

        let exactCode = fixture.identity(path: movedPath, digest: legacy.codeIdentityDigest)
        fixture.provider.identities[movedPath] = exactCode
        XCTAssertEqual(
            fixture.authority(currentURL: exactCode.bundleURL).resolveCurrentInstallation(),
            .useCurrent(
                identity: exactCode,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )
    }

    func testOldCopyRedirectsToRecordedPreferredInstallationBeforeClaimingOwnership() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let preferred = fixture.identity(path: "/Applications/CodexMonitorNative.app", digest: "preferred")
        let oldCopy = fixture.identity(path: "/Users/test/Downloads/CodexMonitorNative.app", digest: "old")
        try fixture.store(preferred)
        fixture.provider.identities[preferred.bundlePath] = preferred
        fixture.provider.identities[oldCopy.bundlePath] = oldCopy

        let resolution = fixture.authority(currentURL: oldCopy.bundleURL).resolveCurrentInstallation()

        XCTAssertEqual(resolution, .redirect(preferred))
    }

    func testUpdatedPreferredBundleStillWinsOverAnOldCopyBeforeItHasLaunched() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let recorded = fixture.identity(path: "/Applications/CodexMonitorNative.app", digest: "old")
        let updatedOnDisk = fixture.identity(path: recorded.bundlePath, digest: "new")
        let staleCopy = fixture.identity(path: "/Users/test/Downloads/CodexMonitorNative.app", digest: "old")
        try fixture.store(recorded)
        fixture.provider.identities[recorded.bundlePath] = updatedOnDisk
        fixture.provider.identities[staleCopy.bundlePath] = staleCopy

        let resolution = fixture.authority(currentURL: staleCopy.bundleURL).resolveCurrentInstallation()

        XCTAssertEqual(resolution, .redirect(updatedOnDisk))
    }

    func testRecordedPreferredInstallationCannotRedirectAcrossSigningAnchors() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let recorded = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "recorded",
            signingAnchor: "recorded-signer"
        )
        let installedOnDisk = fixture.identity(
            path: recorded.bundlePath,
            digest: "replacement",
            signingAnchor: "replacement-signer"
        )
        let downloaded = fixture.identity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "downloaded",
            signingAnchor: "download-signer"
        )
        try fixture.store(recorded)
        fixture.provider.identities[recorded.bundlePath] = installedOnDisk
        fixture.provider.identities[downloaded.bundlePath] = downloaded

        let resolution = fixture.authority(currentURL: downloaded.bundleURL).resolveCurrentInstallation()

        XCTAssertEqual(resolution, .reject("首选 App 签名身份已改变"))
    }

    func testRecordedPreferredInstallationOlderThanCurrentCannotRedirect() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let preferred = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "preferred-old",
            marketingVersion: "1.0"
        )
        let downloaded = fixture.identity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "downloaded-new",
            marketingVersion: "1.1"
        )
        try fixture.store(preferred)
        fixture.provider.identities[preferred.bundlePath] = preferred
        fixture.provider.identities[downloaded.bundlePath] = downloaded

        let resolution = fixture.authority(currentURL: downloaded.bundleURL).resolveCurrentInstallation()

        XCTAssertEqual(
            resolution,
            .useCurrent(
                identity: downloaded,
                shouldPersist: true,
                allowsAutomaticLoginItemReconciliation: true
            )
        )
    }

    func testNewerAdHocCopyCannotDisplaceExistingRecordedPreferredPath() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let preferred = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "preferred-old",
            signatureKind: .adHoc,
            marketingVersion: "1.0"
        )
        let downloaded = fixture.identity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "independent-new",
            signatureKind: .adHoc,
            marketingVersion: "2.0"
        )
        try fixture.store(preferred)
        fixture.provider.identities[preferred.bundlePath] = preferred
        fixture.provider.identities[downloaded.bundlePath] = downloaded

        XCTAssertEqual(
            fixture.authority(currentURL: downloaded.bundleURL)
                .resolveCurrentInstallation(),
            .reject("未记录的 ad-hoc App 不能替换现有首选安装")
        )
    }

    func testRecordedPreferredPathCannotBeDowngradedOnDisk() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let recorded = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "recorded-new",
            marketingVersion: "2.0"
        )
        let downgradedOnDisk = fixture.identity(
            path: recorded.bundlePath,
            digest: "downgraded",
            marketingVersion: "1.0"
        )
        let staleCopy = fixture.identity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "stale",
            marketingVersion: "0.9"
        )
        try fixture.store(recorded)
        fixture.provider.identities[recorded.bundlePath] = downgradedOnDisk
        fixture.provider.identities[staleCopy.bundlePath] = staleCopy

        XCTAssertEqual(
            fixture.authority(currentURL: staleCopy.bundleURL)
                .resolveCurrentInstallation(),
            .reject("首选 App 版本低于已记录安装")
        )
    }

    func testRecordedPreferredReplacementMustKeepStoredSigningAnchor() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let recorded = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "recorded",
            signingAnchor: "trusted-signer"
        )
        let replacedOnDisk = fixture.identity(
            path: recorded.bundlePath,
            digest: "replacement",
            signingAnchor: "unexpected-signer"
        )
        let oldCopy = fixture.identity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "old",
            signingAnchor: "unexpected-signer"
        )
        try fixture.store(recorded)
        fixture.provider.identities[recorded.bundlePath] = replacedOnDisk
        fixture.provider.identities[oldCopy.bundlePath] = oldCopy

        let resolution = fixture.authority(
            currentURL: oldCopy.bundleURL
        ).resolveCurrentInstallation()

        XCTAssertEqual(resolution, .reject("首选 App 签名身份已改变"))
    }

    func testRedirectTargetMustStillMatchImmediatelyBeforeLaunch() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let expected = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "expected"
        )
        fixture.provider.identities[expected.bundlePath] = expected
        let authority = fixture.authority(currentURL: expected.bundleURL)

        XCTAssertTrue(authority.revalidateRedirectTarget(expected))

        fixture.provider.identities[expected.bundlePath] = fixture.identity(
            path: expected.bundlePath,
            digest: "replaced-after-resolution"
        )
        XCTAssertFalse(authority.revalidateRedirectTarget(expected))
    }

    func testRecordedPreferredCheckAcceptsResignedContentsAtSameStableAnchor() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let recorded = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "old"
        )
        let currentOnDisk = fixture.identity(
            path: recorded.bundlePath,
            digest: "resigned"
        )
        try fixture.store(recorded)
        fixture.provider.identities[currentOnDisk.bundlePath] = currentOnDisk

        XCTAssertTrue(
            fixture.authority(currentURL: currentOnDisk.bundleURL)
                .isRecordedPreferredInstallation(currentOnDisk)
        )
    }

    func testMovedSuccessorCanReplaceLiveOwnerAfterRecordedPathDisappears() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let recordedOwner = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "same-build"
        )
        let movedSuccessor = fixture.identity(
            path: "/Users/test/Applications/CodexMonitorNative.app",
            digest: "same-build"
        )
        try fixture.store(recordedOwner)
        fixture.provider.identities[movedSuccessor.bundlePath] = movedSuccessor

        XCTAssertTrue(
            fixture.authority(currentURL: recordedOwner.bundleURL)
                .isValidMovedSuccessor(
                    movedSuccessor,
                    replacing: recordedOwner
                )
        )
    }

    func testMovedSuccessorCannotReplaceLiveOwnerWhileRecordedPathStillExists() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let recordedOwner = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "same-build"
        )
        let secondCopy = fixture.identity(
            path: "/Users/test/Applications/CodexMonitorNative.app",
            digest: "same-build"
        )
        try fixture.store(recordedOwner)
        fixture.provider.identities[recordedOwner.bundlePath] = recordedOwner
        fixture.provider.identities[secondCopy.bundlePath] = secondCopy

        XCTAssertFalse(
            fixture.authority(currentURL: recordedOwner.bundleURL)
                .isValidMovedSuccessor(
                    secondCopy,
                    replacing: recordedOwner
                )
        )
    }

    func testMovedSuccessorRejectsWrongSignerDowngradeAndIndependentAdHocBuild() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let recordedOwner = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "recorded",
            marketingVersion: "2.0"
        )
        try fixture.store(recordedOwner)
        let authority = fixture.authority(currentURL: recordedOwner.bundleURL)

        let wrongSigner = fixture.identity(
            path: "/Users/test/Applications/CodexMonitorNative.app",
            digest: "replacement",
            signingAnchor: "other-signer",
            marketingVersion: "2.0"
        )
        fixture.provider.identities[wrongSigner.bundlePath] = wrongSigner
        XCTAssertFalse(
            authority.isValidMovedSuccessor(wrongSigner, replacing: recordedOwner)
        )

        let downgrade = fixture.identity(
            path: wrongSigner.bundlePath,
            digest: "replacement",
            marketingVersion: "1.0"
        )
        fixture.provider.identities[downgrade.bundlePath] = downgrade
        XCTAssertFalse(
            authority.isValidMovedSuccessor(downgrade, replacing: recordedOwner)
        )

        let adHocOwner = fixture.identity(
            path: recordedOwner.bundlePath,
            digest: "ad-hoc-owner",
            signatureKind: .adHoc,
            marketingVersion: "2.0"
        )
        try fixture.store(adHocOwner)
        let independentAdHoc = fixture.identity(
            path: wrongSigner.bundlePath,
            digest: "independent-ad-hoc",
            signatureKind: .adHoc,
            marketingVersion: "2.0"
        )
        fixture.provider.identities[independentAdHoc.bundlePath] = independentAdHoc
        XCTAssertFalse(
            authority.isValidMovedSuccessor(
                independentAdHoc,
                replacing: adHocOwner
            )
        )
    }

    func testFirstUpgradeCandidateCanReplaceLowerRankedLegacyOwner() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let installed = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "current"
        )
        let legacyOwner = fixture.identity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "legacy"
        )

        XCTAssertTrue(
            fixture.authority(currentURL: installed.bundleURL)
                .shouldCurrentInstallationReplaceLegacyOwner(
                    currentIdentity: installed,
                    ownerIdentity: legacyOwner
                )
        )
    }

    func testSamePathCoverUpgradeCanReplaceLegacyOwnerWithoutCapturedIdentity() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let current = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "current"
        )

        XCTAssertTrue(
            fixture.authority(currentURL: current.bundleURL)
                .shouldCurrentInstallationReplaceLegacyOwner(
                    currentIdentity: current,
                    ownerIdentity: current,
                    ownerIdentityWasCapturedAtClaim: false
                )
        )
    }

    func testUnrecordedAdHocBuildCannotReplaceDifferentLegacyBuildAcrossPaths() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let current = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "current",
            signatureKind: .adHoc,
            marketingVersion: "2.0"
        )
        let legacyOwner = fixture.identity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "independent-legacy",
            signatureKind: .adHoc,
            marketingVersion: "1.0"
        )

        XCTAssertFalse(
            fixture.authority(currentURL: current.bundleURL)
                .shouldCurrentInstallationReplaceLegacyOwner(
                    currentIdentity: current,
                    ownerIdentity: legacyOwner
                )
        )
    }

    func testLegacyOwnerWithDifferentSignerCannotBeReplacedAutomatically() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let installed = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "current",
            signingAnchor: "current-signer"
        )
        let legacyOwner = fixture.identity(
            path: "/Users/test/Downloads/CodexMonitorNative.app",
            digest: "legacy",
            signingAnchor: "other-signer"
        )

        XCTAssertFalse(
            fixture.authority(currentURL: installed.bundleURL)
                .shouldCurrentInstallationReplaceLegacyOwner(
                    currentIdentity: installed,
                    ownerIdentity: legacyOwner
                )
        )
    }

    func testSigningAnchorDigestIsStableForSameRequirementAndChangesWithSigner() {
        let first = AppInstallationSigningAnchor.digest(
            designatedRequirement: "identifier com.example.app and anchor apple generic",
            teamIdentifier: "TEAM123",
            signingIdentifier: "com.example.app",
            isAdHoc: false
        )
        let resigned = AppInstallationSigningAnchor.digest(
            designatedRequirement: "identifier com.example.app and anchor apple generic",
            teamIdentifier: "TEAM123",
            signingIdentifier: "com.example.app",
            isAdHoc: false
        )
        let otherTeam = AppInstallationSigningAnchor.digest(
            designatedRequirement: "identifier com.example.app and anchor apple generic",
            teamIdentifier: "OTHER456",
            signingIdentifier: "com.example.app",
            isAdHoc: false
        )
        let firstAdHoc = AppInstallationSigningAnchor.digest(
            designatedRequirement: "cdhash H\"first-executable-digest\"",
            teamIdentifier: nil,
            signingIdentifier: "com.example.app",
            isAdHoc: true
        )
        let resignedAdHoc = AppInstallationSigningAnchor.digest(
            designatedRequirement: "cdhash H\"second-executable-digest\"",
            teamIdentifier: nil,
            signingIdentifier: "com.example.app",
            isAdHoc: true
        )

        XCTAssertEqual(first, resigned)
        XCTAssertNotEqual(first, otherTeam)
        XCTAssertEqual(firstAdHoc, resignedAdHoc)
    }

    func testDirectDevelopmentCopyRedirectsButScriptOptInCanExerciseSingleInstanceArbitration() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let preferred = fixture.identity(path: "/Applications/CodexMonitorNative.app", digest: "preferred")
        let development = fixture.identity(
            path: "/Users/test/repository/dist/CodexMonitorNative.app",
            digest: "development"
        )
        try fixture.store(preferred)
        fixture.provider.identities[preferred.bundlePath] = preferred
        fixture.provider.identities[development.bundlePath] = development

        XCTAssertEqual(
            fixture.authority(currentURL: development.bundleURL).resolveCurrentInstallation(),
            .redirect(preferred)
        )

        XCTAssertEqual(
            fixture.authority(
                currentURL: development.bundleURL,
                arguments: ["CodexMonitorNative", AppInstallationAuthority.developmentLaunchArgument]
            ).resolveCurrentInstallation(),
            .useCurrent(
                identity: development,
                shouldPersist: false,
                allowsAutomaticLoginItemReconciliation: false
            )
        )
    }

    func testDevelopmentArtifactWithoutPreferredInstallationCannotAutoRepairLoginItem() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let development = fixture.identity(
            path: "/Users/test/repository/dist/CodexMonitorNative.app",
            digest: "development"
        )
        fixture.provider.identities[development.bundlePath] = development

        let resolution = fixture.authority(currentURL: development.bundleURL).resolveCurrentInstallation()

        XCTAssertEqual(
            resolution,
            .useCurrent(
                identity: development,
                shouldPersist: false,
                allowsAutomaticLoginItemReconciliation: false
            )
        )
    }

    func testDevelopmentBypassArgumentCannotPromoteOrdinaryOldAppCopy() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let preferred = fixture.identity(path: "/Applications/CodexMonitorNative.app", digest: "preferred")
        let oldCopy = fixture.identity(path: "/Users/test/Downloads/CodexMonitorNative.app", digest: "old")
        try fixture.store(preferred)
        fixture.provider.identities[preferred.bundlePath] = preferred
        fixture.provider.identities[oldCopy.bundlePath] = oldCopy

        let resolution = fixture.authority(
            currentURL: oldCopy.bundleURL,
            arguments: ["CodexMonitorNative", AppInstallationAuthority.developmentLaunchArgument]
        ).resolveCurrentInstallation()

        XCTAssertEqual(resolution, .redirect(preferred))
    }

    func testMalformedOrUnsupportedPreferredIdentityFailsClosed() throws {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let current = fixture.identity(path: "/Users/test/Downloads/CodexMonitorNative.app", digest: "old")
        fixture.provider.identities[current.bundlePath] = current
        fixture.defaults.set(Data("not-json".utf8), forKey: fixture.preferenceKey)

        XCTAssertEqual(
            fixture.authority(currentURL: current.bundleURL).resolveCurrentInstallation(),
            .reject("已保存的 App 安装身份无效")
        )

        let unsupported: [String: Any] = [
            "schemaVersion": 999,
            "bundlePath": "/Applications/CodexMonitorNative.app",
            "bundleIdentifier": "com.ryukeilee.CodexMonitorNativePrototype",
            "codeIdentityDigest": "future"
        ]
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: unsupported), forKey: fixture.preferenceKey)
        XCTAssertEqual(
            fixture.authority(currentURL: current.bundleURL).resolveCurrentInstallation(),
            .reject("已保存的 App 安装身份无效")
        )
    }

    func testSchemaOneIdentityWithoutSignatureKindStillDecodes() throws {
        let legacyObject: [String: Any] = [
            "schemaVersion": 1,
            "bundlePath": "/Applications/CodexMonitorNative.app",
            "bundleIdentifier": "com.ryukeilee.CodexMonitorNativePrototype",
            "codeIdentityDigest": "legacy-digest",
            "signingAnchorDigest": "legacy-anchor",
            "version": [
                "marketingVersion": "1.0",
                "buildVersion": "1"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyObject)

        let identity = try JSONDecoder().decode(
            AppInstallationIdentity.self,
            from: data
        )

        XCTAssertNil(identity.signatureKind)
        XCTAssertEqual(identity.signingAnchorDigest, "legacy-anchor")
        XCTAssertEqual(identity.version?.marketingVersion, "1.0")
    }

    func testUnexpectedCurrentBundleIdentifierFailsClosed() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let unexpected = AppInstallationIdentity(
            bundlePath: "/Applications/CodexMonitorNative.app",
            bundleIdentifier: "example.unexpected.copy",
            codeIdentityDigest: "unexpected"
        )
        fixture.provider.identities[unexpected.bundlePath] = unexpected

        let resolution = fixture.authority(currentURL: unexpected.bundleURL).resolveCurrentInstallation()

        XCTAssertEqual(resolution, .reject("当前 App Bundle ID 与预期不一致"))
    }

    func testUnsignedCurrentAppFailsClosedBeforeItCanBecomePreferred() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let unsigned = fixture.identity(
            path: "/Applications/CodexMonitorNative.app",
            digest: "unsigned",
            signingAnchor: nil
        )
        fixture.provider.identities[unsigned.bundlePath] = unsigned

        XCTAssertEqual(
            fixture.authority(currentURL: unsigned.bundleURL).resolveCurrentInstallation(),
            .reject("当前 App 代码签名无效")
        )
    }

    func testRawSwiftPMExecutableIsUnmanagedAndCannotMutateLoginItemAutomatically() {
        let fixture = AppInstallationAuthorityFixture()
        defer { fixture.cleanup() }
        let rawExecutableDirectory = URL(fileURLWithPath: "/tmp/debug-build", isDirectory: true)

        let resolution = fixture.authority(currentURL: rawExecutableDirectory).resolveCurrentInstallation()

        XCTAssertEqual(
            resolution,
            .useCurrent(
                identity: nil,
                shouldPersist: false,
                allowsAutomaticLoginItemReconciliation: false
            )
        )
    }

    func testSystemIdentityChangesWhenExecutableOrPathChanges() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorIdentityTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let firstBundleURL = temporaryDirectory.appendingPathComponent("First.app", isDirectory: true)
        let secondBundleURL = temporaryDirectory.appendingPathComponent("Second.app", isDirectory: true)
        try makeBundle(at: firstBundleURL, executableContents: Data("first".utf8))
        try makeBundle(at: secondBundleURL, executableContents: Data("first".utf8))
        let provider = SystemAppInstallationIdentityProvider()

        let first = try XCTUnwrap(provider.identity(for: firstBundleURL))
        let second = try XCTUnwrap(provider.identity(for: secondBundleURL))
        XCTAssertNotEqual(first, second)

        let executableURL = firstBundleURL
            .appendingPathComponent("Contents/MacOS/CodexMonitorNative")
        try Data("resigned-or-replaced".utf8).write(to: executableURL)
        let replaced = try XCTUnwrap(provider.identity(for: firstBundleURL))
        XCTAssertNotEqual(first.codeIdentityDigest, replaced.codeIdentityDigest)
        XCTAssertEqual(first.bundlePath, replaced.bundlePath)

        let codeResourcesURL = firstBundleURL
            .appendingPathComponent("Contents/_CodeSignature/CodeResources")
        try FileManager.default.createDirectory(
            at: codeResourcesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("new-signature-envelope".utf8).write(to: codeResourcesURL)
        let resigned = try XCTUnwrap(provider.identity(for: firstBundleURL))
        XCTAssertNotEqual(replaced.codeIdentityDigest, resigned.codeIdentityDigest)
    }

    func testSystemIdentityReadsUpdatedVersionFromFreshInfoPlistAtSamePath() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorVersionTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let bundleURL = temporaryDirectory.appendingPathComponent("Versioned.app", isDirectory: true)
        let executableContents = Data("same-executable".utf8)
        try makeBundle(
            at: bundleURL,
            executableContents: executableContents,
            marketingVersion: "1.0",
            buildVersion: "1"
        )
        let provider = SystemAppInstallationIdentityProvider()
        let first = try XCTUnwrap(provider.identity(for: bundleURL))

        try makeBundle(
            at: bundleURL,
            executableContents: executableContents,
            marketingVersion: "2.0",
            buildVersion: "2"
        )
        let replaced = try XCTUnwrap(provider.identity(for: bundleURL))

        XCTAssertEqual(
            first.version,
            AppInstallationVersion(marketingVersion: "1.0", buildVersion: "1")
        )
        XCTAssertEqual(
            replaced.version,
            AppInstallationVersion(marketingVersion: "2.0", buildVersion: "2")
        )
        XCTAssertNotEqual(first.codeIdentityDigest, replaced.codeIdentityDigest)
    }

    func testSystemSigningAnchorIsStableAcrossAdHocResigning() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMonitorSigningAnchorTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let bundleURL = temporaryDirectory.appendingPathComponent("Signed.app", isDirectory: true)
        try makeBundle(
            at: bundleURL,
            executableContents: Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        )
        try signBundle(at: bundleURL)

        let provider = SystemAppInstallationIdentityProvider()
        let first = try XCTUnwrap(provider.identity(for: bundleURL))
        let firstAnchor = try XCTUnwrap(first.signingAnchorDigest)
        XCTAssertEqual(first.signatureKind, .adHoc)

        let executableURL = bundleURL
            .appendingPathComponent("Contents/MacOS/CodexMonitorNative")
        try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/false")).write(to: executableURL)
        try signBundle(at: bundleURL)

        let resigned = try XCTUnwrap(provider.identity(for: bundleURL))
        XCTAssertEqual(resigned.signingAnchorDigest, firstAnchor)
        XCTAssertEqual(resigned.signatureKind, .adHoc)
        XCTAssertNotEqual(resigned.codeIdentityDigest, first.codeIdentityDigest)
    }

    func testSystemIdentityReadsCertificateBackedSignatureFromSystemApp() throws {
        let systemAppURL = URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app",
            isDirectory: true
        )
        let provider = SystemAppInstallationIdentityProvider()

        let identity = try XCTUnwrap(provider.identity(for: systemAppURL))

        XCTAssertEqual(identity.signatureKind, .certificateBacked)
        XCTAssertNotNil(identity.signingAnchorDigest)
    }

    private func makeBundle(
        at bundleURL: URL,
        executableContents: Data,
        marketingVersion: String = "1.0",
        buildVersion: String = "1"
    ) throws {
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: macOSURL,
            withIntermediateDirectories: true
        )
        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "CodexMonitorNative",
            "CFBundleIdentifier": "com.ryukeilee.CodexMonitorNativePrototype",
            "CFBundleName": "CodexMonitorNative",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": marketingVersion,
            "CFBundleVersion": buildVersion
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        let executableURL = macOSURL.appendingPathComponent("CodexMonitorNative")
        try executableContents.write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    private func signBundle(at bundleURL: URL) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--force",
            "--sign", "-",
            "--timestamp=none",
            bundleURL.path
        ]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "codesign failed"
            throw NSError(
                domain: "AppInstallationAuthorityTests.codesign",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}

@MainActor
private final class AppInstallationAuthorityFixture {
    let suiteName = "CodexMonitorNativeTests.installationAuthority.\(UUID().uuidString)"
    let preferenceKey = "preferredInstallation"
    let defaults: UserDefaults
    let provider = FakeAppInstallationIdentityProvider()
    var registeredApplicationURL: URL?

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func identity(
        path: String,
        digest: String,
        signingAnchor: String? = "trusted-signing-anchor",
        signatureKind: AppInstallationSignatureKind? = .certificateBacked,
        marketingVersion: String = "1.0",
        buildVersion: String = "1"
    ) -> AppInstallationIdentity {
        AppInstallationIdentity(
            bundlePath: path,
            bundleIdentifier: "com.ryukeilee.CodexMonitorNativePrototype",
            codeIdentityDigest: digest,
            signingAnchorDigest: signingAnchor,
            signatureKind: signatureKind,
            version: AppInstallationVersion(
                marketingVersion: marketingVersion,
                buildVersion: buildVersion
            )
        )
    }

    func authority(
        currentURL: URL,
        arguments: [String] = ["CodexMonitorNative"]
    ) -> AppInstallationAuthority {
        AppInstallationAuthority(
            defaults: defaults,
            preferenceKey: preferenceKey,
            currentBundleURL: currentURL,
            identityProvider: provider,
            arguments: arguments,
            registeredApplicationURLProvider: { [weak self] _ in
                self?.registeredApplicationURL
            }
        )
    }

    func store(_ identity: AppInstallationIdentity) throws {
        defaults.set(try JSONEncoder().encode(identity), forKey: preferenceKey)
    }

    func storedIdentity() throws -> AppInstallationIdentity? {
        guard let data = defaults.data(forKey: preferenceKey) else { return nil }
        return try JSONDecoder().decode(AppInstallationIdentity.self, from: data)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class FakeAppInstallationIdentityProvider: AppInstallationIdentityProviding {
    var identities: [String: AppInstallationIdentity] = [:]

    func identity(for bundleURL: URL) -> AppInstallationIdentity? {
        identities[bundleURL.standardizedFileURL.path]
    }
}
