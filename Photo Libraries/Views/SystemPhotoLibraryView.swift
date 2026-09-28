import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SystemPhotoLibraryTimelineMode: String, CaseIterable, Identifiable {
    case years = "Years"
    case months = "Months"
    case allPhotos = "All Photos"

    var id: Self { self }
}

private struct SystemPhotoLibraryDateSection: Identifiable {
    let id: String
    let title: String
    let assets: [PhotoAssetSummary]
}

private struct SystemBrowserGridRevision: Equatable {
    let catalog: Int
    let albumID: String?
    let searchText: String
    let resolvedPlaceCount: Int
    let timelineMode: SystemPhotoLibraryTimelineMode
    let selectedTimelineSectionID: String?
    let thumbnailSize: Double
    let thumbnailRequestGeneration: Int
    let selectedAssetID: String?
    let selectedAssetIDs: Set<String>
    let isDark: Bool
}

struct SystemPhotoLibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: SystemPhotoLibraryViewModel
    @ObservedObject var registry: LibraryRegistry
    let libraryID: LibraryID
    @ObservedObject var store: LibraryPreviewStore
    @ObservedObject var probe: RegisteredLibraryProbeModel
    @ObservedObject var searchModel: UnifiedSearchViewModel
    @ObservedObject var transferCoordinator: PhotoTransferCoordinator
    let albumID: String?
    let albumTitle: String?

    @State private var searchText = ""
    // Thumbnail grid column width
    @AppStorage("thumbnail-grid.size") private var thumbnailSize = 130.0
    @State private var timelineMode: SystemPhotoLibraryTimelineMode = .allPhotos
    @State private var hasRestoredTimelineMode = false
    @State private var selectedTimelineSectionID: String?
    @State private var allPhotosScrollPositionID: String?
    @State private var allPhotosWasAtBottom = false
    @State private var isAtBottom = false
    @State private var showRemoveConfirmation = false
    @State private var isReauthorizing = false
    @State private var registrationError: String?
    @State private var scrollTracker = LibraryBrowserScrollTracker()
    @State private var browserScrollTargetID: String?
    @State private var browserScrollAnchor: UnitPoint = .top
    @State private var browserScrollRequestGeneration = 0
    @State private var hasRestoredScrollPosition = false
    @State private var pendingRestoreTargetID: String?
    @State private var hasIssuedRestoreScroll = false
    @State private var hasQueuedRestoreAfterLayout = false
    @State private var isShowingExpandedPhoto = false
    @State private var isShowingPhotoPreview = false
    @State private var selectedAssetIDs: Set<String> = []
    @State private var selectionAnchorID: String?
    @State private var showsDeleteConfirmation = false
    @State private var pendingDeleteAssets: [PhotoAssetSummary] = []
    @State private var pendingDeletedAssetIDs: Set<String> = []
    @State private var isDeletingPhotos = false
    @State private var deletionError: String?
    @State private var deletionResult: String?
    @State private var isBrowserVisible = false
    @FocusState private var isPhotoAreaFocused: Bool

    private var library: RegisteredLibrary? {
        registry.libraries.first { $0.id == libraryID }
    }

    private var displayName: String {
        library?.descriptor.metadata.displayName ?? "System Photo Library"
    }

    private var contentTitle: String {
        guard let albumTitle else {
            let videoCount = model.assets.filter { $0.mediaType == "video" }.count
            return "\((model.assets.count - videoCount).formatted()) Photos · \(videoCount.formatted()) Videos"
        }
        return albumTitle
    }

    private var albumAssets: [PhotoAssetSummary] {
        albumID == nil ? model.assets : model.visibleAssets
    }

    private var filteredAssets: [PhotoAssetSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return albumAssets }
        return albumAssets.filter { asset in
            let place = searchModel.place(libraryID: libraryID, assetID: asset.id)
            return asset.originalFilename.localizedCaseInsensitiveContains(query)
                || asset.mediaType.localizedCaseInsensitiveContains(query)
                || asset.creationDate?.formatted().localizedCaseInsensitiveContains(query) == true
                || "\(asset.pixelWidth) × \(asset.pixelHeight)".contains(query)
                || place?.searchableText.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var selectedAsset: PhotoAssetSummary? {
        guard let id = model.selectedAssetID else { return nil }
        return albumAssets.first { $0.id == id }
    }

    private var selectedPhotoCount: Int {
        selectedAssetIDs.isEmpty ? (selectedAsset == nil ? 0 : 1) : selectedAssetIDs.count
    }

    private var nonSystemTransferTargets: [RegisteredLibrary] {
        registry.libraries.filter {
            !$0.descriptor.kind.isSystemPhotoLibrary && $0.availability == .online
        }
    }

    var body: some View {
        configuredBrowserPane
            .onAppear {
                guard !hasRestoredTimelineMode else { return }
                hasRestoredTimelineMode = true
                guard albumID == nil else { return }
                if let saved = LibraryBrowserPositionStore.timelineMode(
                    for: "library-\(libraryID.rawValue.uuidString)"
                ), let mode = SystemPhotoLibraryTimelineMode(rawValue: saved) {
                    timelineMode = mode
                }
            }
            .focusedSceneValue(
                \.libraryMenuActions,
                LibraryMenuActions(
                    isIndexing: store.activeIndexLibraryID != nil,
                    reauthorize: { isReauthorizing = true },
                    removeRegistration: { showRemoveConfirmation = true }
                )
            )
            .focusedSceneValue(\.photoTransferActions, photoTransferActions)
            .task(id: "\(model.selectedAssetID ?? ""):\(model.textMetadataRevision)") {
                guard let asset = selectedAsset else { return }
                searchModel.requestPlace(
                    libraryID: libraryID,
                    assetID: asset.id,
                    coordinate: asset.coordinate
                )
                await model.loadSelectedTextMetadata(registry: registry, libraryID: libraryID)
            }
            .onChange(of: searchText) { oldValue, newValue in
                handleSearchChange(from: oldValue, to: newValue)
            }
            .onChange(of: dateSections.map(\.id)) { _, sectionIDs in
                guard let selectedTimelineSectionID,
                      !sectionIDs.contains(selectedTimelineSectionID) else { return }
                self.selectedTimelineSectionID = nil
                scrollTracker.reset()
                queueBrowserScroll(to: timelineScrollTargetID)
            }
            .onChange(of: selectedTimelineSectionID) { _, _ in
                clearMultiSelection()
                model.clearSelectedAsset()
            }
            .onDisappear {
                isBrowserVisible = false
                persistBrowserPosition()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active {
                    persistBrowserPosition()
                }
            }
            .onChange(of: isShowingExpandedPhoto) { wasExpanded, isExpanded in
                if wasExpanded, !isExpanded, !showsDeleteConfirmation {
                    restoreBrowserPosition(force: true)
                }
            }
            .onChange(of: model.catalogRevision) { _, _ in
                handleCatalogRevisionChange()
            }
    }

    private var browserWithToolbar: some View {
        browserPane
            .frame(minWidth: 560, maxWidth: .infinity)
            .background {
                SystemDeleteKeyMonitor(
                    isEnabled: isBrowserVisible
                        && canDeleteSelectedPhotos
                        && !showsDeleteConfirmation,
                    onDelete: requestPhotoDeletion
                )
            }
            .background {
                PhotoViewerWindowPresenter(
                    isPresented: isShowingPhotoPreview || isShowingExpandedPhoto,
                    onEscape: isShowingExpandedPhoto ? closeExpandedPhoto : closePhotoPreview,
                    onPrevious: selectedAsset.flatMap { adjacentAsset(to: $0, offset: -1) }.map { previous in
                        { select(previous) }
                    },
                    onNext: selectedAsset.flatMap { adjacentAsset(to: $0, offset: 1) }.map { next in
                        { select(next) }
                    }
                ) {
                    if isShowingExpandedPhoto, let asset = selectedAsset {
                        expandedPhoto(asset)
                            .focusable()
                            .focusEffectDisabled()
                            .focused($isPhotoAreaFocused)
                            .focusedValue(\.photoViewerActions, photoViewerActions)
                            .focusedValue(\.photoTransferActions, photoTransferActions)
                    } else if isShowingPhotoPreview, let asset = selectedAsset {
                        photoPreview(asset)
                    }
                }
            }
        .navigationTitle(contentTitle)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search this library")
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Button("Zoom Out", systemImage: "minus") {
                    thumbnailSize = max(90, thumbnailSize - 20)
                }
                .disabled(thumbnailSize <= 90 || isShowingTimelineCovers)

                Button("Zoom In", systemImage: "plus") {
                    thumbnailSize = min(260, thumbnailSize + 20)
                }
                .disabled(thumbnailSize >= 260 || isShowingTimelineCovers)

                if albumID == nil {
                    Picker("Library View", selection: $timelineMode) {
                        ForEach(SystemPhotoLibraryTimelineMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 235)
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if selectedPhotoCount > 0 {
                    Text("\(selectedPhotoCount) Selected")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(selectedPhotoCount) photos selected")
                }

                Button(role: .destructive) {
                    requestPhotoDeletion()
                } label: {
                    Label("Delete Photos", systemImage: "trash")
                }
                .help("Delete the selected photos from the System Photo Library")
                .disabled(!canDeleteSelectedPhotos)

                Button {
                    persistBrowserPosition()
                    model.loadLibrary()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Reload this library")
                .disabled(!model.authorization.permitsReading || model.isLoading)

                Button("Open in Photos", systemImage: "arrow.up.forward.app") {
                    openInPhotos()
                }
                .help("Open this library in Photos")
                .disabled(
                    library?.availability != .online
                        || store.activeIndexLibraryID != nil
                        || probe.isWaitingForPhotos
                        || probe.isIndexing
                        || probe.isWorking
                )
            }
        }
    }

    private var configuredBrowserPane: some View {
        browserWithToolbar
        .onAppear {
            isBrowserVisible = true
            model.refreshAuthorizationStatus()
            if model.authorization.permitsReading,
               !model.isLoading,
               model.assets.isEmpty,
               model.collections.isEmpty {
                model.loadLibrary()
            }
        }
        .onChange(of: albumID, initial: true) { oldAlbumID, newAlbumID in
            clearMultiSelection()
            model.selectAlbum(newAlbumID)
            if newAlbumID != nil {
                timelineMode = .allPhotos
            } else if let saved = LibraryBrowserPositionStore.timelineMode(
                for: "library-\(libraryID.rawValue.uuidString)"
            ), let mode = SystemPhotoLibraryTimelineMode(rawValue: saved) {
                timelineMode = mode
            }
            // The initial callback can run after the browser has queued its
            // restoration. New views already start with cleared scroll state.
            guard oldAlbumID != newAlbumID else { return }
            model.clearSelectedAsset()
            isShowingExpandedPhoto = false
            isShowingPhotoPreview = false
            selectedTimelineSectionID = nil
            scrollTracker.reset()
            hasRestoredScrollPosition = false
            pendingRestoreTargetID = nil
            hasIssuedRestoreScroll = false
            hasQueuedRestoreAfterLayout = false
            restoreBrowserPosition()
        }
        .onChange(of: timelineMode) { oldMode, newMode in
            guard albumID == nil, oldMode != newMode else { return }
            if hasRestoredTimelineMode {
                LibraryBrowserPositionStore.saveTimelineMode(
                    newMode.rawValue, for: "library-\(libraryID.rawValue.uuidString)"
                )
            }
            clearMultiSelection()
            model.clearSelectedAsset()
            if oldMode == .allPhotos {
                allPhotosScrollPositionID = scrollTracker.centeredID
                    ?? LibraryBrowserPositionStore.assetID(for: libraryID)
                allPhotosWasAtBottom = isAtBottom
            }
            selectedTimelineSectionID = nil
            scrollTracker.reset()
            if newMode == .allPhotos {
                if allPhotosWasAtBottom {
                    queueBrowserRestoration(to: albumAssets.last?.id, anchor: .bottom)
                } else if let allPhotosScrollPositionID,
                          albumAssets.contains(where: { $0.id == allPhotosScrollPositionID }) {
                    queueBrowserRestoration(to: allPhotosScrollPositionID, anchor: .center)
                } else {
                    queueBrowserRestoration(to: albumAssets.last?.id, anchor: .bottom)
                }
            } else {
                pendingRestoreTargetID = nil
                hasIssuedRestoreScroll = false
                hasQueuedRestoreAfterLayout = false
                queueBrowserScroll(to: timelineScrollTargetID)
            }
        }
        .alert("Remove Registration?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if !probe.removeRegistration(
                    libraryID: libraryID,
                    registry: registry,
                    store: store
                ) {
                    registrationError = probe.errorMessage
                }
            }
        } message: {
            Text("This removes the app’s bookmark and any app-owned preview cache. It does not delete or modify the System Photo Library.")
        }
        .sheet(isPresented: $showsDeleteConfirmation, onDismiss: {
            pendingDeleteAssets = []
        }) {
            deleteConfirmationSheet
        }
        .fileImporter(
            isPresented: $isReauthorizing,
            allowedContentTypes: [.package],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                _ = try registry.reauthorizeLibrary(id: libraryID, with: url)
                registrationError = nil
            } catch {
                registrationError = error.localizedDescription
            }
        }
    }

    private func handleSearchChange(from oldValue: String, to newValue: String) {
        clearMultiSelection()
        // A search can remove the selected date section; return safely to its covers.
        selectedTimelineSectionID = nil
        if let selectedAssetID = model.selectedAssetID,
           !filteredAssets.contains(where: { $0.id == selectedAssetID }) {
            model.clearSelectedAsset()
        }
        let oldQuery = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newQuery = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldQuery.isEmpty, !newQuery.isEmpty {
            persistBrowserPosition(allowActiveSearch: true)
        } else if !oldQuery.isEmpty, newQuery.isEmpty {
            if timelineMode == .allPhotos {
                restoreBrowserPosition(force: true)
            } else {
                queueBrowserScroll(to: timelineScrollTargetID)
            }
        }
    }

    private func handleCatalogRevisionChange() {
        let availableIDs = Set(albumAssets.map(\.id))
        selectedAssetIDs.formIntersection(availableIDs)
        if let selectionAnchorID, !availableIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = nil
        }
        let completedDeletion = !pendingDeletedAssetIDs.isEmpty
            && pendingDeletedAssetIDs.isDisjoint(with: Set(model.assets.map(\.id)))
        if completedDeletion {
            pendingDeletedAssetIDs.removeAll()
            pendingRestoreTargetID = nil
            hasIssuedRestoreScroll = false
            hasQueuedRestoreAfterLayout = false
            hasRestoredScrollPosition = true
            browserScrollTargetID = nil
            browserScrollRequestGeneration &+= 1
        }
        if timelineMode == .allPhotos, !completedDeletion {
            restoreBrowserPosition(force: true)
        }
    }

    private var browserPane: some View {
        VStack(spacing: 0) {
            if let registrationError {
                StatusBanner(text: registrationError, color: .red, icon: "exclamationmark.triangle.fill")
                    .padding(12)
            }
            if let error = model.errorMessage {
                StatusBanner(text: error, color: .red, icon: "exclamationmark.triangle.fill")
                    .padding(12)
            }
            if isDeletingPhotos {
                StatusBanner(text: "Deleting selected photos…", color: .blue, icon: "trash")
                    .padding(12)
            } else if let deletionError {
                StatusBanner(text: deletionError, color: .red, icon: "exclamationmark.triangle.fill")
                    .padding(12)
            } else if let deletionResult {
                StatusBanner(text: deletionResult, color: .blue, icon: "checkmark.circle.fill")
                    .padding(12)
            }
            if transferCoordinator.isWorking, let status = transferCoordinator.statusMessage {
                VStack(alignment: .leading, spacing: 8) {
                    StatusBanner(text: status, color: .blue, icon: "arrow.left.arrow.right")
                    if transferCoordinator.copyTotalCount > 0 {
                        ProgressView(
                            value: Double(transferCoordinator.copyCompletedCount),
                            total: Double(transferCoordinator.copyTotalCount)
                        )
                        Button("Cancel Transfer") { transferCoordinator.cancel() }
                    }
                    transferDetailsDisclosure
                }
                .padding(12)
            } else if let error = transferCoordinator.errorMessage {
                StatusBanner(text: error, color: .red, icon: "exclamationmark.triangle.fill")
                    .padding(12)
                transferDetailsDisclosure
                    .padding(.horizontal, 12)
            } else if let result = transferCoordinator.resultMessage {
                StatusBanner(text: result, color: .blue, icon: "checkmark.circle.fill")
                    .padding(12)
                transferDetailsDisclosure
                    .padding(.horizontal, 12)
            }
            if probe.activeLibraryID == libraryID, let error = probe.errorMessage {
                StatusBanner(text: error, color: .red, icon: "exclamationmark.triangle.fill")
                    .padding(12)
            } else if probe.activeLibraryID == libraryID,
                      let status = probe.statusMessage,
                      !probe.isIndexing,
                      !probe.isWaitingForPhotos {
                StatusBanner(text: status, color: .blue, icon: "arrow.up.forward.app")
                    .padding(12)
            }
            if model.authorization.permitsReading {
                if model.isLoading {
                    ProgressView("Loading complete PhotoKit catalog…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredAssets.isEmpty,
                          !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredAssets.isEmpty, albumID != nil {
                    ContentUnavailableView(
                        "No Photos in This Album",
                        systemImage: "rectangle.stack.badge.minus",
                        description: Text("\(contentTitle) does not contain any photos or videos.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredAssets.isEmpty {
                    ContentUnavailableView(
                        "No Photos",
                        systemImage: "photo.stack",
                        description: Text("The System Photo Library does not contain any visible photos or videos.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    photoBrowser
                }
            } else {
                ContentUnavailableView {
                    Label("Photo Library Access Required", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text("Public PhotoKit access is required for the System Photo Library.")
                } actions: {
                    Button("Request Access") {
                        Task { await model.requestAccessAndLoad() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func openInPhotos() {
        guard let library, library.availability == .online else { return }
        probe.openInPhotos(
            registry: registry,
            libraryID: libraryID,
            displayName: library.descriptor.metadata.displayName,
            store: store
        )
    }

    @ViewBuilder
    private var photoBrowser: some View {
        ScrollViewReader { proxy in
            ScrollView {
                CachedPreviewGridContent(revision: browserGridRevision) {
                    Group {
                        if isShowingTimelineCovers {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 4),
                                spacing: 1
                            ) {
                                ForEach(dateSections) { section in
                                    if let asset = timelineCoverAsset(for: section) {
                                        timelineCoverCell(asset, section: section)
                                            .id(timelineTileID(for: section.id))
                                    }
                                }
                            }
                            .scrollTargetLayout()
                        } else if let section = selectedTimelineSection {
                            VStack(alignment: .leading, spacing: 10) {
                                timelineDetailHeader(section)
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 1)],
                                    spacing: 1
                                ) {
                                    ForEach(timelineDetailAssets) { asset in
                                        gridCell(asset).id(asset.id)
                                    }
                                }
                            }
                            .scrollTargetLayout()
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 1)],
                                spacing: 1
                            ) {
                                ForEach(filteredAssets) { asset in
                                    gridCell(asset).id(asset.id)
                                }
                            }
                            .scrollTargetLayout()
                        }
                    }
                }
                .equatable()
                .id("photo-browser-\(timelineMode.rawValue)-\(selectedTimelineSectionID ?? "covers")")
                .padding(1)
                .background(colorScheme == .dark ? Color.black : Color.white)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 2
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
            .onScrollTargetVisibilityChange(idType: String.self) { identifiers in
                guard !identifiers.isEmpty else { return }
                scrollTracker.updateVisibleIDs(identifiers)
                if let pendingRestoreTargetID,
                   !hasIssuedRestoreScroll,
                   !hasQueuedRestoreAfterLayout {
                    // The first visible targets confirm that the lazy grid has
                    // laid out. A task started earlier cannot scroll reliably.
                    hasQueuedRestoreAfterLayout = true
                    queueBrowserScroll(to: pendingRestoreTargetID, anchor: browserScrollAnchor)
                    return
                }
                if hasIssuedRestoreScroll,
                   let pendingRestoreTargetID,
                   identifiers.contains(pendingRestoreTargetID) {
                    self.pendingRestoreTargetID = nil
                    hasIssuedRestoreScroll = false
                    hasRestoredScrollPosition = true
                }
            }
            .onAppear { restoreBrowserPosition() }
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .interacting, pendingRestoreTargetID != nil {
                    // A manual scroll takes priority over a delayed restore.
                    pendingRestoreTargetID = nil
                    hasIssuedRestoreScroll = false
                    hasRestoredScrollPosition = true
                }
                if newPhase == .idle {
                    persistBrowserPosition()
                }
            }
            .task(id: browserScrollRequestGeneration) {
                guard let targetID = browserScrollTargetID else { return }
                await Task.yield()
                await Task.yield()
                guard !Task.isCancelled else { return }
                let isRestoration = pendingRestoreTargetID == targetID
                if isRestoration, scrollTracker.visibleIDs.isEmpty { return }
                for _ in 0..<(isRestoration ? 12 : 1) {
                    guard !Task.isCancelled else { return }
                    if isRestoration, pendingRestoreTargetID != targetID { return }
                    if isRestoration { hasIssuedRestoreScroll = true }
                    proxy.scrollTo(targetID, anchor: browserScrollAnchor)
                    guard isRestoration else { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                    if pendingRestoreTargetID == nil { return }
                    if scrollTracker.visibleIDs.contains(targetID) {
                        pendingRestoreTargetID = nil
                        hasIssuedRestoreScroll = false
                        hasRestoredScrollPosition = true
                        return
                    }
                }
                if isRestoration, pendingRestoreTargetID == targetID {
                    pendingRestoreTargetID = nil
                    hasIssuedRestoreScroll = false
                    hasRestoredScrollPosition = true
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isPhotoAreaFocused)
        .focusedValue(\.photoViewerActions, photoViewerActions)
        .focusedValue(\.photoTransferActions, photoTransferActions)
    }

    private var browserGridRevision: SystemBrowserGridRevision {
        SystemBrowserGridRevision(
            catalog: model.gridContentRevision,
            albumID: albumID,
            searchText: searchText,
            resolvedPlaceCount: searchText.isEmpty ? 0 : searchModel.placesByDocumentID.count,
            timelineMode: timelineMode,
            selectedTimelineSectionID: selectedTimelineSectionID,
            thumbnailSize: thumbnailSize,
            thumbnailRequestGeneration: model.thumbnailRequestGeneration,
            selectedAssetID: model.selectedAssetID,
            selectedAssetIDs: selectedAssetIDs,
            isDark: colorScheme == .dark
        )
    }

    private var dateSections: [SystemPhotoLibraryDateSection] {
        guard albumID == nil, timelineMode != .allPhotos else {
            return [SystemPhotoLibraryDateSection(id: "all", title: "All Photos", assets: filteredAssets)]
        }

        let calendar = Calendar.current
        var grouped: [String: (title: String, assets: [PhotoAssetSummary])] = [:]
        for asset in filteredAssets {
            guard let date = asset.creationDate else {
                var section = grouped["unknown"] ?? ("Unknown Date", [])
                section.assets.append(asset)
                grouped["unknown"] = section
                continue
            }
            let components: DateComponents
            let title: String
            switch timelineMode {
            case .years:
                components = calendar.dateComponents([.year], from: date)
                title = date.formatted(.dateTime.year())
            case .months:
                components = calendar.dateComponents([.year, .month], from: date)
                title = date.formatted(.dateTime.month(.abbreviated).year())
            case .allPhotos:
                continue
            }
            let key = String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
            var section = grouped[key] ?? (title, [])
            section.assets.append(asset)
            grouped[key] = section
        }
        return grouped.map { key, value in
            SystemPhotoLibraryDateSection(id: key, title: value.title, assets: value.assets)
        }
        .sorted { lhs, rhs in
            if lhs.id == "unknown" { return false }
            if rhs.id == "unknown" { return true }
            return lhs.id > rhs.id
        }
    }

    private var isShowingTimelineCovers: Bool {
        albumID == nil && timelineMode != .allPhotos && selectedTimelineSectionID == nil
    }

    private var selectedTimelineSection: SystemPhotoLibraryDateSection? {
        guard let selectedTimelineSectionID else { return nil }
        return dateSections.first { $0.id == selectedTimelineSectionID }
    }

    private var timelineDetailAssets: [PhotoAssetSummary] {
        filteredAssets.enumerated().sorted { lhs, rhs in
            switch (lhs.element.creationDate, rhs.element.creationDate) {
            case let (leftDate?, rightDate?):
                return leftDate == rightDate ? lhs.offset < rhs.offset : leftDate < rightDate
            case (nil, nil):
                return lhs.offset < rhs.offset
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            }
        }.map(\.element)
    }

    private func restoreBrowserPosition(force: Bool = false) {
        guard timelineMode == .allPhotos else { return }
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard force || (!hasRestoredScrollPosition && pendingRestoreTargetID == nil) else { return }
        if let albumID {
            guard !model.isLoading || !albumAssets.isEmpty else { return }
            if let savedID = LibraryBrowserPositionStore.albumAssetID(
                for: libraryID, albumID: albumID
            ), albumAssets.contains(where: { $0.id == savedID }) {
                queueBrowserRestoration(to: savedID, anchor: .center)
            } else {
                queueBrowserRestoration(to: albumAssets.last?.id, anchor: .bottom)
            }
            return
        }
        if LibraryBrowserPositionStore.systemIsAtBottom(for: libraryID),
           let newestID = albumAssets.last?.id {
            queueBrowserRestoration(to: newestID, anchor: .bottom)
            return
        }
        if let savedID = LibraryBrowserPositionStore.assetID(for: libraryID) {
            guard albumAssets.contains(where: { $0.id == savedID }) else {
                LibraryBrowserPositionStore.remove(for: libraryID)
                queueBrowserRestoration(to: albumAssets.last?.id, anchor: .bottom)
                return
            }
            queueBrowserRestoration(to: savedID, anchor: .center)
        } else {
            // The catalog remains oldest-to-newest; first entry starts at the
            // newest item unless the user has an explicit saved position.
            queueBrowserRestoration(to: albumAssets.last?.id, anchor: .bottom)
        }
    }

    private func queueBrowserRestoration(to targetID: String?, anchor: UnitPoint) {
        pendingRestoreTargetID = targetID
        hasIssuedRestoreScroll = false
        hasQueuedRestoreAfterLayout = false
        hasRestoredScrollPosition = targetID == nil
        queueBrowserScroll(to: targetID, anchor: anchor)
    }

    private var timelineScrollTargetID: String? {
        guard let firstSection = dateSections.first else { return nil }
        return timelineTileID(for: firstSection.id)
    }

    private func timelineTileID(for sectionID: String) -> String {
        "timeline-\(timelineMode.rawValue)-\(sectionID)"
    }

    private func queueBrowserScroll(to targetID: String?, anchor: UnitPoint = .top) {
        browserScrollTargetID = targetID
        browserScrollAnchor = anchor
        browserScrollRequestGeneration &+= 1
    }

    private func timelineCoverAsset(for section: SystemPhotoLibraryDateSection) -> PhotoAssetSummary? {
        if section.id == "unknown" { return section.assets.first }
        return section.assets.max {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
    }

    private func showTimelineDetail(_ section: SystemPhotoLibraryDateSection) {
        selectedTimelineSectionID = section.id
        scrollTracker.reset()
        queueBrowserScroll(to: timelineTargetID(for: section))
    }

    private func hideTimelineDetail() {
        guard let selectedTimelineSectionID else { return }
        self.selectedTimelineSectionID = nil
        scrollTracker.reset()
        queueBrowserScroll(to: timelineTileID(for: selectedTimelineSectionID))
    }

    private func timelineDetailHeader(_ section: SystemPhotoLibraryDateSection) -> some View {
        HStack(spacing: 10) {
            Button {
                hideTimelineDetail()
            } label: {
                Label(timelineMode.rawValue, systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            Text("\(section.title) · \(section.assets.count) \(section.assets.count == 1 ? "Photo" : "Photos")")
                .font(.headline)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .id("timeline-detail-header-\(section.id)")
    }

    private func persistBrowserPosition(allowActiveSearch: Bool = false) {
        guard !isShowingExpandedPhoto,
              timelineMode == .allPhotos,
              hasRestoredScrollPosition,
              pendingRestoreTargetID == nil,
              (allowActiveSearch || searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              let centeredID = scrollTracker.centeredID,
              albumAssets.contains(where: { $0.id == centeredID }) else {
            return
        }
        if let albumID {
            LibraryBrowserPositionStore.saveAlbum(
                assetID: centeredID, for: libraryID, albumID: albumID
            )
        } else {
            LibraryBrowserPositionStore.saveSystem(
                assetID: centeredID,
                isAtBottom: isAtBottom,
                for: libraryID
            )
        }
    }

    private func gridCell(_ asset: PhotoAssetSummary) -> some View {
        let targetSize = CGSize(width: thumbnailSize * 2, height: thumbnailSize * 2)
        return Button { handleGridClick(asset) } label: {
            squareThumbnail(asset, targetSize: targetSize)
                .overlay {
                    if selectedAssetIDs.contains(asset.id) || model.selectedAssetID == asset.id {
                        Rectangle()
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard !currentClickModifiers.contains(.command),
                      !currentClickModifiers.contains(.shift) else { return }
                selectAndExpand(asset)
            }
        )
        .accessibilityLabel(asset.originalFilename.isEmpty ? asset.mediaType.capitalized : asset.originalFilename)
        .accessibilityValue(
            (asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date")
                + (selectedAssetIDs.contains(asset.id) ? ", selected" : "")
        )
    }

    private func timelineCoverCell(_ asset: PhotoAssetSummary, section: SystemPhotoLibraryDateSection) -> some View {
        return Button { showTimelineDetail(section) } label: {
            squareThumbnail(asset, targetSize: nil)
                .overlay(alignment: .bottomLeading) {
                    timelineCoverLabel(section.title)
                }
                .overlay {
                    if model.selectedAssetID == asset.id {
                        Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityValue(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date")
    }

    private func timelineTargetID(for section: SystemPhotoLibraryDateSection) -> String? {
        if section.id == "unknown" { return section.assets.first?.id }
        return section.assets.enumerated().min { lhs, rhs in
            let leftDate = lhs.element.creationDate ?? .distantFuture
            let rightDate = rhs.element.creationDate ?? .distantFuture
            return leftDate == rightDate ? lhs.offset < rhs.offset : leftDate < rightDate
        }?.element.id
    }

    private func timelineCoverLabel(_ label: String) -> some View {
        Text(label)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 2)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private func squareThumbnail(_ asset: PhotoAssetSummary, targetSize: CGSize?) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    let pixelWidth = ceil(geometry.size.width * displayScale)
                    let requestSize = targetSize ?? CGSize(width: pixelWidth, height: pixelWidth)
                    SystemPhotoLibraryThumbnailView(
                        model: model,
                        asset: asset,
                        targetSize: requestSize,
                        requestGeneration: model.thumbnailRequestGeneration,
                        placeholderSystemImage: asset.mediaType == "video" ? "video" : "photo"
                    )
                    .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipped()
    }

    private var photoViewerActions: PhotoViewerActions {
        PhotoViewerActions(
            canOpen: selectedAsset != nil,
            isExpanded: isShowingExpandedPhoto,
            open: showSelectedPhoto,
            close: closeExpandedPhoto
        )
    }

    private var selectedAssetsForTransfer: [PhotoAssetSummary] {
        if selectedAssetIDs.isEmpty {
            return selectedAsset.map { [$0] } ?? []
        }
        return previewAssets.filter { selectedAssetIDs.contains($0.id) }
    }

    private var canDeleteSelectedPhotos: Bool {
        !selectedAssetsForTransfer.isEmpty
            && !isDeletingPhotos
            && !model.isLoading
            && !transferCoordinator.isWorking
            && transferCoordinator.pendingSystemSourceDeletion == nil
            && transferCoordinator.pendingRegisteredSourceDeletion == nil
    }

    private var deleteConfirmationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pendingDeleteAssets.count == 1 ? "Delete Photo?" : "Delete Photos?")
                .font(.title2.bold())
            Text("Delete \(pendingDeleteAssets.count) selected photo\(pendingDeleteAssets.count == 1 ? "" : "s") from the System Photo Library? They will be removed from every album. This app cannot undo the deletion.")
            HStack {
                Spacer()
                Button("Keep Photos", role: .cancel) {
                    showsDeleteConfirmation = false
                }
                Button("Confirm Delete", role: .destructive) {
                    showsDeleteConfirmation = false
                    deleteConfirmedPhotos()
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func requestPhotoDeletion() {
        guard canDeleteSelectedPhotos else { return }
        pendingDeleteAssets = selectedAssetsForTransfer
        isShowingExpandedPhoto = false
        isShowingPhotoPreview = false
        showsDeleteConfirmation = true
    }

    @ViewBuilder
    private var transferDetailsDisclosure: some View {
        if !transferCoordinator.skippedSystemSources.isEmpty
            || !transferCoordinator.copiedWithLimitations.isEmpty
            || !transferCoordinator.deletionWarnings.isEmpty {
            DisclosureGroup("Transfer details") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(transferCoordinator.skippedSystemSources.indices, id: \.self) { index in
                        Text("Skipped: \(transferCoordinator.skippedSystemSources[index])")
                    }
                    ForEach(transferCoordinator.copiedWithLimitations.indices, id: \.self) { index in
                        Text("Copied with limitations: \(transferCoordinator.copiedWithLimitations[index])")
                    }
                    ForEach(transferCoordinator.deletionWarnings.indices, id: \.self) { index in
                        Text("Before deleting: \(transferCoordinator.deletionWarnings[index])")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
    }

    private var photoTransferActions: PhotoTransferActions {
        let canTransfer = !selectedAssetsForTransfer.isEmpty
            && !isShowingTimelineCovers
            && model.authorization.permitsReading
            && !model.isLoading
            && !model.isExporting
            && (selectedAssetIDs.isEmpty ? !model.selectedResources.isEmpty : true)
            && !transferCoordinator.isWorking
            && transferCoordinator.pendingSystemSourceDeletion == nil
            && transferCoordinator.pendingRegisteredSourceDeletion == nil
            && store.activeIndexLibraryID == nil
            && !probe.isWorking
        return PhotoTransferActions(destinations: nonSystemTransferTargets.map { destination in
            let filename = URL(fileURLWithPath: destination.descriptor.metadata.lastKnownPath)
                .lastPathComponent
            return PhotoTransferDestinationAction(
                id: destination.id,
                title: "Copy to \"\(filename)\"",
                help: "Copying and optional source deletion do not open Photos.app. The app checks the destination's saved transfer access when copying. Edited photos use their current appearance; unedited Live Photos retain motion when verified. RAW alternatives, burst grouping, and reversible edits are omitted. Titles, captions, and keywords are verified after copying. Review GPS altitude before source deletion.",
                isEnabled: canTransfer,
                transfer: { transferSelectedAssets(to: destination) }
            )
        })
    }

    private func transferSelectedAssets(to destination: RegisteredLibrary) {
        guard photoTransferActions.destinations.first(where: { $0.id == destination.id })?.isEnabled == true,
              !selectedAssetsForTransfer.isEmpty else { return }
        let assets = selectedAssetsForTransfer
        let preloadedResources = selectedAssetIDs.isEmpty && assets.count == 1
            ? [assets[0].id: model.selectedResources]
            : [:]
        isShowingExpandedPhoto = false
        isShowingPhotoPreview = false
        registrationError = nil
        do {
            try registry.ensureTransferWriteAccess(for: destination.id)
        } catch {
            registrationError = "Copy not started: \(error.localizedDescription)"
            return
        }
        guard let currentDestination = registry.libraries.first(where: { $0.id == destination.id }) else {
            registrationError = "Copy not started: \(destination.descriptor.metadata.displayName) is no longer registered."
            return
        }
        registrationError = nil
        transferCoordinator.transferSystemAssets(
            assets,
            preloadedResources: preloadedResources,
            to: currentDestination,
            registry: registry,
            store: store,
            allowICloudDownload: model.allowICloudDownload
        )
    }

    private func deleteConfirmedPhotos() {
        let assets = pendingDeleteAssets
        pendingDeleteAssets = []
        guard !assets.isEmpty, !isDeletingPhotos else { return }
        pendingDeletedAssetIDs = Set(assets.map(\.id))
        deletionError = nil
        deletionResult = nil
        isDeletingPhotos = true
        Task {
            defer { isDeletingPhotos = false }
            do {
                let expectedDates = Dictionary(uniqueKeysWithValues: assets.map {
                    ($0.id, (
                        creationDate: $0.creationDate,
                        modificationDate: $0.modificationDate
                    ))
                })
                try await SystemPhotoLibraryProvider().deleteAssets(
                    identifiers: assets.map(\.id),
                    expectedDates: expectedDates
                )
                clearMultiSelection()
                model.clearSelectedAsset()
                isShowingExpandedPhoto = false
                isShowingPhotoPreview = false
                deletionResult = "Deleted \(assets.count) photo(s) from the System Photo Library."
            } catch {
                pendingDeletedAssetIDs.removeAll()
                deletionError = "Could not delete the selected photos: \(error.localizedDescription)"
            }
        }
    }

    private var currentClickModifiers: NSEvent.ModifierFlags {
        NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
    }

    private func handleGridClick(_ asset: PhotoAssetSummary) {
        let modifiers = currentClickModifiers
        if modifiers.contains(.shift) {
            selectRange(through: asset, adding: modifiers.contains(.command))
        } else if modifiers.contains(.command) {
            if let selectedAssetID = model.selectedAssetID, selectedAssetIDs.isEmpty {
                selectedAssetIDs.insert(selectedAssetID)
            }
            if !selectedAssetIDs.insert(asset.id).inserted {
                selectedAssetIDs.remove(asset.id)
            }
            selectionAnchorID = asset.id
            model.clearSelectedAsset()
            isPhotoAreaFocused = true
        } else {
            select(asset)
        }
    }

    private func selectRange(through asset: PhotoAssetSummary, adding: Bool) {
        let assets = previewAssets
        guard let end = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        let anchorID = selectionAnchorID ?? model.selectedAssetID ?? asset.id
        let start = assets.firstIndex(where: { $0.id == anchorID }) ?? end
        let rangeIDs = Set(assets[min(start, end)...max(start, end)].map(\.id))
        selectedAssetIDs = adding ? selectedAssetIDs.union(rangeIDs) : rangeIDs
        selectionAnchorID = anchorID
        model.clearSelectedAsset()
        isPhotoAreaFocused = true
    }

    private func clearMultiSelection() {
        selectedAssetIDs.removeAll()
        selectionAnchorID = nil
    }

    private func select(_ asset: PhotoAssetSummary) {
        clearMultiSelection()
        model.selectAsset(asset.id)
        isShowingPhotoPreview = true
        isPhotoAreaFocused = false
    }

    private func selectAndExpand(_ asset: PhotoAssetSummary) {
        clearMultiSelection()
        model.selectAsset(asset.id)
        isShowingPhotoPreview = true
        showSelectedPhoto()
    }

    private var previewAssets: [PhotoAssetSummary] {
        selectedTimelineSection == nil ? filteredAssets : timelineDetailAssets
    }

    private func adjacentAsset(to asset: PhotoAssetSummary, offset: Int) -> PhotoAssetSummary? {
        PhotoSequence.adjacent(in: previewAssets, selectedID: asset.id, offset: offset)
    }

    private func closePhotoPreview() {
        isShowingPhotoPreview = false
        refocusPhotoAreaAfterTransition()
    }

    private func showSelectedPhoto() {
        guard selectedAsset != nil else { return }
        persistBrowserPosition()
        isShowingExpandedPhoto = true
        refocusPhotoAreaAfterTransition()
    }

    private func closeExpandedPhoto() {
        guard isShowingExpandedPhoto else { return }
        isShowingExpandedPhoto = false
        refocusPhotoAreaAfterTransition()
    }

    private func refocusPhotoAreaAfterTransition() {
        isPhotoAreaFocused = false
        Task { @MainActor in
            await Task.yield()
            isPhotoAreaFocused = true
        }
    }

    private func expandedPhoto(_ asset: PhotoAssetSummary) -> some View {
        ExpandedPhotoContainer(
            title: asset.originalFilename.isEmpty ? asset.mediaType.capitalized : asset.originalFilename,
            previous: adjacentAsset(to: asset, offset: -1).map { previous in
                { select(previous) }
            },
            next: adjacentAsset(to: asset, offset: 1).map { next in
                { select(next) }
            },
            close: closeExpandedPhoto
        ) {
            viewerPhoto(asset)
        }
    }

    private func photoPreview(_ asset: PhotoAssetSummary) -> some View {
        PhotoPreviewContainer(
            title: asset.originalFilename.isEmpty ? asset.mediaType.capitalized : asset.originalFilename,
            isVideo: asset.mediaType == "video",
            previous: adjacentAsset(to: asset, offset: -1).map { previous in
                { select(previous) }
            },
            next: adjacentAsset(to: asset, offset: 1).map { next in
                { select(next) }
            },
            expand: showSelectedPhoto,
            close: closePhotoPreview
        ) {
            viewerPhoto(asset)
        } info: {
            inspectorPane
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isPhotoAreaFocused)
        .focusedValue(\.photoViewerActions, photoViewerActions)
        .focusedValue(\.photoTransferActions, photoTransferActions)
        .task(id: asset.id) {
            refocusPhotoAreaAfterTransition()
        }
    }

    private func viewerPhoto(_ asset: PhotoAssetSummary) -> some View {
        Group {
            if asset.mediaType == "video" {
                SystemLibraryVideoPlayer(assetID: asset.id)
            } else if asset.isLivePhoto {
                SystemLivePhotoView(
                    assetID: asset.id,
                    imageSize: CGSize(width: CGFloat(asset.pixelWidth), height: CGFloat(asset.pixelHeight))
                ) {
                    viewerImage(asset)
                }
            } else {
                viewerImage(asset)
            }
        }
    }

    private func viewerImage(_ asset: PhotoAssetSummary) -> some View {
        GeometryReader { proxy in
            let targetSize = SystemPhotoLibraryViewModel.viewerTargetSize(
                for: proxy.size,
                displayScale: displayScale
            )
            Group {
                if let image = model.viewerImages[asset.id] ?? model.thumbnails[asset.id] {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: "\(asset.id):\(Int(targetSize.width))x\(Int(targetSize.height)):g\(model.thumbnailRequestGeneration)") {
                model.requestViewerImage(for: asset, size: targetSize)
            }
        }
        .onDisappear {
            model.cancelViewerImageRequest(for: asset.id)
        }
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let asset = selectedAsset {
                    PhotoInfoPanel(content: .system(
                        asset,
                        libraryName: displayName,
                        textMetadata: model.selectedTextMetadata,
                        textMetadataError: model.selectedTextMetadataError,
                        technicalMetadata: model.selectedTechnicalMetadata,
                        isLoadingTechnicalMetadata: model.isLoadingTechnicalMetadata,
                        place: searchModel.place(libraryID: libraryID, assetID: asset.id),
                        isLocationUnavailable: searchModel.isPlaceUnavailable(
                            libraryID: libraryID,
                            assetID: asset.id
                        )
                    ))

                    Divider()
                    Text("Resources").font(.subheadline.bold())
                    ForEach(model.selectedResources) { resource in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resource.originalFilename)
                            Text("\(resource.type) · \(resource.uniformTypeIdentifier)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Allow iCloud download", isOn: $model.allowICloudDownload)
                    if model.isExporting {
                        ProgressView(
                            value: Double(model.exportProgress?.completedResourceCount ?? 0),
                            total: Double(max(model.exportProgress?.totalResourceCount ?? 1, 1))
                        )
                        Button("Cancel Export", role: .cancel) { model.cancelExport() }
                    } else {
                        Button("Export All Resources to Staging") { model.exportSelectedAsset() }
                    }
                } else {
                    Text("Info").font(.headline)
                    inspectorField("Photos", model.assetCount.formatted())
                    inspectorField("Authorization", model.authorization.rawValue)
                    Text("Select a photo to inspect its metadata and resources.")
                        .foregroundStyle(.secondary)
                }

            }
            .padding(16)
        }
    }

    private func inspectorField(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled)
        }
    }

}

private struct SystemDeleteKeyMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onDelete: () -> Void

    func makeNSView(context: Context) -> SystemDeleteKeyMonitorView {
        SystemDeleteKeyMonitorView()
    }

    func updateNSView(_ view: SystemDeleteKeyMonitorView, context: Context) {
        view.isEnabled = isEnabled
        view.onDelete = onDelete
        view.installMonitorIfNeeded()
    }

    static func dismantleNSView(_ view: SystemDeleteKeyMonitorView, coordinator: ()) {
        view.removeMonitor()
    }
}

private final class SystemDeleteKeyMonitorView: NSView {
    var isEnabled = false
    var onDelete: (() -> Void)?
    private var eventMonitor: Any?

    func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.isEnabled,
                  let window = self.window,
                  event.window === window || event.window?.parent === window,
                  window.attachedSheet == nil,
                  event.keyCode == 51 || event.keyCode == 117,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !(event.window?.firstResponder is NSTextView) else {
                return event
            }
            self.isEnabled = false
            self.onDelete?()
            return nil
        }
    }

    func removeMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct StatusBanner: View {
    let text: String
    let color: Color
    let icon: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .accessibilityHidden(true)
            Text(text)
                .textSelection(.enabled)
                .id(text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
