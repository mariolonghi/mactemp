import Foundation

/// Shared app metadata. Version comes from Info.plist so the build script and
/// the running app can never disagree about it.
enum AppInfo {
    static let name = "MacTemp"
    static let bundleID = "com.mariolonghi.mactemp"
    static let website = URL(string: "https://mariolonghi.com")!

    static let githubRepo = "mariolonghi/mactemp"
    static let releasesURL = URL(string: "https://github.com/\(githubRepo)/releases/latest")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!

    /// Pinned signer: self-update only ever installs builds signed by us.
    static let teamID = "ZWXAL8XA46"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// True when running as MacTemp.app (vs. a bare development binary).
    static var isBundled: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// The .app bundle path when bundled, else the executable's directory.
    static var bundlePath: String {
        Bundle.main.bundlePath
    }

    /// "1.0.0" -> [1, 0, 0]; tolerant of a leading v and odd parts.
    static func versionTuple(_ tag: String) -> [Int] {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == "v" || $0 == "V" })
        let parts = trimmed.split(separator: ".").map { part in
            Int(part.filter(\.isNumber)) ?? 0
        }
        return parts.isEmpty ? [0] : parts
    }

    /// True when `latest` is strictly newer than `current` (semver-ish compare).
    static func isNewer(latest: String, than current: String) -> Bool {
        let a = versionTuple(latest), b = versionTuple(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
