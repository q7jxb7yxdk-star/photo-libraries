# Photo Libraries

## Project Overview

Photo Libraries is a macOS photo library browser. It lets users view the system Photos library and selected `.photoslibrary` packages in one window, browse by date, album, and media type, and copy or move photos after explicit confirmation. The app creates search indexes and preview data in its own storage. Direct access to registered libraries, transfers, and web sharing have the compatibility and environment limits described below.

## Features and Status

- **Implemented in source**: Browse the system library through PhotoKit; build catalogs for authorized non-system library packages; display albums, thumbnails, photos and videos, information panels, cross-library search, maps, and metadata-derived Memories suggestions.
- **Implemented in source**: Copy from the system library to a registered library or from a registered library to the system library. Moves separately verify the destination and require confirmation before deleting the source. Transfers are not transactional and may not preserve every edit history or compound media resource.
- **Optional; externally unverified**: Web Gallery can attempt to start with the app, or be started and stopped in Settings, after a `*.ts.net` Serve host, an allowed Tailscale login, and at least one shared library are configured. It listens only on local `127.0.0.1:8766`. External HTTPS, identity headers, and reachability depend on separately configured Tailscale Serve. The Apple Maps web map also requires an optional MapKit JS token and network access.
- **Experimental / inactive**: The standalone probes in `PoC/` are outside the app target. The old catalog and preview indexing path in `PhotosAutomationClient` remains in source, but normal app startup now uses direct reading. Do not treat these paths as verified normal functionality.

“Implemented in source” describes the source code only; it **does not mean this task compiled the app or verified it on a device**. See the [technical documentation](TECHNICAL_DOCUMENTATION.md) for implementation details.

## Requirements

- The macOS app and embedded `PhotoLibrariesDirectHelper` target both set `MACOSX_DEPLOYMENT_TARGET = 27.0`, `SUPPORTED_PLATFORMS = macosx`, and `SWIFT_VERSION = 5.0`. There is no supported iOS target.
- Use Xcode with the corresponding macOS SDK and support for opening `Photo Libraries.xcodeproj`. The project records Xcode tool version 26.3 but **does not declare a minimum Xcode version**; this task did not verify which Xcode version can build it.
- The Swift app and helper use Apple system frameworks and SQLite3. No Swift Package Manager, CocoaPods, or other third-party app dependencies are declared, and there is no package lockfile.
- `Tools/generate_memory_music.py` needs Python 3, NumPy, and macOS `afconvert` only when regenerating the bundled music assets. Python and NumPy versions are not pinned; normal app use does not require running this tool.

## Installation / Setup

1. After obtaining the repository, run `open "Photo Libraries.xcodeproj"` from its root, or open the project in Xcode.
2. In Xcode, select the macOS app target `Photo Libraries` as the runnable and choose Debug or Release. `PhotoLibrariesDirectHelper` is an app target dependency and embedded tool. The repository does not include a separately committed shared `.xcscheme`; use the scheme shown by your local Xcode installation.
3. Use your own developer signing configuration. The project currently uses Automatic signing and specifies a development team; that value is not a portable credential or a signing guarantee. Grant the permissions requested by macOS when authorizing the system Photos library or selecting a `.photoslibrary` package.
4. To use Web Gallery, enter your `<your-mac>.ts.net` host (including any nonstandard HTTPS port), an allowed Tailscale login, and the shared libraries in **Settings → Web Gallery**. Configure Tailscale Serve separately to proxy local `127.0.0.1:8766`; do not use Funnel for this feature. A MapKit JS token for the web map is optional and can be entered on the same screen.

When browsing Web Gallery on a phone in landscape orientation, opening a thumbnail lets the photo use the entire available web viewport. Info is hidden by default; tap ⓘ to show or hide its vertically scrolling panel. Safari controls its own tabs and toolbars, so the page cannot guarantee that they remain hidden in a Safari tab. To avoid Safari tabs, choose **Share → Add to Home Screen** in iPhone Safari, enable **Open as Web App**, and launch from the Home Screen icon. The system status bar or Home indicator may still appear. In Home Screen mode, the page places a solid background in the status bar safe area without pushing the web content down further. Its effect on iOS blur still needs device verification. See the [Apple iPhone User Guide](https://support.apple.com/guide/iphone/iphea86e5236/ios) for the Home Screen steps.

The repository has no `.env`, sample environment variables, API key or credential files, dependency installation steps, or reproducible package manager commands. Web Gallery settings and the Maps token are stored in `UserDefaults`, not environment variables or Keychain.

## How to Run

Select the macOS app runnable in Xcode and perform Build/Run yourself. The app can open its local browsing interface without Web Gallery configured. Actual library content, Photos permissions, non-system package formats, and media that may need downloading depend on the Mac. External Web Gallery access requires the app and Mac to stay running and Tailscale Serve to be configured separately. The repository has no separate backend, offline demo fixture, or command-line build/run instructions backed by a committed shared scheme.

## Development

There is currently no committed test target, CI, lint, format, typecheck, or fixture validation command. Code in `PoC/` is outside the normal build. The original command for the music generator is `python3 Tools/generate_memory_music.py`; it rewrites music assets and should run only when regeneration is intended. This task performed documentation and static source checks only; **no macOS Build/Test was run**.

## Project Structure

| Path | Purpose |
| --- | --- |
| `Photo Libraries/` | SwiftUI app, models, library registration, PhotoKit, search, Memories, views, and Web Gallery. |
| `DirectLibraryHelper/` | Embedded helper entry point, cross-process data models, and sandbox entitlement. |
| `Photo Libraries.xcodeproj/` | Xcode targets, build settings, and project configuration. |
| `PoC/` | Experimental probes outside the app target. |
| `Tools/` | Tool for manually generating Memories music assets. |

## Known Limitations

Media access for non-system libraries uses unpublished PhotoKit selectors, and catalog reading depends on the internal SQLite schema of Apple Photos packages. This documentation task did not verify compatibility across macOS versions, distribution or review outcomes, or behavior with real libraries. Search documents for the system library do not include full caption or keyword text; some media-type filtering is more limited for non-system libraries. Place names, web maps, Tailscale sharing, and remote playback each require their respective system or external support. A failed or canceled transfer may leave destination copies behind; inspect both libraries before retrying or deleting the source.

## License

The repository has no project-wide `LICENSE` or equivalent license statement, so its overall license cannot be inferred. External components, including Apple frameworks, MapKit JS, and NumPy, have their own terms and should be checked separately from this project’s license.
