import Foundation

// MARK: - Version check
//
// Asks GitHub Releases whether a newer version exists. A plain GET to the
// public API — no user data, no auth. Results are cached so re-opening the
// menu doesn't re-hit the network.

struct UpdateStatus {
    let current: String
    let latest: String?
    let releaseURL: URL
    let dmgURL: URL?        // direct .dmg download (enables one-click update)
    let error: String?

    var available: Bool {
        guard let latest else { return false }
        return AppInfo.isNewer(latest: latest, than: current)
    }
}

final class UpdateChecker {
    private let cacheTTL: TimeInterval = 600
    private var cached: (at: Date, status: UpdateStatus)?
    private var inFlight = false
    private let lock = NSLock()

    /// Runs the check off the main thread; `completion` is called on the main
    /// queue. Coalesces concurrent calls and serves a fresh-enough cache.
    func check(force: Bool = false, completion: @escaping (UpdateStatus) -> Void) {
        lock.lock()
        if !force, let cached, Date().timeIntervalSince(cached.at) < cacheTTL {
            lock.unlock()
            DispatchQueue.main.async { completion(cached.status) }
            return
        }
        if inFlight {
            lock.unlock()
            return   // a check is already running; menu will pick up its result
        }
        inFlight = true
        lock.unlock()

        var request = URLRequest(url: AppInfo.latestReleaseAPI, timeoutInterval: 5)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacTemp/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = Self.parse(data: data, response: response, error: error)
            if let self {
                self.lock.lock()
                self.cached = (Date(), status)
                self.inFlight = false
                self.lock.unlock()
            }
            DispatchQueue.main.async { completion(status) }
        }.resume()
    }

    private static func parse(data: Data?, response: URLResponse?, error: Error?) -> UpdateStatus {
        func failed(_ message: String) -> UpdateStatus {
            UpdateStatus(current: AppInfo.version, latest: nil,
                         releaseURL: AppInfo.releasesURL, dmgURL: nil, error: message)
        }
        if let error { return failed(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data, data.count < 2 * 1024 * 1024,   // release JSON is a few KB
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return failed("unexpected response") }

        var tag = (json["tag_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if tag.lowercased().hasPrefix("v") { tag.removeFirst() }

        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.lowercased().hasSuffix(".dmg") }
            .flatMap { URL(string: $0) }

        let page = (json["html_url"] as? String).flatMap { URL(string: $0) }
        return UpdateStatus(current: AppInfo.version, latest: tag.isEmpty ? nil : tag,
                            releaseURL: page ?? AppInfo.releasesURL, dmgURL: dmg, error: nil)
    }
}

// MARK: - One-click self-update
//
// Safety model (the whole thing hinges on this):
//   * HTTPS download from GitHub only (host allow-list, defense-in-depth).
//   * Before anything is installed, the downloaded app must pass THREE checks:
//       1. codesign --verify --deep --strict  — signature intact
//       2. spctl -a -t exec                   — notarized / Gatekeeper-accepted
//       3. TeamIdentifier == AppInfo.teamID   — signed by US, not just anyone
//     A tampered or fake "update" therefore cannot be installed.
//   * The swap helper moves the old bundle aside and restores it on failure,
//     so an interrupted update never leaves a missing app.

enum UpdateError: LocalizedError {
    case notPossible(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notPossible(let why): return "Self-update isn't possible: \(why)"
        case .failed(let why): return why
        }
    }
}

enum SelfUpdater {

    private static let maxDownloadBytes = 200 * 1024 * 1024   // sanity cap; our DMG is < 1 MB

    /// Whether an in-place self-update can apply in this run.
    static func canSelfUpdate() -> (ok: Bool, why: String) {
        guard AppInfo.isBundled else { return (false, "running unbundled") }
        let app = AppInfo.bundlePath
        let parent = (app as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: app),
              FileManager.default.isWritableFile(atPath: parent)
        else { return (false, "the install location isn't writable") }
        return (true, "")
    }

    /// Download → verify → stage → spawn swap helper. Blocking; call from a
    /// background queue. On success the caller MUST terminate the app so the
    /// helper can replace and relaunch it.
    static func performUpdate(from dmgURL: URL) throws {
        let (ok, why) = canSelfUpdate()
        guard ok else { throw UpdateError.notPossible(why) }

        try checkURL(dmgURL)

        let workdir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mactemp-update-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)

