import AppKit
import SwiftUI

/// Fills each newly-created app window to the current display's visible frame
/// once. This is a maximized regular window, not macOS full-screen mode.
struct WindowInitialFillView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        InitialWindowFillNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class InitialWindowFillNSView: NSView {
    private var didFillWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didFillWindow, let window else { return }
        didFillWindow = true

        DispatchQueue.main.async { [weak window] in
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            window.setFrame(screen.visibleFrame, display: true, animate: false)
        }
    }
}
