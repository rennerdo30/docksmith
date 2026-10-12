import Foundation
import Darwin

public enum DeviceServiceError: LocalizedError {
    case backendUnavailable
    case deviceMissing
    case inventoryUnavailable
    case invalidSelection
    case unsafeLayout
    case staleLayout
    case layoutUnavailable
    case backupFailed

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable: "This device is connected over USB, but Apple Configurator cannot currently access it. Retry the connection after reopening Configurator."
        case .deviceMissing: "The selected device is no longer connected."
        case .inventoryUnavailable: "The app inventory is unavailable."
        case .invalidSelection: "Select installed, removable apps before deleting."
        case .unsafeLayout: "This layout has unsupported items or an invalid structure."
        case .staleLayout: "The Home Screen changed since it was loaded. Reload before applying."
        case .layoutUnavailable: "The Home Screen layout is unavailable."
        case .backupFailed: "Could not save a private backup before applying the layout."
        }
    }
}

public actor DeviceService {
    private let runner: (any CfgutilRunning)?
    private let hardware: any USBDeviceDiscovering
    private let coreDevice: (any CoreDeviceProviding)?
    private var rememberedNames: [String: String] = [:]
    public var isBackendConfigured: Bool { runner != nil }

    public init(cfgutilPath: String? = nil) throws {
        runner = try? ProcessCfgutilRunner(path: cfgutilPath)
        hardware = IOKitUSBDeviceDiscovery()
        coreDevice = CoreDeviceProvider()
    }

    public init(runner: any CfgutilRunning, hardware: any USBDeviceDiscovering = EmptyUSBDeviceDiscovery(),
                coreDevice: (any CoreDeviceProviding)? = nil) {
        self.runner = runner
        self.hardware = hardware
        self.coreDevice = coreDevice
    }

    public func discover() throws -> [DeviceInfo] {
        let usbDevices = (try? hardware.connectedDevices()) ?? []
        var backendFailure: Error?
        var ready: [DeviceInfo] = []
        do {
            guard let runner else { throw DeviceServiceError.backendUnavailable }
            let result = try runner.run(["--format", "JSON", "list"])
            guard !result.timedOut, result.exitCode == 0,
                  let root = Self.jsonObject(result.stdout) as? [String: Any],
                  let output = root["Output"] as? [String: Any] else {
                throw ProbeError.malformedDiscovery
            }
            ready = output.compactMap { key, raw -> DeviceInfo? in
                guard key != "Errors", let info = raw as? [String: Any],
                      let backendID = info["ECID"] as? String, !backendID.isEmpty else { return nil }
                let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let model = info["deviceType"] as? String
                let location = info["locationID"]
                let isUSB: Bool
                if let number = location as? NSNumber { isUSB = number.int64Value != 0 }
                else if let string = location as? String {
                    isUSB = (UInt64(string) ?? UInt64(string.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0) != 0
                } else { isUSB = false }
                return DeviceInfo(id: DeviceIdentity.canonicalECID(backendID) ?? backendID,
                                  displayName: name ?? model ?? "Apple device", model: model,
                                  transport: isUSB ? "USB" : "Unknown", backendIdentifier: backendID)
            }
        } catch { backendFailure = error }
        for device in ready { rememberedNames[device.id] = device.displayName }
        var merged = Dictionary(ready.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for device in usbDevices where device.isSupportedMobileDevice {
            let identity = device.ecid.flatMap(DeviceIdentity.canonicalECID) ?? "usb-registry:\(device.registryID)"
            if let existing = merged[identity] {
                merged[identity] = DeviceInfo(id: existing.id, displayName: existing.displayName,
                                             model: existing.model, transport: "USB",
                                             backendIdentifier: existing.backendIdentifier)
            } else {
                merged[identity] = DeviceInfo(id: identity, displayName: rememberedNames[identity] ?? "\(device.productName) (USB)",
                                             model: device.productName, transport: "USB",
                                             availability: .usbDetectedBackendUnavailable,
                                             diagnostic: "Your \(device.productName) is connected to this Mac, but Apple Configurator cannot currently access it.")
            }
        }
        if let coreDevice, let discovered = try? coreDevice.discover() {
            let canRemove = (try? coreDevice.supportsAppRemoval()) == true
            for device in discovered {
                let ecid = device.ecid.flatMap(DeviceIdentity.canonicalECID)
                let udid = device.udid.flatMap(DeviceIdentity.canonicalUDID)
                let exactUSB = usbDevices.first { usb in
                    guard usb.isSupportedMobileDevice else { return false }
                    if let ecid, usb.ecid.flatMap(DeviceIdentity.canonicalECID) == ecid { return true }
                    return udid != nil && usb.udid.flatMap(DeviceIdentity.canonicalUDID) == udid
                }
                let identity = exactUSB.map {
                    $0.ecid.flatMap(DeviceIdentity.canonicalECID) ?? "usb-registry:\($0.registryID)"
                } ?? ecid ?? "coredevice:\(device.identifier)"
                if merged[identity]?.capabilities.inventoryBackend == .cfgutil { continue }
                merged[identity] = DeviceInfo(id: identity, displayName: device.name, model: device.model,
                                             transport: exactUSB == nil ? device.transport : "USB",
                                             availability: .usbDetectedBackendUnavailable,
                                             diagnostic: canRemove ? "Apps loaded using Xcode. Supported removable apps can be removed using Xcode; Home Screen editing requires Apple Configurator access." : "Apps loaded using Xcode. App removal and Home Screen editing require Apple Configurator access.",
                                             backendIdentifier: device.identifier,
                                             capabilities: DeviceCapabilities(inventoryBackend: .coreDevice, canRemoveApps: canRemove))
                rememberedNames[identity] = device.name
            }
        }
        if merged.isEmpty, let backendFailure { throw backendFailure }
        return merged.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func loadInventory(deviceID: String) throws -> InventorySnapshot {
        let device = try requireDevice(deviceID, allowReadOnlyApps: true)
        let target = device.backendIdentifier
        if device.capabilities.inventoryBackend == .coreDevice, let coreDevice {
            return try coreDevice.loadInventory(identifier: target, deviceID: deviceID)
        }
        let result = try run(["--format", "JSON", "--ecid", target, "get", "installedApps"])
        guard !result.timedOut,
              let root = Self.jsonObject(result.stdout) as? [String: Any],
              let output = root["Output"] as? [String: Any],
              let device = output[target] as? [String: Any],
              !Self.selectedError(root: root, output: output, device: device, id: target),
              let rawApps = device["installedApps"] as? [[String: Any]] else {
            return InventorySnapshot(deviceID: deviceID, apps: [],
                                     warning: "App inventory could not be decoded.", isPartial: true, isDecoded: false)
        }
        var apps: [InstalledApp] = []
        for raw in rawApps {
            guard let id = raw["bundleIdentifier"] as? String, !id.isEmpty else {
                return InventorySnapshot(deviceID: deviceID, apps: [],
                                         warning: "App inventory contained a malformed record.", isPartial: true, isDecoded: false)
            }
            let name = (raw["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (raw["itunesName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? AppNames.knownName(for: id) ?? id
            let version = raw["bundleVersion"] as? String
            apps.append(InstalledApp(id: id, name: name, version: version))
        }
        return InventorySnapshot(deviceID: deviceID, apps: apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                                 warning: result.exitCode == 0 ? nil : "cfgutil returned a nonzero status; inventory may be partial.",
                                 isPartial: result.exitCode != 0, isDecoded: true)
    }

    public func loadLayout(deviceID: String) throws -> LayoutSnapshot {
        let target = try requireDevice(deviceID).backendIdentifier
        let result = try run(["--format", "JSON", "--ecid", target, "get-icon-layout"])
        let decoded = result.timedOut ? nil : try? LayoutCodec.decode(result.stdout)
        let warning: String? = decoded == nil ? "Home Screen layout could not be decoded."
            : (result.exitCode == 0 ? nil : "cfgutil returned a nonzero status; layout may be partial.")
        return LayoutSnapshot(deviceID: deviceID, capturedAt: Date(), rawJSON: result.stdout,
                              layout: decoded, warning: warning,
                              isPartial: decoded == nil || result.exitCode != 0)
    }

    public func loadSnapshot(deviceID: String) throws -> DeviceSnapshot {
        guard let device = try discover().first(where: { $0.id == deviceID }) else {
            throw DeviceServiceError.deviceMissing
        }
        let inventory = try loadInventory(deviceID: deviceID)
        let layout: LayoutSnapshot
        if device.capabilities.canReadLayout {
            do { layout = try loadLayout(deviceID: deviceID) }
            catch {
                layout = LayoutSnapshot(deviceID: deviceID, capturedAt: Date(), rawJSON: Data(), layout: nil,
                                        warning: "Home Screen layout could not be read. App inventory remains available.", isPartial: true)
            }
        } else {
            layout = LayoutSnapshot(deviceID: deviceID, capturedAt: Date(), rawJSON: Data(), layout: nil,
                                    warning: "Home Screen editing requires Apple Configurator access.", isPartial: true)
        }
        guard let homeLayout = layout.layout else {
            return DeviceSnapshot(device: device, inventory: inventory, layout: layout)
        }
        var merged = inventory.apps
        let known = Set(merged.map(\.id))
        for identifier in Set(LayoutCodec.identifiers(homeLayout)).subtracting(known) {
            merged.append(InstalledApp(id: identifier,
                                       name: AppNames.knownName(for: identifier) ?? identifier,
                                       isFromInventory: false))
        }
        merged.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let allApps = InventorySnapshot(deviceID: deviceID, apps: merged,
                                        warning: inventory.warning, isPartial: inventory.isPartial,
                                        isDecoded: inventory.isDecoded)
        return DeviceSnapshot(device: device, inventory: allApps, layout: layout)
    }

    public func loadIcon(deviceID: String, appID: String) throws -> Data? {
        try Task.checkCancellation()
        let target = try requireDevice(deviceID).backendIdentifier
        try Task.checkCancellation()
        guard Self.validBundleID(appID) else { throw DeviceServiceError.invalidSelection }
        let temp = try Self.privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let result = try run(["--format", "JSON", "--ecid", target,
                             "get-app-icon", "--raw", appID], in: temp)
        try Task.checkCancellation()
        guard !result.timedOut, result.exitCode == 0 else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension.lowercased() == "png" {
            let data = try Data(contentsOf: file)
            if data.starts(with: [0x89, 0x50, 0x4e, 0x47]), data.count <= 10_000_000 { return data }
        }
        return nil
    }

    public func prepareRemoval(deviceID: String, ids: [String]) throws -> RemovalPlan {
        let device = try requireDevice(deviceID, allowReadOnlyApps: true)
        let unique = Array(Set(ids)).sorted()
        guard device.capabilities.canRemoveApps else { throw DeviceServiceError.backendUnavailable }
        guard !unique.isEmpty, unique.allSatisfy(Self.validBundleID) else {
            throw DeviceServiceError.invalidSelection
        }
        return RemovalPlan(deviceID: deviceID, backend: device.capabilities.inventoryBackend, ids: unique, target: device.backendIdentifier)
    }

    public func removeApps(deviceID: String, ids: [String]) throws -> [RemovalResult] {
        try executeRemoval(prepareRemoval(deviceID: deviceID, ids: ids))
    }

    public func executeRemoval(_ plan: RemovalPlan) throws -> [RemovalResult] {
        _ = try requirePinnedDevice(plan)
        let inventory = try loadInventory(deviceID: plan.deviceID)
        guard inventory.isDecoded, plan.backend != .coreDevice || !inventory.isPartial else { throw DeviceServiceError.inventoryUnavailable }
        _ = try requirePinnedDevice(plan)
        let installed = Dictionary(inventory.apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var outcomes: [RemovalResult] = []
        var interrupted = false
        for id in plan.ids {
            if interrupted {
                outcomes.append(RemovalResult(id: id, success: false, message: "Not attempted because device access changed. Review the selection again."))
                continue
            }
            guard let app = installed[id] else {
                outcomes.append(RemovalResult(id: id, success: false, message: "App is not present in the fresh installed-app inventory."))
                continue
            }
            if plan.backend == .coreDevice && (app.isRemovable != true || app.isHidden != false || app.isInternal != false) {
                outcomes.append(RemovalResult(id: id, success: false, message: "Xcode did not report this app as a supported removable app."))
                continue
            }
            do { _ = try requirePinnedDevice(plan) }
            catch {
                interrupted = true
                outcomes.append(RemovalResult(id: id, success: false, message: "Not attempted because device access changed. Review the selection again."))
                continue
            }
            do {
                let succeeded: Bool
                if plan.backend == .coreDevice, let coreDevice {
                    succeeded = try coreDevice.removeApp(identifier: plan.target, bundleID: id)
                } else {
                    let result = try run(["--format", "JSON", "--ecid", plan.target, "remove-app", id])
                    succeeded = !result.timedOut && result.exitCode == 0 && !Self.responseHasSelectedError(result.stdout, id: plan.target)
                }
                outcomes.append(RemovalResult(id: id, success: succeeded,
                                              message: succeeded ? "Removal command completed; verifying." : "Removal failed or its result is uncertain. Reload before retrying."))
            } catch {
                outcomes.append(RemovalResult(id: id, success: false, message: "Device access changed or removal failed. Reload before retrying."))
            }
        }
        var refreshed: InventorySnapshot?
        do {
            _ = try requirePinnedDevice(plan)
            refreshed = try loadInventory(deviceID: plan.deviceID)
            _ = try requirePinnedDevice(plan)
        } catch { refreshed = nil }
        let remaining = Set(refreshed?.apps.map(\.id) ?? [])
        return outcomes.map { result in
            guard result.success else { return result }
            let verified = refreshed?.isDecoded == true && refreshed?.isPartial == false && !remaining.contains(result.id)
            return RemovalResult(id: result.id, success: verified,
                                 message: verified ? "App removal verified." : "Removal could not be verified from a fresh inventory.")
        }
    }

    private func requirePinnedDevice(_ plan: RemovalPlan) throws -> DeviceInfo {
        let device = try requireDevice(plan.deviceID, allowReadOnlyApps: true)
        guard device.capabilities.canRemoveApps, device.capabilities.inventoryBackend == plan.backend,
              device.backendIdentifier == plan.target else { throw DeviceServiceError.backendUnavailable }
        return device
    }

    public func applyLayout(deviceID: String, baseline: LayoutSnapshot, draft: HomeLayout) throws -> ApplyResult {
        let selectedDevice = try requireDevice(deviceID)
        let target = selectedDevice.backendIdentifier
        guard baseline.deviceID == deviceID, baseline.layout != nil,
              !baseline.isPartial, !LayoutCodec.containsUnknown(draft) else { throw DeviceServiceError.unsafeLayout }
        guard let original = baseline.layout,
              LayoutCodec.iconCounts(original) == LayoutCodec.iconCounts(draft),
              LayoutCodec.hasOnlySupportedFolderContents(draft) else { throw DeviceServiceError.unsafeLayout }
        if selectedDevice.model?.hasPrefix("iPhone") == true {
            guard draft.dock.count <= 4, draft.pages.allSatisfy({ $0.count <= 24 }) else {
                throw DeviceServiceError.unsafeLayout
            }
        }
        let proposed = try LayoutCodec.encode(draft)
        let current = try loadLayout(deviceID: deviceID)
        guard let currentLayout = current.layout, !current.isPartial else { throw DeviceServiceError.layoutUnavailable }
        guard LayoutCodec.semanticallyEqual(baseline.rawJSON, current.rawJSON) else {
            throw DeviceServiceError.staleLayout
        }
        // Avoid an unused baseline tree being treated as approval to write opaque items.
        guard !LayoutCodec.containsUnknown(currentLayout) else { throw DeviceServiceError.unsafeLayout }
        let backup: URL
        do { backup = try Self.saveBackup(current.rawJSON) }
        catch { throw DeviceServiceError.backupFailed }
        let temp = try Self.privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("layout.json")
        try Self.writePrivate(proposed, to: input)
        let result = try run(["--format", "JSON", "--ecid", target,
                             "set-icon-layout", input.path])
        guard !result.timedOut, result.exitCode == 0,
              !Self.responseHasSelectedError(result.stdout, id: target) else {
            return ApplyResult(success: false, message: "Layout update failed or its result is uncertain. Reload the device before retrying.", backupURL: backup)
        }
        let verified = try loadLayout(deviceID: deviceID)
        let matches = verified.layout != nil && !verified.isPartial
            && LayoutCodec.semanticallyEqual(proposed, verified.rawJSON)
        return ApplyResult(success: matches,
                           message: matches ? "Home Screen layout verified." : "Layout update could not be verified. Reload the device before retrying.",
                           backupURL: backup)
    }

    private func requireDevice(_ id: String, allowReadOnlyApps: Bool = false) throws -> DeviceInfo {
        guard !id.isEmpty, let device = try discover().first(where: { $0.id == id }) else {
            throw DeviceServiceError.deviceMissing
        }
        guard device.capabilities.inventoryBackend == .cfgutil || (allowReadOnlyApps && device.capabilities.canReadApps) else { throw DeviceServiceError.backendUnavailable }
        return device
    }

    private func run(_ arguments: [String], in directory: URL? = nil) throws -> CommandResult {
        guard let runner else { throw DeviceServiceError.backendUnavailable }
        if let directory { return try runner.run(arguments, in: directory) }
        return try runner.run(arguments)
    }

    private static func validBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.count < 256 && id.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#,
                                                   options: .regularExpression) != nil
    }

    private static func jsonObject(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    private static func meaningful(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let object = value as? [String: Any] { return object.values.contains(where: meaningful) }
        if let array = value as? [Any] { return array.contains(where: meaningful) }
        if let string = value as? String { return !string.isEmpty }
        return true
    }

    private static func selectedError(root: [String: Any], output: [String: Any],
                                      device: [String: Any]?, id: String) -> Bool {
        if meaningful(device?["Errors"]) { return true }
        for container in [output, root] {
            if let errors = container["Errors"] as? [String: Any], meaningful(errors[id]) { return true }
        }
        return false
    }

    private static func responseHasSelectedError(_ data: Data, id: String) -> Bool {
        guard let root = jsonObject(data) as? [String: Any],
              let output = root["Output"] as? [String: Any] else { return false }
        return selectedError(root: root, output: output,
                             device: output[id] as? [String: Any], id: id)
    }

    private static func privateTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("docksmith-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func saveBackup(_ data: Data) throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Docksmith/Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("layout-\(UUID().uuidString).json")
        try writePrivate(data, to: url)
        return url
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { throw DeviceServiceError.backupFailed }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw DeviceServiceError.backupFailed }
                offset += count
            }
        }
    }
}
