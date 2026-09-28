import AppKit
import SwiftUI

/// Keeps an unchanged preview grid from rebuilding when only indexing status
/// or higher-resolution viewer previews change. The caller includes every
/// value that can affect the grid's visible cells in `revision`.
struct CachedPreviewGridContent<Revision: Equatable, Content: View>: View, Equatable {
    let revision: Revision
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
    }
}

/// Observes only one System Photo Library asset. Thumbnail callbacks update
/// this slot instead of publishing the entire view model and invalidating every
/// visible grid cell.
struct SystemPhotoLibraryThumbnailView: View, Equatable {
    let model: SystemPhotoLibraryViewModel
    let asset: PhotoAssetSummary
    let targetSize: CGSize
    let requestGeneration: Int
    let placeholderSystemImage: String
    let showsMediaBadge: Bool

    @ObservedObject private var slot: SystemPhotoThumbnailSlot
    @State private var consumerID = UUID()

    init(
        model: SystemPhotoLibraryViewModel,
        asset: PhotoAssetSummary,
        targetSize: CGSize,
        requestGeneration: Int,
        placeholderSystemImage: String,
        showsMediaBadge: Bool = true
    ) {
        self.model = model
        self.asset = asset
        self.targetSize = targetSize
        self.requestGeneration = requestGeneration
        self.placeholderSystemImage = placeholderSystemImage
        self.showsMediaBadge = showsMediaBadge
        _slot = ObservedObject(
            wrappedValue: model.thumbnailSlot(for: asset.id)
        )
    }

