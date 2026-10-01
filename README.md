# Photo Libraries

## Project Overview

Photo Libraries is a macOS photo library browser. It lets users view the system Photos library and selected `.photoslibrary` packages in one window, browse by date, album, and media type, and copy or move photos after explicit confirmation. The app creates search indexes and preview data in its own storage. Direct access to registered libraries, transfers, and web sharing have the compatibility and environment limits described below.

## Features and Status

- **Implemented in source**: Browse the system library through PhotoKit; build catalogs for authorized non-system library packages; display albums, thumbnails, photos and videos, information panels, cross-library search, maps, and metadata-derived Memories suggestions.
- **Implemented in source**: Copy from the system library to a registered library or from a registered library to the system library. Moves separately verify the destination and require confirmation before deleting the source. Transfers are not transactional and may not preserve every edit history or compound media resource.
- **Optional; runtime unverified**: Web Gallery runs in the embedded `PhotoLibrariesWebGallery.app` login item, independently of the main app. Configure a `*.ts.net` Serve host, allowed Tailscale logins, and shared libraries, authorize the helper, then enable sharing at login in Settings. It listens only on local `127.0.0.1:8766`. External HTTPS, identity headers, and reachability depend on separately configured Tailscale Serve. The Apple Maps web map also requires an optional MapKit JS token and network access.
- **Experimental / inactive**: The standalone probes in `PoC/` are outside the app target. The old catalog and preview indexing path in `PhotosAutomationClient` remains in source, but normal app startup now uses direct reading. Do not treat these paths as verified normal functionality.

“Implemented in source” describes the source code only; it **does not mean this task compiled the app or verified it on a device**. See the [technical documentation](TECHNICAL_DOCUMENTATION.md) for implementation details.

## Requirements

- The `Photo Libraries`, `PhotoLibrariesWebGallery`, and `PhotoLibrariesDirectHelper` targets all set `MACOSX_DEPLOYMENT_TARGET = 27.0`, `SUPPORTED_PLATFORMS = macosx`, and `SWIFT_VERSION = 5.0`. There is no supported iOS target.
- Use Xcode with the corresponding macOS SDK and support for opening `Photo Libraries.xcodeproj`. The project records Xcode tool version 26.3 but **does not declare a minimum Xcode version**; this task did not verify which Xcode version can build it.
- The Swift app and helper use Apple system frameworks and SQLite3. No Swift Package Manager, CocoaPods, or other third-party app dependencies are declared, and there is no package lockfile.
- `Tools/generate_memory_music.py` needs Python 3, NumPy, and macOS `afconvert` only when regenerating the bundled music assets. Python and NumPy versions are not pinned; normal app use does not require running this tool.

## Installation / Setup

1. After obtaining the repository, run `open "Photo Libraries.xcodeproj"` from its root, or open the project in Xcode.
2. In Xcode, select the macOS app target `Photo Libraries` as the runnable and choose Debug or Release. The main target depends on the `PhotoLibrariesWebGallery` login-item app and the `PhotoLibrariesDirectHelper` tool, and embeds both. The login-item app also embeds the direct-library tool. The repository does not include a separately committed shared `.xcscheme`; use the scheme shown by your local Xcode installation.
3. Use your own developer signing configuration. The project currently uses Automatic signing and specifies a development team; that value is not a portable credential or a signing guarantee. Grant the permissions requested by macOS when authorizing the system Photos library or selecting a `.photoslibrary` package.
4. Both app targets must be signed with the same team and the App Group `WX793X49GJ.com.sunny.photo-libraries.web-gallery`. If using another team, update the group identifier in both entitlements and `WebGallerySharedConfiguration.swift`. The main target builds and embeds the login-item app and its direct-library helper. Place the built main app in a stable location, such as Applications, before enabling its login item.
5. To use Web Gallery, enter your `<your-mac>.ts.net` host (including any nonstandard HTTPS port), allowed Tailscale logins, and shared libraries in **Settings → Web Gallery**. Click **Authorize Background Libraries…** first. For each non-system library, select the requested `.photoslibrary` at the displayed path; this grants only the background helper read access. The System Photo Library does not need another package selection: grant the helper its separate macOS Photos permission if prompted. Cancelled or missing grants leave those libraries unavailable. Normal login does not show permission dialogs.
6. Click **Start Sharing at Login**. If macOS requires approval, use **Login Item Settings…** to allow it. You can now quit the main app; after each Mac login the helper serves the gallery independently. **Stop Sharing** disables sharing and unregisters the login item. Multiple non-system libraries can be shared. After adding a library in the main app, select it under **Shared libraries** and authorize the helper again; valid existing grants are skipped. Reauthorize changed paths or stale grants as well. Configuration changes are polled every two seconds; in-flight requests are cancelled when the helper applies the change.
7. Configure Tailscale Serve separately to proxy local `127.0.0.1:8766`; do not use Funnel for this feature. A MapKit JS token for the web map is optional and can be entered on the same screen. Keep the Mac awake, logged in, and the source disks mounted. Enabling the helper does not configure Tailscale or change sleep settings.

