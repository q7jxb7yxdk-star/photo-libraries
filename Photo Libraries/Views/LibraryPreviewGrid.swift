import SwiftUI

struct LibraryPreviewGrid: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: LibraryPreviewStore
    let libraryIDs: [LibraryID]
    var showsLibraryName = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 1)]

    private var entries: [Entry] {
        libraryIDs.flatMap { libraryID -> [Entry] in
            guard let manifest = store.manifest(for: libraryID) else { return [] }
            return manifest.items.map {
                Entry(
                    libraryID: libraryID,
                    libraryName: manifest.libraryDisplayName,
                    item: $0,
                    thumbnailFilename: store.thumbnailRevision(for: $0.id, libraryID: libraryID),
                    error: manifest.itemErrors[$0.id],
                    isLivePhoto: store.isDirectLivePhoto($0.id, libraryID: libraryID)
                        || manifest.livePhotoVideoFilenames?[$0.id] != nil
                )
            }
        }
    }

    var body: some View {
        CachedPreviewGridContent(revision: gridRevision) {
            let entries = entries
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Photos Available",
                    systemImage: "photo.stack",
                    description: Text("Select or refresh a registered library to read its photos directly.")
                )
            } else {
                LazyVGrid(columns: columns, spacing: 1) {
                    ForEach(entries) { entry in
                        Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            CachedLibraryThumbnailView(
                                store: store,
                                libraryID: entry.libraryID,
                                itemID: entry.item.id,
                                revision: entry.thumbnailFilename,
                                placeholderSystemImage: UnifiedSearchViewModel.mediaType(for: entry.item.filename) == "video" ? "video" : "photo",
                                hasError: entry.error != nil,
                                isLivePhoto: entry.isLivePhoto
                            )
                            .equatable()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .clipped()
                        .accessibilityLabel(entry.item.name.isEmpty ? entry.item.filename : entry.item.name)
                        .accessibilityValue(showsLibraryName ? entry.libraryName : "\(entry.item.pixelWidth) × \(entry.item.pixelHeight)")
                    }
                }
                .padding(1)
                .background(colorScheme == .dark ? Color.black : Color.white)
            }
        }
        .equatable()
    }

    private var gridRevision: String {
        let libraryRevisions = libraryIDs.map { libraryID in
            let manifest = store.manifest(for: libraryID)
            return "\(libraryID.rawValue.uuidString):\(manifest?.indexedAt.timeIntervalSinceReferenceDate ?? 0):\(manifest?.items.count ?? 0):\(store.thumbnailGridRevision(for: libraryID))"
        }.joined(separator: "|")
        return "\(libraryRevisions):\(showsLibraryName):\(colorScheme == .dark)"
    }
}

private extension LibraryPreviewGrid {
    struct Entry: Identifiable {
        let libraryID: LibraryID
        let libraryName: String
        let item: PhotosAutomationMediaItem
        let thumbnailFilename: String?
        let error: String?
        let isLivePhoto: Bool

        var id: String { "\(libraryID.rawValue.uuidString):\(item.id)" }
    }
}

private enum AllLibrariesTimelineMode: String, CaseIterable, Identifiable {
    case years = "Years"
    case months = "Months"
    case allPhotos = "All Photos"

    var id: Self { self }
}

private struct AllLibrariesDateSection: Identifiable {
    let id: String
    let title: String
    let entries: [AllLibrariesPhotoEntry]
}

