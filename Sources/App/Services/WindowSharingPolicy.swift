import AppKit
import SwiftUI

enum WindowSharingPolicy {
    static func sharingType(isLocked: Bool, hideFromScreenSharing: Bool, sessionException: Bool) -> NSWindow.SharingType {
        (isLocked || (hideFromScreenSharing && !sessionException)) ? .none : .readOnly
    }
}

/// Gives a SwiftUI scene access to its own NSWindow after attachment.
private struct WindowAccessor: NSViewRepresentable {
    let update: (NSWindow) -> Void

    final class WindowView: NSView {
        var update: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { update?(window) }
        }
    }

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView(frame: .zero)
        view.update = update
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.update = update
        if let window = view.window { update(window) }
    }
}

struct WindowSharingCover: ViewModifier {
    @ObservedObject var appLock: AppLock
    @ObservedObject var settings: AppSettings

    func body(content: Content) -> some View {
        content.background(WindowAccessor { window in
            window.sharingType = WindowSharingPolicy.sharingType(
                isLocked: appLock.isLocked,
                hideFromScreenSharing: settings.hideFromScreenSharing,
                sessionException: settings.allowScreenSharingThisSession
            )
        }.frame(width: 0, height: 0))
    }
}
