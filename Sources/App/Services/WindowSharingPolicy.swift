import AppKit
import Combine

enum WindowSharingPolicy {
    static func sharingType(isLocked: Bool, hideFromScreenSharing: Bool, sessionException: Bool) -> NSWindow.SharingType {
        (isLocked || (hideFromScreenSharing && !sessionException)) ? .none : .readOnly
    }

    /// Sheets, alerts and popovers are their own windows, drawn above the lock
    /// cover of the window they belong to, so they are hidden while locked.
    /// Save and open panels are left visible: they run modally, show only file
    /// names, and hiding one would leave its modal session with nothing to dismiss.
    static func hidesWhileLocked(isSheet: Bool, isPopover: Bool, isFilePanel: Bool) -> Bool {
        !isFilePanel && (isSheet || isPopover)
    }

    enum LockedEventAction: Equatable {
        case pass
        case drop
        /// A click on a window whose hidden sheet blocks its lock cover.
        case dropAndUnlock
    }

    /// While locked, input to a hidden window is dropped, so nothing can be typed
    /// or pressed in a sheet that can't be seen.
    static func lockedEventAction(
        isLocked: Bool, windowIsHidden: Bool, attachedSheetIsHidden: Bool, isMouseDown: Bool
    ) -> LockedEventAction {
        guard isLocked else { return .pass }
        if windowIsHidden { return .drop }
        if attachedSheetIsHidden && isMouseDown { return .dropAndUnlock }
        return .pass
    }
}

/// Applies the screen-sharing setting to every app window (scenes, the menu-bar
/// panel, sheets, alerts and popovers alike) and, while the app is locked, hides
/// the windows a scene's lock cover can't reach, restoring them on unlock.
@MainActor
final class WindowShield {
    private let appLock: AppLock
    private let settings: AppSettings
    private let windows: () -> [NSWindow]
    private let isOverlay: (NSWindow) -> Bool
    /// Windows hidden for the lock, with the alpha to restore.
    private let hidden = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?

    init(
        appLock: AppLock,
        settings: AppSettings,
        windows: @escaping () -> [NSWindow] = { NSApp?.windows ?? [] },   // NSApp is still nil while the App initializes
        isOverlay: ((NSWindow) -> Bool)? = nil
    ) {
        self.appLock = appLock
        self.settings = settings
        self.windows = windows
        self.isOverlay = isOverlay ?? { WindowShield.isOverlayWindow($0) }
    }

    /// Starts following the lock, the settings and newly shown windows.
    func start() {
        appLock.$isLocked.map { _ in () }
            .merge(with: settings.objectWillChange.map { _ in () })
            .receive(on: DispatchQueue.main)   // both fire before the new value is stored
            .sink { [weak self] in MainActor.assumeIsolated { self?.apply() } }
            .store(in: &cancellables)
        // A sheet or alert becomes key as it appears; any window coming on screen
        // changes its occlusion state; a popover announces itself.
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification, NSPopover.didShowNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.filter(event) ?? event }
        }
        apply()
    }

    func apply() {
        let locked = appLock.isLocked
        let sharing = WindowSharingPolicy.sharingType(
            isLocked: locked,
            hideFromScreenSharing: settings.hideFromScreenSharing,
            sessionException: settings.allowScreenSharingThisSession
        )
        for window in windows() {
            if window.sharingType != sharing { window.sharingType = sharing }
            if locked, isOverlay(window), !isHidden(window) {
                hidden.setObject(NSNumber(value: Double(window.alphaValue)), forKey: window)
                window.alphaValue = 0
            }
        }
        if !locked {
            for case let window as NSWindow in hidden.keyEnumerator().allObjects {
                window.alphaValue = CGFloat(hidden.object(forKey: window)?.doubleValue ?? 1)
            }
            hidden.removeAllObjects()
        }
    }

    func isHidden(_ window: NSWindow) -> Bool { hidden.object(forKey: window) != nil }

    private func filter(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window else { return event }
        let action = WindowSharingPolicy.lockedEventAction(
            isLocked: appLock.isLocked,
            windowIsHidden: isHidden(window),
            attachedSheetIsHidden: window.attachedSheet.map { isHidden($0) } ?? false,
            isMouseDown: event.type == .leftMouseDown
        )
        switch action {
        case .pass: return event
        case .drop: return nil
        case .dropAndUnlock:
            appLock.requestUnlock()
            return nil
        }
    }

    static func isOverlayWindow(_ window: NSWindow) -> Bool {
        WindowSharingPolicy.hidesWhileLocked(
            isSheet: window.sheetParent != nil,
            isPopover: String(describing: type(of: window)).contains("Popover"),
            isFilePanel: window is NSSavePanel
        )
    }
}