struct AllLibrariesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var registry: LibraryRegistry
    @ObservedObject var store: LibraryPreviewStore
    @ObservedObject var systemModel: SystemPhotoLibraryViewModel
    @ObservedObject var probe: RegisteredLibraryProbeModel
    @ObservedObject var searchModel: UnifiedSearchViewModel
    var mediaCategory: MediaCategory? = nil
    private var showsVideosOnly: Bool { mediaCategory == .videos }
    private var browserTitle: String { mediaCategory?.title ?? "All Libraries" }
    private var itemLabel: String { mediaCategory == nil ? "photos and videos" : browserTitle.lowercased() }
    @State private var allPhotoEntries: [AllLibrariesPhotoEntry] = []
    @State private var allPhotoEntriesGeneration = 0
    // Thumbnail grid column width
    @AppStorage("thumbnail-grid.size") private var thumbnailSize = 130.0
    @State private var timelineMode: AllLibrariesTimelineMode = .allPhotos
    @State private var hasRestoredTimelineMode = false
    @State private var selectedTimelineSectionID: String?
    @State private var allPhotosScrollPositionID: String?
    @State private var allPhotosWasAtBottom = false
    @State private var scrollTracker = LibraryBrowserScrollTracker()
    @State private var browserScrollTargetID: String?
    @State private var browserScrollAnchor: UnitPoint = .center
    @State private var browserScrollRequestGeneration = 0
    @State private var pendingAllPhotosRevealID: String?
    @State private var hasRestoredScrollPosition = false
    @State private var isAtBottom = false
    @State private var restoreBottomUntilInteraction = false
    @State private var isBrowserVisible = false
    @State private var selectedPhoto: AllLibrariesPhotoReference?
    @State private var expandedPhoto: AllLibrariesPhotoReference?
    @State private var isShowingPhotoPreview = false
    @FocusState private var isPhotoAreaFocused: Bool

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSize), spacing: 1)]
    }

    private var indexedLibraryIDs: [LibraryID] {
        registry.libraries.compactMap { library in
            guard !library.descriptor.kind.isSystemPhotoLibrary else { return nil }
            return store.manifest(for: library.id) == nil ? nil : library.id
        }
    }

    private var manifestCatalogRevisions: [ManifestCatalogRevision] {
        registry.libraries.compactMap { library in
            guard !library.descriptor.kind.isSystemPhotoLibrary,
                  let manifest = store.manifest(for: library.id) else {
                return nil
            }
            return ManifestCatalogRevision(
                libraryID: library.id,
                indexedAt: manifest.indexedAt,
                itemCount: manifest.items.count
            )
        }
    }

    private var allPhotoGridRevision: String {
        let thumbnailRevisions = store.manifests.keys.map { libraryID in
            "\(libraryID.rawValue.uuidString):\(store.thumbnailGridRevision(for: libraryID))"
        }.sorted().joined(separator: "|")
        return "\(allPhotoEntriesGeneration):\(thumbnailRevisions):\(selectedPhoto?.id ?? ""):\(systemModel.thumbnailRequestGeneration):\(thumbnailSize):\(timelineMode.rawValue):\(selectedTimelineSectionID ?? ""):\(mediaCategory?.rawValue ?? "all")"
    }

    private var mediaCountTitle: String {
        if mediaCategory != nil {
            return "\(allPhotoEntries.count.formatted()) \(browserTitle)"
        }
        let videoCount = allPhotoEntries.reduce(into: 0) { count, entry in
            switch entry.source {
            case .system(let asset):
                if asset.mediaType == "video" { count += 1 }
            case .registered(_, let item):
                if UnifiedSearchViewModel.mediaType(for: item.filename) == "video" { count += 1 }
            }
        }
        return "\((allPhotoEntries.count - videoCount).formatted()) Photos · \(videoCount.formatted()) Videos"
    }

    private var visibleSearchResults: [UnifiedSearchDocument] {
        guard mediaCategory != nil else { return searchModel.results }
        let visibleIDs = Set(allPhotoEntries.map { entry -> String in
            switch entry.source {
            case .system(let asset): return "system:\(asset.id)"
            case .registered(let libraryID, let item):
                return "\(libraryID.rawValue.uuidString):\(item.id)"
            }
        })
        return searchModel.results.filter { document in
            let key = document.source == .systemPhotoLibrary
                ? "system:\(document.assetID)"
                : "\(document.libraryID.rawValue.uuidString):\(document.assetID)"
            return visibleIDs.contains(key)
        }
    }

    private var savedBrowserAssetID: String? {
        switch mediaCategory {
        case .some(.videos): LibraryBrowserPositionStore.videosAssetID
        case nil: LibraryBrowserPositionStore.allLibrariesAssetID
        default: nil
        }
    }

    private var savedBrowserIsAtBottom: Bool {
        switch mediaCategory {
        case .some(.videos): LibraryBrowserPositionStore.videosIsAtBottom
        case nil: LibraryBrowserPositionStore.allLibrariesIsAtBottom
        default: false
        }
    }

    var body: some View {
        ZStack {
            ScrollViewReader { proxy in
                ScrollView {
                    browserContent
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollTargetVisibilityChange(idType: String.self) { identifiers in
                    scrollTracker.updateVisibleIDs(identifiers)
                    if let pendingAllPhotosRevealID,
                       identifiers.contains(pendingAllPhotosRevealID) {
                        self.pendingAllPhotosRevealID = nil
                    }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 2
                } action: { _, atBottom in
                    isAtBottom = atBottom
                }
                .onScrollPhaseChange { _, newPhase in
                    if newPhase == .interacting {
                        restoreBottomUntilInteraction = false
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            PhotoViewerWindowPresenter(
                isPresented: isShowingPhotoPreview || expandedPhoto != nil,
                onEscape: expandedPhoto == nil ? closePhotoPreview : closeExpandedPhoto,
                onPrevious: (expandedPhoto ?? selectedPhoto).flatMap { adjacentPhoto(to: $0, offset: -1) }.map { previous in
                    { navigate(to: previous) }
                },
                onNext: (expandedPhoto ?? selectedPhoto).flatMap { adjacentPhoto(to: $0, offset: 1) }.map { next in
                    { navigate(to: next) }
                }
            ) {
                if let expandedPhoto {
                    expandedPhotoView(expandedPhoto)
                } else if isShowingPhotoPreview, let selectedPhoto {
                    photoPreview(selectedPhoto)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isPhotoAreaFocused)
        .focusedValue(\.photoViewerActions, photoViewerActions)
        .navigationTitle(mediaCountTitle)
        .searchable(
            text: $searchModel.query,
            placement: .toolbar,
            prompt: mediaCategory.map { "Search \($0.title.lowercased())" } ?? "Search all libraries"
        )
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

                Picker("Library View", selection: $timelineMode) {
                    ForEach(AllLibrariesTimelineMode.allCases) { mode in
                        Text(mediaCategory != nil && mode == .allPhotos ? "All \(browserTitle)" : mode.rawValue)
                            .tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 235)
            }
        }
        .onAppear {
            isBrowserVisible = true
            if !hasRestoredTimelineMode {
                hasRestoredTimelineMode = true
                let identifier = mediaCategory?.rawValue ?? "all-libraries"
                if let saved = LibraryBrowserPositionStore.timelineMode(for: identifier),
                   let mode = AllLibrariesTimelineMode(rawValue: saved) {
                    timelineMode = mode
                }
            }
            restoreBottomUntilInteraction = savedBrowserIsAtBottom
            systemModel.refreshAuthorizationStatus()
            if systemModel.authorization.permitsReading && systemModel.assets.isEmpty {
                systemModel.loadLibrary()
            }
            searchModel.bootstrap(
                registry: registry,
                store: store,
                systemModel: systemModel
            )
            rebuildAllPhotoEntries()
            restoreBrowserPosition()
        }
        .onChange(of: manifestCatalogRevisions) { _, _ in
            rebuildAllPhotoEntries()
        }
        .onReceive(systemModel.$assets) { assets in
            rebuildAllPhotoEntries(systemAssets: assets)
        }
        .onChange(of: timelineMode) { oldMode, newMode in
            guard oldMode != newMode else { return }
            if hasRestoredTimelineMode {
                LibraryBrowserPositionStore.saveTimelineMode(
                    newMode.rawValue, for: mediaCategory?.rawValue ?? "all-libraries"
                )
            }
            clearPhotoSelection()
            if oldMode == .allPhotos {
                allPhotosScrollPositionID = scrollTracker.centeredID
                    ?? savedBrowserAssetID
                allPhotosWasAtBottom = isAtBottom || restoreBottomUntilInteraction
            }
            selectedTimelineSectionID = nil
            scrollTracker.reset()
            if newMode == .allPhotos {
                let savedID = allPhotosScrollPositionID.flatMap { savedID in
                    allPhotoEntries.contains(where: { $0.id == savedID }) ? savedID : nil
                }
                let targetID = allPhotosWasAtBottom
                    ? allPhotoEntries.last?.id
                    : savedID ?? allPhotoEntries.last?.id
                pendingAllPhotosRevealID = targetID
                queueBrowserScroll(
                    to: targetID,
                    anchor: allPhotosWasAtBottom ? .bottom : .center
                )
            } else {
                pendingAllPhotosRevealID = nil
                restoreBottomUntilInteraction = false
                queueBrowserScroll(to: timelineScrollTargetID, anchor: .top)
            }
        }
        .onChange(of: dateSections.map(\.id)) { _, sectionIDs in
            guard let selectedTimelineSectionID,
                  !sectionIDs.contains(selectedTimelineSectionID) else { return }
            self.selectedTimelineSectionID = nil
            scrollTracker.reset()
            queueBrowserScroll(to: timelineScrollTargetID, anchor: .top)
        }
        .onChange(of: searchModel.query) { oldValue, newValue in
            clearPhotoSelection()
            selectedTimelineSectionID = nil
            let oldQuery = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let newQuery = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if oldQuery.isEmpty, !newQuery.isEmpty {
                persistBrowserPosition()
            } else if !oldQuery.isEmpty, newQuery.isEmpty {
                if timelineMode == .allPhotos {
                    restoreBrowserPosition(force: true)
                } else {
                    queueBrowserScroll(to: timelineScrollTargetID, anchor: .top)
                }
            }
        }
        .onChange(of: visibleSearchResults) { _, results in
            guard !searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let selectedPhoto,
                  !results.contains(where: { $0.id == selectedPhoto.id }) else {
                return
            }
            clearPhotoSelection()
        }
        .onDisappear {
            persistBrowserPosition()
            isBrowserVisible = false
        }
    }

    private var browserContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                Text(browserTitle)
                    .font(.title2.bold())
                Text(mediaCategory == nil
                    ? "The System Photo Library and cached previews from \(indexedLibraryIDs.count) registered libraries are shown together below."
                    : mediaCategory?.includesRegisteredLibraries == true
                        ? "Classified items from the System Photo Library and \(indexedLibraryIDs.count) indexed non-system libraries are shown below."
                        : "This category uses System Photo Library classifications. Non-system libraries do not currently provide a verified classification for it.")
                    .foregroundStyle(.secondary)
                if probe.isWaitingForPreviewRetry {
                    StatusBanner(
                        text: probe.statusMessage
                            ?? "Photos is temporarily resting. Preview indexing will retry automatically.",
                        color: .orange,
                        icon: "clock.arrow.circlepath"
                    )
                } else if probe.deferredPreviewCount > 0 {
                    StatusBanner(
                        text: store.activeIndexLibraryID == probe.activeLibraryID
                            ? "\(probe.deferredPreviewCount) previews deferred; continuing with later items."
                            : "\(probe.deferredPreviewCount) previews remain deferred for the next synchronization.",
                        color: .orange,
                        icon: "clock.arrow.circlepath"
                    )
                }
                if let activeID = store.activeIndexLibraryID {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Indexing in progress")
                            if store.indexTotalCount > 0 {
                                ProgressView(
                                    value: Double(indexProgressCompletedCount(for: activeID)),
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
                        Text(indexStatusText(for: activeID))
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            if searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                unifiedLibrarySection
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    HStack {
                        Text("Search Results").font(.headline)
                        Spacer()
                        if searchModel.isSearching { ProgressView().controlSize(.small) }
                        Text("\(visibleSearchResults.count.formatted()) matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Filters: favorite:true · date:2026-09-21 · year:2026 · type:video · width:>=4000 · dimensions:4032x3024 · library:\"Name\" · city:\"Hong Kong\"")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let error = searchModel.errorMessage {
                        StatusBanner(
                            text: error,
                            color: .red,
                            icon: "exclamationmark.triangle.fill"
                        )
                    } else if visibleSearchResults.isEmpty, !searchModel.isSearching {
                        ContentUnavailableView.search(text: searchModel.query)
                    } else if mediaCategory == .panoramas {
                        panoramaSearchResults
                    } else {
                        UnifiedSearchResultsView(
                            results: visibleSearchResults,
                            store: store,
                            systemModel: systemModel,
                            selectedDocumentID: selectedPhoto?.id,
                            onSelect: selectSearchDocument,
                            onOpen: selectAndExpandSearchDocument
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .padding(.bottom, 1)
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

    private var progressTitle: String {
        if store.indexPhase == .readingCatalog, store.indexTotalCount == 0 {
            return "Preparing catalog…"
        }
        return indexPhaseTitle
    }

    private func indexStatusText(for libraryID: LibraryID) -> String {
        let name = registry.libraries.first { $0.id == libraryID }?.descriptor.metadata.displayName ?? "Library"
        let progress: String
        if store.indexPhase == .generatingPreviews, store.indexTotalCount > 0 {
            let manifest = store.manifest(for: libraryID)
            let thumbnails = min(manifest?.thumbnailFilenames.count ?? 0, store.indexTotalCount)
            let viewerPreviews = min(manifest?.viewerPreviewFilenames?.count ?? 0, store.indexTotalCount)
            progress = " · Thumbnails \(thumbnails) / \(store.indexTotalCount) · Viewer Previews \(viewerPreviews) / \(store.indexTotalCount)"
        } else if store.indexTotalCount > 0 {
            progress = " \(store.indexCompletedCount) / \(store.indexTotalCount)"
        } else {
            progress = ""
        }
        let detail: String
        switch store.indexPhase {
        case .readingCatalog:
            detail = "Photos reads the catalog in bulk; progress advances for each item returned."
        case .generatingPreviews:
            detail = probe.isCancellingIndex
                ? "Photos is finishing the current export batch before stopping."
                : "The catalog is available; previews export in batches, and each completed thumbnail appears immediately."
        case .enrichingMetadata:
            detail = "Captions, keywords, locations, and file sizes are read in bulk and published one item at a time."
        case .generatingPlaybackVideos:
            detail = "Videos are converted to MP4 for playback in the app and Web Gallery."
        case .checkingLivePhotos:
            detail = "Photos is identifying motion clips and caching playable Live Photos."
        case nil:
            return "\(progressTitle) \(name)\(progress)"
        }
        return "\(progressTitle) \(name)\(progress) · \(detail)"
    }

    private func indexProgressCompletedCount(for libraryID: LibraryID) -> Int {
        guard store.indexPhase == .generatingPreviews else {
            return store.indexCompletedCount
        }
        let manifest = store.manifest(for: libraryID)
        return min(manifest?.thumbnailFilenames.count ?? 0, store.indexTotalCount)
            + min(manifest?.viewerPreviewFilenames?.count ?? 0, store.indexTotalCount)
    }

    private var indexProgressTotalCount: Int {
        store.indexPhase == .generatingPreviews
            ? store.indexTotalCount * 2
            : store.indexTotalCount
    }

    private var unifiedLibrarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                HStack {
                    Text(timelineMode == .allPhotos
                        ? (mediaCategory == nil ? "All Photos" : "All \(browserTitle)")
                        : timelineMode.rawValue)
                        .font(.headline)
                    Spacer()
                    Text("\(allPhotoEntries.count.formatted()) \(itemLabel)"
                        + (timelineMode == .allPhotos ? " · oldest to newest" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !systemModel.authorization.permitsReading {
                    Button("Request System Photo Library Access") {
                        Task { await systemModel.requestAccessAndLoad() }
                    }
                }
            }
            .padding(.horizontal, 24)

            if allPhotoEntries.isEmpty {
                ContentUnavailableView(
                    mediaCategory.map { "No \($0.title) Available" } ?? "No Photos Available",
                    systemImage: mediaCategory?.symbol ?? "photo.stack",
                    description: Text(mediaCategory == nil
                        ? "Authorize the System Photo Library or index a registered library to show its photos here."
                        : "Authorize the System Photo Library or index a registered library to show classified items here.")
                )
            } else {
                CachedPreviewGridContent(revision: allPhotoGridRevision) {
                    Group {
                        if isShowingTimelineCovers {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 4),
                                spacing: 1
                            ) {
                                ForEach(dateSections) { section in
                                    if let entry = timelineCoverEntry(for: section) {
                                        timelineCoverCell(entry, section: section)
                                            .id(timelineTileID(for: section.id))
                                    }
                                }
                            }
                            .scrollTargetLayout()
                        } else if let section = selectedTimelineSection {
                            VStack(alignment: .leading, spacing: 10) {
                                timelineDetailHeader(section)
                                if mediaCategory == .panoramas {
                                    panoramaList(allPhotoEntries)
                                } else {
                                    LazyVGrid(columns: columns, spacing: 1) {
                                        ForEach(allPhotoEntries) { entry in
                                            allPhotoCell(entry).id(entry.id)
                                        }
                                    }
                                }
                            }
                            .scrollTargetLayout()
                        } else if mediaCategory == .panoramas {
                            panoramaList(allPhotoEntries)
                                .scrollTargetLayout()
                        } else {
                            LazyVGrid(columns: columns, spacing: 1) {
                                ForEach(allPhotoEntries) { entry in
                                    allPhotoCell(entry).id(entry.id)
                                }
                            }
                            .scrollTargetLayout()
                        }
                    }
                }
                .equatable()
                .id("\(mediaCategory?.rawValue ?? "all-libraries")-\(timelineMode.rawValue)-\(selectedTimelineSectionID ?? "covers")")
                .padding(1)
                .background(colorScheme == .dark ? Color.black : Color.white)
            }

            if let error = systemModel.errorMessage {
                StatusBanner(text: error, color: .red, icon: "exclamationmark.triangle.fill")
                    .padding(.horizontal, 24)
            }
        }
    }

    @ViewBuilder
    private func allPhotoCell(_ entry: AllLibrariesPhotoEntry) -> some View {
        Button { select(entry) } label: {
            squareThumbnail(entry)
                .overlay {
                    if selectedPhoto?.id == entry.id {
                        Rectangle()
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .clipped()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.displayName)
        .accessibilityValue("\(entry.libraryName), \(entry.dateText), \(entry.dimensions)")
    }

    private func panoramaList(_ entries: [AllLibrariesPhotoEntry]) -> some View {
        LazyVStack(spacing: 16) {
            ForEach(entries) { entry in
                panoramaRow(entry, selectedID: entry.id) {
                    select(entry)
                }
                .id(entry.id)
            }
        }
        .padding(.horizontal, 24)
    }

    private var panoramaSearchResults: some View {
        let entriesByID = Dictionary(uniqueKeysWithValues: allPhotoEntries.map { ($0.id, $0) })
        return LazyVStack(spacing: 16) {
            ForEach(visibleSearchResults) { document in
                let entryID = document.source == .systemPhotoLibrary
                    ? "system:\(document.assetID)"
                    : "\(document.libraryID.rawValue.uuidString):\(document.assetID)"
                if let entry = entriesByID[entryID] {
                    panoramaRow(entry, selectedID: document.id) {
                        selectSearchDocument(document)
                    }
                }
            }
        }
    }

    private func panoramaRow(
        _ entry: AllLibrariesPhotoEntry,
        selectedID: String,
        onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            Color.clear
                .frame(height: 235)
                .overlay {
                    GeometryReader { geometry in
                        panoramaThumbnail(entry, size: geometry.size)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    if selectedPhoto?.id == selectedID {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.displayName)
        .accessibilityValue("\(entry.libraryName), \(entry.dateText), \(entry.dimensions)")
    }

    @ViewBuilder
    private func panoramaThumbnail(_ entry: AllLibrariesPhotoEntry, size: CGSize) -> some View {
        switch entry.source {
        case .system(let asset):
            let targetSize = CGSize(
                width: min(4_096, ceil(size.width * displayScale)),
                height: min(4_096, ceil(size.height * displayScale))
            )
            SystemPhotoLibraryThumbnailView(
                model: systemModel,
                asset: asset,
                targetSize: targetSize,
                requestGeneration: systemModel.thumbnailRequestGeneration,
                placeholderSystemImage: "photo",
                showsMediaBadge: false
            )
            .equatable()
        case .registered(let libraryID, let item):
            CachedLibraryThumbnailView(
                store: store,
                libraryID: libraryID,
                itemID: item.id,
                revision: store.viewerPreviewRevision(for: item.id, libraryID: libraryID),
                placeholderSystemImage: "photo",
                hasError: store.manifest(for: libraryID)?.itemErrors[item.id] != nil,
                contentMode: .fill,
                prefersViewerPreview: true,
                showsMediaBadge: false
            )
            .equatable()
        }
    }

    private func squareThumbnail(_ entry: AllLibrariesPhotoEntry, isTimelineCover: Bool = false) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    Group {
                        switch entry.source {
                        case .system(let asset):
                            let pixelWidth = ceil(geometry.size.width * displayScale)
                            let side = isTimelineCover
                                ? pixelWidth : max(300, thumbnailSize * displayScale)
                            SystemPhotoLibraryThumbnailView(
                                model: systemModel,
                                asset: asset,
                                targetSize: CGSize(width: side, height: side),
                                requestGeneration: systemModel.thumbnailRequestGeneration,
                                placeholderSystemImage: asset.mediaType == "video" ? "video" : "photo"
                            )
                            .equatable()

                        case .registered(let libraryID, let item):
                            let manifest = store.manifest(for: libraryID)
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
                                coverPixelSize: isTimelineCover
                                    ? Int(ceil(geometry.size.width * displayScale))
                                    : nil
                            )
                            .equatable()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipped()
    }

    private var dateSections: [AllLibrariesDateSection] {
        guard timelineMode != .allPhotos else { return [] }

        let calendar = Calendar.current
        var grouped: [String: (title: String, entries: [AllLibrariesPhotoEntry])] = [:]
        for entry in allPhotoEntries {
            guard let date = entry.date else {
                var section = grouped["unknown"] ?? ("Unknown Date", [])
                section.entries.append(entry)
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
            section.entries.append(entry)
            grouped[key] = section
        }
        return grouped.map { key, value in
            AllLibrariesDateSection(id: key, title: value.title, entries: value.entries)
        }
        .sorted { lhs, rhs in
            if lhs.id == "unknown" { return false }
            if rhs.id == "unknown" { return true }
            return lhs.id > rhs.id
        }
    }

    private var isShowingTimelineCovers: Bool {
        timelineMode != .allPhotos && selectedTimelineSectionID == nil
    }

    private var selectedTimelineSection: AllLibrariesDateSection? {
        guard let selectedTimelineSectionID else { return nil }
        return dateSections.first { $0.id == selectedTimelineSectionID }
    }

    private var timelineScrollTargetID: String? {
        guard let section = dateSections.first else { return nil }
        return timelineTileID(for: section.id)
    }

    private func timelineTileID(for sectionID: String) -> String {
        "timeline-\(timelineMode.rawValue)-\(sectionID)"
    }

    private func timelineCoverEntry(for section: AllLibrariesDateSection) -> AllLibrariesPhotoEntry? {
        section.id == "unknown" ? section.entries.first : section.entries.last
    }

    private func timelineCoverCell(
        _ entry: AllLibrariesPhotoEntry,
        section: AllLibrariesDateSection
    ) -> some View {
        Button { showTimelineDetail(section) } label: {
            squareThumbnail(entry, isTimelineCover: true)
                .overlay(alignment: .bottomLeading) {
                    Text(section.title)
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityValue("\(section.entries.count) \(itemLabel)")
    }

    private func showTimelineDetail(_ section: AllLibrariesDateSection) {
        selectedTimelineSectionID = section.id
        scrollTracker.reset()
        queueBrowserScroll(to: section.entries.first?.id, anchor: .top)
    }

    private func hideTimelineDetail() {
        guard let selectedTimelineSectionID else { return }
        self.selectedTimelineSectionID = nil
        scrollTracker.reset()
        queueBrowserScroll(to: timelineTileID(for: selectedTimelineSectionID), anchor: .top)
    }

    private func timelineDetailHeader(_ section: AllLibrariesDateSection) -> some View {
        HStack(spacing: 10) {
            Button { hideTimelineDetail() } label: {
                Label(mediaCategory != nil && timelineMode == .allPhotos
                    ? "All \(browserTitle)" : timelineMode.rawValue, systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            Text("\(section.title) · \(section.entries.count) \(itemLabel)")
                .font(.headline)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var photoViewerActions: PhotoViewerActions {
        PhotoViewerActions(
            canOpen: selectedPhoto != nil,
            isExpanded: expandedPhoto != nil,
            open: showSelectedPhoto,
            close: closeExpandedPhoto
        )
    }

    private func select(_ entry: AllLibrariesPhotoEntry) {
        selectedPhoto = photoReference(for: entry)
        isShowingPhotoPreview = true
        isPhotoAreaFocused = true
    }

    private func selectSearchDocument(_ document: UnifiedSearchDocument) {
        selectedPhoto = photoReference(for: document)
        isShowingPhotoPreview = true
        isPhotoAreaFocused = true
    }

    private func selectAndExpandSearchDocument(_ document: UnifiedSearchDocument) {
        selectedPhoto = photoReference(for: document)
        isShowingPhotoPreview = true
        showSelectedPhoto()
    }

    private func showSelectedPhoto() {
        guard let selectedPhoto else { return }
        persistBrowserPosition()
        expandedPhoto = selectedPhoto
        refocusPhotoAreaAfterTransition()
    }

    private func closeExpandedPhoto() {
        guard expandedPhoto != nil else { return }
        expandedPhoto = nil
        refocusPhotoAreaAfterTransition()
    }

    private func closePhotoPreview() {
        isShowingPhotoPreview = false
        refocusPhotoAreaAfterTransition()
    }

    private func navigate(to photo: AllLibrariesPhotoReference) {
        selectedPhoto = photo
        if expandedPhoto != nil {
            expandedPhoto = photo
        }
    }

    private func clearPhotoSelection() {
        selectedPhoto = nil
        expandedPhoto = nil
        isShowingPhotoPreview = false
    }

    private func refocusPhotoAreaAfterTransition() {
        isPhotoAreaFocused = false
        Task { @MainActor in
            await Task.yield()
            isPhotoAreaFocused = true
        }
    }

    private func photoReference(for entry: AllLibrariesPhotoEntry) -> AllLibrariesPhotoReference {
        let source: AllLibrariesPhotoReference.Source
        switch entry.source {
        case .system(let asset):
            source = .system(assetID: asset.id)
        case .registered(let libraryID, let item):
            source = .registered(
                libraryID: libraryID,
                itemID: item.id,
                mediaType: UnifiedSearchViewModel.mediaType(for: item.filename)
            )
        }
        return AllLibrariesPhotoReference(id: entry.id, title: entry.displayName, source: source)
    }

    private func photoReference(for document: UnifiedSearchDocument) -> AllLibrariesPhotoReference {
        let source: AllLibrariesPhotoReference.Source = switch document.source {
        case .systemPhotoLibrary:
            .system(assetID: document.assetID)
        case .registeredLibrary:
            .registered(
                libraryID: document.libraryID,
                itemID: document.assetID,
                mediaType: document.mediaType
            )
        }
        return AllLibrariesPhotoReference(
            id: document.id,
            title: document.displayName.isEmpty ? document.filename : document.displayName,
            source: source
        )
    }

    @ViewBuilder
    private func expandedPhotoView(_ photo: AllLibrariesPhotoReference) -> some View {
        ExpandedPhotoContainer(
            title: photo.title,
            previous: adjacentPhoto(to: photo, offset: -1).map { previous in
                { navigate(to: previous) }
            },
            next: adjacentPhoto(to: photo, offset: 1).map { next in
                { navigate(to: next) }
            },
            close: closeExpandedPhoto
        ) {
            viewerPhoto(photo)
        }
    }

    private func photoPreview(_ photo: AllLibrariesPhotoReference) -> some View {
        PhotoPreviewContainer(
            title: photo.title,
            isVideo: photo.isVideo(systemAssets: systemModel.assets),
            previous: adjacentPhoto(to: photo, offset: -1).map { previous in
                { selectedPhoto = previous }
            },
            next: adjacentPhoto(to: photo, offset: 1).map { next in
                { selectedPhoto = next }
            },
            expand: showSelectedPhoto,
            close: closePhotoPreview
        ) {
            viewerPhoto(photo)
        } info: {
            ScrollView {
                photoInfo(photo)
                    .padding(16)
            }
        }
        .task(id: "\(photo.id):\(systemModel.textMetadataRevision)") {
            switch photo.source {
            case .system(let assetID):
                if systemModel.selectedAssetID != assetID {
                    systemModel.selectAsset(assetID)
                }
                if let libraryID = systemLibraryID,
                   let asset = systemModel.assets.first(where: { $0.id == assetID }) {
                    searchModel.requestPlace(
                        libraryID: libraryID,
                        assetID: assetID,
                        coordinate: asset.coordinate
                    )
                    await systemModel.loadSelectedTextMetadata(
                        registry: registry, libraryID: libraryID
                    )
                }
            case .registered(let libraryID, let itemID, _):
                if let item = store.manifest(for: libraryID)?.items.first(where: { $0.id == itemID }) {
                    searchModel.requestPlace(
                        libraryID: libraryID,
                        assetID: itemID,
                        rawLocation: item.locationDescription
                    )
                    await store.loadDirectTechnicalMetadata(for: itemID, libraryID: libraryID)
                }
            }
        }
    }

    private func adjacentPhoto(
        to photo: AllLibrariesPhotoReference,
        offset: Int
    ) -> AllLibrariesPhotoReference? {
        if searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PhotoSequence.adjacent(
                in: allPhotoEntries,
                selectedID: photo.id,
                offset: offset
            ).map { photoReference(for: $0) }
        }
        return PhotoSequence.adjacent(
            in: visibleSearchResults,
            selectedID: photo.id,
            offset: offset
        ).map { photoReference(for: $0) }
    }

    @ViewBuilder
    private func photoInfo(_ photo: AllLibrariesPhotoReference) -> some View {
        switch photo.source {
        case .system(let assetID):
            if let asset = systemModel.assets.first(where: { $0.id == assetID }) {
                PhotoInfoPanel(content: .system(
                    asset,
                    libraryName: registry.libraries.first {
                        $0.descriptor.kind.isSystemPhotoLibrary
                    }?.descriptor.metadata.displayName ?? "System Photo Library",
                    textMetadata: systemModel.selectedAssetID == assetID
                        ? systemModel.selectedTextMetadata : nil,
                    textMetadataError: systemModel.selectedAssetID == assetID
                        ? systemModel.selectedTextMetadataError : nil,
                    technicalMetadata: systemModel.selectedAssetID == assetID
                        ? systemModel.selectedTechnicalMetadata : nil,
                    isLoadingTechnicalMetadata: systemModel.selectedAssetID == assetID
                        && systemModel.isLoadingTechnicalMetadata,
                    place: systemLibraryID.flatMap {
                        searchModel.place(libraryID: $0, assetID: assetID)
                    },
                    isLocationUnavailable: systemLibraryID.map {
                        searchModel.isPlaceUnavailable(libraryID: $0, assetID: assetID)
                    } ?? true
                ))
            }
        case .registered(let libraryID, let itemID, _):
            if let item = store.manifest(for: libraryID)?.items.first(where: { $0.id == itemID }) {
                PhotoInfoPanel(content: .registered(
                    item,
                    libraryName: store.manifest(for: libraryID)?.libraryDisplayName
                        ?? "Registered Library",
                    isLivePhoto: store.isDirectLivePhoto(item.id, libraryID: libraryID)
                        || store.livePhotoVideoURL(for: item.id, libraryID: libraryID) != nil,
                    technicalMetadata: store.technicalMetadata(for: item.id, libraryID: libraryID),
                    videoDuration: store.manifest(for: libraryID)?
                        .playbackVideoDurations?[item.id],
                    place: searchModel.place(libraryID: libraryID, assetID: itemID),
                    isLocationUnavailable: searchModel.isPlaceUnavailable(
                        libraryID: libraryID,
                        assetID: itemID
                    )
                ))
            }
        }
    }

    private var systemLibraryID: LibraryID? {
        registry.libraries.first { $0.descriptor.kind.isSystemPhotoLibrary }?.id
    }

    @ViewBuilder
    private func viewerPhoto(_ photo: AllLibrariesPhotoReference) -> some View {
        switch photo.source {
            case .system(let assetID):
                if systemModel.assets.first(where: { $0.id == assetID })?.mediaType == "video" {
                    SystemLibraryVideoPlayer(assetID: assetID)
                } else if systemModel.assets.first(where: { $0.id == assetID })?.isLivePhoto == true {
                    let asset = systemModel.assets.first { $0.id == assetID }
                    SystemLivePhotoView(
                        assetID: assetID,
                        imageSize: CGSize(
                            width: CGFloat(asset?.pixelWidth ?? 0),
                            height: CGFloat(asset?.pixelHeight ?? 0)
                        )
                    ) {
                        systemViewerImage(photoID: photo.id, assetID: assetID)
                    }
                } else {
                    systemViewerImage(photoID: photo.id, assetID: assetID)
                }

            case .registered(let libraryID, let itemID, let mediaType):
                if mediaType == "video",
                   let item = store.manifest(for: libraryID)?.items.first(where: { $0.id == itemID }) {
                    RegisteredLibraryVideoPlayer(
                        item: item,
                        libraryID: libraryID,
                        store: store
                    )
                } else if store.isDirectLivePhoto(itemID, libraryID: libraryID),
                          let provider = store.directProvider(for: libraryID) {
                    let item = store.manifest(for: libraryID)?.items.first { $0.id == itemID }
                    DirectRegisteredLivePhotoView(
                        provider: provider, assetID: itemID,
                        imageSize: CGSize(
                            width: CGFloat(item?.pixelWidth ?? 0),
                            height: CGFloat(item?.pixelHeight ?? 0)
                        )
                    ) {
                        registeredViewerImage(libraryID: libraryID, itemID: itemID, mediaType: mediaType)
                    }
                } else if let videoURL = store.livePhotoVideoURL(for: itemID, libraryID: libraryID) {
                    let item = store.manifest(for: libraryID)?.items.first { $0.id == itemID }
                    RegisteredLivePhotoView(
                        videoURL: videoURL,
                        imageSize: CGSize(
                            width: CGFloat(item?.pixelWidth ?? 0),
                            height: CGFloat(item?.pixelHeight ?? 0)
                        )
                    ) {
                        registeredViewerImage(libraryID: libraryID, itemID: itemID, mediaType: mediaType)
                    }
                } else {
                    registeredViewerImage(libraryID: libraryID, itemID: itemID, mediaType: mediaType)
                }
        }
    }

    private func systemViewerImage(photoID: String, assetID: String) -> some View {
        GeometryReader { proxy in
            let targetSize = SystemPhotoLibraryViewModel.viewerTargetSize(
                for: proxy.size,
                displayScale: displayScale
            )
            Group {
                if let image = systemModel.viewerImages[assetID]
                    ?? systemModel.thumbnails[assetID] {
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
            .task(id: "\(photoID):\(Int(targetSize.width))x\(Int(targetSize.height)):g\(systemModel.thumbnailRequestGeneration)") {
                guard let asset = systemModel.assets.first(where: { $0.id == assetID }) else {
                    return
                }
                systemModel.requestViewerImage(for: asset, size: targetSize)
            }
        }
        .onDisappear {
            systemModel.cancelViewerImageRequest(for: assetID)
        }
    }

    private func registeredViewerImage(libraryID: LibraryID, itemID: String, mediaType: String) -> some View {
        CachedLibraryThumbnailView(
            store: store,
            libraryID: libraryID,
            itemID: itemID,
            revision: store.viewerPreviewRevision(for: itemID, libraryID: libraryID),
            placeholderSystemImage: mediaType == "video" ? "video" : "photo",
            hasError: false,
            contentMode: .fit,
            prefersViewerPreview: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rebuildAllPhotoEntries(systemAssets: [PhotoAssetSummary]? = nil) {
        let currentSystemAssets = systemAssets ?? systemModel.assets
        var entries: [AllLibrariesPhotoEntry] = []
        entries.reserveCapacity(
            currentSystemAssets.count
                + registry.libraries.reduce(into: 0) { count, library in
                    guard !library.descriptor.kind.isSystemPhotoLibrary else { return }
                    count += store.manifest(for: library.id)?.items.count ?? 0
                }
        )

        if systemModel.authorization.permitsReading {
            let systemLibraryName = registry.libraries.first {
                $0.descriptor.kind.isSystemPhotoLibrary
            }?.descriptor.metadata.displayName ?? "System Photo Library"
            entries.append(contentsOf: currentSystemAssets.filter { asset in
                mediaCategory.map { asset.mediaCategories.contains($0) } ?? true
            }.map { asset in
                AllLibrariesPhotoEntry(
                    id: "system:\(asset.id)",
                    libraryName: systemLibraryName,
                    date: asset.creationDate,
                    displayName: asset.originalFilename.isEmpty
                        ? asset.mediaType.capitalized
                        : asset.originalFilename,
                    dimensions: "\(asset.pixelWidth) × \(asset.pixelHeight)",
                    source: .system(asset)
                )
            })
        }

        for library in registry.libraries where !library.descriptor.kind.isSystemPhotoLibrary {
            guard let manifest = store.manifest(for: library.id) else { continue }
            entries.append(contentsOf: manifest.items.filter { item in
                switch mediaCategory {
                case nil: return true
                case .some(.videos):
                    return UnifiedSearchViewModel.mediaType(for: item.filename) == "video"
                case .some(.livePhotos):
                    return store.isDirectLivePhoto(item.id, libraryID: library.id)
                        || manifest.livePhotoVideoFilenames?[item.id] != nil
                default: return false
                }
            }.map { item in
                AllLibrariesPhotoEntry(
                    id: "\(library.id.rawValue.uuidString):\(item.id)",
                    libraryName: manifest.libraryDisplayName,
                    date: item.captureDate,
                    displayName: item.name.isEmpty ? item.filename : item.name,
                    dimensions: "\(item.pixelWidth) × \(item.pixelHeight)",
                    source: .registered(library.id, item)
                )
            })
        }

        allPhotoEntries = entries.sorted(by: AllLibrariesPhotoEntry.isEarlier)
        allPhotoEntriesGeneration += 1
        if searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let selectedPhoto,
           !allPhotoEntries.contains(where: { $0.id == selectedPhoto.id }) {
            clearPhotoSelection()
        }
        restoreBrowserPosition()
    }

    private func restoreBrowserPosition(force: Bool = false) {
        guard isBrowserVisible,
              expandedPhoto == nil,
              timelineMode == .allPhotos else { return }
        guard searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if restoreBottomUntilInteraction {
            guard let lastID = allPhotoEntries.last?.id else { return }
            hasRestoredScrollPosition = true
            queueBrowserScroll(to: lastID, anchor: .bottom)
            return
        }
        guard force || !hasRestoredScrollPosition else { return }
        guard let savedID = savedBrowserAssetID else {
            hasRestoredScrollPosition = true
            queueBrowserScroll(to: allPhotoEntries.last?.id)
            return
        }
        guard allPhotoEntries.contains(where: { $0.id == savedID }) else {
            // The System Photo Library can arrive after the cached libraries.
            // Keep the saved ID until all currently loading assets are ready;
            // a later catalog publication will try restoration again.
            if !systemModel.isLoading {
                hasRestoredScrollPosition = true
                queueBrowserScroll(to: allPhotoEntries.last?.id)
            }
            return
        }
        hasRestoredScrollPosition = true
        queueBrowserScroll(to: savedID)
    }

    private func queueBrowserScroll(to targetID: String?, anchor: UnitPoint = .center) {
        browserScrollTargetID = targetID
        browserScrollAnchor = anchor
        browserScrollRequestGeneration &+= 1
    }

    private func persistBrowserPosition() {
        guard expandedPhoto == nil,
              timelineMode == .allPhotos,
              hasRestoredScrollPosition,
              pendingAllPhotosRevealID == nil,
              !restoreBottomUntilInteraction,
              searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let centeredID = scrollTracker.centeredID,
              allPhotoEntries.contains(where: { $0.id == centeredID }) else {
            return
        }
        if showsVideosOnly {
            LibraryBrowserPositionStore.saveVideos(assetID: centeredID, isAtBottom: isAtBottom)
        } else if mediaCategory == nil {
            LibraryBrowserPositionStore.saveAllLibraries(assetID: centeredID, isAtBottom: isAtBottom)
        }
    }
}

private struct ManifestCatalogRevision: Equatable {
    let libraryID: LibraryID
    let indexedAt: Date
    let itemCount: Int
}

private struct AllLibrariesPhotoEntry: Identifiable {
    enum Source {
        case system(PhotoAssetSummary)
        case registered(LibraryID, PhotosAutomationMediaItem)
    }

    let id: String
    let libraryName: String
    let date: Date?
    let displayName: String
    let dimensions: String
    let source: Source

    var dateText: String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date"
    }

    nonisolated static func isEarlier(_ lhs: Self, _ rhs: Self) -> Bool {
        switch (lhs.date, rhs.date) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            let libraryOrder = lhs.libraryName.localizedStandardCompare(rhs.libraryName)
            if libraryOrder != .orderedSame { return libraryOrder == .orderedAscending }
            let nameOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

private struct AllLibrariesPhotoReference {
    enum Source {
        case system(assetID: String)
        case registered(libraryID: LibraryID, itemID: String, mediaType: String)
    }

    let id: String
    let title: String
    let source: Source

    func isVideo(systemAssets: [PhotoAssetSummary]) -> Bool {
        switch source {
        case .system(let assetID):
            systemAssets.first(where: { $0.id == assetID })?.mediaType == "video"
        case .registered(_, _, let mediaType):
            mediaType == "video"
        }
    }
}
