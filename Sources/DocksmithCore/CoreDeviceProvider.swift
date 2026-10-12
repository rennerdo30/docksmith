import Foundation

public struct CoreDeviceInfo: Sendable {
    public let identifier: String
    public let udid: String?
    public let ecid: String?
    public let name: String
    public let model: String
    public let transport: String
}

public protocol CoreDeviceProviding: Sendable {
    func supportsAppRemoval() throws -> Bool
    func removeApp(identifier: String, bundleID: String) throws -> Bool
    func discover() throws -> [CoreDeviceInfo]
    func loadInventory(identifier: String, deviceID: String) throws -> InventorySnapshot
}

public protocol CoreDeviceRunning: Sendable {
    func supportsAppRemoval() throws -> Bool
    func uninstallApp(identifier: String, bundleID: String) throws -> CommandResult
    func listDevices() throws -> CommandResult
    func listApps(identifier: String) throws -> CommandResult
}

public struct ProcessCoreDeviceRunner: CoreDeviceRunning {
    public init() {}
    public func supportsAppRemoval() throws -> Bool {
        let help = try BoundedProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                                          arguments: ["devicectl", "help", "device", "uninstall", "app"], timeout: 10)
        guard !help.timedOut, help.exitCode == 0, let text = String(data: help.stdout, encoding: .utf8) else { return false }
        return text.contains("devicectl device uninstall app") && text.contains("<bundle-identifier>") && text.contains("--device")
    }
    public func uninstallApp(identifier: String, bundleID: String) throws -> CommandResult {
        guard !identifier.isEmpty, !bundleID.isEmpty else { throw RunnerError.unsupportedInvocation }
        return try run(["device", "uninstall", "app", "--device", identifier, bundleID])
    }
    public func listDevices() throws -> CommandResult {
        try run(["list", "devices"])
    }
    public func listApps(identifier: String) throws -> CommandResult {
        guard !identifier.isEmpty else { throw RunnerError.unsupportedInvocation }
        return try run(["device", "info", "apps", "--device", identifier, "--include-all-apps"])
    }
    private func run(_ arguments: [String]) throws -> CommandResult {
        // xcrun fails cleanly if optional Xcode/devicectl is not installed.
        try BoundedProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                               arguments: ["devicectl"] + arguments + ["--timeout", "15", "--quiet", "--json-output", "-"],
                               timeout: 20)
    }
}

public struct CoreDeviceProvider: CoreDeviceProviding {
    private let runner: any CoreDeviceRunning
    public init(runner: any CoreDeviceRunning = ProcessCoreDeviceRunner()) { self.runner = runner }

    public func supportsAppRemoval() throws -> Bool { try runner.supportsAppRemoval() }
    public func removeApp(identifier: String, bundleID: String) throws -> Bool {
        let command = try runner.uninstallApp(identifier: identifier, bundleID: bundleID)
        return Self.commandSucceeded(command)
    }

    public func discover() throws -> [CoreDeviceInfo] {
        guard let result = Self.successfulResult(try runner.listDevices()),
              let devices = result["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { device in
            guard let identifier = device["identifier"] as? String, !identifier.isEmpty,
                  let hardware = device["hardwareProperties"] as? [String: Any],
                  hardware["reality"] as? String == "physical",
                  let type = hardware["deviceType"] as? String, ["iPhone", "iPad"].contains(type),
                  let connection = device["connectionProperties"] as? [String: Any],
                  connection["tunnelState"] as? String == "connected" else { return nil }
            let properties = device["deviceProperties"] as? [String: Any]
            let ecid = (hardware["ecid"] as? NSNumber)?.stringValue ?? hardware["ecid"] as? String
            return CoreDeviceInfo(identifier: identifier, udid: hardware["udid"] as? String,
                                  ecid: ecid, name: properties?["name"] as? String ?? type,
                                  model: hardware["productType"] as? String ?? type,
                                  transport: Self.transport(connection["transportType"] as? String))
        }
    }

    public func loadInventory(identifier: String, deviceID: String) throws -> InventorySnapshot {
        guard let result = Self.successfulResult(try runner.listApps(identifier: identifier)),
              let rawApps = result["apps"] as? [[String: Any]],
              ["defaultAppsIncluded", "hiddenAppsIncluded", "internalAppsIncluded", "removableAppsIncluded"].allSatisfy({ result[$0] as? Bool == true }) else {
            return InventorySnapshot(deviceID: deviceID, apps: [], warning: "Xcode could not return a complete app inventory. Retry Connection.", isPartial: true, isDecoded: false)
        }
        var apps: [String: InstalledApp] = [:]
        for raw in rawApps {
            guard let id = raw["bundleIdentifier"] as? String, !id.isEmpty, apps[id] == nil else {
                return InventorySnapshot(deviceID: deviceID, apps: [], warning: "Xcode returned a malformed app inventory.", isPartial: true, isDecoded: false)
            }
            apps[id] = InstalledApp(id: id, name: raw["name"] as? String ?? AppNames.knownName(for: id) ?? id,
                                    version: raw["version"] as? String ?? raw["bundleVersion"] as? String,
                                    isRemovable: raw["removable"] as? Bool, isHidden: raw["hidden"] as? Bool,
                                    isInternal: raw["internalApp"] as? Bool)
        }
        return InventorySnapshot(deviceID: deviceID,
                                 apps: apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                                 warning: "Inventory includes system, hidden and internal apps when reported. Home Screen editing requires Apple Configurator access.",
                                 isPartial: false, isDecoded: true)
    }

    private static func transport(_ reported: String?) -> String {
        switch reported {
        case "wired": "USB"
        case "localNetwork": "Network"
        default: "Unknown"
        }
    }

    private static func commandSucceeded(_ command: CommandResult) -> Bool {
        guard !command.timedOut, command.exitCode == 0,
              let root = try? JSONSerialization.jsonObject(with: command.stdout) as? [String: Any],
              let info = root["info"] as? [String: Any] else { return false }
        return info["outcome"] as? String == "success"
    }

    private static func successfulResult(_ command: CommandResult) -> [String: Any]? {
        guard !command.timedOut, command.exitCode == 0,
              let root = try? JSONSerialization.jsonObject(with: command.stdout) as? [String: Any],
              let info = root["info"] as? [String: Any], info["outcome"] as? String == "success" else { return nil }
        return root["result"] as? [String: Any]
    }
}
