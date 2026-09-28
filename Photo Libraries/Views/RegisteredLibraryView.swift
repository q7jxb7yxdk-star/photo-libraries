import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum RegisteredLibraryTimelineMode: String, CaseIterable, Identifiable {
    case years = "Years"
    case months = "Months"
    case allPhotos = "All Photos"

    var id: Self { self }
}

private struct RegisteredLibraryDateSection: Identifiable {
    let id: String
    let title: String
    let items: [PhotosAutomationMediaItem]
}

private struct RegisteredBrowserGridRevision: Equatable {
    let libraryID: LibraryID
    let indexedAt: Date?
    let itemCount: Int
    let thumbnailGridRevision: Int
    let albumID: String?
    let searchText: String
    let resolvedPlaceCount: Int
    let timelineMode: RegisteredLibraryTimelineMode
    let selectedTimelineSectionID: String?
    let thumbnailSize: Double
    let selectedItemID: String?
    let selectedItemIDs: Set<String>
    let isDark: Bool
}

struct RegisteredLibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    let registry: LibraryRegistry
    let libraryID: LibraryID
    @ObservedObject var store: LibraryPreviewStore
    @ObservedObject var probe: RegisteredLibraryProbeModel
    @ObservedObject var searchModel: UnifiedSearchViewModel
    @ObservedObject var transferCoordinator: PhotoTransferCoordinator
    let albumID: String?
    let albumTitle: String?

    @State private var showRemoveConfirmation = false
    @State private var isReauthorizing = false
    @State private var registrationError: String?
    @State private var searchText = ""
    // Thumbnail grid column width
    @AppStorage("thumbnail-grid.size") private var thumbnailSize = 130.0
    @State private var timelineMode: RegisteredLibraryTimelineMode = .allPhotos
    @State private var hasRestoredTimelineMode = false
    @State private var selectedTimelineSectionID: String?
    @State private var allPhotosScrollPositionID: String?
    @State private var selectedItemID: String?
    @State private var selectedItemIDs: Set<String> = []
    @State private var selectionAnchorID: String?
    @State private var showsTechnicalDetails = false
    @State private var scrollTracker = LibraryBrowserScrollTracker()
    @State private var browserScrollTargetID: String?
    @State private var browserScrollAnchor: UnitPoint = .top
    @State private var browserScrollRequestGeneration = 0
    @State private var pendingAllPhotosRevealID: String?
    @State private var hasRestoredScrollPosition = false
    @State private var isShowingExpandedPhoto = false
    @State private var isShowingPhotoPreview = false
    @FocusState private var isPhotoAreaFocused: Bool

    private var library: RegisteredLibrary? {
        registry.libraries.first { $0.id == libraryID }
    }

    private var manifest: LibraryPreviewManifest? {
        store.manifest(for: libraryID)
    }

    private var selectedAlbum: PhotosAutomationAlbum? {
        guard let albumID else { return nil }
        return manifest?.albums?.first { $0.id == albumID }
    }

    private var contentTitle: String {
        guard let albumTitle else {
            let items = manifest?.items ?? []
            let videoCount = items.filter {
                UnifiedSearchViewModel.mediaType(for: $0.filename) == "video"
            }.count
            return "\((items.count - videoCount).formatted()) Photos · \(videoCount.formatted()) Videos"
        }
        return albumTitle
    }

    private var albumItems: [PhotosAutomationMediaItem] {
        guard let items = manifest?.items else { return [] }
        guard let albumID else { return items }
        guard let album = manifest?.albums?.first(where: { $0.id == albumID }),
              let memberIDs = album.mediaItemIDs else {
            return []
        }
        let membership = Set(memberIDs)
        return items.filter { membership.contains($0.id) }
    }

    private var filteredItems: [PhotosAutomationMediaItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return albumItems }
        return albumItems.filter { item in
            let place = searchModel.place(libraryID: libraryID, assetID: item.id)
            return item.filename.localizedCaseInsensitiveContains(query)
                || item.name.localizedCaseInsensitiveContains(query)
                || item.itemDescription.localizedCaseInsensitiveContains(query)
                || item.locationDescription.localizedCaseInsensitiveContains(query)
                || place?.searchableText.localizedCaseInsensitiveContains(query) == true
                || item.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var selectedItem: PhotosAutomationMediaItem? {
        guard let selectedItemID else { return nil }
        return albumItems.first { $0.id == selectedItemID }
    }

    private var selectedPhotoCount: Int {
        selectedItemIDs.isEmpty ? (selectedItemID == nil ? 0 : 1) : selectedItemIDs.count
    }

    var body: some View {
        browserPane
            .onAppear {
                guard !hasRestoredTimelineMode else { return }
                hasRestoredTimelineMode = true
                guard albumID == nil else { return }
                if let saved = LibraryBrowserPositionStore.timelineMode(
                    for: "library-\(libraryID.rawValue.uuidString)"
                ), let mode = RegisteredLibraryTimelineMode(rawValue: saved) {
                    timelineMode = mode
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity)
            .background {
                PhotoViewerWindowPresenter(
                    isPresented: isShowingPhotoPreview || isShowingExpandedPhoto,
                    onEscape: isShowingExpandedPhoto ? closeExpandedPhoto : closePhotoPreview,
                    onPrevious: selectedItem.flatMap { adjacentItem(to: $0, offset: -1) }.map { previous in
                        { select(previous) }
                    },
                    onNext: selectedItem.flatMap { adjacentItem(to: $0, offset: 1) }.map { next in
                        { select(next) }
                    }
                ) {
                    if isShowingExpandedPhoto, let item = selectedItem {
                        expandedPhoto(item)
                            .focusable()
                            .focusEffectDisabled()
                            .focused($isPhotoAreaFocused)
                            .focusedValue(\.photoViewerActions, photoViewerActions)
                            .focusedValue(\.photoCopyActions, photoCopyActions)
                    } else if isShowingPhotoPreview, let item = selectedItem {
                        photoPreview(item)
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
                        ForEach(RegisteredLibraryTimelineMode.allCases) { mode in
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

                Button("Refresh Library", systemImage: "arrow.clockwise") {
                    startOpenAndIndex(forceRefresh: true)
                }
                .help("Read the selected library's catalog again")
                .disabled(library?.availability != .online || store.activeIndexLibraryID != nil)

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
        .alert("Remove Registration?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                _ = probe.removeRegistration(
                    libraryID: libraryID,
                    registry: registry,
                    store: store
                )
            }
        } message: {
            Text("This removes the app’s bookmark and app-owned preview cache. It does not delete or modify the Photos library.")
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
        .focusedSceneValue(
            \.libraryMenuActions,
            LibraryMenuActions(
                isIndexing: store.activeIndexLibraryID != nil,
                reauthorize: { isReauthorizing = true },
                removeRegistration: { showRemoveConfirmation = true }
            )
        )
        .focusedSceneValue(\.photoCopyActions, photoCopyActions)
        .task(id: libraryID) {
            startOpenAndIndex(forceRefresh: false)
        }
        .task(id: selectedItemID) {
            guard let item = selectedItem else { return }
            searchModel.requestPlace(
                libraryID: libraryID,
                assetID: item.id,
                rawLocation: item.locationDescription
            )
            await store.loadDirectTechnicalMetadata(for: item.id, libraryID: libraryID)
        }
        .onChange(of: albumID, initial: true) { _, newAlbumID in
            clearMultiSelection()
            if newAlbumID != nil {
                timelineMode = .allPhotos
            } else if let saved = LibraryBrowserPositionStore.timelineMode(
                for: "library-\(libraryID.rawValue.uuidString)"
            ), let mode = RegisteredLibraryTimelineMode(rawValue: saved) {
                timelineMode = mode
            }
            isShowingExpandedPhoto = false
            isShowingPhotoPreview = false
            selectedTimelineSectionID = nil
            scrollTracker.reset()
            hasRestoredScrollPosition = false
            pendingAllPhotosRevealID = nil
            if let selectedItemID,
               !albumItems.contains(where: { $0.id == selectedItemID }) {
                self.selectedItemID = nil
            }
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
            if oldMode == .allPhotos {
                allPhotosScrollPositionID = scrollTracker.centeredID
                    ?? LibraryBrowserPositionStore.assetID(for: libraryID)
            }
            selectedTimelineSectionID = nil
            scrollTracker.reset()
            let savedID = allPhotosScrollPositionID.flatMap { savedID in
                albumItems.contains(where: { $0.id == savedID }) ? savedID : nil
            }
            let targetID = newMode == .allPhotos
                ? savedID ?? albumItems.last?.id
                : timelineScrollTargetID
            pendingAllPhotosRevealID = newMode == .allPhotos ? targetID : nil
            queueBrowserScroll(
                to: targetID,
                anchor: newMode == .allPhotos && savedID == nil ? .bottom : .top
            )
        }
        .onChange(of: searchText) { oldValue, newValue in
            clearMultiSelection()
            // A search can remove the selected date section; return safely to its covers.
            selectedTimelineSectionID = nil
            if let selectedItemID,
               !filteredItems.contains(where: { $0.id == selectedItemID }) {
                self.selectedItemID = nil
            }
            let oldQuery = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let newQuery = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if oldQuery.isEmpty, !newQuery.isEmpty {
                persistBrowserPosition()
            } else if !oldQuery.isEmpty, newQuery.isEmpty {
                if timelineMode == .allPhotos {
                    restoreBrowserPosition(force: true)
                } else {
                    queueBrowserScroll(to: timelineScrollTargetID)
                }
            }
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
        }
        .onChange(of: manifest?.indexedAt) { _, _ in
            let availableIDs = Set(albumItems.map(\.id))
            selectedItemIDs.formIntersection(availableIDs)
            if let selectedItemID, !availableIDs.contains(selectedItemID) {
                self.selectedItemID = nil
            }
            if let selectionAnchorID, !availableIDs.contains(selectionAnchorID) {
                self.selectionAnchorID = nil
            }
            restoreBrowserPosition()
        }
        .onDisappear {
            persistBrowserPosition()
        }
    }

    private var browserPane: some View {
        VStack(spacing: 0) {
            statusArea
            if transferCoordinator.isWorking, let status = transferCoordinator.statusMessage {
                VStack(alignment: .leading, spacing: 8) {
                    StatusBanner(text: status, color: .blue, icon: "arrow.left.arrow.right")
                    if transferCoordinator.copyTotalCount > 0 {
                        ProgressView(
                            value: Double(transferCoordinator.copyCompletedCount),
                            total: Double(transferCoordinator.copyTotalCount)
                        )
                        Button("Cancel Copy") { transferCoordinator.cancel() }
                    }
                }
                .padding(12)
            } else if let error = transferCoordinator.errorMessage {
                StatusBanner(text: error, color: .red, icon: "exclamationmark.triangle.fill")
                    .padding(12)
            } else if let result = transferCoordinator.resultMessage {
                StatusBanner(text: result, color: .blue, icon: "checkmark.circle.fill")
                    .padding(12)
            }
            if !transferCoordinator.copiedWithLimitations.isEmpty {
                DisclosureGroup("Transfer details") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(transferCoordinator.copiedWithLimitations.indices, id: \.self) { index in
                            Text("Copied with limitations: \(transferCoordinator.copiedWithLimitations[index])")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
            }
            if manifest == nil {
                ContentUnavailableView {
                    Label("Reading Library", systemImage: "photo.stack")
                } description: {
                    Text("Reading the selected library directly. Photos does not need to be open.")
                } actions: {
                    Button("Retry Reading Library") {
                        startOpenAndIndex(forceRefresh: true)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if albumID != nil, selectedAlbum?.mediaItemIDs == nil {
                ContentUnavailableView {
                    Label("Album Data Unavailable", systemImage: "rectangle.stack.badge.clock")
                } description: {
                    Text("Refresh this library to read the photos in \(contentTitle).")
                } actions: {
                    Button("Refresh Library") {
                        startOpenAndIndex(forceRefresh: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(library?.availability != .online || store.activeIndexLibraryID != nil)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty,
                      !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty, albumID != nil {
                ContentUnavailableView(
                    "No Photos in This Album",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("\(contentTitle) does not contain any photos or videos.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: "photo.stack",
                    description: Text("This library does not contain any photos or videos.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                photoBrowser
            }
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        if probe.activeLibraryID == libraryID,
           probe.isWaitingForPhotos {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(probe.statusMessage ?? "Waiting for Photos…")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel", role: .cancel) {
                    probe.cancelWaitingForPhotos()
                }
            }
            .padding(12)
        }
        if store.activeIndexLibraryID == libraryID {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16)
                        .accessibilityLabel("Indexing in progress")
                    if store.indexTotalCount > 0 {
                        ProgressView(
                            value: Double(indexProgressCompletedCount),
                            total: Double(indexProgressTotalCount)
                        )
                        .frame(maxWidth: 220)
                    }
                    Spacer(minLength: 0)
                    Button(
                        probe.isCancellingIndex ? "Cancelling…" : "Cancel",
                        role: .cancel
                    ) {
                        store.requestIndexCancellation()
                    }
                    .disabled(probe.isCancellingIndex)
                }
                Text(indexStatusText)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
        if let registrationError {
            StatusBanner(text: registrationError, color: .red, icon: "exclamationmark.triangle.fill")
                .padding(12)
        } else if let directError = probe.directErrors[libraryID] {
            StatusBanner(text: directError, color: .red, icon: "exclamationmark.triangle.fill")
                .padding(12)
        } else if probe.activeLibraryID == libraryID,
                  probe.isWaitingForPreviewRetry {
            StatusBanner(
                text: probe.statusMessage
                    ?? "Photos is temporarily resting. Preview indexing will retry automatically.",
                color: .orange,
                icon: "clock.arrow.circlepath"
            )
            .padding(12)
        } else if probe.activeLibraryID == libraryID,
                  probe.deferredPreviewCount > 0 {
            StatusBanner(
                text: store.activeIndexLibraryID == libraryID
                    ? "\(probe.deferredPreviewCount) previews deferred; continuing with later items."
                    : "\(probe.deferredPreviewCount) previews remain deferred for the next synchronization.",
                color: .orange,
                icon: "clock.arrow.circlepath"
            )
            .padding(12)
        } else if probe.activeLibraryID == libraryID, let error = probe.errorMessage {
            StatusBanner(text: error, color: .red, icon: "exclamationmark.triangle.fill")
                .padding(12)
        } else if probe.activeLibraryID == libraryID,
                  let status = probe.statusMessage,
                  !probe.isIndexing,
                  !probe.isWaitingForPhotos {
            StatusBanner(text: status, color: .blue, icon: "arrow.up.forward.app")
                .padding(12)
        }
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
                                    if let item = timelineCoverItem(for: section) {
                                        timelineCoverCell(item, section: section)
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
                                    ForEach(timelineDetailItems) { item in
                                        gridCell(item).id(item.id)
                                    }
                                }
                            }
                            .scrollTargetLayout()
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 1)],
                                spacing: 1
                            ) {
                                ForEach(filteredItems) { item in
                                    gridCell(item).id(item.id)
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
            .onScrollTargetVisibilityChange(idType: String.self) { identifiers in
                scrollTracker.updateVisibleIDs(identifiers)
                if let pendingAllPhotosRevealID,
                   identifiers.contains(pendingAllPhotosRevealID) {
                    self.pendingAllPhotosRevealID = nil
                }
            }
            .onAppear { restoreBrowserPosition() }
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .interacting {
                    pendingAllPhotosRevealID = nil
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
                let isReveal = pendingAllPhotosRevealID == targetID
                for _ in 0..<(isReveal ? 12 : 1) {
                    guard !Task.isCancelled else { return }
                    if isReveal, pendingAllPhotosRevealID != targetID { return }
                    proxy.scrollTo(targetID, anchor: browserScrollAnchor)
                    guard isReveal else { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if scrollTracker.visibleIDs.contains(targetID) {
                        pendingAllPhotosRevealID = nil
                        return
                    }
                }
                if isReveal, pendingAllPhotosRevealID == targetID {
                    pendingAllPhotosRevealID = nil
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isPhotoAreaFocused)
        .focusedValue(\.photoViewerActions, photoViewerActions)
        .focusedValue(\.photoCopyActions, photoCopyActions)
    }

    private var browserGridRevision: RegisteredBrowserGridRevision {
        RegisteredBrowserGridRevision(
            libraryID: libraryID,
            indexedAt: manifest?.indexedAt,
            itemCount: manifest?.items.count ?? 0,
            thumbnailGridRevision: store.thumbnailGridRevision(for: libraryID),
            albumID: albumID,
            searchText: searchText,
            resolvedPlaceCount: searchText.isEmpty
                ? 0
                : searchModel.placesByDocumentID.count,
            timelineMode: timelineMode,
            selectedTimelineSectionID: selectedTimelineSectionID,
            thumbnailSize: thumbnailSize,
            selectedItemID: selectedItemID,
            selectedItemIDs: selectedItemIDs,
            isDark: colorScheme == .dark
        )
    }

    private var dateSections: [RegisteredLibraryDateSection] {
        guard albumID == nil, timelineMode != .allPhotos else {
            return [RegisteredLibraryDateSection(id: "all", title: "All Photos", items: filteredItems)]
        }

        let calendar = Calendar.current
        var grouped: [String: (title: String, items: [PhotosAutomationMediaItem])] = [:]
        for item in filteredItems {
            guard let date = item.captureDate else {
                var section = grouped["unknown"] ?? ("Unknown Date", [])
                section.items.append(item)
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
            section.items.append(item)
            grouped[key] = section
        }
        return grouped.map { key, value in
            RegisteredLibraryDateSection(id: key, title: value.title, items: value.items)
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

    private var selectedTimelineSection: RegisteredLibraryDateSection? {
        guard let selectedTimelineSectionID else { return nil }
        return dateSections.first { $0.id == selectedTimelineSectionID }
    }

    private var timelineDetailItems: [PhotosAutomationMediaItem] {
        filteredItems.enumerated().sorted { lhs, rhs in
            switch (lhs.element.captureDate, rhs.element.captureDate) {
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
        guard timelineMode == .allPhotos, manifest != nil else { return }
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard force || !hasRestoredScrollPosition else { return }
        hasRestoredScrollPosition = true
        let savedID = albumID.flatMap {
            LibraryBrowserPositionStore.albumAssetID(for: libraryID, albumID: $0)
        } ?? (albumID == nil ? LibraryBrowserPositionStore.assetID(for: libraryID) : nil)
        if let savedID {
            guard albumItems.contains(where: { $0.id == savedID }) else {
                if let albumID {
                    LibraryBrowserPositionStore.removeAlbum(for: libraryID, albumID: albumID)
                } else {
                    LibraryBrowserPositionStore.remove(for: libraryID)
                }
                queueBrowserScroll(to: albumItems.last?.id)
                return
            }
            queueBrowserScroll(to: savedID)
        } else {
            // The catalog remains oldest-to-newest; first entry starts at the
            // newest item unless the user has an explicit saved position.
            queueBrowserScroll(to: albumItems.last?.id)
        }
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

    private func timelineCoverItem(for section: RegisteredLibraryDateSection) -> PhotosAutomationMediaItem? {
        if section.id == "unknown" { return section.items.first }
        return section.items.max {
            ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast)
        }
    }

    private func showTimelineDetail(_ section: RegisteredLibraryDateSection) {
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

    private func timelineDetailHeader(_ section: RegisteredLibraryDateSection) -> some View {
        HStack(spacing: 10) {
            Button {
                hideTimelineDetail()
            } label: {
                Label(timelineMode.rawValue, systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            Text("\(section.title) · \(section.items.count) \(section.items.count == 1 ? "Photo" : "Photos")")
                .font(.headline)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .id("timeline-detail-header-\(section.id)")
    }

    private func persistBrowserPosition() {
        guard !isShowingExpandedPhoto,
              timelineMode == .allPhotos,
              hasRestoredScrollPosition,
              pendingAllPhotosRevealID == nil,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let centeredID = scrollTracker.centeredID,
              albumItems.contains(where: { $0.id == centeredID }) else {
            return
        }
        if let albumID {
            LibraryBrowserPositionStore.saveAlbum(
                assetID: centeredID, for: libraryID, albumID: albumID
            )
        } else {
            LibraryBrowserPositionStore.save(assetID: centeredID, for: libraryID)
        }
    }

    private func gridCell(_ item: PhotosAutomationMediaItem) -> some View {
        let description = item.dateDescription.isEmpty
            ? "\(item.pixelWidth) × \(item.pixelHeight)"
            : item.dateDescription
        return Button { handleGridClick(item) } label: {
            squareThumbnail(item)
                .overlay {
                    if selectedItemIDs.contains(item.id) || selectedItemID == item.id {
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
                selectAndExpand(item)
            }
        )
        .accessibilityLabel(item.name.isEmpty ? item.filename : item.name)
        .accessibilityValue(description + (selectedItemIDs.contains(item.id) ? ", selected" : ""))
    }

    private func timelineCoverCell(_ item: PhotosAutomationMediaItem, section: RegisteredLibraryDateSection) -> some View {
        Button { showTimelineDetail(section) } label: {
            squareThumbnail(item, isTimelineCover: true)
                .overlay(alignment: .bottomLeading) {
                    timelineCoverLabel(section.title)
                }
                .overlay {
                    if selectedItemID == item.id {
                        Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityValue(item.dateDescription.isEmpty ? "Unknown date" : item.dateDescription)
    }

    private func timelineTargetID(for section: RegisteredLibraryDateSection) -> String? {
        if section.id == "unknown" { return section.items.first?.id }
        return section.items.enumerated().min { lhs, rhs in
            let leftDate = lhs.element.captureDate ?? .distantFuture
            let rightDate = rhs.element.captureDate ?? .distantFuture
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

    private func squareThumbnail(_ item: PhotosAutomationMediaItem, isTimelineCover: Bool = false) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    let thumbnailAspectRatio: Double? = item.pixelWidth > 0 && item.pixelHeight > 0
                        ? Double(max(item.pixelWidth, item.pixelHeight))
                            / Double(min(item.pixelWidth, item.pixelHeight))
                        : nil
                    CachedLibraryThumbnailView(
                        store: store,
                        libraryID: libraryID,
                        itemID: item.id,
                        revision: isTimelineCover
                            ? store.viewerPreviewRevision(for: item.id, libraryID: libraryID)
                            : store.thumbnailRevision(for: item.id, libraryID: libraryID),
                        placeholderSystemImage: UnifiedSearchViewModel.mediaType(for: item.filename) == "video" ? "video" : "photo",
                        hasError: manifest?.itemErrors[item.id] != nil,
                        isLivePhoto: store.isDirectLivePhoto(item.id, libraryID: libraryID)
                            || manifest?.livePhotoVideoFilenames?[item.id] != nil,
                        thumbnailPixelSize: isTimelineCover
                            ? nil
                            : max(1, Int(ceil(geometry.size.width * displayScale))),
                        thumbnailAspectRatio: isTimelineCover ? nil : thumbnailAspectRatio,
                        coverPixelSize: isTimelineCover
                            ? Int(ceil(geometry.size.width * displayScale))
                            : nil
                    )
                    .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipped()
    }

    private var photoViewerActions: PhotoViewerActions {
        PhotoViewerActions(
            canOpen: selectedItem != nil,
            isExpanded: isShowingExpandedPhoto,
            open: showSelectedPhoto,
            close: closeExpandedPhoto
        )
    }

    private var itemsSelectedForCopy: [PhotosAutomationMediaItem] {
        let identifiers = selectedItemIDs.isEmpty
            ? Set(selectedItemID.map { [$0] } ?? [])
            : selectedItemIDs
        return previewItems.filter { identifiers.contains($0.id) }
    }

    private var photoCopyActions: PhotoCopyActions {
        PhotoCopyActions(
            canCopyToSystemLibrary: !itemsSelectedForCopy.isEmpty
                && library?.availability == .online
                && store.activeIndexLibraryID == nil
                && !probe.isWaitingForPhotos
                && !probe.isIndexing
                && !probe.isWorking
                && !transferCoordinator.isWorking
                && transferCoordinator.pendingSystemSourceDeletion == nil
                && transferCoordinator.pendingRegisteredSourceDeletion == nil,
            copyToSystemLibrary: copySelectedItemsToSystemLibrary
        )
    }

    private func copySelectedItemsToSystemLibrary() {
        guard photoCopyActions.canCopyToSystemLibrary,
              let library else { return }
        let items = itemsSelectedForCopy
        isShowingExpandedPhoto = false
        isShowingPhotoPreview = false
        var source = library
        if PhotoTransferCoordinator.needsTransferAuthorization(source.descriptor) {
            _ = try? registry.ensureTransferWriteAccess(for: source.id)
            source = registry.libraries.first(where: { $0.id == library.id }) ?? source
        }
        transferCoordinator.copyRegisteredItemsToSystemLibrary(
            items,
            source: source,
            registry: registry,
            store: store
        )
    }

    private var currentClickModifiers: NSEvent.ModifierFlags {
        NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
    }

    private func handleGridClick(_ item: PhotosAutomationMediaItem) {
        let modifiers = currentClickModifiers
        if modifiers.contains(.shift) {
            selectRange(through: item, adding: modifiers.contains(.command))
        } else if modifiers.contains(.command) {
            if let selectedItemID, selectedItemIDs.isEmpty {
                selectedItemIDs.insert(selectedItemID)
            }
            if !selectedItemIDs.insert(item.id).inserted {
                selectedItemIDs.remove(item.id)
            }
            selectionAnchorID = item.id
            selectedItemID = nil
            isPhotoAreaFocused = true
        } else {
            clearMultiSelection()
            select(item)
        }
    }

    private func selectRange(through item: PhotosAutomationMediaItem, adding: Bool) {
        let items = previewItems
        guard let end = items.firstIndex(where: { $0.id == item.id }) else { return }
        let anchorID = selectionAnchorID ?? selectedItemID ?? item.id
        let start = items.firstIndex(where: { $0.id == anchorID }) ?? end
        let rangeIDs = Set(items[min(start, end)...max(start, end)].map(\.id))
        selectedItemIDs = adding ? selectedItemIDs.union(rangeIDs) : rangeIDs
        selectionAnchorID = anchorID
        selectedItemID = nil
        isPhotoAreaFocused = true
    }

    private func clearMultiSelection() {
        selectedItemIDs.removeAll()
        selectionAnchorID = nil
    }

    private func select(_ item: PhotosAutomationMediaItem) {
        selectedItemID = item.id
        isShowingPhotoPreview = true
        isPhotoAreaFocused = false
    }

    private func selectAndExpand(_ item: PhotosAutomationMediaItem) {
        clearMultiSelection()
        selectedItemID = item.id
        isShowingPhotoPreview = true
        showSelectedPhoto()
    }

    private var previewItems: [PhotosAutomationMediaItem] {
        selectedTimelineSection == nil ? filteredItems : timelineDetailItems
    }

    private func adjacentItem(to item: PhotosAutomationMediaItem, offset: Int) -> PhotosAutomationMediaItem? {
        PhotoSequence.adjacent(in: previewItems, selectedID: item.id, offset: offset)
    }

    private func closePhotoPreview() {
        isShowingPhotoPreview = false
        refocusPhotoAreaAfterTransition()
    }

    private func showSelectedPhoto() {
        guard selectedItem != nil else { return }
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

    private func expandedPhoto(_ item: PhotosAutomationMediaItem) -> some View {
        ExpandedPhotoContainer(
            title: item.name.isEmpty ? item.filename : item.name,
            previous: adjacentItem(to: item, offset: -1).map { previous in
                { select(previous) }
            },
            next: adjacentItem(to: item, offset: 1).map { next in
                { select(next) }
            },
            close: closeExpandedPhoto
        ) {
            viewerPhoto(item)
        }
    }

    private func photoPreview(_ item: PhotosAutomationMediaItem) -> some View {
        PhotoPreviewContainer(
            title: item.name.isEmpty ? item.filename : item.name,
            isVideo: UnifiedSearchViewModel.mediaType(for: item.filename) == "video",
            previous: adjacentItem(to: item, offset: -1).map { previous in
                { select(previous) }
            },
            next: adjacentItem(to: item, offset: 1).map { next in
                { select(next) }
            },
            expand: showSelectedPhoto,
            close: closePhotoPreview
        ) {
            viewerPhoto(item)
        } info: {
            inspectorPane
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isPhotoAreaFocused)
        .focusedValue(\.photoViewerActions, photoViewerActions)
        .focusedValue(\.photoCopyActions, photoCopyActions)
        .task(id: item.id) {
            refocusPhotoAreaAfterTransition()
        }
    }

    private func viewerPhoto(_ item: PhotosAutomationMediaItem) -> some View {
        Group {
            if UnifiedSearchViewModel.mediaType(for: item.filename) == "video" {
                RegisteredLibraryVideoPlayer(
                    item: item,
                    libraryID: libraryID,
                    store: store
                )
            } else if store.isDirectLivePhoto(item.id, libraryID: libraryID),
                      let provider = store.directProvider(for: libraryID) {
                DirectRegisteredLivePhotoView(
                    provider: provider, assetID: item.id,
                    imageSize: CGSize(width: CGFloat(item.pixelWidth), height: CGFloat(item.pixelHeight))
                ) {
                    viewerImage(item)
                }
            } else if let videoURL = store.livePhotoVideoURL(for: item.id, libraryID: libraryID) {
                RegisteredLivePhotoView(
                    videoURL: videoURL,
                    imageSize: CGSize(width: CGFloat(item.pixelWidth), height: CGFloat(item.pixelHeight))
                ) {
                    viewerImage(item)
                }
            } else {
                viewerImage(item)
            }
        }
    }

    private func viewerImage(_ item: PhotosAutomationMediaItem) -> some View {
        CachedLibraryThumbnailView(
            store: store,
            libraryID: libraryID,
            itemID: item.id,
            revision: store.viewerPreviewRevision(for: item.id, libraryID: libraryID),
            placeholderSystemImage: "photo",
            hasError: manifest?.itemErrors[item.id] != nil,
            contentMode: .fit,
            prefersViewerPreview: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let item = selectedItem {
                    let place = searchModel.place(libraryID: libraryID, assetID: item.id)
                    PhotoInfoPanel(content: .registered(
                        item,
                        libraryName: library?.descriptor.metadata.displayName ?? "Registered Library",
                        isLivePhoto: store.isDirectLivePhoto(item.id, libraryID: libraryID)
                            || store.livePhotoVideoURL(for: item.id, libraryID: libraryID) != nil,
                        technicalMetadata: store.technicalMetadata(
                            for: item.id,
                            libraryID: libraryID
                        ),
                        videoDuration: store.manifest(for: libraryID)?
                            .playbackVideoDurations?[item.id],
                        place: place,
                        isLocationUnavailable: searchModel.isPlaceUnavailable(
                            libraryID: libraryID,
                            assetID: item.id
                        )
                    ))
                } else if let library {
                    Text("Info").font(.headline)
                    inspectorField("Library", library.descriptor.metadata.displayName)
                    inspectorField("Location", library.descriptor.metadata.lastKnownPath)
                    inspectorField("Availability", library.availability.displayName)
                    if let manifest {
                        inspectorField("Photos", manifest.totalMediaItemCount.formatted())
                        inspectorField("Indexed", manifest.indexedAt.formatted())
                    }
                    Text("Select a photo to inspect its metadata.")
                        .foregroundStyle(.secondary)
                }

                Divider()
                DisclosureGroup("Technical Details", isExpanded: $showsTechnicalDetails) {
                    VStack(alignment: .leading, spacing: 7) {
                        inspectorField("PhotoKit catalog", "System Library only")
                        inspectorField("Non-system access", "Photos Automation + cached previews")
                        inspectorField("Private database writes", "Never")
                        inspectorField("System Library setting", "Never changed")
                    }
                    .padding(.top, 8)
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

    private func isComplete(_ manifest: LibraryPreviewManifest) -> Bool {
        manifest.isComplete && manifest.items.count >= manifest.totalMediaItemCount
    }

    private func startOpenAndIndex(forceRefresh: Bool) {
        guard let library, library.availability == .online else { return }
        probe.loadDirectCatalog(
            registry: registry, libraryID: libraryID, store: store,
            forceRefresh: forceRefresh
        )
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

    private var indexPhaseTitle: String {
        switch store.indexPhase {
        case .readingCatalog:
            "Reading catalog"
        case .generatingPreviews:
            "Generating previews"
        case .enrichingMetadata:
            "Enriching metadata"
        case .generatingPlaybackVideos:
            "Preparing videos"
        case .checkingLivePhotos:
            "Checking Live Photos"
        case nil:
            "Indexing"
        }
    }

    private var indexProgressText: String {
        guard store.indexTotalCount > 0 else {
            return "Preparing catalog…"
        }
        if store.indexPhase == .generatingPreviews {
            let thumbnails = min(manifest?.thumbnailFilenames.count ?? 0, store.indexTotalCount)
            let viewerPreviews = min(manifest?.viewerPreviewFilenames?.count ?? 0, store.indexTotalCount)
            return "Generating previews · Thumbnails \(thumbnails) / \(store.indexTotalCount) · Viewer Previews \(viewerPreviews) / \(store.indexTotalCount)"
        }
        return "\(indexPhaseTitle) \(store.indexCompletedCount) / \(store.indexTotalCount)"
    }

    private var indexProgressCompletedCount: Int {
        guard store.indexPhase == .generatingPreviews else {
            return store.indexCompletedCount
        }
        return min(manifest?.thumbnailFilenames.count ?? 0, store.indexTotalCount)
            + min(manifest?.viewerPreviewFilenames?.count ?? 0, store.indexTotalCount)
    }

    private var indexProgressTotalCount: Int {
        store.indexPhase == .generatingPreviews
            ? store.indexTotalCount * 2
            : store.indexTotalCount
    }

    private var indexStatusText: String {
        let detail: String
        switch store.indexPhase {
        case .readingCatalog:
            detail = "Photos reads the catalog in bulk; progress advances for each item returned."
        case .generatingPreviews:
            detail = probe.isCancellingIndex
                ? "Photos is finishing the current export batch before stopping."
                : "All photos are listed; previews export in batches, and each completed thumbnail appears immediately."
        case .enrichingMetadata:
            detail = "Captions, keywords, locations, and file sizes are read in bulk and published one item at a time."
        case .generatingPlaybackVideos:
            detail = "Videos are converted to MP4 for playback in the app and Web Gallery."
        case .checkingLivePhotos:
            detail = "Photos is identifying motion clips and caching playable Live Photos."
        case nil:
            return indexProgressText
        }
        return "\(indexProgressText) · \(detail)"
    }
}
