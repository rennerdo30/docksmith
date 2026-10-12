import Foundation

public struct DeviceInfo: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let model: String?
    public let transport: String

    public init(id: String, displayName: String, model: String?, transport: String) {
        self.id = id
        self.displayName = displayName
        self.model = model
        self.transport = transport
    }
}

public struct InstalledApp: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let version: String?
    public let iconData: Data?
    public let isFromInventory: Bool

    public init(id: String, name: String, version: String? = nil,
                iconData: Data? = nil, isFromInventory: Bool = true) {
        self.id = id
        self.name = name
        self.version = version
        self.iconData = iconData
        self.isFromInventory = isFromInventory
    }
}

public struct InventorySnapshot: Sendable {
    public let deviceID: String
    public let apps: [InstalledApp]
    public let warning: String?
    public let isPartial: Bool
    public let isDecoded: Bool
}

public struct HomeLayout: Equatable, Sendable {
    public var dock: [LayoutNode]
    public var pages: [[LayoutNode]]

    public init(dock: [LayoutNode], pages: [[LayoutNode]]) {
        self.dock = dock
        self.pages = pages
    }
}

public indirect enum LayoutNode: Equatable, Identifiable, Sendable {
    case icon(String)
    case folder(LayoutFolder)
    case unknown(Data)

    public var id: String {
        switch self {
        case .icon(let identifier): "icon:\(identifier)"
        case .folder(let folder): "folder:\(folder.id)"
        case .unknown(let data): "unknown:\(data.base64EncodedString())"
        }
    }
}

public struct LayoutFolder: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var pages: [[LayoutNode]]
    public var wasFlat: Bool

    public init(id: UUID = UUID(), name: String, pages: [[LayoutNode]], wasFlat: Bool) {
        self.id = id
        self.name = name
        self.pages = pages
        self.wasFlat = wasFlat
    }
}

public struct LayoutSnapshot: Sendable {
    public let deviceID: String
    public let capturedAt: Date
    public let rawJSON: Data
    public let layout: HomeLayout?
    public let warning: String?
    public let isPartial: Bool
}

public struct DeviceSnapshot: Sendable {
    public let device: DeviceInfo
    public let inventory: InventorySnapshot
    public let layout: LayoutSnapshot
}

public struct RemovalResult: Sendable {
    public let id: String
    public let success: Bool
    public let message: String
}

public struct ApplyResult: Sendable {
    public let success: Bool
    public let message: String
    public let backupURL: URL?
}

public enum AppNames {
    // Apple Platform Deployment bundle-ID table (2026-02-11):
    // https://support.apple.com/en-euro/guide/deployment/depece748c41/web
    // Unknown identifiers stay visible as identifiers.
    private static let known: [String: String] = [
        "com.apple.AppStore": "App Store",
        "com.apple.AppStoreConnect": "App Store Connect",
        "com.apple.business-essentials": "Apple Business",
        "com.apple.ios.configurator": "Apple Configurator",
        "com.apple.store.Jolly": "Apple Store",
        "com.apple.visionproapp": "Apple Vision Pro",
        "com.apple.BarcodeScanner": "Barcode Scanner",
        "com.apple.iBooks": "Books",
        "com.apple.calculator": "Calculator",
        "com.apple.mobilecal": "Calendar",
        "com.apple.camera": "Camera",
        "com.apple.music.classical": "Classical",
        "com.apple.classroom": "Classroom",
        "com.apple.clips": "Clips",
        "com.apple.mobiletimer": "Clock",
        "com.apple.compass": "Compass",
        "com.apple.MobileAddressBook": "Contacts",
        "developer.apple.wwdc-Release": "Developer",
        "com.apple.facetime": "FaceTime",
        "com.apple.DocumentsApp": "Files",
        "com.apple.FinalCutApp.companion": "Final Cut Camera",
        "com.apple.FinalCutApp": "Final Cut Pro",
        "com.apple.findmy": "Find My",
        "com.apple.Fitness": "Fitness",
        "com.apple.freeform": "Freeform",
        "com.apple.games": "Games",
        "com.apple.mobilegarageband": "GarageBand",
        "com.apple.Health": "Health",
        "com.apple.Home": "Home",
        "com.apple.iCloudDriveApp": "iCloud Drive",
        "com.apple.iMovie": "iMovie",
        "com.apple.rsvp": "Invites",
        "com.apple.MobileStore": "iTunes Store",
        "com.apple.journal": "Journal",
        "com.apple.Keynote": "Keynote",
        "com.apple.mobilelogic": "Logic Pro",
        "com.apple.musicapps.remote": "Logic Remote",
        "com.apple.Magnifier": "Magnifier",
        "com.apple.mobilemail": "Mail",
        "com.apple.Maps": "Maps",
        "com.apple.measure": "Measure",
        "com.apple.MobileSMS": "Messages",
        "com.apple.Music": "Music",
        "com.apple.news": "News",
        "com.apple.mobilenotes": "Notes",
        "com.apple.Numbers": "Numbers",
        "com.apple.Pages": "Pages",
        "com.apple.Passwords": "Passwords",
        "com.apple.mobilephone": "Phone",
        "com.apple.Photo-Booth": "Photo Booth",
        "com.pixelmatorteam.pixelmator.touch.x.photo": "Photomator",
        "com.apple.mobileslideshow": "Photos",
        "com.pixelmatorteam.pixelmator.touch": "Pixelmator Classic iOS",
        "com.apple.GenerativePlaygroundApp": "Playground",
        "com.apple.podcasts": "Podcasts",
        "com.apple.Preview": "Preview",
        "com.apple.RealityComposer": "Reality Composer",
        "com.apple.reminders": "Reminders",
        "com.apple.Research": "Research",
        "com.apple.mobilesafari": "Safari",
        "com.apple.schoolwork.ClassKitApp": "Schoolwork",
        "com.apple.Preferences": "Settings",
        "com.shazam.Shazam": "Shazam",
        "com.apple.shortcuts": "Shortcuts",
        "com.apple.sports": "Sports",
        "com.apple.stocks": "Stocks",
        "com.apple.Playgrounds": "Swift Playground",
        "com.apple.TestFlight": "TestFlight",
        "com.apple.tips": "Tips",
        "com.apple.Translate": "Translate",
        "com.apple.tv": "TV",
        "com.apple.VoiceMemos": "Voice Memos",
        "com.apple.Passbook": "Wallet",
        "com.apple.Bridge": "Watch",
        "com.apple.weather": "Weather",
    ]

    public static func displayName(for identifier: String, in apps: [InstalledApp]) -> String {
        apps.first(where: { $0.id == identifier })?.name ?? known[identifier] ?? identifier
    }

    static func knownName(for identifier: String) -> String? { known[identifier] }
}
