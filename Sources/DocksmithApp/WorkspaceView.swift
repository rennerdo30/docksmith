import AppKit
import DocksmithCore
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var model: WorkspaceModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("DEVICE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Device", selection: Binding(
                    get: { model.selectedDeviceID },
                    set: { model.requestSelectedDevice($0) }
                )) {
                    Text("Choose a device").tag(String?.none)
                    ForEach(model.devices) { device in
                        Text(device.displayName).tag(Optional(device.id))
                    }
                }
                .labelsHidden()
                .disabled(model.selectionLocked || model.devices.isEmpty)

                if let device = model.selectedDevice {
                    Label(device.transport, systemImage: device.transport == "USB" ? "cable.connector" : "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                List(WorkspaceSection.allCases, selection: $model.section) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .tag(section)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                Button("Refresh Devices", systemImage: "arrow.clockwise") {
                    model.requestRefresh()
                }
                .disabled(model.selectionLocked)
                .buttonStyle(.borderless)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.orange.opacity(0.1))
                }
                if let busyMessage = model.busyMessage {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busyMessage)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                content
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(model.selectedDevice?.displayName ?? "Docksmith")
                        .font(.headline)
                }
                ToolbarItem {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        model.requestRefresh()
                    }
                    .disabled(model.selectionLocked)
                }
            }
        }
        .tint(.orange)
        .confirmationDialog("Discard Home Screen changes?", isPresented: $model.showDiscardConfirmation) {
            Button("Discard Changes", role: .destructive) { model.confirmDiscard() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("Your layout edits have not been applied to the device.")
        }
        .sheet(isPresented: $model.showRemoveConfirmation) { RemoveConfirmationView() }
        .sheet(isPresented: $model.showApplyConfirmation) { ApplyConfirmationView() }
        .sheet(isPresented: Binding(
            get: { !model.removalResults.isEmpty },
            set: { if !$0 { model.removalResults = [] } }
        )) { RemovalResultsView() }
        .alert("Layout result", isPresented: Binding(
            get: { model.applyResult != nil },
            set: { if !$0 { model.applyResult = nil } }
        )) {
            Button("OK") { model.applyResult = nil }
        } message: {
            Text(model.applyResult?.message ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if model.setupRequired {
            ContentUnavailableView {
                Label("Apple Configurator Required", systemImage: "shippingbox")
            } description: {
                Text("Install Apple Configurator and choose its cfgutil executable to inspect connected devices.")
            } actions: {
                Button("Choose cfgutil…") { model.chooseCfgutil() }
            }
        } else if model.devices.isEmpty && model.section != .connection {
            ContentUnavailableView {
                Label("No Devices Found", systemImage: "iphone.slash")
            } description: {
                Text("Connect with a cable, unlock the device, accept Trust, then refresh.")
            } actions: {
                Button("Refresh Devices") { model.requestRefresh() }
            }
        } else {
            switch model.section {
            case .apps: AppsView()
            case .home: HomeScreenView()
            case .connection: ConnectionView()
            }
        }
    }
}

struct AppArtwork: View {
    let app: InstalledApp?
    let name: String
    var iconData: Data? = nil

    var body: some View {
        Group {
            if let data = iconData ?? app?.iconData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.orange.opacity(0.16))
                    .overlay(Text(String(name.prefix(1)).uppercased()).font(.title3.weight(.medium)))
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

struct AppsView: View {
    @EnvironmentObject private var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Apps").font(.largeTitle.bold())
                Spacer()
                if let inventory = model.inventory {
                    Text("\(inventory.apps.count) installed")
                        .foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 24)

            if let warning = model.inventory?.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }

            TextField("Search apps", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

            if model.inventory == nil {
                ContentUnavailableView("Choose a device", systemImage: "iphone", description: Text("Select a connected device to load its apps."))
            } else if model.visibleApps.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else {
                List(model.visibleApps) { app in
                    HStack(spacing: 12) {
                        Toggle(model.displayName(for: app.id), isOn: Binding(
                            get: { model.selectedApps.contains(app.id) },
                            set: { selected in
                                if selected { model.selectedApps.insert(app.id) }
                                else { model.selectedApps.remove(app.id) }
                            }
                        ))
                        .labelsHidden()
                        .disabled(model.isBusy || !app.isFromInventory)
                        AppArtwork(app: app, name: model.displayName(for: app.id), iconData: model.iconCache[app.id])
                            .task(id: "\(app.id):\(model.isBusy)") { await model.loadIconIfNeeded(for: app.id) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName(for: app.id)).font(.body.weight(.medium))
                            if app.name == app.id {
                                Text(app.id).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if let version = app.version {
                                Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !model.isBusy, app.isFromInventory else { return }
                        if model.selectedApps.contains(app.id) { model.selectedApps.remove(app.id) }
                        else { model.selectedApps.insert(app.id) }
                    }
                }
                .listStyle(.inset)
            }

            if !model.selectedApps.isEmpty {
                Divider()
                HStack {
                    Text("\(model.selectedApps.count) apps selected")
                    Spacer()
                    Button("Remove Selected…", role: .destructive) {
                        model.showRemoveConfirmation = true
                    }
                    .disabled(model.isBusy || model.hasDraftChanges)
                }
                .padding(16)
                if model.hasDraftChanges {
                    Text("Apply or revert Home Screen changes before removing apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding([.horizontal, .bottom], 16)
                }
            }
        }
    }
}

private struct RemoveConfirmationView: View {
    @EnvironmentObject private var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Remove \(model.selectedApps.count) apps?", systemImage: "trash")
                .font(.title2.bold())
                .foregroundStyle(.red)
            Text("From \(model.selectedDevice?.displayName ?? "the selected device").")
            Text("Removing apps can delete their local data. Review every app before continuing.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.selectedApps).sorted(by: { model.displayName(for: $0) < model.displayName(for: $1) }), id: \.self) { id in
                        VStack(alignment: .leading) {
                            Text("• \(model.displayName(for: id))")
                            if model.displayName(for: id) == "Unrecognized app" {
                                Text(id).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") { model.showRemoveConfirmation = false }
                    .keyboardShortcut(.cancelAction)
                Button("Remove \(model.selectedApps.count) Apps", role: .destructive) {
                    Task { await model.removeSelectedApps() }
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct RemovalResultsView: View {
    @EnvironmentObject private var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Removal results").font(.title2.bold())
            List(model.removalResults, id: \.id) { result in
                Label(model.displayName(for: result.id), systemImage: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                Text(result.message).font(.caption).foregroundStyle(.secondary)
            }
            .frame(height: 240)
            HStack {
                Spacer()
                Button("Done") { model.removalResults = [] }
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct ConnectionView: View {
    @EnvironmentObject private var model: WorkspaceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Connection").font(.largeTitle.bold())
                if let device = model.selectedDevice {
                    Label("\(device.displayName) · \(device.transport)", systemImage: "iphone")
                        .font(.headline)
                }
                GroupBox("Connect over USB") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Connect your device to this Mac with a cable.")
                        Text("2. Unlock it and accept the Trust prompt.")
                        Text("3. Select it in the sidebar and refresh.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                GroupBox("Finder Wi-Fi setup") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("First connect with a cable. In Finder, select the device, enable “Show this device when on Wi-Fi”, and click Apply.")
                        Text("Docksmith has not verified that cfgutil reads or changes work over Wi-Fi. An Unknown connection label does not imply Wi-Fi support.")
                            .foregroundStyle(.secondary)
                        Link("Apple's Finder Wi-Fi instructions", destination: URL(string: "https://support.apple.com/en-is/guide/mac-help/mchlada1d602/mac")!)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                Button("Choose cfgutil Executable…") { model.chooseCfgutil() }
                    .disabled(model.hasDraftChanges || model.isBusy)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
        }
    }
}
