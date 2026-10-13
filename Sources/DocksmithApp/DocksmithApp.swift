import AppKit
import DocksmithCore
import SwiftUI

@main
struct DocksmithApp: App {
    @StateObject private var model = WorkspaceModel()

    var body: some Scene {
        WindowGroup("Docksmith") {
            WorkspaceView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 700)
                .task { await model.refreshDevices() }
        }
        .windowStyle(.titleBar)
    }
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case home = "Home Screen"
    case connection = "Connection"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .apps: "square.grid.2x2"
        case .home: "apps.iphone"
        case .connection: "cable.connector"
        }
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    @Published var selectedDeviceID: String?
    @Published var section: WorkspaceSection = .apps
    @Published var inventory: InventorySnapshot?
    @Published var baseline: LayoutSnapshot?
    @Published var draft: HomeLayout?
    @Published var selectedApps: Set<String> = []
    @Published var search = ""
    @Published var removableOnly = false
    @Published var lastSuccessfulRefresh: Date?
    @Published var reviewDeviceName = ""
    @Published var busyMessage: String?
    @Published var errorMessage: String?
    @Published var setupRequired = false
    @Published var removalResults: [RemovalResult] = []
    @Published var applyResult: ApplyResult?
    @Published var iconCache: [String: Data] = [:]
    @Published var showRemoveConfirmation = false
    @Published var removalPlan: RemovalPlan?
    @Published var showApplyConfirmation = false
    @Published var showDiscardConfirmation = false

    private var service: DeviceService?
    private var generation = 0
    private var pendingDeviceID: String?
    private var pendingRefresh = false
    private var resultNames: [String: String] = [:]

    var selectedDevice: DeviceInfo? { devices.first { $0.id == selectedDeviceID } }
    var isBusy: Bool { busyMessage != nil }
    var selectedDeviceReady: Bool { selectedDevice?.capabilities.inventoryBackend == .cfgutil }
    var canReadApps: Bool { selectedDevice?.capabilities.canReadApps == true }
    var canRemoveApps: Bool { selectedDevice?.capabilities.canRemoveApps == true }
    func canSelectForRemoval(_ app: InstalledApp) -> Bool {
        canRemoveApps && AppSelection.isEligible(app, backend: inventory?.source ?? .none)
    }
    func selectShownRemovable() {
        guard !selectionLocked, canRemoveApps else { return }
        selectedApps = AppSelection.selectingShown(selectedApps, apps: visibleApps, backend: inventory?.source ?? .none)
    }
    func clearSelection() { guard !selectionLocked else { return }; selectedApps = [] }
    var hiddenSelectedCount: Int { selectedApps.subtracting(visibleApps.map(\.id)).count }

    var selectionLocked: Bool { isBusy || showRemoveConfirmation || showApplyConfirmation }
    var hasDraftChanges: Bool { baseline?.layout != nil && draft != baseline?.layout }
    var canEditLayout: Bool { selectedDeviceReady && !isBusy && baseline?.isPartial == false && !hasUnknownLayoutEntries }
    var hasUnknownLayoutEntries: Bool {
        guard let draft else { return false }
        func containsUnknown(_ nodes: [LayoutNode]) -> Bool {
            nodes.contains { node in
                switch node {
                case .unknown: true
                case .icon: false
                case .folder(let folder): folder.pages.contains(where: containsUnknown)
                }
            }
        }
        return containsUnknown(draft.dock) || draft.pages.contains(where: containsUnknown)
    }

    var visibleApps: [InstalledApp] {
        AppSelection.visible(inventory?.apps ?? [], search: search, removableOnly: removableOnly,
                             backend: inventory?.source ?? .none)
    }

    func displayName(for identifier: String) -> String {
        let name = resultNames[identifier] ?? AppNames.displayName(for: identifier, in: inventory?.apps ?? [])
        return name == identifier ? "Unrecognized app" : name
    }

    func requestSelectedDevice(_ id: String?) {
        guard !selectionLocked, selectedDeviceID != id else { return }
        if hasDraftChanges {
            pendingDeviceID = id
            pendingRefresh = false
            showDiscardConfirmation = true
        } else { setSelectedDevice(id) }
    }

    func requestRefresh() {
        guard !selectionLocked else { return }
        if hasDraftChanges {
            pendingRefresh = true
            pendingDeviceID = nil
            showDiscardConfirmation = true
        } else { Task { await refreshDevices() } }
    }

    func confirmDiscard() {
        showDiscardConfirmation = false
        if pendingRefresh {
            pendingRefresh = false
            Task { await refreshDevices() }
        } else { setSelectedDevice(pendingDeviceID) }
        pendingDeviceID = nil
    }

    private func setSelectedDevice(_ id: String?) {
        guard !isBusy, selectedDeviceID != id else { return }
        selectedDeviceID = id
        generation += 1
        inventory = nil
        baseline = nil
        draft = nil
        selectedApps = []
        removalPlan = nil
        search = ""
        removalResults = []
        applyResult = nil
        iconCache = [:]
        resultNames = [:]
        errorMessage = nil
        Task { await loadSelectedDevice() }
    }

    func chooseCfgutil() {
        guard !hasDraftChanges, !selectionLocked else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose Apple's cfgutil executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "cfgutilPath")
        service = nil
        generation += 1
        inventory = nil
        baseline = nil
        draft = nil
        selectedApps = []
        removalPlan = nil
        iconCache = [:]
        resultNames = [:]
        removalResults = []
        applyResult = nil
        setupRequired = false
        Task { await refreshDevices() }
    }

    private func configuredService() throws -> DeviceService {
        if let service { return service }
        let path = UserDefaults.standard.string(forKey: "cfgutilPath")
        let created = try DeviceService(cfgutilPath: path)
        service = created
        return created
    }

    func refreshDevices() async {
        guard !isBusy else { return }
        busyMessage = "Finding devices…"
        errorMessage = nil
        do {
            let backend = try configuredService()
            let found = try await backend.discover()
            devices = found
            lastSuccessfulRefresh = Date()
            removalPlan = nil
            setupRequired = !(await backend.isBackendConfigured)
            if let selectedDeviceID, !found.contains(where: { $0.id == selectedDeviceID }) {
                self.selectedDeviceID = nil
                generation += 1
                inventory = nil
                baseline = nil
                draft = nil
                selectedApps = []
                iconCache = [:]
                removalResults = []
                applyResult = nil
                resultNames = [:]
            }
            busyMessage = nil
            if selectedDeviceID != nil { await loadSelectedDevice() }
        } catch {
            if let service { setupRequired = !(await service.isBackendConfigured) }
            else { setupRequired = true }
            errorMessage = error.localizedDescription
            devices = []
            selectedDeviceID = nil
            generation += 1
            inventory = nil
            baseline = nil
            draft = nil
            selectedApps = []
            removalPlan = nil
            iconCache = [:]
            removalResults = []
            applyResult = nil
            resultNames = [:]
            busyMessage = nil
        }
    }

    func connectPairedDevice() async {
        guard !selectionLocked, !hasDraftChanges, let selectedDeviceID else { return }
        busyMessage = "Connecting to paired device…"
        errorMessage = nil
        do {
            _ = try await configuredService().connectPairedDevice(deviceID: selectedDeviceID)
            busyMessage = nil
            await refreshDevices()
        } catch {
            busyMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    func loadSelectedDevice() async {
        guard let selectedDeviceID else { return }
        let token = generation
        inventory = nil
        baseline = nil
        draft = nil
        selectedApps = []
        removalPlan = nil
        iconCache = [:]
        guard canReadApps else { return }
        busyMessage = "Reading device…"
        errorMessage = nil
        defer { if token == generation { busyMessage = nil } }
        do {
            let service = try configuredService()
            let snapshot = try await service.loadSnapshot(deviceID: selectedDeviceID)
            let loadedApps = snapshot.inventory
            let loadedLayout = snapshot.layout
            guard token == generation, self.selectedDeviceID == selectedDeviceID else { return }
            inventory = loadedApps
            baseline = loadedLayout
            draft = loadedLayout.layout
            selectedApps = []
            iconCache = Dictionary(uniqueKeysWithValues: loadedApps.apps.compactMap { app in
                app.iconData.map { (app.id, $0) }
            })
        } catch {
            guard token == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadIconIfNeeded(for appID: String) async {
        guard selectedDeviceReady, !isBusy, let selectedDeviceID, iconCache[appID] == nil,
              let service else { return }
        let token = generation
        if let data = try? await service.loadIcon(deviceID: selectedDeviceID, appID: appID),
           token == generation, self.selectedDeviceID == selectedDeviceID {
            iconCache[appID] = data
        }
    }

    func removeSelectedApps() async {
        guard canRemoveApps, let selectedDeviceID, let plan = removalPlan,
              plan.deviceID == selectedDeviceID, !hasDraftChanges, !isBusy else { return }
        busyMessage = "Removing selected apps…"
        showRemoveConfirmation = false
        errorMessage = nil
        defer { busyMessage = nil; removalPlan = nil }
        do {
            let service = try configuredService()
            removalResults = try await service.executeRemoval(plan)
            selectedApps = []
            inventory = nil
            inventory = try await service.loadInventory(deviceID: selectedDeviceID)
            if selectedDevice?.capabilities.canReadLayout == true {
                let updatedLayout = try await service.loadLayout(deviceID: selectedDeviceID)
                baseline = updatedLayout
                draft = updatedLayout.layout
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyDraft() async {
        guard selectedDeviceReady, let selectedDeviceID, let baseline, let draft, hasDraftChanges,
              !baseline.isPartial,
              !hasUnknownLayoutEntries, !isBusy else { return }
        busyMessage = "Applying Home Screen layout…"
        showApplyConfirmation = false
        errorMessage = nil
        defer { busyMessage = nil }
        do {
            let service = try configuredService()
            applyResult = try await service.applyLayout(deviceID: selectedDeviceID, baseline: baseline, draft: draft)
            let updated = try await service.loadLayout(deviceID: selectedDeviceID)
            self.baseline = updated
            self.draft = updated.layout
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revertDraft() { draft = baseline?.layout }

    func reviewRemoval() async {
        guard canRemoveApps, let selectedDeviceID, !selectedApps.isEmpty, !isBusy, !hasDraftChanges else { return }
        busyMessage = "Preparing removal review…"
        errorMessage = nil
        defer { busyMessage = nil }
        do {
            removalPlan = try await configuredService().prepareRemoval(deviceID: selectedDeviceID, ids: Array(selectedApps))
            reviewDeviceName = selectedDevice?.displayName ?? "Selected device"
            resultNames = Dictionary(uniqueKeysWithValues: (removalPlan?.ids ?? []).map { id in
                let name = AppNames.displayName(for: id, in: inventory?.apps ?? [])
                return (id, name == id ? "Unrecognized app" : name)
            })
            showRemoveConfirmation = true
        } catch { removalPlan = nil; errorMessage = error.localizedDescription }
    }

    func openConfigurator() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.configurator.ui") else {
            errorMessage = "Install Apple Configurator, then choose its cfgutil executable from Connection."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