    var body: some View {
        Color.clear
            .overlay {
                Group {
                    if let image = slot.image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Color.secondary.opacity(0.12)
                            Image(systemName: placeholderSystemImage)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .overlay(alignment: .bottomTrailing) {
                if showsMediaBadge && placeholderSystemImage == "video" {
                    VideoDurationBadge(duration: asset.duration)
                        .padding(8)
                } else if showsMediaBadge && asset.isLivePhoto {
                    ThumbnailLivePhotoBadge()
                        .padding(8)
                }
            }
            .task(id: requestIdentity) {
                model.requestThumbnail(for: asset, size: targetSize, consumerID: consumerID)
            }
            .onDisappear {
                model.releaseThumbnail(for: asset.id, consumerID: consumerID)
            }
    }

    private var requestIdentity: String {
        "\(asset.id):\(Int(targetSize.width))x\(Int(targetSize.height)):g\(requestGeneration)"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
            && lhs.asset == rhs.asset
            && lhs.targetSize == rhs.targetSize
            && lhs.requestGeneration == rhs.requestGeneration
            && lhs.placeholderSystemImage == rhs.placeholderSystemImage
            && lhs.showsMediaBadge == rhs.showsMediaBadge
    }
}

/// Loads only visible app-owned preview files. Disk I/O and CGImage decoding
/// happen away from the main actor; NSCache bounds the retained images.
struct CachedLibraryThumbnailView: View, Equatable {
    let store: LibraryPreviewStore
    let libraryID: LibraryID
    let itemID: String
    let revision: String?
    let placeholderSystemImage: String
    let hasError: Bool
    let contentMode: ContentMode
    let prefersViewerPreview: Bool
    let thumbnailPixelSize: Int?
    let thumbnailAspectRatio: Double?
    let coverPixelSize: Int?
    let showsMediaBadge: Bool
    let isLivePhoto: Bool

    @State private var image: NSImage?
    @State private var loadedRequestIdentity: String?
    @State private var duration: TimeInterval?

    init(
        store: LibraryPreviewStore,
        libraryID: LibraryID,
        itemID: String,
        revision: String?,
        placeholderSystemImage: String,
        hasError: Bool,
        isLivePhoto: Bool = false,
        contentMode: ContentMode = .fill,
        prefersViewerPreview: Bool = false,
        thumbnailPixelSize: Int? = nil,
        thumbnailAspectRatio: Double? = nil,
        coverPixelSize: Int? = nil,
        showsMediaBadge: Bool = true
    ) {
        self.store = store
        self.libraryID = libraryID
        self.itemID = itemID
        self.revision = revision
        self.placeholderSystemImage = placeholderSystemImage
        self.hasError = hasError
        self.contentMode = contentMode
        self.prefersViewerPreview = prefersViewerPreview
        self.thumbnailPixelSize = thumbnailPixelSize
        self.thumbnailAspectRatio = thumbnailAspectRatio
        self.coverPixelSize = coverPixelSize
        self.showsMediaBadge = showsMediaBadge
        self.isLivePhoto = isLivePhoto
    }

    var body: some View {
        Color.clear
            .overlay {
                Group {
                    if loadedRequestIdentity == requestIdentity, let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                    } else {
                        ZStack {
                            Color.secondary.opacity(0.12)
                            Image(systemName: hasError ? "exclamationmark.triangle" : placeholderSystemImage)
                                .foregroundStyle(hasError ? Color.orange : Color.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .overlay(alignment: .bottomTrailing) {
                if showsMediaBadge && placeholderSystemImage == "video" && !prefersViewerPreview {
                    VideoDurationBadge(duration: duration)
                        .padding(8)
                } else if showsMediaBadge && isLivePhoto && !prefersViewerPreview {
                    ThumbnailLivePhotoBadge()
                        .padding(8)
                }
            }
            .task(id: requestIdentity) {
                duration = nil
                guard showsMediaBadge, placeholderSystemImage == "video", !prefersViewerPreview else { return }
                let loadedDuration = await store.playbackDuration(for: itemID, libraryID: libraryID)
                guard !Task.isCancelled else { return }
                duration = loadedDuration
            }
            .task(id: requestIdentity) {
                let identity = requestIdentity
                if loadedRequestIdentity != identity { image = nil }
                guard revision != nil else {
                    loadedRequestIdentity = nil
                    return
                }
                let loadedImage: NSImage?
                if let coverPixelSize {
                    loadedImage = await store.loadCoverPreview(
                        for: itemID,
                        libraryID: libraryID,
                        pixelSize: coverPixelSize
                    )
                } else if prefersViewerPreview {
                    loadedImage = await store.loadViewerPreview(
                        for: itemID,
                        libraryID: libraryID
                    )
                } else {
                    loadedImage = await store.loadThumbnail(
                        for: itemID,
                        libraryID: libraryID,
                        pixelSize: thumbnailPixelSize ?? 600,
                        sourceAspectRatio: thumbnailAspectRatio
                    )
                }
                guard !Task.isCancelled else { return }
                image = loadedImage
                loadedRequestIdentity = identity
            }
    }

    private var requestIdentity: String {
        let tier = coverPixelSize.map { "cover:\($0)" }
            ?? (prefersViewerPreview
                ? "viewer"
                : "thumbnail:\(thumbnailPixelSize ?? 600):aspect:\(thumbnailAspectRatio ?? 0)")
        return "\(libraryID.rawValue.uuidString):\(itemID):\(revision ?? "missing"):\(tier)"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store
            && lhs.libraryID == rhs.libraryID
            && lhs.itemID == rhs.itemID
            && lhs.revision == rhs.revision
            && lhs.placeholderSystemImage == rhs.placeholderSystemImage
            && lhs.hasError == rhs.hasError
            && lhs.contentMode == rhs.contentMode
            && lhs.prefersViewerPreview == rhs.prefersViewerPreview
            && lhs.thumbnailPixelSize == rhs.thumbnailPixelSize
            && lhs.thumbnailAspectRatio == rhs.thumbnailAspectRatio
            && lhs.coverPixelSize == rhs.coverPixelSize
            && lhs.showsMediaBadge == rhs.showsMediaBadge
            && lhs.isLivePhoto == rhs.isLivePhoto
    }
}

private struct ThumbnailLivePhotoBadge: View {
    var body: some View {
        Image(systemName: "livephoto")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(7)
            .background(.black.opacity(0.7), in: Capsule())
            .accessibilityLabel("Live Photo")
    }
}

private struct VideoDurationBadge: View {
    let duration: TimeInterval?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill")
            if let label { Text(label).monospacedDigit() }
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, label == nil ? 7 : 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.7), in: Capsule())
    }

    private var label: String? {
        guard let duration, duration.isFinite, duration > 0,
              duration < Double(Int.max) else { return nil }
        let seconds = Int(duration.rounded())
        let minutes = seconds / 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds % 60)
        }
        return String(format: "%d:%02d", minutes, seconds % 60)
    }
}

struct ExpandedPhotoContainer<Content: View>: View {
    let title: String
    let previous: (() -> Void)?
    let next: (() -> Void)?
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            content()
                .padding(8)
                .ignoresSafeArea(.container, edges: .top)