### Network access and sign-in

The current gallery uses [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve), so the viewing device needs access to the tailnet, normally through an installed and signed-in Tailscale client. Signing in to the Tailscale website in an ordinary browser does not join that device to the private network. A company computer that cannot install Tailscale cannot use this setup directly unless its network already provides a permitted route to the tailnet.

[Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel) can expose a service to public browsers without installing Tailscale on the viewing device, but Funnel does not add a visitor login page. The current gallery requires a trusted `tailscale-user-login` header and has no independent browser login/session mechanism, so **Funnel is not supported by this implementation**. Public access would require a separately integrated authentication layer and corresponding host, session, and authorization changes before exposure. Tailscale's [tsidp](https://tailscale.com/blog/building-tsidp) keeps its user authorization endpoint tailnet-only, so it does not by itself remove the viewing device's tailnet requirement.

The HTTPS port exposed by Serve can differ from the local backend port. For example, a configured public-facing tailnet URL ending in `:8767` must proxy to `http://127.0.0.1:8766`; do not change the backend port just to match the URL. The **Tailscale Serve host** field must match the actual hostname and HTTPS port. A running local listener does not establish that the Serve route, DNS, or remote browser connection works.

When browsing Web Gallery on a phone in landscape orientation, opening a thumbnail lets the photo use the entire available web viewport. Info is hidden by default; tap ⓘ to show or hide its vertically scrolling panel. Safari controls its own tabs and toolbars, so the page cannot guarantee that they remain hidden in a Safari tab. To avoid Safari tabs, choose **Share → Add to Home Screen** in iPhone Safari, enable **Open as Web App**, and launch from the Home Screen icon. The system status bar or Home indicator may still appear. In Home Screen mode, the page places a solid background in the status bar safe area without pushing the web content down further. Its effect on iOS blur still needs device verification. See the [Apple iPhone User Guide](https://support.apple.com/guide/iphone/iphea86e5236/ios) for the Home Screen steps.

The repository has no `.env`, sample environment variables, API key or credential files, dependency installation steps, or reproducible package manager commands. Web Gallery settings and the Maps token remain in the main app’s `UserDefaults`; selected sharing settings and sanitized library identities are also published to `configuration.json` in the signed App Group. Main-app bookmarks and transfer write grants are never exported. Helper-owned read-only bookmarks stay in its own `UserDefaults`, and its catalog/preview/search caches stay in its own sandbox. The Maps token is not stored in Keychain.

## How to Run

Select the macOS app runnable in Xcode and perform Build/Run yourself. The app can open its local browsing interface without Web Gallery configured. Actual library content, Photos permissions, non-system package formats, and media that may need downloading depend on the Mac. External Web Gallery access requires the background login item and Mac to stay running and Tailscale Serve to be configured separately. The main app can be closed. The repository has no offline demo fixture or command-line build/run instructions backed by a committed shared scheme. Static checks do not verify login-item registration, TCC permission attribution, signing, or external reachability. A local diagnostic snapshot observed the gallery listening on `127.0.0.1:8766`; the external HTTPS URL was not verified. Validate startup after login and access from each viewing device manually.

## Development

There is currently no committed test target, CI, lint, format, typecheck, or fixture validation command. Code in `PoC/` is outside the normal build. The original command for the music generator is `python3 Tools/generate_memory_music.py`; it rewrites music assets and should run only when regeneration is intended. This task performed documentation and static source checks only; **no macOS Build/Test was run**.

## Project Structure

| Path | Purpose |
| --- | --- |
| `Photo Libraries/` | SwiftUI app, models, library registration, PhotoKit, search, Memories, views, and Web Gallery. |
| `DirectLibraryHelper/` | Embedded helper entry point, cross-process data models, and inherited sandbox entitlement. |
| `WebGalleryHelper/` | Independent login-item app entry point, explicit Photos/package authorization, configuration polling, and sandbox entitlements. |
| `Photo Libraries.xcodeproj/` | Xcode targets, build settings, and project configuration. |
| `PoC/` | Experimental probes outside the app target. |
| `Tools/` | Tool for manually generating Memories music assets. |

## Known Limitations

Media access for non-system libraries uses unpublished PhotoKit selectors, and catalog reading depends on the internal SQLite schema of Apple Photos packages. This documentation task did not verify compatibility across macOS versions, distribution or review outcomes, or behavior with real libraries. Search documents for the system library do not include full caption or keyword text; some media-type filtering is more limited for non-system libraries. Place names, web maps, Tailscale sharing, and remote playback each require their respective system or external support. A failed or canceled transfer may leave destination copies behind; inspect both libraries before retrying or deleting the source.

## License

The repository has no project-wide `LICENSE` or equivalent license statement, so its overall license cannot be inferred. External components, including Apple frameworks, MapKit JS, and NumPy, have their own terms and should be checked separately from this project’s license.
