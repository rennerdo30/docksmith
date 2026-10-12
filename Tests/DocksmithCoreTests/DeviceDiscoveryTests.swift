import Foundation
import XCTest
@testable import DocksmithCore

final class DeviceDiscoveryTests: XCTestCase {
    private let phone = USBDevicePresence(registryID: 12, productName: "iPhone", vendorID: 0x05ac, ecid: "0x2a")

    func testUSBPhoneRemainsVisibleWhenCfgutilOmitsItOrFails() async throws {
        for result in [CommandResult(stdout: Data(#"{"Output":{}}"#.utf8)), CommandResult(stdout: Data(), exitCode: 1)] {
            let runner = DiscoveryRunner(result: result)
            let devices = try await DeviceService(runner: runner, hardware: HardwareFixture([phone])).discover()
            XCTAssertEqual(devices.count, 1)
            XCTAssertEqual(devices[0].id, "42")
            XCTAssertEqual(devices[0].availability, .usbDetectedBackendUnavailable)
            XCTAssertNotNil(devices[0].diagnostic)
        }
    }

    func testExactCanonicalECIDDeduplicatesAndKeepsOriginalBackendTarget() async throws {
        let runner = DiscoveryRunner(result: readyResult(ecid: "0X2A"))
        let service = DeviceService(runner: runner, hardware: HardwareFixture([phone]))
        let devices = try await service.discover()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, "42")
        XCTAssertEqual(devices[0].displayName, "Test phone")
        XCTAssertEqual(devices[0].availability, .ready)
        XCTAssertEqual(devices[0].transport, "USB")
        _ = try await service.loadInventory(deviceID: "42")
        XCTAssertTrue(runner.commands.contains(["--format", "JSON", "--ecid", "0X2A", "get", "installedApps"]))
        XCTAssertEqual(DeviceIdentity.canonicalECID("0x002a"), DeviceIdentity.canonicalECID("42"))
        XCTAssertNotEqual(DeviceIdentity.canonicalECID("142"), DeviceIdentity.canonicalECID("42"))
    }

    func testRetryBecomesReadyWithStableIdentityAndUnplugDisappears() async throws {
        let runner = DiscoveryRunner(result: CommandResult(stdout: Data(#"{"Output":{}}"#.utf8)))
        let hardware = HardwareFixture([phone])
        let service = DeviceService(runner: runner, hardware: hardware)
        let first = try await service.discover()
        runner.result = readyResult(ecid: "42")
        let recovered = try await service.discover()
        XCTAssertEqual(first[0].id, recovered[0].id)
        XCTAssertEqual(recovered[0].availability, .ready)
        runner.result = CommandResult(stdout: Data(#"{"Output":{}}"#.utf8))
        let unavailableAgain = try await service.discover()
        XCTAssertEqual(unavailableAgain[0].displayName, "Test phone")
        hardware.devices = []
        let unplugged = try await service.discover()
        XCTAssertTrue(unplugged.isEmpty)
    }

    func testUnavailableDeviceCannotStartReadsIconsOrWrites() async throws {
        let runner = DiscoveryRunner(result: CommandResult(stdout: Data(#"{"Output":{}}"#.utf8)))
        let service = DeviceService(runner: runner, hardware: HardwareFixture([phone]))
        let layout = HomeLayout(dock: [], pages: [[]])
        let baseline = LayoutSnapshot(deviceID: "42", capturedAt: Date(), rawJSON: Data("[[],[]]".utf8), layout: layout, warning: nil, isPartial: false)
        for operation in 0..<5 {
            do {
                switch operation {
                case 0: _ = try await service.loadInventory(deviceID: "42")
                case 1: _ = try await service.loadLayout(deviceID: "42")
                case 2: _ = try await service.loadIcon(deviceID: "42", appID: "com.example.one")
                case 3: _ = try await service.removeApps(deviceID: "42", ids: ["com.example.one"])
                default: _ = try await service.applyLayout(deviceID: "42", baseline: baseline, draft: layout)
                }
                XCTFail("Expected backend-unavailable rejection")
            } catch DeviceServiceError.backendUnavailable { }
        }
        XCTAssertTrue(runner.commands.allSatisfy { $0 == ["--format", "JSON", "list"] })
    }

    func testUnrelatedUSBDevicesIgnoredAndMissingECIDNeverGuessed() async throws {
        let hardware = HardwareFixture([
            USBDevicePresence(registryID: 5, productName: "Apple TV", vendorID: 0x05ac, ecid: "42"),
            USBDevicePresence(registryID: 6, productName: "iPhone", vendorID: 1, ecid: "42"),
            USBDevicePresence(registryID: 7, productName: "iPhone", vendorID: 0x05ac, ecid: nil),
        ])
        let devices = try await DeviceService(runner: DiscoveryRunner(result: readyResult(ecid: "42")), hardware: hardware).discover()
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.filter { $0.availability == .usbDetectedBackendUnavailable }.first?.id, "usb-registry:7")
        XCTAssertEqual(IOKitUSBDeviceDiscovery.ecid(from: ["UsbAppleDeviceECID": NSNumber(value: 42), "USB Serial Number": "unrelated"]), "42")
        XCTAssertNil(IOKitUSBDeviceDiscovery.ecid(from: ["USB Serial Number": "00000000-0000000000000000"]))
    }

    private func readyResult(ecid: String) -> CommandResult {
        CommandResult(stdout: Data("{\"Output\":{\"test\":{\"ECID\":\"\(ecid)\",\"name\":\"Test phone\",\"deviceType\":\"iPhone\"}}}".utf8))
    }
}

private final class HardwareFixture: USBDeviceDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [USBDevicePresence]
    init(_ devices: [USBDevicePresence]) { stored = devices }
    var devices: [USBDevicePresence] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func connectedDevices() throws -> [USBDevicePresence] { devices }
}

private final class DiscoveryRunner: CfgutilRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: CommandResult
    private var recorded: [[String]] = []
    init(result: CommandResult) { storedResult = result }
    var result: CommandResult {
        get { lock.withLock { storedResult } }
        set { lock.withLock { storedResult = newValue } }
    }
    var commands: [[String]] { lock.withLock { recorded } }
    func run(_ arguments: [String]) throws -> CommandResult {
        lock.withLock {
            recorded.append(arguments)
            if arguments.last == "list" { return storedResult }
            return CommandResult(stdout: Data(#"{"Output":{"0X2A":{"installedApps":[]}}}"#.utf8))
        }
    }
}
