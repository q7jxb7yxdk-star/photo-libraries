#if WEB_GALLERY_HELPER
import AppKit
import Foundation
import Photos

/// A separate login-item app owns the listener, Photos permission, bookmarks,
/// and preview cache. It never reads the main app's private defaults or cache.
@main
@MainActor
enum GalleryHelperEntry {
    static func main() {
        let application = NSApplication.shared
        let delegate = GalleryHelperDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class GalleryHelperDelegate: NSObject, NSApplicationDelegate {
    private struct LibraryGrant: Codable {
        let path: String
        let bookmark: Data
    }

    private static let grantsKey = "WebGalleryHelper.readOnlyLibraryGrants.v1"
    private var pollingTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var isAuthorizing = false
    private var appliedConfiguration: Data?
    private var appliedAccessState: String?
    private var nextCatalogRetry: Date?
    private var stateGeneration = UUID()
    private var registry: LibraryRegistry?
    private var systemModel: SystemPhotoLibraryViewModel?
    private var store: LibraryPreviewStore?
    private var searchModel: UnifiedSearchViewModel?
    private var unavailableLibraries: [String] = []
    private var terminationMessage: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isAuthorizing { await self.refreshConfiguration() }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--authorize") {
            beginAuthorization()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        // Explicitly opening the helper from the main app provides a way to
        // authorize it again when the login item is already running.
        beginAuthorization()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollingTask?.cancel()
        authorizationTask?.cancel()
        WebGalleryServer.shared.stop()
        report(terminationMessage ?? "Background gallery stopped.")
    }

    private func beginAuthorization() {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        stopServing()
        report("Authorizing background gallery access…")
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            let authorizationMessage = await self.authorizeSelectedLibraries()
            self.appliedConfiguration = nil
            if let current = try? WebGallerySharedConfiguration.load(), !current.enabled {
                let message = authorizationMessage
                    + " Enable Start Sharing at Login in the main app to run the background gallery."
                let alert = NSAlert()
                alert.messageText = "Background Gallery Authorization"
                alert.informativeText = message
                alert.addButton(withTitle: "OK")
                alert.runModal()
                self.isAuthorizing = false
                self.terminationMessage = message
                self.stopServing()
                self.report(message)
                NSApplication.shared.terminate(nil)
                return
            }
            self.isAuthorizing = false
            await self.refreshConfiguration()
        }
    }

    private func authorizeSelectedLibraries() async -> String {
        do {
            let snapshot = try WebGallerySharedConfiguration.load()
            var incomplete: [String] = []
            NSApplication.shared.activate(ignoringOtherApps: true)
            if snapshot.descriptors.contains(where: {
                snapshot.sharedLibraryIDs.contains($0.id.rawValue.uuidString)
                    && $0.kind.isSystemPhotoLibrary
            }), PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                // Only explicit setup requests permission. Normal login never
                // asks for Photos authorization or shows an open panel.
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            if !PhotoLibraryAuthorization(
                PHPhotoLibrary.authorizationStatus(for: .readWrite)
            ).permitsReading {
                incomplete += snapshot.descriptors.filter {
                    $0.kind.isSystemPhotoLibrary
                        && snapshot.sharedLibraryIDs.contains($0.id.rawValue.uuidString)
                }.map { $0.metadata.displayName + " (Photos permission required)" }
            }
            var grants = loadGrants()
            for descriptor in snapshot.descriptors where
                !descriptor.kind.isSystemPhotoLibrary
                    && snapshot.sharedLibraryIDs.contains(descriptor.id.rawValue.uuidString) {
                guard !Task.isCancelled else { return "Background authorization cancelled." }
                if ownDescriptor(descriptor, grants: grants) != nil { continue }
                let expected = URL(fileURLWithPath: descriptor.metadata.lastKnownPath)
                    .standardizedFileURL
                let panel = NSOpenPanel()
                panel.title = "Authorize Background Gallery"
                panel.message = "Select \(descriptor.metadata.displayName) at \(expected.path) to grant the background gallery read-only access."
                panel.prompt = "Authorize"
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.treatsFilePackagesAsDirectories = false
                panel.allowsMultipleSelection = false
                panel.directoryURL = expected.deletingLastPathComponent()
                panel.nameFieldStringValue = expected.lastPathComponent
                let result = await withCheckedContinuation { continuation in
                    panel.begin { response in continuation.resume(returning: response) }
                }
                guard result == .OK, let selected = panel.url,
                      selected.standardizedFileURL.path == expected.path,
                      selected.pathExtension.lowercased() == "photoslibrary" else {
                    incomplete.append(descriptor.metadata.displayName + " (cancelled or wrong package selected)")
                    continue
                }
                // The sharing selection can change while a permission dialog
                // is visible. Do not retain a grant for a superseded selection.
                let current = try WebGallerySharedConfiguration.load()
                guard current.sharedLibraryIDs.contains(descriptor.id.rawValue.uuidString),
                      current.descriptors.contains(where: {
                          $0.id == descriptor.id
                              && $0.metadata.lastKnownPath == descriptor.metadata.lastKnownPath
                              && !$0.kind.isSystemPhotoLibrary
                      }) else { continue }
                let accessed = selected.startAccessingSecurityScopedResource()
                defer { if accessed { selected.stopAccessingSecurityScopedResource() } }
                let bookmark = try selected.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                grants[descriptor.id.rawValue.uuidString] = LibraryGrant(
                    path: expected.path, bookmark: bookmark
                )
                let data = try JSONEncoder().encode(grants)
                UserDefaults.standard.set(data, forKey: Self.grantsKey)
            }
            return incomplete.isEmpty ? "Background setup complete."
                : "Background setup incomplete: " + incomplete.joined(separator: ", ") + "."
        } catch {
            return "Background authorization failed: \(error.localizedDescription)"
        }
    }

