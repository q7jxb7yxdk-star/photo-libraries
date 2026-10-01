import SwiftUI

struct LibraryMenuActions {
    let isIndexing: Bool
    let reauthorize: () -> Void
    let removeRegistration: () -> Void
}

struct PhotoViewerActions {
    let canOpen: Bool
    let isExpanded: Bool
    let open: () -> Void
    let close: () -> Void
}

struct PhotoCopyActions {
    let canCopyToSystemLibrary: Bool
    let copyToSystemLibrary: () -> Void
}

struct PhotoTransferDestinationAction: Identifiable {
    let id: LibraryID
    let title: String
    let help: String
    let isEnabled: Bool
    let transfer: () -> Void
}

struct PhotoTransferActions {
    let destinations: [PhotoTransferDestinationAction]
}

private struct LibraryMenuActionsKey: FocusedValueKey {
    typealias Value = LibraryMenuActions
}

private struct PhotoViewerActionsKey: FocusedValueKey {
    typealias Value = PhotoViewerActions
}

private struct PhotoCopyActionsKey: FocusedValueKey {
    typealias Value = PhotoCopyActions
}

private struct PhotoTransferActionsKey: FocusedValueKey {
    typealias Value = PhotoTransferActions
}

extension FocusedValues {
    var libraryMenuActions: LibraryMenuActions? {
        get { self[LibraryMenuActionsKey.self] }
        set { self[LibraryMenuActionsKey.self] = newValue }
    }

    var photoViewerActions: PhotoViewerActions? {
        get { self[PhotoViewerActionsKey.self] }
        set { self[PhotoViewerActionsKey.self] = newValue }
    }

    var photoCopyActions: PhotoCopyActions? {
        get { self[PhotoCopyActionsKey.self] }
        set { self[PhotoCopyActionsKey.self] = newValue }
    }

    var photoTransferActions: PhotoTransferActions? {
        get { self[PhotoTransferActionsKey.self] }
        set { self[PhotoTransferActionsKey.self] = newValue }
    }
}

private struct LibraryCommands: Commands {
    @FocusedValue(\.libraryMenuActions) private var actions

    var body: some Commands {
        CommandMenu("Library") {
            Button("Reauthorize Library…") {
                actions?.reauthorize()
            }
            .disabled(actions == nil)

            Divider()

            Button("Remove Registration…") {
                actions?.removeRegistration()
            }
            .disabled(actions == nil || actions?.isIndexing == true)
        }
    }
}

private struct PhotoViewerCommands: Commands {
    @FocusedValue(\.photoViewerActions) private var actions
    @FocusedValue(\.photoCopyActions) private var copyActions
    @FocusedValue(\.photoTransferActions) private var transferActions

    var body: some Commands {
        CommandMenu("Photo") {
            Button("Open Photo") {
                actions?.open()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(actions?.canOpen != true || actions?.isExpanded == true)

            Button("Close Photo") {
                actions?.close()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(actions?.isExpanded != true)

            Divider()

            Button("Copy to System Photo Library") {
                copyActions?.copyToSystemLibrary()
            }
            .disabled(copyActions?.canCopyToSystemLibrary != true)

            ForEach(transferActions?.destinations ?? []) { destination in
                Button(destination.title) {
                    destination.transfer()
                }
                .disabled(!destination.isEnabled)
                .help(destination.help)
            }
        }
    }
}

#if !WEB_GALLERY_HELPER
@main struct MyApp: App {
    @StateObject private var registry = LibraryRegistry()
    @StateObject private var systemModel = SystemPhotoLibraryViewModel()
    @StateObject private var previewStore = LibraryPreviewStore.shared
    @State private var didConfigureGalleryService = false

    var body: some Scene {
        WindowGroup {
            ContentView(
                registry: registry,
                systemModel: systemModel,
                previewStore: previewStore
            )
                .background(WindowInitialFillView())
                .task {
                    guard !didConfigureGalleryService else { return }
                    didConfigureGalleryService = true
                    WebGalleryBackgroundService.shared.configure(
                        registry: registry, server: .shared
                    )
                }
        }
        .commands {
            LibraryCommands()
            PhotoViewerCommands()
        }

        Settings {
            WebGallerySettingsView(
                server: .shared,
                registry: registry,
                systemModel: systemModel,
                store: previewStore
            )
        }
    }
}

#endif
