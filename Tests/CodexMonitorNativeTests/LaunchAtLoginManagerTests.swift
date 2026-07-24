import ServiceManagement
import XCTest
@testable import CodexMonitorNative

@MainActor
final class LaunchAtLoginManagerTests: XCTestCase {
    func testEnabledStatusIsReportedOnlyForRecordedCurrentInstallation() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        try fixture.storeRegisteredIdentity(fixture.currentIdentity)
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .enabled)

        let manager = fixture.makeManager(service: service)

        XCTAssertTrue(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.helperText, "已启用")
        XCTAssertNil(manager.lastErrorSummary)
    }

    func testEnabledStatusWithoutMatchingInstallationIsNotReportedAsEnabled() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        let service = FakeLoginItemManager(status: .enabled)

        let manager = fixture.makeManager(service: service)

        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.statusInfo, .registrationNeedsRepair)
        XCTAssertEqual(manager.helperText, "登录项未绑定到当前 App")
    }

    func testRequiresApprovalIsNeverReportedAsEnabledOrRegisteredAgainAtLaunch() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        try fixture.storeRegisteredIdentity(fixture.currentIdentity)
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .requiresApproval)
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()

        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.helperText, "需在系统设置中批准")
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
    }

    func testLegacyRequiresApprovalMigratesPendingIntentWithoutRetryingRegistration() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        let service = FakeLoginItemManager(status: .requiresApproval)
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()
        manager.reconcileAtLaunch()

        XCTAssertTrue(manager.desiredLaunchAtLogin)
        XCTAssertTrue(fixture.defaults.bool(forKey: fixture.preferenceKey))
        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.statusInfo, .requiresApproval)
        XCTAssertEqual(manager.helperText, "需在系统设置中批准")
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
    }

    func testLegacyPendingIntentCanBeDisabledAndPersistsDisabledPreference() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        let service = FakeLoginItemManager(status: .requiresApproval)
        let manager = fixture.makeManager(service: service)

        manager.setLaunchAtLogin(false)

        XCTAssertFalse(manager.desiredLaunchAtLogin)
        XCTAssertFalse(fixture.defaults.bool(forKey: fixture.preferenceKey))
        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.statusInfo, .notRegistered)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 1)
    }

    func testLaunchReconciliationMigratesLegacyEnabledRegistrationExactlyOnce() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        let service = FakeLoginItemManager(status: .enabled)
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()
        manager.reconcileAtLaunch()

        XCTAssertTrue(manager.desiredLaunchAtLogin)
        XCTAssertTrue(fixture.defaults.bool(forKey: fixture.preferenceKey))
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(manager.shouldLaunchAtLogin)
        XCTAssertEqual(try fixture.registeredIdentity(), fixture.currentIdentity)
    }

    func testLaunchReconciliationRegistersMissingDesiredLoginItemExactlyOnce() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .notRegistered)
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()
        manager.reconcileAtLaunch()

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertTrue(manager.shouldLaunchAtLogin)
        XCTAssertEqual(try fixture.registeredIdentity(), fixture.currentIdentity)
    }

    func testRecreatedManagerDoesNotRepeatSuccessfulLaunchRepair() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .notRegistered)
        fixture.makeManager(service: service).reconcileAtLaunch()

        fixture.makeManager(service: service).reconcileAtLaunch()

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(try fixture.registeredIdentity(), fixture.currentIdentity)
    }

    func testLaunchReconciliationReplacesNotFoundRegistration() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .notFound)
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(manager.shouldLaunchAtLogin)
    }

    func testMovedInstallationReplacesEnabledRegistrationAndStoresNewIdentity() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        try fixture.storeRegisteredIdentity(.init(
            bundlePath: "/Applications/OldCodexMonitorNative.app",
            bundleIdentifier: fixture.currentIdentity.bundleIdentifier,
            codeIdentityDigest: fixture.currentIdentity.codeIdentityDigest
        ))
        let service = FakeLoginItemManager(status: .enabled)
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(try fixture.registeredIdentity(), fixture.currentIdentity)
        XCTAssertTrue(manager.shouldLaunchAtLogin)
    }

    func testResignedInstallationAtSamePathReplacesEnabledRegistration() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        try fixture.storeRegisteredIdentity(.init(
            bundlePath: fixture.currentIdentity.bundlePath,
            bundleIdentifier: fixture.currentIdentity.bundleIdentifier,
            codeIdentityDigest: "old-signature-digest"
        ))
        let service = FakeLoginItemManager(status: .enabled)
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(try fixture.registeredIdentity(), fixture.currentIdentity)
        XCTAssertTrue(manager.shouldLaunchAtLogin)
    }

    func testExplicitDisabledPreferenceRemovesUnexpectedEnabledRegistration() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(false, forKey: fixture.preferenceKey)
        try fixture.storeRegisteredIdentity(fixture.currentIdentity)
        let service = FakeLoginItemManager(status: .enabled)
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertNil(try fixture.registeredIdentity())
    }

    func testExplicitDisabledPreferenceClearsResidualSlotWhenCurrentStatusIsNotRegistered() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(false, forKey: fixture.preferenceKey)
        try fixture.storeRegisteredIdentity(fixture.currentIdentity)
        let service = FakeLoginItemManager(status: .notRegistered)
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()

        // When the system already reports .notRegistered, no unregister
        // call is needed — the slot is already clear.
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertNil(try fixture.registeredIdentity())
    }

    func testAlreadyRegisteredFailureIsNotRetriedAfterManagerRecreation() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .notRegistered)
        service.registerError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: kSMErrorAlreadyRegistered
        )
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()
        manager.reconcileAtLaunch()
        let recreatedManager = fixture.makeManager(service: service)
        recreatedManager.reconcileAtLaunch()

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(recreatedManager.shouldLaunchAtLogin)
        XCTAssertEqual(recreatedManager.lastErrorSummary, "系统仍保留其他 App 登录项")
    }

    func testSuppressedRepairRetriesAfterSystemStatusChanges() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .notRegistered)
        service.registerError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: kSMErrorAlreadyRegistered
        )
        fixture.makeManager(service: service).reconcileAtLaunch()

        service.registerError = nil
        service.status = .notFound
        let recreatedManager = fixture.makeManager(service: service)
        recreatedManager.reconcileAtLaunch()

        XCTAssertEqual(service.unregisterCallCount, 2)
        XCTAssertEqual(service.registerCallCount, 2)
        XCTAssertTrue(recreatedManager.shouldLaunchAtLogin)
        XCTAssertNil(recreatedManager.lastErrorSummary)
    }

    func testTransientRegistrationFailureRetriesOnceOnNextLaunch() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .notRegistered)
        service.registerError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: kSMErrorServiceUnavailable
        )

        fixture.makeManager(service: service).reconcileAtLaunch()

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 1)
        service.registerError = nil

        let recreatedManager = fixture.makeManager(service: service)
        recreatedManager.reconcileAtLaunch()

        XCTAssertEqual(service.unregisterCallCount, 2)
        XCTAssertEqual(service.registerCallCount, 2)
        XCTAssertTrue(recreatedManager.shouldLaunchAtLogin)
        XCTAssertNil(recreatedManager.lastErrorSummary)
    }

    func testRepairClearsStoredRegistrationIdentityBeforeFailedReregistration() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        try fixture.storeRegisteredIdentity(fixture.currentIdentity)
        let service = FakeLoginItemManager(status: .notRegistered)
        service.registerError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: kSMErrorServiceUnavailable
        )

        fixture.makeManager(service: service).reconcileAtLaunch()

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertNil(try fixture.registeredIdentity())
    }

    func testTransientDisableFailureRetriesOnceOnNextLaunch() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        try fixture.storeRegisteredIdentity(fixture.currentIdentity)
        let service = FakeLoginItemManager(status: .enabled)
        service.unregisterError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: kSMErrorServiceUnavailable
        )
        let manager = fixture.makeManager(service: service)

        manager.setLaunchAtLogin(false)

        XCTAssertFalse(manager.desiredLaunchAtLogin)
        XCTAssertTrue(manager.shouldLaunchAtLogin)
        XCTAssertTrue(manager.toggleValue)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)

        service.unregisterError = nil
        let recreatedManager = fixture.makeManager(service: service)
        recreatedManager.reconcileAtLaunch()

        XCTAssertFalse(recreatedManager.desiredLaunchAtLogin)
        XCTAssertEqual(service.unregisterCallCount, 2)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertFalse(recreatedManager.shouldLaunchAtLogin)
        XCTAssertFalse(recreatedManager.toggleValue)
        XCTAssertNil(recreatedManager.lastErrorSummary)
    }

    func testMissingPreferenceAndMissingRegistrationDoesNotOptUserIn() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        let service = FakeLoginItemManager(status: .notRegistered)
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()

        XCTAssertFalse(manager.desiredLaunchAtLogin)
        XCTAssertNil(fixture.defaults.object(forKey: fixture.preferenceKey))
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
    }

    func testRepeatedEnableOfAlignedRegistrationIsIdempotent() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        try fixture.storeRegisteredIdentity(fixture.currentIdentity)
        let service = FakeLoginItemManager(status: .enabled)
        let manager = fixture.makeManager(service: service)

        manager.setLaunchAtLogin(true)
        manager.setLaunchAtLogin(true)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertTrue(manager.shouldLaunchAtLogin)
    }

    func testMismatchedApprovalStateWaitsForExplicitUserRepair() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        try fixture.storeRegisteredIdentity(.init(
            bundlePath: "/Applications/OldCodexMonitorNative.app",
            bundleIdentifier: fixture.currentIdentity.bundleIdentifier,
            codeIdentityDigest: "old"
        ))
        let service = FakeLoginItemManager(status: .requiresApproval)
        service.registerError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: kSMErrorLaunchDeniedByUser
        )
        service.statusAfterRegisterAttempt = .requiresApproval
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertFalse(manager.shouldLaunchAtLogin)

        manager.setLaunchAtLogin(true)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(manager.statusInfo, .requiresApproval)
        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.lastErrorSummary, "需在系统设置中批准")
        XCTAssertEqual(try fixture.registeredIdentity(), fixture.currentIdentity)
    }

    func testJobNotFoundDuringRepairDoesNotCauseDuplicateRegistration() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .notFound)
        service.unregisterError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: kSMErrorJobNotFound
        )
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(manager.shouldLaunchAtLogin)
    }

    func testInvalidSignatureRepairFailureNeverShowsEnabledAndIsNotRetriedInSameLaunch() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .notRegistered)
        service.registerError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: kSMErrorInvalidSignature
        )
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()
        manager.reconcileAtLaunch()

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.lastErrorSummary, "当前 App 签名无效")
    }

    func testSuccessfulRegisterWithoutEnabledReadbackNeverShowsEnabled() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .notRegistered)
        service.statusAfterRegisterAttempt = .notRegistered
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.statusInfo, .notRegistered)
        XCTAssertEqual(manager.lastErrorSummary, "开机启动未生效")
    }

    func testSuccessfulRegisterRequiringApprovalRecordsCurrentButNeverShowsEnabled() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .notRegistered)
        service.statusAfterRegisterAttempt = .requiresApproval
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()

        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.statusInfo, .requiresApproval)
        XCTAssertNil(manager.lastErrorSummary)
        XCTAssertEqual(try fixture.registeredIdentity(), fixture.currentIdentity)
    }

    func testPendingDesiredStateCanBeCancelledWithoutFirstBecomingEnabled() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        try fixture.storeRegisteredIdentity(fixture.currentIdentity)
        let service = FakeLoginItemManager(status: .requiresApproval)
        let manager = fixture.makeManager(service: service)

        manager.setLaunchAtLogin(false)

        XCTAssertFalse(manager.desiredLaunchAtLogin)
        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertNil(try fixture.registeredIdentity())
    }

    func testUnrelatedErrorCodeCollisionDoesNotBlockRegistration() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .notFound)
        // An unregister error from a different framework domain is not a
        // legitimate kSMErrorJobNotFound, but it must not block registration.
        service.unregisterError = NSError(domain: NSCocoaErrorDomain, code: kSMErrorJobNotFound)
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()

        XCTAssertEqual(service.unregisterCallCount, 1)
        // Registration proceeds despite the unrelated unregister error.
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(manager.shouldLaunchAtLogin)
        XCTAssertNil(manager.lastErrorSummary)
    }

    func testToggleRollsBackAndShowsShortErrorWhenSystemUpdateFails() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        let service = FakeLoginItemManager(status: .notRegistered)
        service.registerError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
        )
        let manager = fixture.makeManager(service: service)

        manager.setLaunchAtLogin(true)

        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.helperText, "未启用")
        XCTAssertEqual(manager.lastErrorSummary, "登录会话不可用")
    }

    func testUnavailableCurrentInstallationIdentityNeverShowsSystemEnabledState() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .enabled)
        let manager = fixture.makeManager(service: service, currentIdentity: nil)

        manager.reconcileAtLaunch()

        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.helperText, "无法验证当前 App 安装")
        XCTAssertEqual(manager.lastErrorSummary, "无法验证当前 App 安装")
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
    }

    // MARK: - Development build (allowsAutomaticReconciliation = false)

    func testDevBuildWithStoredEnabledPreferenceAndNotFoundStatusRegistersAtLaunch() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        try fixture.storeRegisteredIdentity(fixture.currentIdentity)
        let service = FakeLoginItemManager(status: .notFound)
        let manager = fixture.makeManager(
            service: service,
            currentIdentity: fixture.currentIdentity,
            allowsAutomaticReconciliation: false
        )

        manager.reconcileAtLaunch()

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(manager.shouldLaunchAtLogin)
        XCTAssertNil(manager.lastErrorSummary)
    }

    func testDevBuildWithStoredDisabledPreferenceAndEnabledStatusUnregistersAtLaunch() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(false, forKey: fixture.preferenceKey)
        try fixture.storeRegisteredIdentity(fixture.currentIdentity)
        let service = FakeLoginItemManager(status: .enabled)
        let manager = fixture.makeManager(
            service: service,
            currentIdentity: fixture.currentIdentity,
            allowsAutomaticReconciliation: false
        )

        manager.reconcileAtLaunch()

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertNil(manager.lastErrorSummary)
    }

    func testDevBuildNoStoredPreferenceDoesNotRegisterForNotFound() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        let service = FakeLoginItemManager(status: .notFound)
        let manager = fixture.makeManager(
            service: service,
            currentIdentity: fixture.currentIdentity,
            allowsAutomaticReconciliation: false
        )

        manager.reconcileAtLaunch()

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.statusInfo, .notFound)
        XCTAssertEqual(manager.helperText, "未找到登录项")
    }

    // MARK: - Toggle value for requiresApproval

    func testToggleValueIsTrueWhenRequiresApprovalAndDesiredEnabled() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        try! fixture.storeRegisteredIdentity(fixture.currentIdentity)
        let service = FakeLoginItemManager(status: .requiresApproval)
        let manager = fixture.makeManager(service: service)

        // reconcileAtLaunch for allowsAutomaticReconciliation=true with
        // .requiresApproval and matching identity does not register/unregister.
        manager.reconcileAtLaunch()

        // desiredLaunchAtLogin=YES (from stored preference), status=.requiresApproval
        XCTAssertTrue(manager.desiredLaunchAtLogin)
        XCTAssertEqual(manager.statusInfo, .requiresApproval)
        // toggleValue should reflect the user's intent, not just isEnabled
        XCTAssertTrue(manager.toggleValue)
        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.helperText, "需在系统设置中批准")
    }

    func testToggleValueIsFalseWhenRequiresApprovalAndDesiredDisabled() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(false, forKey: fixture.preferenceKey)
        let service = FakeLoginItemManager(status: .requiresApproval)
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()

        XCTAssertFalse(manager.desiredLaunchAtLogin)
        // reconcileDisabledState calls unregisterExistingRegistration which:
        // 1. unregisters (success on the fake)
        // 2. clearRegisteredInstallationIdentity
        // 3. clearReconciliationFailure
        // 4. refreshStatus → reads loginItemManager.status
        //
        // The existing testLegacyPendingIntentCanBeDisabledAndPersistsDisabledPreference
        // uses setLaunchAtLogin(false) and expects .notRegistered.
        // Match that behavior here since both paths call reconcileDisabledState.
        XCTAssertEqual(manager.statusInfo, .notRegistered)
        // User explicitly disabled, so toggle should be OFF
        XCTAssertFalse(manager.toggleValue)
        XCTAssertFalse(manager.shouldLaunchAtLogin)
    }

    func testToggleValueAfterSetLaunchAtLoginWithRequiresApproval() {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        let service = FakeLoginItemManager(status: .notRegistered)
        service.statusAfterRegisterAttempt = .requiresApproval
        let manager = fixture.makeManager(service: service)

        manager.setLaunchAtLogin(true)

        // Registration succeeded but system requires approval
        XCTAssertTrue(manager.desiredLaunchAtLogin)
        XCTAssertEqual(manager.statusInfo, .requiresApproval)
        // toggleValue should show ON because user intends to enable
        XCTAssertTrue(manager.toggleValue)
        XCTAssertFalse(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.helperText, "需在系统设置中批准")
    }

    func testToggleValueAfterApprovalChangesToEnabled() throws {
        let fixture = LaunchAtLoginTestFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: fixture.preferenceKey)
        try fixture.storeRegisteredIdentity(fixture.currentIdentity)
        let service = FakeLoginItemManager(status: .requiresApproval)
        let manager = fixture.makeManager(service: service)

        manager.reconcileAtLaunch()
        XCTAssertEqual(manager.statusInfo, .requiresApproval)
        XCTAssertTrue(manager.toggleValue)

        // Simulate user approving in System Settings → status becomes .enabled
        service.status = .enabled
        manager.refreshStatus()

        XCTAssertEqual(manager.statusInfo, .enabled)
        XCTAssertTrue(manager.toggleValue)
        XCTAssertTrue(manager.shouldLaunchAtLogin)
        XCTAssertEqual(manager.helperText, "已启用")
    }
}

