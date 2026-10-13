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

    func testModernPairedOfflineGatesAndNoReadsOrWrites() async throws {
        let runner = CoreRunnerFixture()
        runner.supportsRemoval = true
        let records: [[String: Any]] = [
            ["identifier": "offline", "properties": ["hardware": ["ecid": 42, "deviceType": "iPhone", "reality": "physical"], "state": ["name": "Remembered phone"], "connection": ["state": "disconnected", "pairingState": "paired", "transportType": "localNetwork"]]],
            ["identifier": "unknown", "properties": ["hardware": ["ecid": 43, "deviceType": "iPhone", "reality": "physical"], "connection": ["state": "unknown", "pairingState": "paired"]]],
            ["identifier": "unpaired", "properties": ["hardware": ["ecid": 44, "deviceType": "iPad", "reality": "physical"], "connection": ["state": "disconnected", "pairingState": "unpaired"]]],
            ["identifier": "sim", "properties": ["hardware": ["ecid": 45, "deviceType": "iPhone", "reality": "simulated"], "connection": ["state": "disconnected", "pairingState": "paired"]]],
            ["identifier": "tv", "properties": ["hardware": ["ecid": 46, "deviceType": "AppleTV", "reality": "physical"], "connection": ["state": "disconnected", "pairingState": "paired"]]],
            ["identifier": "bad", "properties": ["hardware": ["ecid": "invalid", "deviceType": "iPhone", "reality": "physical"], "connection": ["state": "disconnected", "pairingState": "paired"]]]
        ]
        runner.devicesResult = CommandResult(stdout: try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["devices": records]]))
        let cfg = EmptyCfgFixture()
        let service = DeviceService(runner: cfg, coreDevice: CoreDeviceProvider(runner: runner))
        let found = try await service.discover()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].availability, .pairedDisconnected)
        XCTAssertEqual(found[0].transport, "Network")
        XCTAssertFalse(found[0].usbPresent)
        XCTAssertFalse(found[0].capabilities.canReadApps)
        XCTAssertFalse(found[0].capabilities.canRemoveApps)
        XCTAssertFalse(found[0].capabilities.canReadLayout)
        do { _ = try await service.loadInventory(deviceID: "42"); XCTFail("Offline inventory must fail") }
        catch DeviceServiceError.backendUnavailable { }
        do { _ = try await service.prepareRemoval(deviceID: "42", ids: ["com.example.one"]); XCTFail("Offline removal must fail") }
        catch DeviceServiceError.backendUnavailable { }
        XCTAssertTrue(runner.appTargets.isEmpty)
        XCTAssertTrue(runner.uninstallTargets.isEmpty)
        let usb = CoreHardwareFixture(devices: [USBDevicePresence(registryID: 1, productName: "iPhone", vendorID: 1452, ecid: "42")])
        let withUSB = try await DeviceService(runner: cfg, hardware: usb, coreDevice: CoreDeviceProvider(runner: runner)).discover()
        XCTAssertEqual(withUSB[0].availability, .usbDetectedBackendUnavailable)
        XCTAssertEqual(withUSB[0].displayName, "Remembered phone")
        XCTAssertTrue(withUSB[0].usbPresent)
        XCTAssertFalse(withUSB[0].capabilities.canReadApps)
        cfg.discovery = Data(#"{"Output":{"test":{"ECID":"42","name":"Live phone"}}}"#.utf8)
        let live = try await service.discover()
        XCTAssertEqual(live[0].capabilities.inventoryBackend, .cfgutil)
    }

    func testReportedNetworkPreservedWithUSBAndDisconnectInvalidatesReview() async throws {
        let runner = CoreRunnerFixture()
        runner.supportsRemoval = true
        runner.devicesResult = CommandResult(stdout: Data(String(decoding: CoreRunnerFixture.devices, as: UTF8.self).replacingOccurrences(of: "wired", with: "localNetwork").utf8))
        let usb = CoreHardwareFixture(devices: [USBDevicePresence(registryID: 1, productName: "iPhone", vendorID: 1452, ecid: "42")])
        let service = DeviceService(runner: EmptyCfgFixture(), hardware: usb, coreDevice: CoreDeviceProvider(runner: runner))
        let found = try await service.discover()
        XCTAssertEqual(found[0].transport, "Network")
        XCTAssertTrue(found[0].usbPresent)
        let plan = try await service.prepareRemoval(deviceID: "42", ids: ["com.example.one"])
        runner.appTargets = []
        runner.devicesResult = CommandResult(stdout: Data(#"{"info":{"outcome":"success"},"result":{"devices":[{"identifier":"fixture-target","hardwareProperties":{"ecid":42,"deviceType":"iPhone","reality":"physical"},"connectionProperties":{"tunnelState":"disconnected","pairingState":"paired"}}]}}"#.utf8))
        do { _ = try await service.executeRemoval(plan); XCTFail("Disconnect must invalidate review") }
        catch DeviceServiceError.backendUnavailable { }
        XCTAssertTrue(runner.appTargets.isEmpty)
        XCTAssertTrue(runner.uninstallTargets.isEmpty)
    }

    func testCoreOnlyRemovalPlanSupportsExactNonECIDIdentity() async throws {
        for usbMatch in [true, false] {
            let runner = CoreRunnerFixture()
            runner.supportsRemoval = true
            runner.devicesResult = CommandResult(stdout: Data(String(decoding: CoreRunnerFixture.devices, as: UTF8.self).replacingOccurrences(of: "\"ecid\":42,", with: "").utf8))
            let hardware = CoreHardwareFixture(devices: usbMatch ? [USBDevicePresence(registryID: 9, productName: "iPhone", vendorID: 1452, ecid: nil, udid: "00000001-0000000000000002")] : [])
            let service = DeviceService(runner: EmptyCfgFixture(), hardware: hardware, coreDevice: CoreDeviceProvider(runner: runner))
            let id = usbMatch ? "usb-registry:9" : "coredevice:fixture-target"
            let plan = try await service.prepareRemoval(deviceID: id, ids: ["com.example.one"])
            runner.inventories = [CommandResult(stdout: CoreRunnerFixture.apps), CommandResult(stdout: CoreRunnerFixture.emptyApps)]
            let outcomes = try await service.executeRemoval(plan)
            XCTAssertTrue(outcomes[0].success)
            XCTAssertEqual(runner.uninstallTargets.count, 1)
            XCTAssertEqual(runner.uninstallTargets[0].0, "fixture-target")
        }
    }

    func testIdlePairedCoreInventoryActivatesOnlyWithLiveCfgAndMatchingUSB() async throws {
        for hasUSB in [true, false] {
            let cfg = PartialCfgFixture()
            let core = CoreRunnerFixture()
            core.devicesResult = CommandResult(stdout: Data(#"{"info":{"outcome":"success"},"result":{"devices":[{"identifier":"fixture-target","hardwareProperties":{"ecid":42,"deviceType":"iPhone","reality":"physical"},"connectionProperties":{"tunnelState":"disconnected","pairingState":"paired"}}]}}"#.utf8))
            core.onListApps = { core.devicesResult = CommandResult(stdout: CoreRunnerFixture.devices) }
            let hardware = CoreHardwareFixture(devices: hasUSB ? [USBDevicePresence(registryID: 1, productName: "iPhone", vendorID: 1452, ecid: "42")] : [])
            let service = DeviceService(runner: cfg, hardware: hardware, coreDevice: CoreDeviceProvider(runner: core))
            let inventory = try await service.loadInventory(deviceID: "42")
            XCTAssertEqual(inventory.source, hasUSB ? .coreDevice : .cfgutil)
            XCTAssertEqual(core.appTargets.count, hasUSB ? 1 : 0)
            if hasUSB {
                let plan = try await service.prepareRemoval(deviceID: "42", ids: ["com.example.one"])
                core.devicesResult = CommandResult(stdout: Data(#"{"info":{"outcome":"success"},"result":{"devices":[{"identifier":"fixture-target","hardwareProperties":{"ecid":42,"deviceType":"iPhone","reality":"physical"},"connectionProperties":{"tunnelState":"disconnected","pairingState":"paired"}}]}}"#.utf8))
                core.inventories = [CommandResult(stdout: CoreRunnerFixture.apps), CommandResult(stdout: CoreRunnerFixture.emptyApps)]
                let outcomes = try await service.executeRemoval(plan)
                XCTAssertTrue(outcomes[0].success)
                XCTAssertEqual(cfg.writeCommands.count, 1)
            }
        }
        let core = CoreRunnerFixture()
        core.devicesResult = CommandResult(stdout: Data(#"{"info":{"outcome":"success"},"result":{"devices":[{"identifier":"fixture-target","hardwareProperties":{"ecid":42,"deviceType":"iPhone","reality":"physical"},"connectionProperties":{"tunnelState":"disconnected","pairingState":"paired"}}]}}"#.utf8))
        let hardware = CoreHardwareFixture(devices: [USBDevicePresence(registryID: 1, productName: "iPhone", vendorID: 1452, ecid: "42")])
        let unavailable = DeviceService(runner: EmptyCfgFixture(), hardware: hardware, coreDevice: CoreDeviceProvider(runner: core))
        do { _ = try await unavailable.loadInventory(deviceID: "42"); XCTFail("Idle Core cannot activate without Configurator") }
        catch DeviceServiceError.backendUnavailable { }
        XCTAssertTrue(core.appTargets.isEmpty)
        core.onListApps = { core.devicesResult = CommandResult(stdout: CoreRunnerFixture.devices) }
        core.appsResult = CommandResult(stdout: Data(#"{"info":{"outcome":"success"},"result":{"apps":[]}}"#.utf8))
        let incomplete = try await DeviceService(runner: PartialCfgFixture(), hardware: hardware, coreDevice: CoreDeviceProvider(runner: core)).loadInventory(deviceID: "42")
        XCTAssertEqual(incomplete.source, .cfgutil)
        XCTAssertTrue(incomplete.isPartial)
    }

    func testPartialCfgInventoryUsesCompleteExactCoreSourceWithCfgLayoutAndMutator() async throws {
        let cfg = PartialCfgFixture()
        let core = CoreRunnerFixture()
        let service = DeviceService(runner: cfg, coreDevice: CoreDeviceProvider(runner: core))
        let inventory = try await service.loadInventory(deviceID: "42")
        XCTAssertEqual(inventory.source, .coreDevice)
        XCTAssertEqual(inventory.apps.count, 2)
        XCTAssertFalse(inventory.isPartial)
        XCTAssertFalse(AppSelection.isEligible(inventory.apps.first { $0.id == "com.example.system" }!, backend: inventory.source))
        let plan = try await service.prepareRemoval(deviceID: "42", ids: ["com.example.system"])
        XCTAssertEqual(plan.backend, .cfgutil)
        XCTAssertEqual(plan.inventorySource, .coreDevice)
        let outcomes = try await service.executeRemoval(plan)
        XCTAssertFalse(outcomes[0].success)
        XCTAssertTrue(cfg.writeCommands.isEmpty)
        XCTAssertTrue(core.uninstallTargets.isEmpty)
        core.devicesResult = CommandResult(stdout: Data(String(decoding: CoreRunnerFixture.devices, as: UTF8.self).replacingOccurrences(of: "\"ecid\":42", with: "\"ecid\":43").utf8))
        let wrong = try await service.loadInventory(deviceID: "42")
        XCTAssertEqual(wrong.source, .cfgutil)
        XCTAssertTrue(wrong.isPartial)
        XCTAssertEqual(wrong.apps.count, 1)
    }

    func testPinnedEnrichmentCannotFallbackToPartialCfgInventory() async throws {
        for lostConnection in [true, false] {
            let cfg = PartialCfgFixture()
            let core = CoreRunnerFixture()
            let service = DeviceService(runner: cfg, coreDevice: CoreDeviceProvider(runner: core))
            let plan = try await service.prepareRemoval(deviceID: "42", ids: ["com.example.one"])
            if lostConnection { core.devicesResult = CommandResult(stdout: Data(), exitCode: 1) }
            else { core.appsResult = CommandResult(stdout: Data(#"{"info":{"outcome":"success"},"result":{"apps":[]}}"#.utf8)) }
            do { _ = try await service.executeRemoval(plan); XCTFail("Pinned source must remain complete and connected") }
            catch DeviceServiceError.inventoryUnavailable { }
            XCTAssertTrue(cfg.writeCommands.isEmpty)
        }
        let cfg = PartialCfgFixture()
        let core = CoreRunnerFixture()
        let service = DeviceService(runner: cfg, coreDevice: CoreDeviceProvider(runner: core))
        let plan = try await service.prepareRemoval(deviceID: "42", ids: ["com.example.one"])
        cfg.onWrite = { core.appsResult = CommandResult(stdout: Data(#"{"info":{"outcome":"success"},"result":{"apps":[]}}"#.utf8)) }
        let outcome = try await service.executeRemoval(plan)
        XCTAssertEqual(cfg.writeCommands.count, 1)
        XCTAssertFalse(outcome[0].success)
        XCTAssertEqual(outcome[0].message, "Removal could not be verified from a fresh inventory.")
    }

    func testLosingEnrichmentSourceMidBatchStopsRemainingAndLeavesSuccessUnverified() async throws {
        let cfg = PartialCfgFixture()
        let core = CoreRunnerFixture()
        core.appsResult = CommandResult(stdout: Data(String(decoding: CoreRunnerFixture.apps, as: UTF8.self)
            .replacingOccurrences(of: "\"removable\":false", with: "\"removable\":true")
            .replacingOccurrences(of: "\"hidden\":true", with: "\"hidden\":false")
            .replacingOccurrences(of: "\"internalApp\":true", with: "\"internalApp\":false").utf8))
        let service = DeviceService(runner: cfg, coreDevice: CoreDeviceProvider(runner: core))
        let plan = try await service.prepareRemoval(deviceID: "42", ids: ["com.example.one", "com.example.system"])
        cfg.onWrite = { core.devicesResult = CommandResult(stdout: Data(), exitCode: 1) }
        let outcomes = try await service.executeRemoval(plan)
        XCTAssertEqual(cfg.writeCommands.count, 1)
        XCTAssertFalse(outcomes[0].success)
        XCTAssertEqual(outcomes[0].message, "Removal could not be verified from a fresh inventory.")
        XCTAssertFalse(outcomes[1].success)
        XCTAssertTrue(outcomes[1].message.hasPrefix("Not attempted"))
    }

    func testBatchSelectionKeepsHiddenIDsAndStrictEligibility() {
        let apps = [InstalledApp(id: "com.example.a", name: "Same", isRemovable: true, isHidden: false, isInternal: false),
                    InstalledApp(id: "com.example.b", name: "Same", isRemovable: true, isHidden: false, isInternal: false),
                    InstalledApp(id: "com.example.hidden", name: "Hidden", isRemovable: true, isHidden: true, isInternal: false),
                    InstalledApp(id: "com.example.unknown", name: "Unknown", isRemovable: true)]
        let shown = AppSelection.visible(apps, search: "example.b", removableOnly: true, backend: .coreDevice)
        XCTAssertEqual(shown.map(\.id), ["com.example.b"])
        let selected = AppSelection.selectingShown(["com.example.a"], apps: shown, backend: .coreDevice)
        XCTAssertEqual(selected, ["com.example.a", "com.example.b"])
        XCTAssertEqual(AppSelection.selectingShown([], apps: apps, backend: .coreDevice), selected)
        XCTAssertEqual(selected.subtracting(shown.map(\.id)), ["com.example.a"])
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
        runner.inventories = [CommandResult(stdout: CoreRunnerFixture.apps), CommandResult(stdout: CoreRunnerFixture.apps), CommandResult(stdout: CoreRunnerFixture.emptyApps)]
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

    func testExplicitWirelessConnectionActivatesOnlyTheSelectedExistingPairing() async throws {
        let runner = CoreRunnerFixture()
        func devices(state: String) throws -> Data {
            var root = try JSONSerialization.jsonObject(with: CoreRunnerFixture.devices) as! [String: Any]
            var result = root["result"] as! [String: Any]
            var devices = result["devices"] as! [[String: Any]]
            devices[0]["connectionProperties"] = ["tunnelState": state, "transportType": "localNetwork", "pairingState": "paired"]
            result["devices"] = devices; root["result"] = result
            return try JSONSerialization.data(withJSONObject: root)
        }
        runner.devicesResult = CommandResult(stdout: try devices(state: "disconnected"))
        let connected = try devices(state: "connected")
        runner.onListApps = { runner.devicesResult = CommandResult(stdout: connected) }
        let cfg = EmptyCfgFixture()
        let service = DeviceService(runner: cfg, coreDevice: CoreDeviceProvider(runner: runner))
        let before = try await service.discover()
        XCTAssertEqual(before.first?.availability, .pairedDisconnected)
        XCTAssertTrue(runner.appTargets.isEmpty)
        let after = try await service.connectPairedDevice(deviceID: "42")
        XCTAssertTrue(after.capabilities.canReadApps)
        XCTAssertEqual(after.transport, "Network")
        XCTAssertFalse(after.usbPresent)
        XCTAssertEqual(runner.appTargets, ["fixture-target"])
        XCTAssertTrue(runner.uninstallTargets.isEmpty)
        XCTAssertTrue(cfg.commands.allSatisfy { $0 == ["--format", "JSON", "list"] })
    }

    func testWirelessConnectionRejectsUnknownPairingWrongDeviceAndIncompleteRead() async throws {
        for pairing in ["unpaired", "unknown", "paired"] {
            let runner = CoreRunnerFixture()
            var root = try JSONSerialization.jsonObject(with: CoreRunnerFixture.devices) as! [String: Any]
            var result = root["result"] as! [String: Any]
            var devices = result["devices"] as! [[String: Any]]
            devices[0]["connectionProperties"] = ["tunnelState": "disconnected", "transportType": "localNetwork", "pairingState": pairing]
            result["devices"] = devices; root["result"] = result
            runner.devicesResult = CommandResult(stdout: try JSONSerialization.data(withJSONObject: root))
            runner.appsResult = CommandResult(stdout: Data(), exitCode: 1)
            let service = DeviceService(runner: EmptyCfgFixture(), coreDevice: CoreDeviceProvider(runner: runner))
            do { _ = try await service.connectPairedDevice(deviceID: "43"); XCTFail("Unknown device must not be contacted") }
            catch DeviceServiceError.deviceMissing { }
            XCTAssertTrue(runner.appTargets.isEmpty)
            do { _ = try await service.connectPairedDevice(deviceID: "42"); XCTFail("A complete read is required") }
            catch DeviceServiceError.deviceMissing { XCTAssertNotEqual(pairing, "paired") }
            catch DeviceServiceError.wirelessUnavailable { XCTAssertEqual(pairing, "paired") }
            XCTAssertEqual(runner.appTargets.count, pairing == "paired" ? 1 : 0)
            XCTAssertTrue(runner.uninstallTargets.isEmpty)
        }
    }

    func testUncertainUninstallAndIncompleteRefreshNeverClaimVerified() async throws {
        for failedCommand in [true, false] {
            let runner = CoreRunnerFixture()
            runner.supportsRemoval = true
            runner.inventories = [CommandResult(stdout: CoreRunnerFixture.apps), CommandResult(stdout: CoreRunnerFixture.apps),
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
    var onListApps: (() -> Void)?
    func supportsAppRemoval() throws -> Bool { supportsRemoval }
    func uninstallApp(identifier: String, bundleID: String) throws -> CommandResult {
        uninstallTargets.append((identifier, bundleID))
        onUninstall?()
        return uninstallResult
    }
    func listDevices() throws -> CommandResult { devicesResult }
    func listApps(identifier: String) throws -> CommandResult {
        appTargets.append(identifier)
        onListApps?()
        return inventories.isEmpty ? appsResult : inventories.removeFirst()
    }
}

private final class PartialCfgFixture: CfgutilRunning, @unchecked Sendable {
    var writeCommands: [[String]] = []
    var onWrite: (() -> Void)?
    func run(_ arguments: [String]) throws -> CommandResult {
        if arguments.last == "list" { return CommandResult(stdout: Data(#"{"Output":{"test":{"ECID":"42","name":"Live fixture"}}}"#.utf8)) }
        if arguments.contains("remove-app") {
            writeCommands.append(arguments); onWrite?()
            return CommandResult(stdout: Data(#"{"Output":{"42":{}}}"#.utf8))
        }
        return CommandResult(stdout: Data(#"{"Output":{"42":{"installedApps":[{"bundleIdentifier":"com.example.one","displayName":"One"}]}}}"#.utf8), exitCode: 1)
    }
}
