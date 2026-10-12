import Foundation

public enum ProbeState: String, Codable {
    case supported, unavailable, indeterminate
}

public struct Check: Codable {
    public let state: ProbeState
    public let count: Int?
    public let warning: String?

    public init(_ state: ProbeState, count: Int? = nil, warning: String? = nil) {
        self.state = state
        self.count = count
        self.warning = warning
    }
}

public struct DeviceChoice {
    public let ecid: String
    public let category: String
}

public struct Discovery {
    public let devices: [DeviceChoice]
    public let warning: String?
}

public struct ProbeReport: Codable {
    public let backend: String
    public let deviceCount: Int
    public let inventory: Check
    public let layout: Check
}

public enum ProbeError: LocalizedError {
    case malformedDiscovery
    case deviceNotFound
    case selectionRequired

    public var errorDescription: String? {
        switch self {
        case .malformedDiscovery: "Could not decode the device list from cfgutil."
        case .deviceNotFound: "The selected device is not in the current device list."
        case .selectionRequired: "Select a device with --device NUMBER or --ecid VALUE."
        }
    }
}

public enum CfgutilParser {
    private static func object(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    public static func discovery(_ result: CommandResult) throws -> Discovery {
        guard !result.timedOut,
              let root = object(result.stdout) as? [String: Any],
              let output = root["Output"] as? [String: Any] else {
            throw ProbeError.malformedDiscovery
        }
        let devices = output.compactMap { key, value -> DeviceChoice? in
            guard key != "Errors" else { return nil }
            guard let info = value as? [String: Any] else { return nil }
            guard let ecid = info["ECID"] as? String else { return nil }
            guard !ecid.isEmpty else { return nil }
            return DeviceChoice(ecid: ecid, category: info["deviceType"] as? String ?? "device")
        }.sorted { $0.ecid < $1.ecid }
        let warning = result.exitCode == 0 ? nil : "Device discovery returned a nonzero status; the list may be partial."
        return Discovery(devices: devices, warning: warning)
    }

    public static func inventory(_ result: CommandResult, ecid: String) -> Check {
        guard !result.timedOut else { return Check(.indeterminate, warning: "Inventory request timed out.") }
        guard let root = object(result.stdout) as? [String: Any],
              let output = root["Output"] as? [String: Any],
              let device = output[ecid] as? [String: Any] else {
            return Check(.indeterminate, warning: "Inventory response was missing or malformed.")
        }
        if hasSelectedError(root: root, output: output, device: device, ecid: ecid) {
            return Check(.unavailable, warning: "cfgutil reported a device error for inventory.")
        }
        guard let apps = device["installedApps"] as? [Any] else {
            return Check(.indeterminate, warning: "Inventory response did not contain an app list.")
        }
        guard apps.allSatisfy({ ($0 as? [String: Any])?["bundleIdentifier"] is String }) else {
            return Check(.indeterminate, warning: "Inventory response contained malformed app records.")
        }
        let warning = result.exitCode == 0 ? nil : "cfgutil returned a nonzero status; decoded inventory may be partial."
        return Check(.supported, count: apps.count, warning: warning)
    }

    public static func layout(_ result: CommandResult, ecid: String) -> Check {
        guard !result.timedOut else { return Check(.indeterminate, warning: "Layout request timed out.") }
        guard let parsed = object(result.stdout) else {
            return Check(.indeterminate, warning: "Layout response was missing or malformed.")
        }
        if let pages = parsed as? [Any], validLayout(pages) {
            let warning = result.exitCode == 0 ? nil : "cfgutil returned a nonzero status; decoded layout may be partial."
            return Check(.supported, count: pages.count - 1, warning: warning)
        }
        if let root = parsed as? [String: Any], let output = root["Output"] as? [String: Any] {
            if hasSelectedError(root: root, output: output,
                                device: output[ecid] as? [String: Any], ecid: ecid) {
                return Check(.unavailable, warning: "cfgutil reported a device error for layout.")
            }
            if let pages = output[ecid] as? [Any], validLayout(pages) {
                let warning = result.exitCode == 0 ? nil : "cfgutil returned a nonzero status; decoded layout may be partial."
                return Check(.supported, count: pages.count - 1, warning: warning)
            }
        }
        return Check(.indeterminate, warning: "Layout response did not contain pages.")
    }

    private static func meaningful(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let dictionary = value as? [String: Any] { return dictionary.values.contains(where: { meaningful($0) }) }
        if let array = value as? [Any] { return array.contains(where: { meaningful($0) }) }
        if let string = value as? String { return !string.isEmpty }
        return true
    }

    private static func hasSelectedError(root: [String: Any], output: [String: Any],
                                         device: [String: Any]?, ecid: String) -> Bool {
        if meaningful(device?["Errors"]) { return true }
        for container in [output, root] {
            if let errors = container["Errors"] as? [String: Any], meaningful(errors[ecid]) { return true }
        }
        return false
    }

    private static func validLayout(_ pages: [Any]) -> Bool {
        guard pages.count >= 2 else { return false }
        return pages.allSatisfy { page in
            guard let icons = page as? [Any] else { return false }
            return icons.allSatisfy { icon in
                if let name = icon as? String { return !name.isEmpty }
                if let folder = icon as? [Any] { return validFolder(folder) }
                return false
            }
        }
    }

    private static func validFolder(_ folder: [Any]) -> Bool {
        guard let name = folder.first as? String, !name.isEmpty else { return false }
        return folder.dropFirst().allSatisfy { content in
            if let app = content as? String { return !app.isEmpty }
            if let page = content as? [Any] {
                return page.allSatisfy { ($0 as? String)?.isEmpty == false }
            }
            return false
        }
    }
}

public final class DocksmithProbe {
    private let runner: CfgutilRunning

    public init(runner: CfgutilRunning) { self.runner = runner }

    public func discover() throws -> Discovery {
        try CfgutilParser.discovery(runner.run(["--format", "JSON", "list"]))
    }

    public func probe(ecid: String) throws -> ProbeReport {
        let discovery = try discover()
        guard discovery.devices.contains(where: { $0.ecid == ecid }) else { throw ProbeError.deviceNotFound }
        let inventory = CfgutilParser.inventory(
            try runner.run(["--format", "JSON", "--ecid", ecid, "get", "installedApps"]), ecid: ecid)
        let layout = CfgutilParser.layout(
            try runner.run(["--format", "JSON", "--ecid", ecid, "get-icon-layout"]), ecid: ecid)
        return ProbeReport(backend: "cfgutil", deviceCount: discovery.devices.count,
                           inventory: inventory, layout: layout)
    }
}
