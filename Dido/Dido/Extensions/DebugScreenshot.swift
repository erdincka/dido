import AppKit
import SwiftUI

/// Debug-only helper for visual verification without Screen Recording permission.
/// Launch with `-DidoScreenshot /path/to/out.png` (optionally `-DidoAppearance dark`, `-DidoOpen /file`, `-DidoAsk "question"`, `-DidoShowSettings YES`, `-DidoShowDashboard YES`, `-DidoSearch text`, `-DidoOpenFirstSource YES`, `-DidoScreenshotDelay 30`); `-DidoOpen library` opens the whole-library chat
/// and the app writes a PNG of its main window after a short delay, then quits.
@MainActor
final class DebugScreenshotDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let appearance = defaults.string(forKey: "DidoAppearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if defaults.bool(forKey: "DidoShowSettings") {
            AppState.shared.showingSettings = true
        }
        if defaults.bool(forKey: "DidoShowDashboard") {
            AppState.shared.showDashboard()
        }
        if let search = defaults.string(forKey: "DidoSearch") {
            AppState.shared.searchText = search
        }
        if let open = defaults.string(forKey: "DidoOpen") {
            AppState.shared.pendingQuestion = defaults.string(forKey: "DidoAsk")
            if open == "library" {
                AppState.shared.askLibrary()
            } else {
                AppState.shared.selectFile(URL(fileURLWithPath: open))
            }
        }
        guard let path = defaults.string(forKey: "DidoScreenshot") else { return }
        let delay = max(defaults.double(forKey: "DidoScreenshotDelay"), 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // A fixed on-screen frame keeps captures comparable and avoids windows that straddle displays.
            if let window = NSApp.mainWindow ?? NSApp.windows.first, let screen = NSScreen.main {
                let origin = screen.visibleFrame.origin
                window.setFrame(NSRect(x: origin.x + 40, y: origin.y + 40, width: 1380, height: 860), display: true)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Self.capture(to: path)
            NSApp.terminate(nil)
        }
        #endif
    }

    #if DEBUG
    private static func capture(to path: String) {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }) else { return }
        let windowID = CGWindowID(window.windowNumber)
        var bitmap: NSBitmapImageRep?
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) {
            let candidate = NSBitmapImageRep(cgImage: image)
            if !isBlank(candidate) { bitmap = candidate }
        }
        if bitmap == nil, let view = window.contentView, let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            // The window image is empty when the screen is locked or asleep; render the view hierarchy instead.
            view.cacheDisplay(in: view.bounds, to: cached)
            bitmap = cached
        }
        guard let png = bitmap?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// True when a sparse sample of pixels is all one colour.
    private static func isBlank(_ bitmap: NSBitmapImageRep) -> Bool {
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        guard width > 0, height > 0, let first = bitmap.colorAt(x: 0, y: 0) else { return true }
        for y in stride(from: 0, to: height, by: max(height / 12, 1)) {
            for x in stride(from: 0, to: width, by: max(width / 12, 1)) {
                if let colour = bitmap.colorAt(x: x, y: y), colour != first { return false }
            }
        }
        return true
    }
    #endif
}
