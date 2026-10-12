import XCTest
@testable import DocksmithCore

final class ProbeTests: XCTestCase {
    private let ecid = "private-test-id"

    private func result(_ json: String, exit: Int32 = 0) -> CommandResult {
        CommandResult(stdout: Data(json.utf8), exitCode: exit)
    }

    func testNonzeroInventoryWithEmptyNestedErrorsKeepsDecodedCount() {
        let response = result(#"{"Output":{"private-test-id":{"installedApps":[{"bundleIdentifier":"a"},{"bundleIdentifier":"b"}]},"Errors":{"private-test-id":{}}}}"#, exit: 1)
        let check = CfgutilParser.inventory(response, ecid: ecid)
        XCTAssertEqual(check.state, .supported)
        XCTAssertEqual(check.count, 2)
        XCTAssertNotNil(check.warning)
    }

    func testGenuineInventoryErrorIsUnavailable() {
        let response = result(#"{"Output":{"private-test-id":{"installedApps":[]},"Errors":{"private-test-id":{"installedApps":"denied"}}}}"#, exit: 1)
        let check = CfgutilParser.inventory(response, ecid: ecid)
        XCTAssertEqual(check.state, .unavailable)
        XCTAssertNil(check.count)
    }

    func testBareNestedLayoutIsAccepted() {
        let response = result(#"[["Dock app"],["Page app",["Folder",["Folder app"],["Other app"]]],["Second page"]]"#)
        let check = CfgutilParser.layout(response, ecid: ecid)
        XCTAssertEqual(check.state, .supported)
        XCTAssertEqual(check.count, 2)
    }

    func testMalformedLayoutIsIndeterminate() {
        let check = CfgutilParser.layout(result("not json", exit: 1), ecid: ecid)
        XCTAssertEqual(check.state, .indeterminate)
        XCTAssertEqual(CfgutilParser.layout(result("[1,2]"), ecid: ecid).state, .indeterminate)
        XCTAssertEqual(CfgutilParser.layout(result("[]"), ecid: ecid).state, .indeterminate)
    }

    func testMalformedAppsAreIndeterminateAndOtherDeviceErrorsAreIgnored() {
        let malformed = result(#"{"Output":{"private-test-id":{"installedApps":[1]},"Errors":{}}}"#)
        XCTAssertEqual(CfgutilParser.inventory(malformed, ecid: ecid).state, .indeterminate)
        let otherError = result(#"{"Output":{"private-test-id":{"installedApps":[{"bundleIdentifier":"a"}]},"Errors":{"different-id":{"installedApps":"denied"}}}}"#)
        XCTAssertEqual(CfgutilParser.inventory(otherError, ecid: ecid).state, .supported)
    }

    func testDiscoverySkipsOutputErrorsEntry() throws {
        let response = result(#"{"Output":{"private-test-id":{"ECID":"private-test-id","deviceType":"iPhone"},"Errors":{"private-test-id":{}}}}"#)
        XCTAssertEqual(try CfgutilParser.discovery(response).devices.count, 1)
    }

    func testProbeRequiresExplicitCurrentDeviceAndNeverLeaksIdentifiers() throws {
        let runner = FixtureRunner(results: [
            result(#"{"Output":{"id-a":{"ECID":"id-a","deviceType":"iPhone"},"id-b":{"ECID":"id-b","deviceType":"iPad"}}}"#),
            result(#"{"Output":{"id-b":{"installedApps":[{"bundleIdentifier":"a"}]},"Errors":{"id-b":{}}}}"#, exit: 1),
            result("[[\"dock\"],[\"page\"]]"),
        ])
        let probe = DocksmithProbe(runner: runner)
        let report = try probe.probe(ecid: "id-b")
        XCTAssertEqual(report.deviceCount, 2)
        XCTAssertEqual(report.inventory.state, .supported)
        XCTAssertEqual(report.layout.state, .supported)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains("id-b"))
        XCTAssertFalse(encoded.contains("installedApps"))
        XCTAssertEqual(runner.calls[1], ["--format", "JSON", "--ecid", "id-b", "get", "installedApps"])
    }

    func testUnknownDeviceDoesNotStartDeviceReads() throws {
        let runner = FixtureRunner(results: [result(#"{"Output":{"id-a":{"ECID":"id-a"}}}"#)])
        XCTAssertThrowsError(try DocksmithProbe(runner: runner).probe(ecid: "id-b"))
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testProcessRunnerRejectsDeviceWriteCommand() throws {
        let runner = try ProcessCfgutilRunner(path: "/usr/bin/true")
        XCTAssertThrowsError(try runner.run(["erase"])) { error in
            guard case RunnerError.unsupportedInvocation = error else {
                return XCTFail("Expected the read-only command guard")
            }
        }
    }
}

private final class FixtureRunner: CfgutilRunning, @unchecked Sendable {
    var results: [CommandResult]
    var calls: [[String]] = []
    init(results: [CommandResult]) { self.results = results }
    func run(_ arguments: [String]) throws -> CommandResult {
        calls.append(arguments)
        return results.removeFirst()
    }
}