    private func refreshConfiguration() async {
        var preparationGeneration: UUID?
        do {
            let snapshot = try WebGallerySharedConfiguration.load()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let configuration = try encoder.encode(snapshot)
            let grants = loadGrants()
            let accessState = snapshot.descriptors.filter {
                snapshot.sharedLibraryIDs.contains($0.id.rawValue.uuidString)
            }.map { descriptor in
                let available = descriptor.kind.isSystemPhotoLibrary
                    ? PhotoLibraryAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite)).permitsReading
                    : ownDescriptor(descriptor, grants: grants) != nil
                return "\(descriptor.id.rawValue.uuidString):\(available)"
            }.sorted().joined(separator: ",")
            let shouldRetryCatalog = nextCatalogRetry.map { $0 <= Date() } ?? false
            if configuration == appliedConfiguration,
               accessState == appliedAccessState, !shouldRetryCatalog {
                reportCurrentStatus()
                return
            }
            stopServing()
            let generation = stateGeneration
            preparationGeneration = generation
            appliedConfiguration = configuration
            appliedAccessState = accessState
            nextCatalogRetry = nil
            guard snapshot.enabled else {
                report("Background gallery is off.")
                return
            }
            var descriptors: [LibraryDescriptor] = []
            unavailableLibraries = []
            for descriptor in snapshot.descriptors where
                snapshot.sharedLibraryIDs.contains(descriptor.id.rawValue.uuidString) {
                if descriptor.kind.isSystemPhotoLibrary {
                    if PhotoLibraryAuthorization(
                        PHPhotoLibrary.authorizationStatus(for: .readWrite)
                    ).permitsReading {
                        descriptors.append(descriptor)
                    } else {
                        unavailableLibraries.append(descriptor.metadata.displayName)
                    }
                } else if let authorized = ownDescriptor(descriptor, grants: grants) {
                    descriptors.append(authorized)
                } else {
                    unavailableLibraries.append(descriptor.metadata.displayName)
                }
            }
            let systemModel = SystemPhotoLibraryViewModel()
            let store = LibraryPreviewStore()
            var readyDescriptors = descriptors.filter { $0.kind.isSystemPhotoLibrary }
            for descriptor in descriptors where !descriptor.kind.isSystemPhotoLibrary {
                let provider = RegisteredPhotoLibraryProvider(bookmarkData: descriptor.bookmarkData)
                do {
                    let catalog = try await provider.catalog()
                    guard generation == stateGeneration,
                          !isAuthorizing, !Task.isCancelled else { return }
                    // Recheck after every asynchronous catalog read so a
                    // removal during preparation cannot start a stale listener.
                    guard try encoder.encode(WebGallerySharedConfiguration.load()) == configuration else {
                        appliedConfiguration = nil
                        return
                    }
                    try store.adoptDirectCatalog(
                        catalog, provider: provider, libraryID: descriptor.id,
                        displayName: descriptor.metadata.displayName
                    )
                    readyDescriptors.append(descriptor)
                } catch {
                    guard generation == stateGeneration, !isAuthorizing else { return }
                    unavailableLibraries.append(descriptor.metadata.displayName)
                    nextCatalogRetry = Date().addingTimeInterval(30)
                }
            }
            let registry = LibraryRegistry(descriptors: readyDescriptors)
            guard generation == stateGeneration, !isAuthorizing, !Task.isCancelled,
                  try encoder.encode(WebGallerySharedConfiguration.load()) == configuration else {
                appliedConfiguration = nil
                return
            }
            self.registry = registry
            self.systemModel = systemModel
            self.store = store
            let searchModel = UnifiedSearchViewModel()
            self.searchModel = searchModel
            searchModel.bootstrap(registry: registry, store: store, systemModel: systemModel)
            WebGalleryServer.shared.useSearchModel(searchModel)
            // Stale helper cache files can stay on disk, but neither routes
            // nor aggregate snapshots may see a library whose refresh failed.
            var servingConfiguration = snapshot
            servingConfiguration.descriptors = readyDescriptors
            servingConfiguration.sharedLibraryIDs = readyDescriptors.map { $0.id.rawValue.uuidString }
            WebGalleryServer.shared.applyConfiguration(servingConfiguration)
            WebGalleryServer.shared.start(registry: registry, systemModel: systemModel, store: store)
            reportCurrentStatus()
        } catch {
            if let preparationGeneration, preparationGeneration != stateGeneration { return }
            stopServing()
            appliedConfiguration = nil
            report("Background gallery stopped: \(error.localizedDescription)")
        }
    }

    private func ownDescriptor(
        _ descriptor: LibraryDescriptor, grants: [String: LibraryGrant]
    ) -> LibraryDescriptor? {
        let expectedPath = URL(fileURLWithPath: descriptor.metadata.lastKnownPath)
            .standardizedFileURL.path
        guard let grant = grants[descriptor.id.rawValue.uuidString], grant.path == expectedPath else {
            return nil
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: grant.bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale
        ), !stale, url.standardizedFileURL.path == expectedPath,
              url.pathExtension.lowercased() == "photoslibrary",
              url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return LibraryDescriptor(
            id: descriptor.id, kind: descriptor.kind,
            bookmarkData: grant.bookmark, writeBookmarkData: nil,
            addedAt: descriptor.addedAt, metadata: descriptor.metadata
        )
    }

    private func loadGrants() -> [String: LibraryGrant] {
        guard let data = UserDefaults.standard.data(forKey: Self.grantsKey),
              let grants = try? JSONDecoder().decode([String: LibraryGrant].self, from: data) else {
            return [:]
        }
        return grants
    }

    private func stopServing() {
        stateGeneration = UUID()
        WebGalleryServer.shared.stop()
        registry = nil
        systemModel = nil
        store = nil
        searchModel = nil
        unavailableLibraries = []
    }

    private func reportCurrentStatus() {
        var message = WebGalleryServer.shared.statusMessage
        if !WebGalleryServer.shared.isRunning,
           message.hasPrefix("Web gallery could not start:"), nextCatalogRetry == nil {
            nextCatalogRetry = Date().addingTimeInterval(30)
        }
        if !unavailableLibraries.isEmpty {
            message += " Authorize or reconnect: "
                + Array(Set(unavailableLibraries)).sorted().joined(separator: ", ") + "."
        }
        report(message)
    }

    private func report(_ message: String) {
        try? WebGallerySharedConfiguration.writeStatus(
            isRunning: WebGalleryServer.shared.isRunning, message: message,
            isAuthorizing: isAuthorizing
        )
    }
}
#endif
