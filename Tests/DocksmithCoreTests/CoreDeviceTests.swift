import Foundation
import XCTest
@testable import DocksmithCore

final class CoreDeviceTests: XCTestCase {
    func testConnectedPhysicalDeviceDiscoveryAndFullInventory() throws {
        let runner = CoreRunnerFixture()
        let provider = CoreDeviceProvider(runner: runner)
        let devices = try provider.discover()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].identifier, "fixture-target")
        let inventory = try provider.loadInventory(identifier: devices[0].identifier, deviceID: "42")
        XCTAssertTrue(inventory.isDecoded)
        XCTAssertFalse(inventory.isPartial)
        XCTAssertEqual(inventory.apps.count, 2)
        XCTAssertEqual(inventory.apps.first { $0.id == "com.example.one" }?.isRemovable, true)
        XCTAssertEqual(inventory.apps.first { $0.id == "com.example.system" }?.isHidden, true)
        XCTAssertEqual(runner.appTargets, ["fixture-target"])
    }

    func testFailedOrMalformedInventoryNeverClaimsZeroInstalledApps() throws {
        for command in [CommandResult(stdout: Data(), exitCode: 1),
                        CommandResult(stdout: CoreRunnerFixture.apps, timedOut: true),
                        CommandResult(stdout: Data(#"{"info":{"outcome":"failed"},"result":{"defaultAppsIncluded":true,"hiddenAppsIncluded":true,"internalAppsIncluded":true,"removableAppsIncluded":true,"apps":[]}}"#.utf8)),
                        CommandResult(stdout: Data(#"{"info":{"outcome":"success"},"result":{}}"#.utf8))] {
            let runner = CoreRunnerFixture()
            runner.appsResult = command
            let inventory = try CoreDeviceProvider(runner: runner).loadInventory(identifier: "fixture-target", deviceID: "42")
            XCTAssertFalse(inventory.isDecoded)
            XCTAssertTrue(inventory.isPartial)
        }
    }

    func testExactUSBMergeAllowsAppsButNeverCfgutilOnlyOperations() async throws {
        let coreRunner = CoreRunnerFixture()
        let cfg = EmptyCfgFixture()
        let hardware = CoreHardwareFixture(devices: [USBDevicePresence(registryID: 1, productName: "iPhone", vendorID: 1452, ecid: "42")])
        let service = DeviceService(runner: cfg, hardware: hardware, coreDevice: CoreDeviceProvider(runner: coreRunner))
        let devices = try await service.discover()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, "42")
        XCTAssertEqual(devices[0].capabilities.inventoryBackend, .coreDevice)
        XCTAssertFalse(devices[0].capabilities.canReadLayout)
        XCTAssertFalse(devices[0].capabilities.canRemoveApps)
        let inventory = try await service.loadInventory(deviceID: "42")
        XCTAssertEqual(inventory.apps.count, 2)
        do { _ = try await service.loadLayout(deviceID: "42"); XCTFail("Layout should require Configurator") }
        catch DeviceServiceError.backendUnavailable { }
        do { _ = try await service.loadIcon(deviceID: "42", appID: "com.example.one"); XCTFail("Icons should require Configurator") }
        catch DeviceServiceError.backendUnavailable { }
        do { _ = try await service.removeApps(deviceID: "42", ids: ["com.example.one"]); XCTFail("Removal should require Configurator") }
        catch DeviceServiceError.backendUnavailable { }
        XCTAssertTrue(cfg.commands.allSatisfy { $0 == ["--format", "JSON", "list"] })
    }

    func testCfgutilIsPreferredAndFriendlyNamesNeverMergeDifferentDevices() async throws {
        let cfg = EmptyCfgFixture()
        cfg.discovery = Data(#"{"Output":{"test":{"ECID":"0x2a","name":"Fixture phone"}}}"#.utf8)
        let service = DeviceService(runner: cfg, coreDevice: CoreDeviceProvider(runner: CoreRunnerFixture()))
        let devices = try await service.discover()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].capabilities.inventoryBackend, .cfgutil)
        cfg.discovery = Data(#"{"Output":{"test":{"ECID":"43","name":"Fixture phone"}}}"#.utf8)
        let different = try await service.discover()
        XCTAssertEqual(different.count, 2)
    }

    func testUSBUDIDWithoutECIDMergesExactlyAndOptionalCoreDeviceFailureKeepsUSBVisible() async throws {
        let hardware = CoreHardwareFixture(devices: [USBDevicePresence(registryID: 9, productName: "iPhone", vendorID: 1452, ecid: nil, udid: "00000001-0000000000000002")])
        let runner = CoreRunnerFixture()
        let service = DeviceService(runner: EmptyCfgFixture(), hardware: hardware, coreDevice: CoreDeviceProvider(runner: runner))
        let found = try await service.discover()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].id, "usb-registry:9")
        XCTAssertTrue(found[0].capabilities.canReadApps)
        runner.devicesResult = CommandResult(stdout: Data(), exitCode: 1)
        let missingXcode = try await service.discover()
        XCTAssertEqual(missingXcode.count, 1)
        XCTAssertFalse(missingXcode[0].capabilities.canReadApps)
    }

    func testReadOnlySnapshotRetainsInventoryWithoutRequestingLayout() async throws {
        let service = DeviceService(runner: EmptyCfgFixture(), coreDevice: CoreDeviceProvider(runner: CoreRunnerFixture()))
        let snapshot = try await service.loadSnapshot(deviceID: "42")
        XCTAssertEqual(snapshot.inventory.apps.count, 2)
        XCTAssertNil(snapshot.layout.layout)
        XCTAssertTrue(snapshot.layout.isPartial)
    }

    func testFrozenCoreDeviceRemovalUsesExactTargetAndVerifiesCompleteAbsence() async throws {
        let runner = CoreRunnerFixture()
        runner.supportsRemoval = true
        runner.inventories = [CommandResult(stdout: CoreRunnerFixture.apps), CommandResult(stdout: CoreRunnerFixture.emptyApps)]
        let service = DeviceService(runner: EmptyCfgFixture(), coreDevice: CoreDeviceProvider(runner: runner))
        let plan = try await service.prepareRemoval(deviceID: "42", ids: ["com.example.one"])
        XCTAssertEqual(plan.backendName, "Xcode")
        let outcomes = try await service.executeRemoval(plan)
        XCTAssertTrue(outcomes[0].success)
        XCTAssertEqual(runner.uninstallTargets.count, 1)
        XCTAssertEqual(runner.uninstallTargets[0].0, "fixture-target")
        XCTAssertEqual(runner.uninstallTargets[0].1, "com.example.one")
    }

    func testUnknownProtectedHiddenAndInternalAppsAreNeverUninstalled() async throws {
        let runner = CoreRunnerFixture()
        runner.supportsRemoval = true
        runner.appsResult = CommandResult(stdout: Data(#"{"info":{"outcome":"success"},"result":{"defaultAppsIncluded":true,"hiddenAppsIncluded":true,"internalAppsIncluded":true,"removableAppsIncluded":true,"apps":[{"bundleIdentifier":"com.example.unknown","removable":true},{"bundleIdentifier":"com.example.hidden","removable":true,"hidden":true,"internalApp":false},{"bundleIdentifier":"com.example.internal","removable":true,"hidden":false,"internalApp":true},{"bundleIdentifier":"com.example.protected","removable":false,"hidden":false,"internalApp":false}]}}"#.utf8))
        let service = DeviceService(runner: EmptyCfgFixture(), coreDevice: CoreDeviceProvider(runner: runner))
        let result = try await service.removeApps(deviceID: "42", ids: ["com.example.unknown", "com.example.hidden", "com.example.internal", "com.example.protected"])
        XCTAssertEqual(result.count, 4)
        XCTAssertTrue(result.allSatisfy { !$0.success })
        XCTAssertTrue(runner.uninstallTargets.isEmpty)
    }

    func testBackendDriftStopsFrozenPlanAndMidBatchStopsRemainingApps() async throws {
        let runner = CoreRunnerFixture()
        runner.supportsRemoval = true
        let cfg = EmptyCfgFixture()
        let service = DeviceService(runner: cfg, coreDevice: CoreDeviceProvider(runner: runner))
        let plan = try await service.prepareRemoval(deviceID: "42", ids: ["com.example.one"])
        cfg.discovery = Data(#"{"Output":{"test":{"ECID":"42"}}}"#.utf8)
        do { _ = try await service.executeRemoval(plan); XCTFail("Backend change must invalidate review") }
        catch DeviceServiceError.backendUnavailable { }
        XCTAssertTrue(runner.uninstallTargets.isEmpty)
        cfg.discovery = Data(#"{"Output":{}}"#.utf8)
        runner.appsResult = CommandResult(stdout: Data(#"{"info":{"outcome":"success"},"result":{"defaultAppsIncluded":true,"hiddenAppsIncluded":true,"internalAppsIncluded":true,"removableAppsIncluded":true,"apps":[{"bundleIdentifier":"com.example.a","removable":true,"hidden":false,"internalApp":false},{"bundleIdentifier":"com.example.b","removable":true,"hidden":false,"internalApp":false},{"bundleIdentifier":"com.example.c","removable":true,"hidden":false,"internalApp":false}]}}"#.utf8))
        runner.onUninstall = { runner.supportsRemoval = false }
        let batch = try await service.prepareRemoval(deviceID: "42", ids: ["com.example.a", "com.example.b", "com.example.c"])
        let outcomes = try await service.executeRemoval(batch)
        XCTAssertEqual(runner.uninstallTargets.count, 1)
        XCTAssertTrue(outcomes.dropFirst().allSatisfy { $0.message.hasPrefix("Not attempted") })
    }

    func testUncertainUninstallAndIncompleteRefreshNeverClaimVerified() async throws {
        for failedCommand in [true, false] {
            let runner = CoreRunnerFixture()
            runner.supportsRemoval = true
            runner.inventories = [CommandResult(stdout: CoreRunnerFixture.apps),
                                  failedCommand ? CommandResult(stdout: CoreRunnerFixture.emptyApps) : CommandResult(stdout: Data(#"{"info":{"outcome":"success"},"result":{"apps":[]}}"#.utf8))]
            if failedCommand { runner.uninstallResult = CommandResult(stdout: Data(), timedOut: true) }
            let result = try await DeviceService(runner: EmptyCfgFixture(), coreDevice: CoreDeviceProvider(runner: runner)).removeApps(deviceID: "42", ids: ["com.example.one"])
            XCTAssertFalse(result[0].success)
            XCTAssertEqual(runner.uninstallTargets.count, 1)
        }
        let duplicate = CoreRunnerFixture()
        duplicate.appsResult = CommandResult(stdout: Data(#"{"info":{"outcome":"success"},"result":{"defaultAppsIncluded":true,"hiddenAppsIncluded":true,"internalAppsIncluded":true,"removableAppsIncluded":true,"apps":[{"bundleIdentifier":"com.example.one","removable":true},{"bundleIdentifier":"com.example.one","removable":false}]}}"#.utf8))
        XCTAssertFalse(try CoreDeviceProvider(runner: duplicate).loadInventory(identifier: "fixture-target", deviceID: "42").isDecoded)
    }
}

private struct CoreHardwareFixture: USBDeviceDiscovering {
    let devices: [USBDevicePresence]
    func connectedDevices() throws -> [USBDevicePresence] { devices }
}

private final class EmptyCfgFixture: CfgutilRunning, @unchecked Sendable {
    var discovery = Data(#"{"Output":{}}"#.utf8)
    var commands: [[String]] = []
    func run(_ arguments: [String]) throws -> CommandResult {
        commands.append(arguments)
        return CommandResult(stdout: discovery)
    }
}

private final class CoreRunnerFixture: CoreDeviceRunning, @unchecked Sendable {
    static let devices = Data(#"{"info":{"outcome":"success"},"result":{"devices":[{"identifier":"fixture-target","hardwareProperties":{"ecid":42,"udid":"00000001-0000000000000002","deviceType":"iPhone","productType":"iPhone1,1","reality":"physical"},"deviceProperties":{"name":"Fixture phone"},"connectionProperties":{"tunnelState":"connected","transportType":"wired"}},{"identifier":"simulator","hardwareProperties":{"deviceType":"iPhone","reality":"simulated"},"connectionProperties":{"tunnelState":"connected"}},{"identifier":"stale","hardwareProperties":{"deviceType":"iPhone","reality":"physical"},"connectionProperties":{"tunnelState":"disconnected"}}]}}"#.utf8)
    static let apps = Data(#"{"info":{"outcome":"success"},"result":{"defaultAppsIncluded":true,"hiddenAppsIncluded":true,"internalAppsIncluded":true,"removableAppsIncluded":true,"apps":[{"bundleIdentifier":"com.example.one","name":"One","version":"1.0","removable":true,"hidden":false,"internalApp":false},{"bundleIdentifier":"com.example.system","name":"System","removable":false,"hidden":true,"internalApp":true}]}}"#.utf8)
    static let emptyApps = Data(#"{"info":{"outcome":"success"},"result":{"defaultAppsIncluded":true,"hiddenAppsIncluded":true,"internalAppsIncluded":true,"removableAppsIncluded":true,"apps":[]}}"#.utf8)
    var devicesResult = CommandResult(stdout: devices)
    var appsResult = CommandResult(stdout: apps)
    var appTargets: [String] = []
    var supportsRemoval = false
    var uninstallResult = CommandResult(stdout: Data(#"{"info":{"outcome":"success"},"result":{}}"#.utf8))
    var uninstallTargets: [(String, String)] = []
    var inventories: [CommandResult] = []
    var onUninstall: (() -> Void)?
    func supportsAppRemoval() throws -> Bool { supportsRemoval }
    func uninstallApp(identifier: String, bundleID: String) throws -> CommandResult {
        uninstallTargets.append((identifier, bundleID))
        onUninstall?()
        return uninstallResult
    }
    func listDevices() throws -> CommandResult { devicesResult }
    func listApps(identifier: String) throws -> CommandResult {
        appTargets.append(identifier)
        return inventories.isEmpty ? appsResult : inventories.removeFirst()
    }
}
