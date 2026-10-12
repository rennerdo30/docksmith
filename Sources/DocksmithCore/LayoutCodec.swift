import Foundation

public enum LayoutCodecError: LocalizedError {
    case malformed
    case containsUnknownNodes

    public var errorDescription: String? {
        switch self {
        case .malformed: "The Home Screen layout is malformed."
        case .containsUnknownNodes: "This layout contains an icon form Docksmith cannot safely edit."
        }
    }
}

public enum LayoutCodec {
    public static func decode(_ data: Data) throws -> HomeLayout {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [Any], raw.count >= 2,
              let dock = raw[0] as? [Any] else { throw LayoutCodecError.malformed }
        let pages = try raw.dropFirst().map { item -> [LayoutNode] in
            guard let array = item as? [Any] else { throw LayoutCodecError.malformed }
            return array.map(decodeNode)
        }
        return HomeLayout(dock: dock.map(decodeNode), pages: pages)
    }

    public static func encode(_ layout: HomeLayout) throws -> Data {
        guard !layout.pages.isEmpty else { throw LayoutCodecError.malformed }
        let raw: [Any] = try [encodePage(layout.dock)] + layout.pages.map(encodePage)
        return try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
    }

    public static func containsUnknown(_ layout: HomeLayout) -> Bool {
        (layout.dock + layout.pages.flatMap { $0 }).contains { node in
            switch node {
            case .unknown: true
            case .icon: false
            case .folder(let folder): folder.pages.flatMap { $0 }.contains {
                if case .unknown = $0 { return true }
                return false
            }
            }
        }
    }

    public static func identifiers(_ layout: HomeLayout) -> [String] {
        (layout.dock + layout.pages.flatMap { $0 }).flatMap { node -> [String] in
            switch node {
            case .icon(let id): [id]
            case .folder(let folder): folder.pages.flatMap { $0 }.compactMap {
                if case .icon(let id) = $0 { return id }
                return nil
            }
            case .unknown: []
            }
        }
    }

    public static func iconCounts(_ layout: HomeLayout) -> [String: Int] {
        var counts: [String: Int] = [:]
        for identifier in identifiers(layout) { counts[identifier, default: 0] += 1 }
        return counts
    }

    public static func hasOnlySupportedFolderContents(_ layout: HomeLayout) -> Bool {
        (layout.dock + layout.pages.flatMap { $0 }).allSatisfy { node in
            guard case .folder(let folder) = node else { return true }
            return !folder.pages.isEmpty && folder.pages.allSatisfy { page in
                page.allSatisfy { if case .icon = $0 { return true }; return false }
            }
        }
    }

    public static func semanticallyEqual(_ a: Data, _ b: Data) -> Bool {
        guard let first = try? decode(a), let second = try? decode(b),
              let canonicalA = try? canonicalLayout(first),
              let canonicalB = try? canonicalLayout(second) else {
            return false
        }
        return canonicalA == canonicalB
    }

    private static func canonicalLayout(_ layout: HomeLayout) throws -> Data {
        func page(_ nodes: [LayoutNode]) throws -> [Any] {
            try nodes.map { node -> Any in
                switch node {
                case .icon(let identifier): return identifier
                case .folder(let folder):
                    // cfgutil can return a single folder page in either supported form.
                    // Compare its contents, independent of encoding form and local UUID.
                    return [folder.name] + (try folder.pages.map(page))
                case .unknown(let raw):
                    return try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
                }
            }
        }
        let raw: [Any] = try [page(layout.dock)] + layout.pages.map(page)
        return try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
    }

    private static func decodeNode(_ raw: Any) -> LayoutNode {
        if let identifier = raw as? String, !identifier.isEmpty { return .icon(identifier) }
        if let array = raw as? [Any], let name = array.first as? String, !name.isEmpty {
            let rest = Array(array.dropFirst())
            if rest.allSatisfy({ $0 is String }) {
                return .folder(LayoutFolder(name: name, pages: [rest.map(decodeNode)], wasFlat: true))
            }
            if rest.allSatisfy({ $0 is [Any] }) {
                let pages = rest.compactMap { ($0 as? [Any])?.map(decodeNode) }
                return .folder(LayoutFolder(name: name, pages: pages, wasFlat: false))
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])) ?? Data()
        return .unknown(data)
    }

    private static func encodePage(_ nodes: [LayoutNode]) throws -> [Any] {
        try nodes.map { node -> Any in
            switch node {
            case .icon(let identifier):
                guard !identifier.isEmpty else { throw LayoutCodecError.malformed }
                return identifier
            case .folder(let folder):
                guard !folder.name.isEmpty, !folder.pages.isEmpty else { throw LayoutCodecError.malformed }
                if folder.wasFlat && folder.pages.count == 1 {
                    return [folder.name] + (try encodePage(folder.pages[0]))
                }
                return [folder.name] + (try folder.pages.map(encodePage))
            case .unknown:
                throw LayoutCodecError.containsUnknownNodes
            }
        }
    }
}
