import DocksmithCore
import SwiftUI

private struct FolderSelection: Identifiable { let id: UUID }

struct HomeScreenView: View {
    @EnvironmentObject private var model: WorkspaceModel
    @State private var openFolder: FolderSelection?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Home Screen").font(.largeTitle.bold())
                Spacer()
                if model.hasDraftChanges {
                    Button("Revert") { model.revertDraft() }
                        .disabled(model.isBusy)
                    Button("Review Changes…") { model.showApplyConfirmation = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canEditLayout)
                }
            }
            .padding(24)

            if model.hasUnknownLayoutEntries {
                Label("This layout has entries Docksmith cannot edit safely. Apply is disabled; unknown entries remain in the draft.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
            }
            if model.baseline?.isPartial == true {
                Label("This layout read may be incomplete. Reload or reconnect before editing and applying changes.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
            }
            if let warning = model.baseline?.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
            }

            if let draft = model.draft {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Move icons and folders with the arrow buttons or Move to menu. Widgets and their positions are not supported by this editor.")
                            .foregroundStyle(.secondary)
                        section("Dock", nodes: draft.dock, area: .dock)
                        ForEach(draft.pages.indices, id: \.self) { page in
                            section("Page \(page + 1)", nodes: draft.pages[page], area: .page(page))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            } else {
                ContentUnavailableView("Layout unavailable", systemImage: "square.grid.3x3", description: Text("The selected device did not provide an editable Home Screen layout."))
            }
        }
        .sheet(item: $openFolder) { selection in
            FolderEditorView(folderID: selection.id)
                .environmentObject(model)
        }
    }

    private func section(_ title: String, nodes: [LayoutNode], area: LayoutArea) -> some View {
        GroupBox(title) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                    LayoutTile(node: node, area: area, index: index) { folderID in
                        openFolder = FolderSelection(id: folderID)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .overlay {
                if nodes.isEmpty {
                    Text("Empty").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LayoutTile: View {
    @EnvironmentObject private var model: WorkspaceModel
    let node: LayoutNode
    let area: LayoutArea
    let index: Int
    let openFolder: (UUID) -> Void

    private var name: String {
        switch node {
        case .icon(let id): model.displayName(for: id)
        case .folder(let folder): folder.name
        case .unknown: "Unknown item"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            if case .icon(let id) = node {
                let app = model.inventory?.apps.first { $0.id == id }
                AppArtwork(app: app, name: name, iconData: model.iconCache[id])
                    .task(id: "\(id):\(model.isBusy)") { await model.loadIconIfNeeded(for: id) }
            } else if case .folder = node {
                Image(systemName: "folder.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                    .frame(height: 40)
            } else {
                Image(systemName: "questionmark.square.dashed")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(height: 40)
            }

            if case .folder(let folder) = node {
                Button(folder.name) { openFolder(folder.id) }
                    .buttonStyle(.plain)
                    .lineLimit(1)
            } else {
                Text(name).lineLimit(1)
            }

            HStack(spacing: 2) {
                Button { model.reorder(index, in: area, by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(index == 0 || !model.canEditLayout || isUnknown)
                .help("Move left")
                Button { model.reorder(index, in: area, by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(index + 1 >= model.nodes(in: area).count || !model.canEditLayout || isUnknown)
                .help("Move right")
                Menu {
                    destinations
                } label: {
                    Image(systemName: "arrow.turn.down.right")
                }
                .disabled(!model.canEditLayout || isUnknown)
                .help("Move to another page, Dock, or folder")
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }

    private var isUnknown: Bool {
        if case .unknown = node { true } else { false }
    }

    @ViewBuilder private var destinations: some View {
        if area != .dock, model.nodes(in: .dock).count < 4 {
            Button("Dock") { model.move(index, from: area, to: .dock) }
        }
        if let layout = model.draft {
            ForEach(layout.pages.indices, id: \.self) { page in
                if area != .page(page), model.nodes(in: .page(page)).count < 24 {
                    Button("Page \(page + 1)") { model.move(index, from: area, to: .page(page)) }
                }
            }
        }
        Button("New Page") { model.moveToNewPage(index, from: area) }

        if case .icon = node {
            if !model.folderDestinations.isEmpty { Divider() }
            ForEach(model.folderDestinations, id: \.id) { folder in
                ForEach(0..<folder.pageCount, id: \.self) { page in
                    if area != .folder(folder.id, page), model.nodes(in: .folder(folder.id, page)).count < 9 {
                        Button("Folder: \(folder.name), Page \(page + 1)") {
                            model.move(index, from: area, to: .folder(folder.id, page))
                        }
                    }
                }
                Button("New Page in Folder: \(folder.name)") {
                    model.moveToNewFolderPage(index, from: area, folderID: folder.id)
                }
            }
            if case .folder = area { /* Folder creation is available on pages and Dock. */ }
            else {
                let peers = model.nodes(in: area)
                let iconPeers = peers.indices.filter { peer in
                    guard peer != index else { return false }
                    if case .icon = peers[peer] { return true }
                    return false
                }
                if !iconPeers.isEmpty {
                    Divider()
                    Menu("Create Folder With") {
                        ForEach(iconPeers, id: \.self) { peer in
                            if case .icon(let id) = peers[peer] {
                                Button(model.displayName(for: id)) {
                                    model.createFolder(at: index, with: peer, in: area)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct FolderEditorView: View {
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let folderID: UUID
    @State private var name = ""

    private var folder: LayoutFolder? {
        for node in (model.draft?.dock ?? []) + (model.draft?.pages.flatMap { $0 } ?? []) {
            if case .folder(let folder) = node, folder.id == folderID { return folder }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Folder").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            HStack {
                TextField("Folder name", text: $name)
                Button("Rename") { model.renameFolder(folderID, to: name) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canEditLayout)
            }
            if let folder {
                ScrollView {
                    ForEach(folder.pages.indices, id: \.self) { page in
                        GroupBox("Folder page \(page + 1)") {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                                ForEach(Array(folder.pages[page].enumerated()), id: \.offset) { index, node in
                                    LayoutTile(node: node, area: .folder(folderID, page), index: index) { _ in }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 480)
        .onAppear { name = folder?.name ?? "" }
    }
}

struct ApplyConfirmationView: View {
    @EnvironmentObject private var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Home Screen changes").font(.title2.bold())
            Text("Device: \(model.selectedDevice?.displayName ?? "No device selected")")
            Text("This will change icon and folder positions on the device. Widgets are not managed. Docksmith saves a local snapshot before applying.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.layoutChanges, id: \.self) { change in
                        Text("• \(change)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            HStack {
                Spacer()
                Button("Cancel") { model.showApplyConfirmation = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply Layout") { Task { await model.applyDraft() } }
                    .disabled(!model.canEditLayout || !model.hasDraftChanges)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

@MainActor
private extension WorkspaceModel {
    var layoutChanges: [String] {
        guard let before = baseline?.layout, let after = draft else { return [] }
        func positions(_ layout: HomeLayout) -> [String: String] {
            var result: [String: String] = [:]
            func visit(_ nodes: [LayoutNode], location: String) {
                for (index, node) in nodes.enumerated() {
                    let place = "\(location), position \(index + 1)"
                    switch node {
                    case .icon(let id): result[id] = place
                    case .folder(let folder):
                        result["folder:\(folder.id)"] = "\(folder.name), \(place)"
                        for (page, children) in folder.pages.enumerated() {
                            visit(children, location: "folder \(folder.name) page \(page + 1)")
                        }
                    case .unknown: break
                    }
                }
            }
            visit(layout.dock, location: "Dock")
            for (page, nodes) in layout.pages.enumerated() {
                visit(nodes, location: "page \(page + 1)")
            }
            return result
        }
        let original = positions(before)
        let edited = positions(after)
        return Set(original.keys).union(edited.keys).sorted().compactMap { key in
            guard original[key] != edited[key] else { return nil }
            let name = key.hasPrefix("folder:") ? "Folder" : displayName(for: key)
            return "\(name): \(original[key] ?? "new") → \(edited[key] ?? "removed")"
        }
    }
}
