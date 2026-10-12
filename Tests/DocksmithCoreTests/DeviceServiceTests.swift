import Foundation
import XCTest
@testable import DocksmithCore

final class DeviceServiceTests: XCTestCase {
    func testFolderRoundTripPreservesFlatAndPagedForms() throws {
        let original = Data(#"[["com.apple.mobilesafari"],[ ["Work","com.example.one","com.example.two"], ["Travel",["com.example.map"],["com.example.ticket"]] ]]"#.utf8)
        let layout = try LayoutCodec.decode(original)
        XCTAssertEqual(layout.pages.count, 1)
        let encoded = try LayoutCodec.encode(layout)
        XCTAssertTrue(LayoutCodec.semanticallyEqual(original, encoded))
        XCTAssertEqual(try LayoutCodec.decode(encoded).pages.count, 1)
    }

    func testUnsupportedNodeCannotBeApplied() throws {
        let original = Data(#"[["dock"],[{"future":"form"}]]"#.utf8)
        let layout = try LayoutCodec.decode(original)
        XCTAssertTrue(LayoutCodec.containsUnknown(layout))
        XCTAssertThrowsError(try LayoutCodec.encode(layout))
    }

    func testEquivalentFolderFormsCompareEqualButChangesDoNot() {
        let flat = Data(#"[[],[["Work","com.example.one","com.example.two"]]]"#.utf8)
        let paged = Data(#"[[],[["Work",["com.example.one","com.example.two"]]]]"#.utf8)
        let reordered = Data(#"[[],[["Work",["com.example.two","com.example.one"]]]]"#.utf8)
        let renamed = Data(#"[[],[["Other",["com.example.one","com.example.two"]]]]"#.utf8)
        XCTAssertTrue(LayoutCodec.semanticallyEqual(flat, paged))
        XCTAssertFalse(LayoutCodec.semanticallyEqual(flat, reordered))
        XCTAssertFalse(LayoutCodec.semanticallyEqual(flat, renamed))
        let unknownA = Data(#"[[],[{"future":true,"position":1}]]"#.utf8)
        let unknownB = Data(#"[[],[{"position":1,"future":true}]]"#.utf8)
        let unknownChanged = Data(#"[[],[{"position":2,"future":true}]]"#.utf8)
        XCTAssertTrue(LayoutCodec.semanticallyEqual(unknownA, unknownB))
        XCTAssertFalse(LayoutCodec.semanticallyEqual(unknownA, unknownChanged))
    }

    func testStaleLayoutStopsBeforeWrite() async throws {
        let initial = Data(#"[["dock"],["first"]]"#.utf8)
        let changed = Data(#"[["dock"],["second"]]"#.utf8)
        let mock = ServiceFixtureRunner(layoutResponses: [changed])
        let service = DeviceService(runner: mock)
        let baseline = LayoutSnapshot(deviceID: "selected", capturedAt: Date(),
                                      rawJSON: initial, layout: try LayoutCodec.decode(initial),
                                      warning: nil, isPartial: false)
        do {
            _ = try await service.applyLayout(deviceID: "selected", baseline: baseline,
                                              draft: try LayoutCodec.decode(initial))
            XCTFail("Expected stale layout rejection")
        } catch DeviceServiceError.staleLayout {
            XCTAssertFalse(mock.commands.contains { $0.contains("set-icon-layout") })
        }
    }

    func testDraftCannotOmitOrDuplicateIcons() async throws {
        let original = Data(#"[["dock"],["first","second"]]"#.utf8)
        let mock = ServiceFixtureRunner(layoutResponses: [])
        let service = DeviceService(runner: mock)
        let baseline = LayoutSnapshot(deviceID: "selected", capturedAt: Date(),
                                      rawJSON: original, layout: try LayoutCodec.decode(original),
                                      warning: nil, isPartial: false)
        for proposed in [#"[["dock"],["first"]]"#, #"[["dock"],["first","first","second"]]"#] {
            do {
                _ = try await service.applyLayout(deviceID: "selected", baseline: baseline,
                                                  draft: try LayoutCodec.decode(Data(proposed.utf8)))
                XCTFail("Expected icon preservation check")
            } catch DeviceServiceError.unsafeLayout { }
        }
        XCTAssertFalse(mock.commands.contains { $0.contains("set-icon-layout") })
        XCTAssertFalse(mock.commands.contains { $0.contains("get-icon-layout") })
    }

    func testPartialRefreshDoesNotClaimRemovalVerified() async throws {
        let first = Data(#"{"Output":{"selected":{"installedApps":[{"bundleIdentifier":"com.example.one","displayName":"One"}]},"Errors":{"selected":{}}}}"#.utf8)
        let partialEmpty = Data(#"{"Output":{"selected":{"installedApps":[]},"Errors":{"selected":{}}}}"#.utf8)
        let mock = ServiceFixtureRunner(layoutResponses: [], inventories: [
            CommandResult(stdout: first), CommandResult(stdout: partialEmpty, exitCode: 1),
        ])
        let results = try await DeviceService(runner: mock).removeApps(deviceID: "selected", ids: ["com.example.one"])
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].success)
        XCTAssertEqual(mock.commands.filter { $0.contains("remove-app") }.count, 1)
    }

    func testInventoriedAppleAppIsAttemptedAndCfgutilFailureIsReported() async throws {
        let inventory = Data(#"{"Output":{"selected":{"installedApps":[{"bundleIdentifier":"com.apple.Pages","displayName":"Pages"}]},"Errors":{"selected":{}}}}"#.utf8)
        let mock = ServiceFixtureRunner(layoutResponses: [], inventories: [
            CommandResult(stdout: inventory), CommandResult(stdout: inventory),
        ], removalResult: CommandResult(stdout: Data(#"{"Output":{"Errors":{"selected":{"remove-app":"rejected"}}}}"#.utf8), exitCode: 1))
        let results = try await DeviceService(runner: mock).removeApps(deviceID: "selected", ids: ["com.apple.Pages"])
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].success)
        XCTAssertEqual(mock.commands.filter { $0.contains("remove-app") }.count, 1)
    }

    func testInventoriedAppleAppRemovalIsVerifiedFromCompleteRefresh() async throws {
        let inventory = Data(#"{"Output":{"selected":{"installedApps":[{"bundleIdentifier":"com.apple.mobilegarageband","displayName":"GarageBand"}]},"Errors":{"selected":{}}}}"#.utf8)
        let completeEmpty = Data(#"{"Output":{"selected":{"installedApps":[]},"Errors":{"selected":{}}}}"#.utf8)
        let mock = ServiceFixtureRunner(layoutResponses: [], inventories: [
            CommandResult(stdout: inventory), CommandResult(stdout: completeEmpty),
        ])
        let results = try await DeviceService(runner: mock).removeApps(deviceID: "selected", ids: ["com.apple.mobilegarageband"])
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].success)
        XCTAssertEqual(results[0].message, "App removal verified.")
        XCTAssertEqual(mock.commands.filter { $0.contains("remove-app") }, [
            ["--format", "JSON", "--ecid", "selected", "remove-app", "com.apple.mobilegarageband"],
        ])
    }

    func testAppAbsentFromFreshInventoryIsNeverRemoved() async throws {
        let emptyInventory = Data(#"{"Output":{"selected":{"installedApps":[]},"Errors":{"selected":{}}}}"#.utf8)
        let mock = ServiceFixtureRunner(layoutResponses: [], inventories: [
            CommandResult(stdout: emptyInventory), CommandResult(stdout: emptyInventory),
        ])
        let results = try await DeviceService(runner: mock).removeApps(deviceID: "selected", ids: ["com.apple.mobilegarageband"])
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].success)
        XCTAssertFalse(mock.commands.contains { $0.contains("remove-app") })
    }
}

private final class ServiceFixtureRunner: CfgutilRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var layouts: [Data]
    private var inventories: [CommandResult]
    private let removalResult: CommandResult?
    private var recorded: [[String]] = []

    init(layoutResponses: [Data], inventories: [CommandResult] = [], removalResult: CommandResult? = nil) {
        layouts = layoutResponses
        self.inventories = inventories
        self.removalResult = removalResult
    }

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ arguments: [String]) throws -> CommandResult {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(arguments)
        if arguments.last == "list" {
            return CommandResult(stdout: Data(#"{"Output":{"selected":{"ECID":"selected","name":"Test device"}}}"#.utf8))
        }
        if arguments.last == "get-icon-layout" {
            return CommandResult(stdout: layouts.removeFirst())
        }
        if arguments.last == "installedApps" {
            return inventories.removeFirst()
        }
        if arguments.contains("remove-app") {
            return removalResult ?? CommandResult(stdout: Data(#"{"Output":{"selected":{},"Errors":{"selected":{}}}}"#.utf8))
        }
        throw RunnerError.unsupportedInvocation
    }
}