            HStack {
                PhotoNavigationButton(label: "Previous Photo", symbol: "chevron.left", action: previous)
                Spacer()
                PhotoNavigationButton(label: "Next Photo", symbol: "chevron.right", action: next)
            }
            .padding(16)

            VStack {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Button("Close", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .keyboardShortcut(.cancelAction)
                        .help("Return to thumbnails (Esc)")
                }
                Spacer()
            }
            .padding(18)
        }
        .onExitCommand(perform: close)
        .onMoveCommand { direction in
            switch direction {
            case .left, .up:
                previous?()
            case .right, .down:
                next?()
            default:
                break
            }
        }
    }
}

struct PhotoPreviewContainer<Photo: View, Info: View>: View {
    let title: String
    let isVideo: Bool
    let previous: (() -> Void)?
    let next: (() -> Void)?
    let expand: () -> Void
    let close: () -> Void
    @ViewBuilder let photo: () -> Photo
    @ViewBuilder let info: () -> Info

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if isVideo {
                    Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right", action: expand)
                }
                Button("Close", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()

            HSplitView {
                ZStack {
                    Color.black
                    if isVideo {
                        photo()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Button(action: expand) {
                            photo()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Expand photo")
                    }

                    HStack {
                        PhotoNavigationButton(label: "Previous Photo", symbol: "chevron.left", action: previous)
                        Spacer()
                        PhotoNavigationButton(label: "Next Photo", symbol: "chevron.right", action: next)
                    }
                    .padding(16)
                }
                .frame(minWidth: 400, maxWidth: .infinity)

                info()
                    .frame(width: 300)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: close)
    }
}

private struct PhotoNavigationButton: View {
    let label: String
    let symbol: String
    let action: (() -> Void)?

    var body: some View {
        Button(action: { action?() }) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .opacity(action == nil ? 0.3 : 1)
        .accessibilityLabel(label)
    }
}

enum PhotoSequence {
    static func adjacent<Item: Identifiable>(
        in items: [Item],
        selectedID: String,
        offset: Int
    ) -> Item? where Item.ID == String {
        guard let index = items.firstIndex(where: { $0.id == selectedID }),
              items.indices.contains(index + offset) else { return nil }
        return items[index + offset]
    }
}

/// The viewer covers the existing window without changing the browser's
/// NavigationSplitView, toolbar, or scroll view geometry.
struct PhotoViewerWindowPresenter<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let onEscape: (() -> Void)?
    let onPrevious: (() -> Void)?
    let onNext: (() -> Void)?
    let onPlayPause: (() -> Void)?
    @ViewBuilder let content: () -> Content

