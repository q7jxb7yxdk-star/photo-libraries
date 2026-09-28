import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SidebarSelection: Hashable {
    case allLibraries
    case memories
    case media(MediaCategory)
    case map
    case registeredLibrary(LibraryID)
    case album(libraryID: LibraryID, albumID: String)
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var registry: LibraryRegistry
    @ObservedObject var systemModel: SystemPhotoLibraryViewModel
    @ObservedObject var previewStore: LibraryPreviewStore
    @StateObject private var registeredLibraryProbe = RegisteredLibraryProbeModel()
    @StateObject private var unifiedSearch = UnifiedSearchViewModel()
    @StateObject private var transferCoordinator = PhotoTransferCoordinator()
    @ObservedObject private var webGallery = WebGalleryServer.shared
    @State private var selection: SidebarSelection? = .allLibraries
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var hasRestoredBrowserState = false
    @State private var isAddingLibrary = false
    @State private var pendingLibraryKind: LibraryKind = .userSelectedPhotosLibrary
    @State private var registryError: String?
    @State private var shouldSyncAfterPhotosActivity = false
    @State private var automaticSyncRequest: Task<Void, Never>?
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            selectedDetail
        }
        .onAppear {
            webGallery.useSearchModel(unifiedSearch)
            guard !hasRestoredBrowserState else { return }
            selection = restoredSelection()
            if UserDefaults.standard.object(forKey: "library-browser.sidebar-visible") != nil {
                columnVisibility = UserDefaults.standard.bool(forKey: "library-browser.sidebar-visible")
                    ? .all : .detailOnly
            }
            hasRestoredBrowserState = true
        }
        .onChange(of: selection) { _, newSelection in
            guard hasRestoredBrowserState else { return }
            saveSelection(newSelection)
        }
        .onChange(of: columnVisibility) { _, visibility in
            guard hasRestoredBrowserState else { return }
            UserDefaults.standard.set(
                visibility != .detailOnly,
                forKey: "library-browser.sidebar-visible"
            )
        }
        .fileImporter(
            isPresented: $isAddingLibrary,
            allowedContentTypes: [.package],
            allowsMultipleSelection: !pendingLibraryKind.isSystemPhotoLibrary
        ) { result in
            do {
                let urls = try result.get()
                var lastRegistered: LibraryDescriptor?
                var failures: [String] = []
                for url in urls {
                    do {
                        lastRegistered = try registry.addSelectedLibrary(
                            at: url,
                            kind: pendingLibraryKind
                        )
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                if let lastRegistered {
                    selection = .registeredLibrary(lastRegistered.id)
                }
                if !failures.isEmpty {
                    registryError = failures.joined(separator: "\n")
                }
            } catch {
                registryError = error.localizedDescription
            }
        }
        .alert("Library Access Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(registryError ?? "Unknown error")
        }
        .alert(
            transferCoordinator.pendingSystemSourceDeletion?.sources.count == 1
                ? "Delete System Library Source?"
                : "Delete System Library Sources?",
            isPresented: pendingDeletionBinding,
            presenting: transferCoordinator.pendingSystemSourceDeletion
        ) { pending in
            Button(pending.sources.count == 1 ? "Keep Source" : "Keep Sources", role: .cancel) {
                transferCoordinator.retainSystemSource()
            }
            Button(pending.sources.count == 1 ? "Delete Source" : "Delete Sources", role: .destructive) {
                transferCoordinator.confirmSystemSourceDeletion()
            }
        } message: { pending in
            Text("Destination copies in \(pending.destinationDisplayName) were verified. Some metadata may differ; edited originals and edit history may be lost. This app cannot undo deletion.\(pending.retainedSourceExplanation)")
        }
        .alert(
            transferCoordinator.pendingRegisteredSourceDeletion?.sources.count == 1
                ? "Delete Non-System Library Source?"
                : "Delete Non-System Library Sources?",
            isPresented: registeredDeletionBinding,
            presenting: transferCoordinator.pendingRegisteredSourceDeletion
        ) { pending in
            Button(pending.sources.count == 1 ? "Keep Source" : "Keep Sources", role: .cancel) {
                transferCoordinator.retainRegisteredSource()
            }
            Button(pending.sources.count == 1 ? "Delete Source" : "Delete Sources", role: .destructive) {
                transferCoordinator.confirmRegisteredSourceDeletion()
            }
        } message: { pending in
            Text("System Library copies and album memberships were verified. Empty source albums may also be deleted. Some metadata needs manual review. This app cannot undo deletion.")
        }
        .task {
            scheduleAutomaticSync()
        }
        .task(id: systemLibraryID) {
            systemModel.refreshAuthorizationStatus()
            guard systemLibraryID != nil,
                  systemModel.authorization.permitsReading,
                  !systemModel.isLoading,
                  systemModel.assets.isEmpty,
                  systemModel.collections.isEmpty else {
                return
            }
            systemModel.loadLibrary()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            scheduleAutomaticSync()
        }
        .onChange(of: registry.descriptors) { _, descriptors in
            unifiedSearch.bootstrap(
                registry: registry,
                store: previewStore,
                systemModel: systemModel
            )
            let selectedLibraryID: LibraryID?
            switch selection {
            case .registeredLibrary(let id), .album(let id, _):
                selectedLibraryID = id
            case .allLibraries, .memories, .media(_), .map, nil:
                selectedLibraryID = nil
            }
            guard let selectedLibraryID,
                  !descriptors.contains(where: { $0.id == selectedLibraryID }) else {
                return
            }
            selection = .allLibraries
        }
        .onChange(of: systemModel.collections) { _, collections in
            guard case let .album(libraryID, albumID) = selection,
                  registry.descriptors.first(where: { $0.id == libraryID })?
                    .kind.isSystemPhotoLibrary == true,
                  !collections.isEmpty,
                  Self.collectionNode(withID: albumID, in: collections) == nil else { return }
            selection = .registeredLibrary(libraryID)
        }
        .onReceive(previewStore.$manifests) { manifests in
            guard case let .album(libraryID, albumID) = selection,
                  registry.descriptors.first(where: { $0.id == libraryID })?
                    .kind.isSystemPhotoLibrary == false,
                  let albums = manifests[libraryID]?.albums,
                  !albums.contains(where: { $0.id == albumID }) else { return }
            selection = .registeredLibrary(libraryID)
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didActivateApplicationNotification
            )
        ) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else {
                return
            }

            if application.bundleIdentifier == "com.apple.Photos" {
                shouldSyncAfterPhotosActivity = true
                automaticSyncRequest?.cancel()
                return
            }

            guard application.bundleIdentifier == Bundle.main.bundleIdentifier,
                  shouldSyncAfterPhotosActivity else {
                return
            }
            shouldSyncAfterPhotosActivity = false
            scheduleAutomaticSync(bypassThrottle: true)
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didTerminateApplicationNotification
            )
        ) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.bundleIdentifier == "com.apple.Photos" else { return }
            shouldSyncAfterPhotosActivity = false
            automaticSyncRequest?.cancel()
            registeredLibraryProbe.cancelAutomaticSync()
        }
        .onReceive(transferCoordinator.libraryContentDidChange) { change in
            switch change {
            case .system:
                systemModel.refreshAfterTransfer()
            case .registered(let libraryID):
                registeredLibraryProbe.refreshAfterTransfer(
                    registry: registry, libraryID: libraryID, store: previewStore
                )
            }
        }
        .onReceive(previewStore.searchMutations) { mutation in
            unifiedSearch.apply(mutation)
        }
        .onChange(of: systemModel.assets) { _, assets in
            guard let library = registry.libraries.first(where: {
                $0.descriptor.kind.isSystemPhotoLibrary
            }) else { return }
            unifiedSearch.replaceSystemLibrary(library, assets: assets)
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Browse") {
                Label("All Libraries", systemImage: "square.grid.2x2")
                    .tag(SidebarSelection.allLibraries)
                Label("Memories", systemImage: "sparkles.rectangle.stack")
                    .tag(SidebarSelection.memories)
                Label("Map", systemImage: "map")
                    .tag(SidebarSelection.map)
            }
            Section("Libraries") {
                ForEach(registry.libraries) { library in
                    sidebarLibraryDisclosure(for: library)
                }
            }
            Section("Media Types") {
                ForEach(MediaCategory.allCases, id: \.self) { category in
                    Label(category.title, systemImage: category.symbol)
                        .tag(SidebarSelection.media(category))
                }
            }
            Section("Sharing") {
                Label(
                    webGallery.isRunning ? "Web Gallery · On" : "Web Gallery · Off",
                    systemImage: "network"
                )
            }
        }
        .navigationTitle("Libraries")
        .toolbar {
            ToolbarItem {
                Menu("Add Library", systemImage: "plus") {
                    Button("Add System Photo Library…") {
                        pendingLibraryKind = .systemPhotoLibrary
                        isAddingLibrary = true
                    }
                    Button("Add Non-System Photo Library…") {
                        pendingLibraryKind = .userSelectedPhotosLibrary
                        isAddingLibrary = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        switch selection {
        case .allLibraries:
            AllLibrariesView(
                registry: registry,
                store: previewStore,
                systemModel: systemModel,
                probe: registeredLibraryProbe,
                searchModel: unifiedSearch
            )
            .id(SidebarSelection.allLibraries)
        case .memories:
            MemoriesView(
                registry: registry,
                store: previewStore,
                systemModel: systemModel,
                searchModel: unifiedSearch
            )
        case .media(let category):
            AllLibrariesView(
                registry: registry,
                store: previewStore,
                systemModel: systemModel,
                probe: registeredLibraryProbe,
                searchModel: unifiedSearch,
                mediaCategory: category
            )
            .id(SidebarSelection.media(category))
        case .map:
            LibraryMapView(
                registry: registry,
                store: previewStore,
                systemModel: systemModel,
                probe: registeredLibraryProbe
            )
        case .registeredLibrary(let id):
            libraryDetail(libraryID: id, albumID: nil)
                .id(id.rawValue)
        case .album(let libraryID, let albumID):
            libraryDetail(libraryID: libraryID, albumID: albumID)
                .id(libraryID.rawValue)
        case nil:
            ContentUnavailableView("Select a Library", systemImage: "photo.stack")
        }
    }

    @ViewBuilder
    private func libraryDetail(libraryID: LibraryID, albumID: String?) -> some View {
        let title = albumID.flatMap { albumTitle(libraryID: libraryID, albumID: $0) }
        if registry.libraries.first(where: { $0.id == libraryID })?
            .descriptor.kind.isSystemPhotoLibrary == true {
            SystemPhotoLibraryView(
                model: systemModel,
                registry: registry,
                libraryID: libraryID,
                store: previewStore,
                probe: registeredLibraryProbe,
                searchModel: unifiedSearch,
                transferCoordinator: transferCoordinator,
                albumID: albumID,
                albumTitle: title
            )
        } else {
            RegisteredLibraryView(
                registry: registry,
                libraryID: libraryID,
                store: previewStore,
                probe: registeredLibraryProbe,
                searchModel: unifiedSearch,
                transferCoordinator: transferCoordinator,
                albumID: albumID,
                albumTitle: title
            )
        }
    }

    private func scheduleAutomaticSync(bypassThrottle: Bool = false) {
        automaticSyncRequest?.cancel()
        automaticSyncRequest = Task { @MainActor in
            registeredLibraryProbe.refreshDirectCatalogs(
                registry: registry, store: previewStore
            )
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { registryError != nil },
            set: { if !$0 { registryError = nil } }
        )
    }

    private var pendingDeletionBinding: Binding<Bool> {
        Binding(
            get: { transferCoordinator.pendingSystemSourceDeletion != nil },
            set: { isPresented in
                if !isPresented,
                   transferCoordinator.pendingSystemSourceDeletion != nil {
                    transferCoordinator.retainSystemSource()
                }
            }
        )
    }

    private var registeredDeletionBinding: Binding<Bool> {
        Binding(
            get: { transferCoordinator.pendingRegisteredSourceDeletion != nil },
            set: { isPresented in
                if !isPresented,
                   transferCoordinator.pendingRegisteredSourceDeletion != nil {
                    transferCoordinator.retainRegisteredSource()
                }
            }
        )
    }

    private var systemLibraryID: LibraryID? {
        registry.libraries.first(where: {
            $0.descriptor.kind.isSystemPhotoLibrary
        })?.id
    }

    private func restoredSelection() -> SidebarSelection {
        let defaults = UserDefaults.standard
        guard let state = defaults.dictionary(forKey: "library-browser.last-selection"),
              let kind = state["kind"] as? String else { return .allLibraries }
        switch kind {
        case "all": return .allLibraries
        case "memories": return .memories
        case "map": return .map
        case "media":
            guard let value = state["category"] as? String,
                  let category = MediaCategory(rawValue: value) else { return .allLibraries }
            return .media(category)
        case "library", "album":
            guard let value = state["libraryID"] as? String,
                  let uuid = UUID(uuidString: value) else { return .allLibraries }
            let libraryID = LibraryID(rawValue: uuid)
            guard registry.descriptors.contains(where: { $0.id == libraryID }) else {
                return .allLibraries
            }
            if kind == "album", let albumID = state["albumID"] as? String,
               !albumID.isEmpty {
                if let descriptor = registry.descriptors.first(where: { $0.id == libraryID }) {
                    if descriptor.kind.isSystemPhotoLibrary {
                        if !systemModel.collections.isEmpty,
                           Self.collectionNode(withID: albumID, in: systemModel.collections) == nil {
                            return .registeredLibrary(libraryID)
                        }
                    } else if let albums = previewStore.manifest(for: libraryID)?.albums,
                              !albums.contains(where: { $0.id == albumID }) {
                        return .registeredLibrary(libraryID)
                    }
                }
                return .album(libraryID: libraryID, albumID: albumID)
            }
            return .registeredLibrary(libraryID)
        default: return .allLibraries
        }
    }

    private func saveSelection(_ selection: SidebarSelection?) {
        let state: [String: String]
        switch selection {
        case .allLibraries: state = ["kind": "all"]
        case .memories: state = ["kind": "memories"]
        case .map: state = ["kind": "map"]
        case .media(let category):
            state = ["kind": "media", "category": category.rawValue]
        case .registeredLibrary(let libraryID):
            state = ["kind": "library", "libraryID": libraryID.rawValue.uuidString]
        case .album(let libraryID, let albumID):
            state = [
                "kind": "album", "libraryID": libraryID.rawValue.uuidString,
                "albumID": albumID
            ]
        case nil: return
        }
        UserDefaults.standard.set(state, forKey: "library-browser.last-selection")
    }

    private func availabilityIcon(_ availability: LibraryAvailability) -> String {
        switch availability {
        case .online: "externaldrive.fill.badge.checkmark"
        case .offline: "externaldrive.badge.xmark"
        case .needsReauthorization: "lock.trianglebadge.exclamationmark"
        case .invalidSelection: "exclamationmark.triangle"
        }
    }

    private func sidebarIcon(for library: RegisteredLibrary) -> String {
        library.descriptor.kind.isSystemPhotoLibrary
            ? "photo.stack.fill"
            : availabilityIcon(library.availability)
    }

    @ViewBuilder
    private func sidebarLibraryDisclosure(for library: RegisteredLibrary) -> some View {
        if library.descriptor.kind.isSystemPhotoLibrary {
            DisclosureGroup {
                ForEach(systemModel.collections) { node in
                    PhotoCollectionSidebarRow(node: node, libraryID: library.id)
                }
            } label: {
                sidebarRow(for: library)
            }
            .tag(SidebarSelection.registeredLibrary(library.id))
        } else if let albums = previewStore.manifest(for: library.id)?.albums,
                  !albums.isEmpty {
            DisclosureGroup {
                ForEach(albums.sorted(by: Self.isEarlierAlbum)) { album in
                    StoredAlbumSidebarRow(album: album)
                        .tag(SidebarSelection.album(
                            libraryID: library.id,
                            albumID: album.id
                        ))
                }
            } label: {
                sidebarRow(for: library)
            }
            .tag(SidebarSelection.registeredLibrary(library.id))
        } else {
            sidebarRow(for: library)
                .tag(SidebarSelection.registeredLibrary(library.id))
        }
    }

    private func sidebarRow(for library: RegisteredLibrary) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(library.descriptor.metadata.displayName)
                Text(sidebarDetail(for: library))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: sidebarIcon(for: library))
        }
    }

    private func sidebarDetail(for library: RegisteredLibrary) -> String {
        if library.descriptor.kind.isSystemPhotoLibrary {
            return systemModel.authorization.permitsReading
                ? "System library"
                : "Access required"
        }
        if let manifest = previewStore.manifest(for: library.id) {
            let completeness = manifest.items.count >= manifest.totalMediaItemCount && manifest.isComplete
                ? ""
                : " · incomplete"
            return "Non-system library\(completeness)"
        }
        return library.availability == .online ? "Not read yet" : library.availability.displayName
    }

    private func albumTitle(libraryID: LibraryID, albumID: String) -> String? {
        if registry.libraries.first(where: { $0.id == libraryID })?
            .descriptor.kind.isSystemPhotoLibrary == true {
            return Self.collectionNode(withID: albumID, in: systemModel.collections)?.title
        }
        return previewStore.manifest(for: libraryID)?.albums?
            .first(where: { $0.id == albumID })?.name
    }

    nonisolated private static func collectionNode(
        withID identifier: String,
        in nodes: [PhotoCollectionNode]
    ) -> PhotoCollectionNode? {
        for node in nodes {
            if node.id == identifier { return node }
            if let match = collectionNode(withID: identifier, in: node.children) {
                return match
            }
        }
        return nil
    }

    nonisolated private static func isEarlierAlbum(
        _ lhs: PhotosAutomationAlbum,
        _ rhs: PhotosAutomationAlbum
    ) -> Bool {
        let leftParent = lhs.parentName ?? ""
        let rightParent = rhs.parentName ?? ""
        if leftParent != rightParent {
            return leftParent.localizedStandardCompare(rightParent) == .orderedAscending
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private struct PhotoCollectionSidebarRow: View {
    let node: PhotoCollectionNode
    let libraryID: LibraryID

    var body: some View {
        if node.kind == .folder {
            DisclosureGroup {
                ForEach(node.children) { child in
                    PhotoCollectionSidebarRow(node: child, libraryID: libraryID)
                }
            } label: {
                label
            }
        } else {
            label
                .tag(SidebarSelection.album(libraryID: libraryID, albumID: node.id))
        }
    }

    private var label: some View {
        Label {
            HStack {
                Text(node.title)
                if let count = node.assetCount {
                    Text(count.formatted()).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: node.kind == .folder ? "folder" : "rectangle.stack")
        }
    }
}

private struct StoredAlbumSidebarRow: View {
    let album: PhotosAutomationAlbum

    var body: some View {
        Label {
            HStack {
                Text(album.name)
                Text(album.mediaItemCount.formatted()).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "rectangle.stack")
        }
        .help(album.parentName.map { "Folder: \($0)" } ?? album.name)
    }
}

#Preview {
    ContentView(
        registry: LibraryRegistry(),
        systemModel: SystemPhotoLibraryViewModel(),
        previewStore: .shared
    )
}