@MainActor
private final class LaunchAtLoginTestFixture {
    let suiteName = "CodexMonitorNativeTests.launchAtLogin.\(UUID().uuidString)"
    let preferenceKey = "launchAtLogin.preference"
    let registrationIdentityKey = "launchAtLogin.registrationIdentity"
    let currentIdentity = AppInstallationIdentity(
        bundlePath: "/Applications/CodexMonitorNative.app",
        bundleIdentifier: "com.ryukeilee.CodexMonitorNativePrototype",
        codeIdentityDigest: "current-signature-digest"
    )
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeManager(service: FakeLoginItemManager) -> LaunchAtLoginManager {
        makeManager(service: service, currentIdentity: currentIdentity)
    }

    func makeManager(
        service: FakeLoginItemManager,
        currentIdentity: AppInstallationIdentity?
    ) -> LaunchAtLoginManager {
        LaunchAtLoginManager(
            loginItemManager: service,
            defaults: defaults,
            preferenceKey: preferenceKey,
            registrationIdentityKey: registrationIdentityKey,
            currentInstallationIdentity: currentIdentity
        )
    }

    func makeManager(
        service: FakeLoginItemManager,
        currentIdentity: AppInstallationIdentity?,
        allowsAutomaticReconciliation: Bool
    ) -> LaunchAtLoginManager {
        LaunchAtLoginManager(
            loginItemManager: service,
            defaults: defaults,
            preferenceKey: preferenceKey,
            registrationIdentityKey: registrationIdentityKey,
            currentInstallationIdentity: currentIdentity,
            allowsAutomaticReconciliation: allowsAutomaticReconciliation
        )
    }

    func storeRegisteredIdentity(_ identity: AppInstallationIdentity) throws {
        defaults.set(try JSONEncoder().encode(identity), forKey: registrationIdentityKey)
    }

    func registeredIdentity() throws -> AppInstallationIdentity? {
        guard let data = defaults.data(forKey: registrationIdentityKey) else { return nil }
        return try JSONDecoder().decode(AppInstallationIdentity.self, from: data)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class FakeLoginItemManager: LoginItemManaging {
    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?
    var statusAfterRegisterAttempt: SMAppService.Status?
    var statusAfterUnregisterAttempt: SMAppService.Status?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let statusAfterRegisterAttempt {
            status = statusAfterRegisterAttempt
        }
        if let registerError {
            throw registerError
        }
        if statusAfterRegisterAttempt == nil {
            status = .enabled
        }
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let statusAfterUnregisterAttempt {
            status = statusAfterUnregisterAttempt
        }
        if let unregisterError {
            throw unregisterError
        }
        if statusAfterUnregisterAttempt == nil {
            status = .notRegistered
        }
    }
}