    init(
        isPresented: Bool,
        onEscape: (() -> Void)? = nil,
        onPrevious: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil,
        onPlayPause: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isPresented = isPresented
        self.onEscape = onEscape
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onPlayPause = onPlayPause
        self.content = content
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PhotoViewerWindowAttachmentView {
        let view = PhotoViewerWindowAttachmentView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.update(parent: window, isPresented: isPresented, onEscape: onEscape, onPrevious: onPrevious, onNext: onNext, onPlayPause: onPlayPause, content: content())
        }
        return view
    }

    func updateNSView(_ view: PhotoViewerWindowAttachmentView, context: Context) {
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.update(parent: window, isPresented: isPresented, onEscape: onEscape, onPrevious: onPrevious, onNext: onNext, onPlayPause: onPlayPause, content: content())
        }
        context.coordinator.update(
            parent: view.window,
            isPresented: isPresented,
            onEscape: onEscape,
            onPrevious: onPrevious,
            onNext: onNext,
            onPlayPause: onPlayPause,
            content: content()
        )
    }

    static func dismantleNSView(_ view: PhotoViewerWindowAttachmentView, coordinator: Coordinator) {
        view.onWindowChange = nil
        coordinator.dismiss()
    }

    final class Coordinator: NSObject {
        private weak var parentWindow: NSWindow?
        private var viewerWindow: PhotoViewerOverlayWindow?
        private var hostingView: NSHostingView<Content>?

        func update(parent: NSWindow?, isPresented: Bool, onEscape: (() -> Void)?, onPrevious: (() -> Void)?, onNext: (() -> Void)?, onPlayPause: (() -> Void)?, content: Content) {
            guard isPresented, let parent else {
                dismiss()
                return
            }
            if parentWindow !== parent {
                dismiss()
            }
            if let hostingView {
                viewerWindow?.onEscape = onEscape
                viewerWindow?.onPrevious = onPrevious
                viewerWindow?.onNext = onNext
                viewerWindow?.onPlayPause = onPlayPause
                hostingView.rootView = content
                syncFrame()
                return
            }

            let window = PhotoViewerOverlayWindow(
                contentRect: parent.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.collectionBehavior = [.fullScreenAuxiliary]
            window.onEscape = onEscape
            window.onPrevious = onPrevious
            window.onNext = onNext
            window.onPlayPause = onPlayPause
            let host = NSHostingView(rootView: content)
            window.contentView = host
            parentWindow = parent
            viewerWindow = window
            hostingView = host
            NotificationCenter.default.addObserver(
                self, selector: #selector(parentFrameDidChange(_:)),
                name: NSWindow.didMoveNotification, object: parent
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(parentFrameDidChange(_:)),
                name: NSWindow.didResizeNotification, object: parent
            )
            parent.addChildWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }

        @objc private func parentFrameDidChange(_ notification: Notification) {
            syncFrame()
        }

        private func syncFrame() {
            guard let parentWindow, let viewerWindow else { return }
            viewerWindow.setFrame(parentWindow.frame, display: true)
        }

        func dismiss() {
            guard let viewerWindow else { return }
            if let parentWindow {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: parentWindow)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: parentWindow)
                parentWindow.removeChildWindow(viewerWindow)
            }
            viewerWindow.orderOut(nil)
            viewerWindow.onEscape = nil
            viewerWindow.onPrevious = nil
            viewerWindow.onNext = nil
            viewerWindow.onPlayPause = nil
            self.viewerWindow = nil
            hostingView = nil
            parentWindow?.makeKeyAndOrderFront(nil)
            parentWindow = nil
        }
    }
}

final class PhotoViewerWindowAttachmentView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

private final class PhotoViewerOverlayWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onPlayPause: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53, let onEscape {
                onEscape()
                return
            }
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               !(firstResponder is NSTextView) {
                switch event.keyCode {
                case 123, 126:
                    onPrevious?()
                    return
                case 124, 125:
                    onNext?()
                    return
                case 49:
                    if let onPlayPause {
                        onPlayPause()
                        return
                    }
                default:
                    break
                }
            }
        }
        super.sendEvent(event)
    }
}