        do {
            let dmg = workdir.appendingPathComponent("update.dmg")
            try download(dmgURL, to: dmg)

            let mount = try mountDMG(dmg)
            defer { unmountDMG(mount) }

            let newApp = try findApp(in: mount)
            try verifyApp(newApp)

            let staged = workdir.appendingPathComponent(newApp.lastPathComponent)
            try run("/usr/bin/ditto", [newApp.path, staged.path],
                    orThrow: "couldn't stage the update")

            try spawnSwapHelper(staged: staged,
                                target: URL(fileURLWithPath: AppInfo.bundlePath),
                                waitPID: ProcessInfo.processInfo.processIdentifier,
                                workdir: workdir)
        } catch {
            try? FileManager.default.removeItem(at: workdir)
            throw error
        }
    }

    // MARK: internals

    /// HTTPS + GitHub hosts only (defense-in-depth; verifyApp is the real gate).
    private static func checkURL(_ url: URL) throws {
        let host = (url.host ?? "").lowercased()
        let allowed = host == "github.com" || host.hasSuffix(".githubusercontent.com")
        guard url.scheme == "https", allowed else {
            throw UpdateError.failed("unexpected update URL, refusing to download")
        }
    }

    private static func download(_ url: URL, to dest: URL) throws {
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.setValue("MacTemp/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URL, Error> = .failure(UpdateError.failed("download did not complete"))
        let task = URLSession.shared.downloadTask(with: request) { tmp, response, error in
            defer { semaphore.signal() }
            if let error { result = .failure(error); return }
            guard let tmp,
                  let http = response as? HTTPURLResponse, http.statusCode == 200
            else { result = .failure(UpdateError.failed("download failed")); return }
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
                result = .success(dest)
            } catch { result = .failure(error) }
        }
        task.resume()
        semaphore.wait()

        let file = try result.get()
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size > 0, size <= maxDownloadBytes else {
            throw UpdateError.failed("update download has an unexpected size")
        }
    }

    private static func mountDMG(_ dmg: URL) throws -> URL {
        let out = try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen"],
                          orThrow: "couldn't open the update image")
        for line in out.split(separator: "\n") {
            let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if let volume = fields.last, volume.hasPrefix("/Volumes/") {
                return URL(fileURLWithPath: volume)
            }
        }
        throw UpdateError.failed("couldn't find the mounted update volume")
    }

    private static func unmountDMG(_ mount: URL) {
        _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"], orThrow: "")
    }

    private static func findApp(in mount: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = entries.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.failed("no application found inside the update")
        }
        return app
    }

    /// Reject anything that isn't a valid, notarized app signed by our Team ID.
    static func verifyApp(_ app: URL) throws {
        guard (try? run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
                        orThrow: "")) != nil else {
            throw UpdateError.failed("the download's code signature is invalid")
        }
        guard (try? run("/usr/sbin/spctl", ["-a", "-t", "exec", app.path], orThrow: "")) != nil else {
            throw UpdateError.failed("the download isn't notarized / accepted by macOS")
        }
        let details = (try? run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path],
                                orThrow: "", mergeStderr: true)) ?? ""
        guard details.contains("TeamIdentifier=\(AppInfo.teamID)") else {
            throw UpdateError.failed("the download isn't signed by the expected developer")
        }
    }

    /// Detached helper: wait for us to quit, swap the bundle, relaunch, clean up.
    private static func spawnSwapHelper(staged: URL, target: URL, waitPID: Int32,
                                        workdir: URL) throws {
        func q(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let script = """
        #!/bin/bash
        target=\(q(target.path))
        staged=\(q(staged.path))
        workdir=\(q(workdir.path))
        # wait (up to ~15s) for the running app to exit
        for i in $(seq 1 150); do kill -0 \(waitPID) 2>/dev/null || break; sleep 0.1; done
        sleep 0.3
        rm -rf "$target.old" 2>/dev/null
        if mv "$target" "$target.old" 2>/dev/null; then
          if ditto "$staged" "$target"; then
            xattr -dr com.apple.quarantine "$target" 2>/dev/null
            rm -rf "$target.old"
          else
            # restore on failure
            rm -rf "$target"; mv "$target.old" "$target"
          fi
        fi
        open "$target"
        rm -rf "$workdir"
        """
        let helper = workdir.appendingPathComponent("swap.sh")
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helper.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()   // not waited on — it outlives us by design
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String],
                            orThrow message: String, mergeStderr: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergeStderr ? pipe : Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.failed(message.isEmpty ? "\(tool) failed" : message)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
