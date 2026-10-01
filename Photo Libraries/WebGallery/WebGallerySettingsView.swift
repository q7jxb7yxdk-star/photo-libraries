import AppKit
import SwiftUI

struct WebGallerySettingsView: View {
    @ObservedObject var server: WebGalleryServer
    @ObservedObject var registry: LibraryRegistry
    @ObservedObject var systemModel: SystemPhotoLibraryViewModel
    @ObservedObject var store: LibraryPreviewStore
    @State private var loginInput = ""
    @ObservedObject private var backgroundService = WebGalleryBackgroundService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Web Gallery").font(.title2.bold())
            }

            Text("Share selected libraries for viewing through Tailscale Serve. The website only accepts named Tailscale users and offers no edit, move, or delete actions.")
                .foregroundStyle(.secondary)
            Text("Configure Tailscale Serve on this Mac to proxy 127.0.0.1:\(WebGalleryServer.port), then enter its *.ts.net hostname and HTTPS port, if shown. Share this Mac with each recipient using their own Tailscale account.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                TextField("Tailscale Serve host (example.ts.net:10000)", text: $server.expectedHost)
                    .textContentType(.URL)
                LabeledContent("Local service") {
                    Text("127.0.0.1:\(WebGalleryServer.port)")
                        .textSelection(.enabled)
                }

                Section("Apple Maps for the web") {
                    SecureField("MapKit JS Maps token", text: $server.mapsToken)
                    Text("Create a MapKit JS token restricted to \(mapsTokenHost), without https:// or the port. Use a Maps token, not a private key. Authorized visitors' browsers connect to Apple Maps for map imagery.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("How to create a Maps token", destination: URL(string: "https://developer.apple.com/documentation/mapkitjs/creating-a-maps-token")!)
                }

                Section("Allowed Tailscale logins") {
                    HStack {
                        TextField("name@example.com", text: $loginInput)
                            .onSubmit(addLogin)
                        Button("Add", action: addLogin)
                    }
                    ForEach(server.allowedLogins, id: \.self) { login in
                        HStack {
                            Text(login).textSelection(.enabled)
                            Spacer()
                            Button("Remove") { server.removeLogin(login) }
                        }
                    }
                }

                Section("Shared libraries") {
                    ForEach(registry.libraries) { library in
                        Toggle(isOn: Binding(
                            get: { server.sharedLibraryIDs.contains(library.id) },
                            set: { server.setShared($0, libraryID: library.id) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.descriptor.metadata.displayName)
                                Text(library.descriptor.kind.isSystemPhotoLibrary
                                    ? "System Photo Library · hidden photos excluded"
                                    : "Registered library · cached snapshot, refresh in Photos to update")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Text("Starting the gallery shares previews from the selected libraries. Recipients can save or screenshot photos they view. Keep the Mac awake and logged in; the background service runs independently of the main app. Configure Tailscale Serve separately and never use Funnel for this gallery.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("First authorize the background helper, then start sharing at login. Select the same shared library packages when prompted. The helper has its own Photos permission and read-only file grants; your main app permissions and caches are kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Authorize Background Libraries…") { backgroundService.authorizeLibraries() }
                    .disabled(backgroundService.isAuthorizing)
                Button("Login Item Settings…") { backgroundService.openLoginSettings() }
            }

            HStack {
                Text(backgroundService.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if backgroundService.isEnabled {
                    Button("Stop Sharing", role: .destructive) { backgroundService.disable() }
                } else {
                    Button("Start Sharing at Login") {
                        backgroundService.enable()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(backgroundService.isAuthorizing)
                }
            }
        }
        .onAppear { backgroundService.configure(registry: registry, server: server) }
        .padding(24)
        .frame(width: 620, height: preferredHeight)
    }

    private var preferredHeight: CGFloat {
        let additionalLogins = max(0, server.allowedLogins.count - 1)
        let additionalLibraries = max(0, registry.libraries.count - 2)
        let contentHeight = 850 + CGFloat(additionalLogins * 34 + additionalLibraries * 52)
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        return min(contentHeight, max(420, screenHeight - 48))
    }

    private var mapsTokenHost: String {
        let hostname = server.expectedHost.split(separator: ":").first.map(String.init) ?? ""
        return hostname.isEmpty ? "your Mac's *.ts.net hostname" : hostname
    }

    private func addLogin() {
        server.addLogin(loginInput)
        loginInput = ""
    }
}
