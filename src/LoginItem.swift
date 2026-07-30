import Foundation

/// Launch-at-login via a per-user LaunchAgent — a plist in
/// ~/Library/LaunchAgents. No admin rights needed. We deliberately do NOT
/// `launchctl load` when enabling, because the app is already running and a
/// RunAtLoad agent would spawn a duplicate; the file alone starts it next login.
///
/// Enabled by default: the first bundled run writes the agent. The menu toggle
/// records the user's choice in UserDefaults, and `applyAtStartup` refreshes
/// the plist each launch so it tracks the app if the bundle is moved.
enum LoginItem {

    private static let prefKey = "launchAtLogin"

    private static var plistPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(AppInfo.bundleID).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath.path)
    }

    /// Called once at app start. Applies the default (on) unless the user has
    /// explicitly turned it off, and refreshes the plist's path.
    static func applyAtStartup() {
        guard AppInfo.isBundled else { return }   // never point launchd at a dev binary
        let defaults = UserDefaults.standard
        let wanted = defaults.object(forKey: prefKey) as? Bool ?? true
        if wanted { enable() } else { disable() }
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: prefKey)
        if enabled { enable() } else { disable() }
    }

    private static func enable() {
        guard AppInfo.isBundled else { return }
        do {
            try FileManager.default.createDirectory(
                at: plistPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plistXML().write(to: plistPath, atomically: true, encoding: .utf8)
        } catch {
            NSLog("LoginItem: couldn't write \(plistPath.path): \(error)")
        }
    }

    private static func disable() {
        guard isEnabled else { return }
        // Unload if it happens to be registered, then remove the file.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unload", plistPath.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: plistPath)
    }

    private static func plistXML() -> String {
        // Launch via `open` so macOS treats it as a proper app activation.
        // XML-escape the path: one containing & or < would otherwise produce a
        // malformed plist that launchd silently refuses to load.
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(AppInfo.bundleID)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>\(escape(AppInfo.bundlePath))</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
    }
}
