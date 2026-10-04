import AppKit

enum WindowCheck {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    /// True when the app has a normal window open on some Space. A closed window still exists but belongs to no Space.
    ///
    /// ponytail: uses two private window-server calls, because the public window list reports "closed" and
    /// "on another Space" identically. If they ever go away this returns true and rows simply stay visible;
    /// the public alternative is the Accessibility API, which needs a permission prompt.
    static func hasOpenWindow(bundleId: String) -> Bool {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).map(\.processIdentifier))
        let handle = dlopen(nil, RTLD_NOW)
        guard !pids.isEmpty,
              let connSym = dlsym(handle, "CGSMainConnectionID"),
              let spacesSym = dlsym(handle, "CGSCopySpacesForWindows"),
              let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return true }

        let ids: [Int] = windows.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  w[kCGWindowLayer as String] as? Int == 0,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Height"] as? Double ?? 0) > 100 else { return nil } // skip menu-bar-sized helper windows
            return w[kCGWindowNumber as String] as? Int
        }
        guard !ids.isEmpty else { return false }

        let connection = unsafeBitCast(connSym, to: MainConnection.self)()
        let allSpaces: Int32 = 7
        let spaces = unsafeBitCast(spacesSym, to: CopySpaces.self)(connection, allSpaces, ids as CFArray)?
            .takeRetainedValue() as? [Any] ?? []
        return !spaces.isEmpty
    }
}
