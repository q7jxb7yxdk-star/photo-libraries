import AppKit
import Combine
import ServiceManagement

/// The main app manages settings and registration, and never binds the HTTP port.
@MainActor
final class WebGalleryBackgroundService: ObservableObject {
    static let shared = WebGalleryBackgroundService()
    private static let enabledKey = "WebGallery.backgroundSharingEnabled.v1"
    private static let identifier = "com.sunny.photo-libraries.web-gallery"
    private let service = SMAppService.loginItem(identifier: WebGalleryBackgroundService.identifier)
    @Published private(set) var isRunning = false
    @Published private(set) var isEnabled = false
    @Published private(set) var isAuthorizing = false
    private var authorizationRequestedAt: Date?
    @Published private(set) var statusMessage = "Background sharing is off."
    private var subscriptions = Set<AnyCancellable>()
    private var monitor: Task<Void, Never>?
    private weak var registry: LibraryRegistry?
    private weak var server: WebGalleryServer?

    private init() {}

    func configure(registry: LibraryRegistry, server: WebGalleryServer) {
        guard self.registry == nil else { return }
        self.registry = registry
        self.server = server
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        registry.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }.store(in: &subscriptions)
        server.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }.store(in: &subscriptions)
        publish()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func publish() {
        guard let registry, let server else { return }
        do {
            try WebGallerySharedConfiguration.publish(server: server, registry: registry, enabled: isEnabled)
        } catch {
            isRunning = false
            statusMessage = error.localizedDescription
        }
    }

    func enable() {
        guard !isAuthorizing else { return }
        guard let registry, let server else { return }
        guard server.hasValidConfiguration,
              registry.libraries.contains(where: { server.sharedLibraryIDs.contains($0.id) }) else {
            statusMessage = "Enter the Serve host, allowed logins, and at least one shared library first."
            return
        }
        do {
            // Publish before registration: the newly launched helper must have a configuration.
            try WebGallerySharedConfiguration.publish(server: server, registry: registry, enabled: true)
            if service.status != .enabled { try service.register() }
            isEnabled = true
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            refreshStatus()
        } catch {
            try? WebGallerySharedConfiguration.publish(server: server, registry: registry, enabled: isEnabled)
            statusMessage = error.localizedDescription
        }
    }

    func disable() {
        guard let registry, let server else { return }
        do {
            // Revoke sharing even if macOS cannot unregister the login item immediately.
            try WebGallerySharedConfiguration.publish(server: server, registry: registry, enabled: false)
            isEnabled = false
            isRunning = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            if service.status != .notRegistered { try service.unregister() }
            statusMessage = "Background sharing is off."
        } catch { statusMessage = error.localizedDescription }
    }

    func authorizeLibraries() {
        guard let registry, let server else { return }
        do {
            try WebGallerySharedConfiguration.publish(server: server, registry: registry, enabled: isEnabled)
            let url = Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Library/LoginItems/PhotoLibrariesWebGallery.app"
            )
            guard FileManager.default.fileExists(atPath: url.path) else {
                statusMessage = "The background helper is missing from this app bundle."
                return
            }
            authorizationRequestedAt = .now
            isAuthorizing = true
            statusMessage = "Complete the background helper’s permission dialogs before starting sharing."
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--authorize"]
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                Task { @MainActor [weak self] in
                    if let error {
                        self?.isAuthorizing = false
                        self?.authorizationRequestedAt = nil
                        self?.statusMessage = error.localizedDescription
                    }
                }
            }
        } catch { statusMessage = error.localizedDescription }
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func refreshStatus() {
        if let requestedAt = authorizationRequestedAt {
            if let status = try? WebGallerySharedConfiguration.loadStatus(), status.updatedAt >= requestedAt {
                isAuthorizing = status.isAuthorizing
                isRunning = status.isRunning
                statusMessage = status.message
                if !status.isAuthorizing { authorizationRequestedAt = nil }
                return
            }
            return
        }
        guard isEnabled else { return }
        if service.status == .requiresApproval {
            isRunning = false
            statusMessage = "Allow Photo Libraries in System Settings → Login Items & Extensions."
        } else if service.status != .enabled {
            isRunning = false
            statusMessage = "The background login item is disabled. Enable it to resume sharing."
        } else if let status = try? WebGallerySharedConfiguration.loadStatus(),
                  Date.now.timeIntervalSince(status.updatedAt) < 10 {
            isRunning = status.isRunning
            statusMessage = status.message
        } else {
            isRunning = false
            statusMessage = "Waiting for the background gallery. Authorize its libraries if needed."
        }
    }
}
