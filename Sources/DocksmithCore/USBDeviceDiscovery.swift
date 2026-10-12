import Foundation
import IOKit

public struct USBDevicePresence: Sendable {
    public let registryID: UInt64
    public let productName: String
    public let vendorID: Int
    public let ecid: String?

    public init(registryID: UInt64, productName: String, vendorID: Int, ecid: String?) {
        self.registryID = registryID
        self.productName = productName
        self.vendorID = vendorID
        self.ecid = ecid
    }

    var isSupportedMobileDevice: Bool {
        vendorID == 0x05ac && ["iPhone", "iPad", "iPod"].contains {
            productName == $0 || productName.hasPrefix($0 + " ")
        }
    }
}

public protocol USBDeviceDiscovering: Sendable {
    func connectedDevices() throws -> [USBDevicePresence]
}

public struct EmptyUSBDeviceDiscovery: USBDeviceDiscovering {
    public init() {}
    public func connectedDevices() throws -> [USBDevicePresence] { [] }
}

public struct IOKitUSBDeviceDiscovery: USBDeviceDiscovering {
    public init() {}

    public func connectedDevices() throws -> [USBDevicePresence] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var devices: [USBDevicePresence] = []
        while true {
            let device = IOIteratorNext(iterator)
            guard device != 0 else { break }
            defer { IOObjectRelease(device) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(device, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let raw = properties?.takeRetainedValue() as? [String: Any],
                  let product = (raw["USB Product Name"] ?? raw["kUSBProductString"]) as? String,
                  let vendor = raw["idVendor"] as? NSNumber else { continue }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(device, &registryID) == KERN_SUCCESS else { continue }
            let presence = USBDevicePresence(registryID: registryID, productName: product,
                                             vendorID: vendor.intValue, ecid: Self.ecid(from: raw))
            if presence.isSupportedMobileDevice { devices.append(presence) }
        }
        return devices
    }

    static func ecid(from properties: [String: Any]) -> String? {
        if let number = properties["UsbAppleDeviceECID"] as? NSNumber { return number.stringValue }
        if let number = properties["ECID"] as? NSNumber { return number.stringValue }
        if let ecid = properties["ECID"] as? String { return ecid }
        // Apple USB recovery/normal-mode serial descriptors can contain a hex ECID.
        guard let serial = properties["USB Serial Number"] as? String,
              let range = serial.range(of: #"(?i)\bECID:\s*(?:0x)?[0-9a-f]+\b"#, options: .regularExpression) else { return nil }
        let field = serial[range].split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
        return field.lowercased().hasPrefix("0x") ? field : "0x" + field
    }
}

enum DeviceIdentity {
    static func canonicalECID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("0x") {
            return UInt64(value.dropFirst(2), radix: 16).map(String.init)
        }
        if let decimal = UInt64(value) { return String(decimal) }
        if value.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil {
            return UInt64(value, radix: 16).map(String.init)
        }
        return nil
    }
}
