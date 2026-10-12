import DocksmithCore
import Foundation

enum LayoutArea: Hashable {
    case dock
    case page(Int)
    case folder(UUID, Int)
}

@MainActor
extension WorkspaceModel {
    func nodes(in area: LayoutArea) -> [LayoutNode] {
        guard let draft else { return [] }
        switch area {
        case .dock: return draft.dock
        case .page(let index): return draft.pages.indices.contains(index) ? draft.pages[index] : []
        case .folder(let id, let page):
            for node in draft.dock + draft.pages.flatMap({ $0 }) {
                if case .folder(let folder) = node, folder.id == id,
                   folder.pages.indices.contains(page) { return folder.pages[page] }
            }
            return []
        }
    }

    var folderDestinations: [(id: UUID, name: String, pageCount: Int)] {
        guard let draft else { return [] }
        return (draft.dock + draft.pages.flatMap { $0 }).compactMap { node in
            guard case .folder(let folder) = node else { return nil }
            return (folder.id, folder.name, folder.pages.count)
        }
    }

    func move(_ index: Int, from source: LayoutArea, to destination: LayoutArea) {
        guard var layout = draft else { return }
        var sourceNodes = nodes(in: source)
        guard sourceNodes.indices.contains(index) else { return }
        let node = sourceNodes.remove(at: index)
        if case .folder = destination {
            guard case .icon = node else { return }
        }
        guard write(sourceNodes, to: source, in: &layout) else { return }
        var destinationNodes = read(destination, in: layout) ?? []
        switch destination {
        case .dock where destinationNodes.count >= 4: return
        case .page where destinationNodes.count >= 24: return
        case .folder where destinationNodes.count >= 9: return
        default: break
        }
        destinationNodes.append(node)
        guard write(destinationNodes, to: destination, in: &layout) else { return }
        normalize(&layout)
        draft = layout
    }

    func moveToNewPage(_ index: Int, from source: LayoutArea) {
        guard var layout = draft else { return }
        var sourceNodes = nodes(in: source)
        guard sourceNodes.indices.contains(index) else { return }
        let node = sourceNodes.remove(at: index)
        guard write(sourceNodes, to: source, in: &layout) else { return }
        layout.pages.append([node])
        normalize(&layout)
        draft = layout
    }

    func moveToNewFolderPage(_ index: Int, from source: LayoutArea, folderID: UUID) {
        guard var layout = draft else { return }
        var sourceNodes = nodes(in: source)
        guard sourceNodes.indices.contains(index), case .icon = sourceNodes[index] else { return }
        let node = sourceNodes.remove(at: index)
        guard write(sourceNodes, to: source, in: &layout) else { return }
        func appendPage(_ items: inout [LayoutNode]) -> Bool {
            for item in items.indices {
                if case .folder(var folder) = items[item], folder.id == folderID {
                    folder.pages.append([node])
                    folder.wasFlat = false
                    items[item] = .folder(folder)
                    return true
                }
            }
            return false
        }
        var appended = appendPage(&layout.dock)
        if !appended {
            for page in layout.pages.indices {
                if appendPage(&layout.pages[page]) { appended = true; break }
            }
        }
        guard appended else { return }
        normalize(&layout)
        draft = layout
    }

    func reorder(_ index: Int, in area: LayoutArea, by offset: Int) {
        guard var layout = draft else { return }
        var current = nodes(in: area)
        let next = index + offset
        guard current.indices.contains(index), current.indices.contains(next) else { return }
        current.swapAt(index, next)
        if write(current, to: area, in: &layout) { draft = layout }
    }

    func createFolder(at first: Int, with second: Int, in area: LayoutArea) {
        if case .folder = area { return }
        guard var layout = draft, first != second else { return }
        var current = nodes(in: area)
        guard current.indices.contains(first), current.indices.contains(second),
              case .icon = current[first], case .icon = current[second] else { return }
        let firstNode = current[first]
        let secondNode = current[second]
        for index in [first, second].sorted(by: >) { current.remove(at: index) }
        current.insert(.folder(LayoutFolder(id: UUID(), name: "New Folder",
                                            pages: [[firstNode, secondNode]], wasFlat: false)),
                       at: min(first, second))
        if write(current, to: area, in: &layout) { draft = layout }
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var layout = draft else { return }
        func update(_ nodes: inout [LayoutNode]) {
            for index in nodes.indices {
                if case .folder(var folder) = nodes[index], folder.id == id {
                    folder.name = trimmed
                    nodes[index] = .folder(folder)
                }
            }
        }
        update(&layout.dock)
        for page in layout.pages.indices { update(&layout.pages[page]) }
        draft = layout
    }

    private func read(_ area: LayoutArea, in layout: HomeLayout) -> [LayoutNode]? {
        switch area {
        case .dock: return layout.dock
        case .page(let index): return layout.pages.indices.contains(index) ? layout.pages[index] : nil
        case .folder(let id, let page):
            for node in layout.dock + layout.pages.flatMap({ $0 }) {
                if case .folder(let folder) = node, folder.id == id,
                   folder.pages.indices.contains(page) { return folder.pages[page] }
            }
            return nil
        }
    }

    private func normalize(_ layout: inout HomeLayout) {
        func withoutEmptyFolders(_ nodes: [LayoutNode]) -> [LayoutNode] {
            nodes.filter { node in
                if case .folder(let folder) = node { return folder.pages.contains { !$0.isEmpty } }
                return true
            }
        }
        layout.dock = withoutEmptyFolders(layout.dock)
        layout.pages = layout.pages.map(withoutEmptyFolders).filter { !$0.isEmpty }
        if layout.pages.isEmpty { layout.pages = [[]] }
    }

    @discardableResult
    private func write(_ nodes: [LayoutNode], to area: LayoutArea, in layout: inout HomeLayout) -> Bool {
        switch area {
        case .dock:
            layout.dock = nodes
            return true
        case .page(let index):
            guard layout.pages.indices.contains(index) else { return false }
            layout.pages[index] = nodes
            return true
        case .folder(let id, let page):
            func update(_ items: inout [LayoutNode]) -> Bool {
                for index in items.indices {
                    if case .folder(var folder) = items[index], folder.id == id,
                       folder.pages.indices.contains(page) {
                        folder.pages[page] = nodes
                        items[index] = .folder(folder)
                        return true
                    }
                }
                return false
            }
            if update(&layout.dock) { return true }
            for index in layout.pages.indices {
                if update(&layout.pages[index]) { return true }
            }
            return false
        }
    }
}
