import AppKit
import SwiftUI

/// Debug-only helper for visual verification without Screen Recording permission.
/// Launch with `-DidoScreenshot /path/to/out.png` (optionally `-DidoAppearance dark`, `-DidoOpen /file`, `-DidoAsk "question"`, `-DidoScreenshotDelay 30`)
/// and the app writes a PNG of its main window after a short delay, then quits.
@MainActor
final class DebugScreenshotDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let appearance = defaults.string(forKey: "DidoAppearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let open = defaults.string(forKey: "DidoOpen") {
            AppState.shared.pendingQuestion = defaults.string(forKey: "DidoAsk")
            AppState.shared.selectFile(URL(fileURLWithPath: open))
        }
        guard let path = defaults.string(forKey: "DidoScreenshot") else { return }
        let delay = max(defaults.double(forKey: "DidoScreenshotDelay"), 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Self.capture(to: path)
            NSApp.terminate(nil)
        }
        #endif
    }

    #if DEBUG
    private static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        let windowID = CGWindowID(window.windowNumber)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
    #endif
}
